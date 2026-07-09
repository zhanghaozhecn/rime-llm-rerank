/*
 * rime_llm.cpp — RIME LLM 候选重排 C++ 插件 (CPU)
 * 编译: cmake -G "Visual Studio 17 2022" -A x64 -S . -B build
 *        cmake --build build --config Release
 * Lua:  require("rime_llm") → llm.score(ctx, cands)
 */

#define NOMINMAX
#include <windows.h>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#include "llama.h"

#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <atomic>
#include <cmath>
#include <cstring>
#include <cstdarg>
#include <algorithm>

// ============================================================
// 配置默认值
// ============================================================
static std::string  g_model_path      = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static int          g_min_tokens      = 1;
static int          g_max_ctx_tokens  = 6;
static int          g_n_threads       = std::thread::hardware_concurrency();
static int          g_n_ctx           = 64;
static int          g_n_seq_max       = 9;

// ============================================================
// 模型状态
// ============================================================
static llama_model        * g_model   = nullptr;
static llama_context      * g_ctx     = nullptr;
static const llama_vocab  * g_vocab   = nullptr;
static std::mutex           g_mutex;
static std::atomic<bool>    g_loaded{false};
static std::atomic<bool>    g_loading{false};
static std::vector<double>      g_last_scores;
static std::vector<std::string> g_last_cands;

// ============================================================
// 轻量日志
// ============================================================
static void log_msg(const char * fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    char path[MAX_PATH];
    GetTempPathA(sizeof(path), path);
    strcat_s(path, sizeof(path), "rime_llm_log.txt");
    FILE * f = fopen(path, "a");
    if (f) { fprintf(f, "%s\n", buf); fclose(f); }
}

// ============================================================
// 异步模型加载
// ============================================================
static void load_model_async() {
    if (g_loaded.load() || g_loading.load()) return;
    g_loading.store(true);

    std::thread([]() {
        log_msg("loading model: %s", g_model_path.c_str());

        llama_backend_init();

        llama_model_params mparams = llama_model_default_params();
        mparams.use_mmap = 1;

        g_model = llama_model_load_from_file(g_model_path.c_str(), mparams);
        if (!g_model) {
            log_msg("ERROR: failed to load model");
            g_loading.store(false);
            return;
        }
        g_vocab = llama_model_get_vocab(g_model);

        llama_context_params cparams = llama_context_default_params();
        cparams.n_ctx           = g_n_ctx;
        cparams.n_threads       = g_n_threads;
        cparams.n_threads_batch = g_n_threads;
        cparams.n_seq_max       = g_n_seq_max;

        g_ctx = llama_new_context_with_model(g_model, cparams);
        if (!g_ctx) {
            log_msg("ERROR: failed to create context");
            llama_model_free(g_model);
            g_model = nullptr;
            g_loading.store(false);
            return;
        }

        // warmup
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            llama_memory_clear(llama_get_memory(g_ctx), true);
            const char * warmup = "\n";
            llama_token tokens[4];
            int n_tokens = llama_tokenize(g_vocab, warmup, (int)strlen(warmup),
                                           tokens, 4, true, true);
            if (n_tokens > 0) {
                llama_batch batch = llama_batch_get_one(tokens, n_tokens);
                llama_decode(g_ctx, batch);
            }
        }

        g_loaded.store(true);
        g_loading.store(false);
        log_msg("model ready (n_ctx=%d threads=%d)", g_n_ctx, g_n_threads);
    }).detach();
}

// ============================================================
// 分词
// ============================================================
static std::vector<llama_token> tokenize(const char * text) {
    std::vector<llama_token> toks(128);
    int n = llama_tokenize(g_vocab, text, (int)strlen(text),
                            toks.data(), (int)toks.size(), true, true);
    if (n < 0) {
        toks.resize(-n);
        n = llama_tokenize(g_vocab, text, (int)strlen(text),
                           toks.data(), (int)toks.size(), true, true);
    }
    toks.resize(std::max(0, n));
    return toks;
}

// ============================================================
// 核心：KV cache 复制并行评分
// 上下文在 seq 0 单次 decode，然后 llama_memory_seq_cp 复制到其他序列，
// 候选 token 多序列并行 decode。延迟约减半（194→93ms）。
// 注意: seq_cp 跨 stream 时必须传 p1=-1（全部位置），Qwen3.5 混合架构
//       各 seq 在不同 stream，传部分范围会触发 ASSERT(is_full) 失败。
// ============================================================
static void score_batch(const std::vector<llama_token> & ctx_ids,
                         const std::vector<std::vector<llama_token>> & cands,
                         std::vector<double> & scores_out) {
    scores_out.assign(cands.size(), -1e10);
    int n_cands = (int)cands.size();
    if (n_cands == 0) return;

    std::lock_guard<std::mutex> lock(g_mutex);
    llama_memory_clear(llama_get_memory(g_ctx), true);

    int ctx_len = (int)ctx_ids.size();

    // ── Step 1: 上下文在 seq 0 中单次 decode ──
    llama_batch ctx_batch = llama_batch_init(ctx_len, 0, 1);
    for (int j = 0; j < ctx_len; j++) {
        ctx_batch.token[j]      = ctx_ids[j];
        ctx_batch.pos[j]        = j;
        ctx_batch.n_seq_id[j]   = 1;
        ctx_batch.seq_id[j][0]  = 0;
    }
    ctx_batch.logits[ctx_len - 1] = 1;
    ctx_batch.n_tokens = ctx_len;

    if (llama_decode(g_ctx, ctx_batch) != 0) {
        llama_batch_free(ctx_batch);
        return;
    }
    llama_batch_free(ctx_batch);

    // ── Step 2: 复制 KV cache 到其他候选序列 ──
    // p1=-1 表示 [p0, inf)，绕过跨 stream 的 is_full 检查
    for (int i = 1; i < n_cands; i++) {
        llama_memory_seq_cp(llama_get_memory(g_ctx), 0, i, 0, -1);
    }

    // ── Step 3: 候选 token 多序列并行 decode ──
    int cand_total = 0;
    for (auto & c : cands) cand_total += (int)c.size();

    llama_batch cand_batch = llama_batch_init(cand_total, 0, n_cands);
    int idx = 0;
    for (int i = 0; i < n_cands; i++) {
        int wlen = (int)cands[i].size();
        for (int j = 0; j < wlen; j++) {
            cand_batch.token[idx]     = cands[i][j];
            cand_batch.pos[idx]       = ctx_len + j;
            cand_batch.n_seq_id[idx]  = 1;
            cand_batch.seq_id[idx][0] = i;
            cand_batch.logits[idx]    = 1;
            idx++;
        }
    }
    cand_batch.n_tokens = idx;

    if (llama_decode(g_ctx, cand_batch) != 0) {
        llama_batch_free(cand_batch);
        return;
    }

    // ── Step 4: 计算 CE loss（logits 按 batch 顺序排列）──
    int vs = llama_n_vocab(g_vocab);
    int row_start = 0;
    for (int i = 0; i < n_cands; i++) {
        int wlen = (int)cands[i].size();
        double ce = 0;
        for (int j = 0; j < wlen; j++) {
            float * logits = llama_get_logits_ith(g_ctx, row_start + j);
            if (!logits) { ce = -1e10; break; }
            int tid  = cands[i][j];
            float m  = -1e30f;
            for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
            double se = 0;
            for (int k = 0; k < vs; k++) se += exp((double)(logits[k] - m));
            ce -= (double)(logits[tid] - m) - log(se);
        }
        scores_out[i] = -ce;
        row_start += wlen;
    }
    llama_batch_free(cand_batch);
}

// ============================================================
// Lua API
// ============================================================
static int lua_score(lua_State * L) {
    if (!g_loaded.load()) {
        if (!g_loading.load()) load_model_async();
        lua_pushnil(L);
        return 1;
    }

    const char * context = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);

    std::vector<std::string> cand_texts;
    int n = (int)luaL_len(L, 2);
    if (n < 2) { lua_pushnil(L); return 1; }
    if (n > g_n_seq_max) n = g_n_seq_max;
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 2, i);
        const char * s = lua_tostring(L, -1);
        if (s) cand_texts.push_back(s);
        lua_pop(L, 1);
    }
    if (cand_texts.size() < 2) { lua_pushnil(L); return 1; }

    std::vector<llama_token> ctx_ids = tokenize(context);
    if ((int)ctx_ids.size() < g_min_tokens) { lua_pushnil(L); return 1; }

    if ((int)ctx_ids.size() > g_max_ctx_tokens)
        ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - g_max_ctx_tokens);

    std::vector<std::vector<llama_token>> cand_ids;
    for (auto & s : cand_texts) {
        auto ids = tokenize(s.c_str());
        if (ids.empty()) ids.push_back(0);
        cand_ids.push_back(ids);
    }

    std::vector<double> scores;
    try {
        score_batch(ctx_ids, cand_ids, scores);
    } catch (...) {
        log_msg("ERROR: exception in score_batch");
        lua_pushnil(L);
        return 1;
    }

    // 按分数降序排列候选的索引
    std::vector<int> order(scores.size());
    for (int i = 0; i < (int)order.size(); i++) order[i] = i;
    std::sort(order.begin(), order.end(),
              [&](int a, int b) { return scores[a] > scores[b]; });

    // 保存分数到模块变量（供 get_scores() 获取）
    g_last_scores = scores;
    g_last_cands  = cand_texts;

    // 返回排序后的候选表
    lua_newtable(L);
    for (int i = 0; i < (int)order.size(); i++) {
        int idx = order[i];
        lua_pushstring(L, cand_texts[idx].c_str());
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

static int lua_get_scores(lua_State * L) {
    std::lock_guard<std::mutex> lock(g_mutex);
    lua_newtable(L);
    for (size_t i = 0; i < g_last_cands.size(); i++) {
        lua_pushnumber(L, g_last_scores[i]);
        lua_setfield(L, -2, g_last_cands[i].c_str());
    }
    return 1;
}

static int lua_is_ready(lua_State * L) {
    lua_pushboolean(L, g_loaded.load() ? 1 : 0);
    return 1;
}

// ============================================================
// __index / __newindex
// ============================================================
static int lua_index(lua_State * L) {
    const char * key = luaL_checkstring(L, 2);
    if (strcmp(key, "is_ready") == 0)       lua_pushcfunction(L, lua_is_ready);
    else if (strcmp(key, "get_scores") == 0) lua_pushcfunction(L, lua_get_scores);
    else if (strcmp(key, "score") == 0)     lua_pushcfunction(L, lua_score);
    else if (strcmp(key, "model_path") == 0) lua_pushstring(L, g_model_path.c_str());
    else if (strcmp(key, "max_ctx") == 0)   lua_pushinteger(L, g_max_ctx_tokens);
    else if (strcmp(key, "min_tokens") == 0) lua_pushinteger(L, g_min_tokens);
    else if (strcmp(key, "n_threads") == 0) lua_pushinteger(L, g_n_threads);
    else if (strcmp(key, "n_ctx") == 0)     lua_pushinteger(L, g_n_ctx);
    else if (strcmp(key, "n_seq_max") == 0) lua_pushinteger(L, g_n_seq_max);
    else lua_pushnil(L);
    return 1;
}

static int lua_newindex(lua_State * L) {
    const char * key = luaL_checkstring(L, 2);
    if (strcmp(key, "model_path") == 0)      g_model_path = luaL_checkstring(L, 3);
    else if (strcmp(key, "max_ctx") == 0)    g_max_ctx_tokens = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "min_tokens") == 0) g_min_tokens = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "n_threads") == 0)  g_n_threads = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "n_ctx") == 0)      g_n_ctx = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "n_seq_max") == 0)  g_n_seq_max = (int)luaL_checkinteger(L, 3);
    return 0;
}

// ============================================================
// 模块入口
// ============================================================
extern "C" __declspec(dllexport) int luaopen_rime_llm(lua_State * L) {
    lua_newtable(L);

    lua_pushcfunction(L, lua_score);
    lua_setfield(L, -2, "score");

    lua_pushcfunction(L, lua_is_ready);
    lua_setfield(L, -2, "is_ready");

    lua_pushstring(L, g_model_path.c_str());
    lua_setfield(L, -2, "model_path");

    lua_pushinteger(L, g_max_ctx_tokens);
    lua_setfield(L, -2, "max_ctx");

    lua_pushinteger(L, g_n_threads);
    lua_setfield(L, -2, "n_threads");

    lua_pushinteger(L, g_n_ctx);
    lua_setfield(L, -2, "n_ctx");

    lua_pushinteger(L, g_n_seq_max);
    lua_setfield(L, -2, "n_seq_max");

    lua_newtable(L);
    lua_pushcfunction(L, lua_index);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, lua_newindex);
    lua_setfield(L, -2, "__newindex");
    lua_setmetatable(L, -2);

    load_model_async();

    return 1;
}
