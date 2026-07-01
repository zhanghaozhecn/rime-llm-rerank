/*
 * rime_llm.cpp — RIME LLM 候选重排 C++ 插件
 * 编译: 参见 CMakeLists.txt + build.ps1
 * 用法: Lua 中 require("rime_llm") → llm.score(ctx, cands)
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
// 配置（可通过 Lua 属性修改）
// ============================================================
// 自动检测 CPU 线程数（物理核心 × 2 ≈ 逻辑处理器）
static int detect_phys_cores() {
    int n = (int)std::thread::hardware_concurrency();
    return n > 0 ? (n * 2 / 3) : 8;  // 逻辑线程的 2/3 ≈ 物理核数
}
static int detect_logi_cores() {
    int n = (int)std::thread::hardware_concurrency();
    return n > 0 ? n : 8;
}

static std::string  g_model_path = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static int          g_max_ctx_tokens = 4;
static int          g_max_candidates = 4;
static int          g_n_threads = detect_phys_cores();       // 物理核 ~ 14
static int          g_n_threads_batch = detect_logi_cores(); // 全逻辑 ~ 20
static int          g_n_ctx = 64;
static int          g_n_seq_max = 9;

// ============================================================
// 模型状态
// ============================================================
static llama_model        * g_model   = nullptr;
static llama_context      * g_ctx     = nullptr;
static const llama_vocab  * g_vocab   = nullptr;
static std::mutex           g_mutex;
static std::atomic<bool>    g_loaded{false};
static std::atomic<bool>    g_loading{false};

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
        cparams.n_ctx = g_n_ctx;
        cparams.n_threads = g_n_threads;
        cparams.n_threads_batch = g_n_threads_batch;
        cparams.n_seq_max = g_n_seq_max;

        g_ctx = llama_new_context_with_model(g_model, cparams);
        if (!g_ctx) {
            log_msg("ERROR: failed to create context");
            llama_model_free(g_model);
            g_model = nullptr;
            g_loading.store(false);
            return;
        }

        // 预热
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
        log_msg("model ready (n_ctx=%d, threads=%d)", g_n_ctx, g_n_threads);
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
// 核心：并行 batch 评分（所有候选一次 decode）
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
    int total = n_cands * ctx_len;
    for (auto & c : cands) total += (int)c.size();

    llama_batch batch = llama_batch_init(total, 0, g_n_seq_max);
    int idx = 0;
    for (int i = 0; i < n_cands; i++) {
        for (int j = 0; j < ctx_len; j++) {
            batch.token[idx] = ctx_ids[j];
            batch.pos[idx] = j;
            batch.n_seq_id[idx] = 1;
            batch.seq_id[idx][0] = i;
            idx++;
        }
        int wlen = (int)cands[i].size();
        for (int j = 0; j < wlen; j++) {
            batch.token[idx] = cands[i][j];
            batch.pos[idx] = ctx_len + j;
            batch.n_seq_id[idx] = 1;
            batch.seq_id[idx][0] = i;
            batch.logits[idx] = 1;
            idx++;
        }
    }
    batch.n_tokens = idx;

    if (llama_decode(g_ctx, batch) != 0) {
        llama_batch_free(batch);
        return;
    }

    int row_start = 0;
    for (int i = 0; i < n_cands; i++) {
        int wlen = (int)cands[i].size();
        double ce = 0;
        for (int j = 0; j < wlen; j++) {
            int pos = row_start + ctx_len + j;
            float * logits = llama_get_logits_ith(g_ctx, pos);
            if (!logits) { ce = -1e10; break; }
            int vs = llama_n_vocab(g_vocab);
            int tid = cands[i][j];
            float m = -1e30f;
            for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
            double se = 0;
            for (int k = 0; k < vs; k++) se += exp((double)(logits[k] - m));
            ce -= (double)(logits[tid] - m) - log(se);
        }
        scores_out[i] = -ce;
        row_start += ctx_len + wlen;
    }
    llama_batch_free(batch);
}

// ============================================================
// Lua API: score(context, candidates_table) → string | nil
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
    if (n > g_max_candidates) n = g_max_candidates;
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 2, i);
        const char * s = lua_tostring(L, -1);
        if (s) cand_texts.push_back(s);
        lua_pop(L, 1);
    }
    if (cand_texts.size() < 2) { lua_pushnil(L); return 1; }

    std::vector<llama_token> ctx_ids = tokenize(context);
    if (ctx_ids.empty() || (int)ctx_ids.size() < 2) {
        lua_pushnil(L);
        return 1;
    }

    if ((int)ctx_ids.size() > g_max_ctx_tokens)
        ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - g_max_ctx_tokens);

    // 分词所有候选
    std::vector<std::vector<llama_token>> cand_ids;
    for (auto & s : cand_texts) {
        auto ids = tokenize(s.c_str());
        if (ids.empty()) ids.push_back(0);  // fallback
        cand_ids.push_back(ids);
    }

    // 并行评分
    std::vector<double> scores;
    try {
        score_batch(ctx_ids, cand_ids, scores);
    } catch (...) {
        log_msg("ERROR: exception in score_batch");
        lua_pushnil(L);
        return 1;
    }

    // 找最佳
    int best_idx = -1;
    double best_score = -1e100;
    for (int i = 0; i < (int)scores.size(); i++) {
        if (scores[i] > best_score) { best_score = scores[i]; best_idx = i; }
    }

    if (best_idx >= 0 && best_idx < (int)cand_texts.size())
        lua_pushstring(L, cand_texts[best_idx].c_str());
    else
        lua_pushnil(L);
    return 1;
}

// ============================================================
// Lua API: is_ready() → bool
// ============================================================
static int lua_is_ready(lua_State * L) {
    lua_pushboolean(L, g_loaded.load() ? 1 : 0);
    return 1;
}

// ============================================================
// __index / __newindex
// ============================================================
static int lua_index(lua_State * L) {
    const char * key = luaL_checkstring(L, 2);
    if (strcmp(key, "is_ready") == 0) lua_pushcfunction(L, lua_is_ready);
    else if (strcmp(key, "score") == 0) lua_pushcfunction(L, lua_score);
    else if (strcmp(key, "model_path") == 0) lua_pushstring(L, g_model_path.c_str());
    else if (strcmp(key, "max_ctx") == 0) lua_pushinteger(L, g_max_ctx_tokens);
    else if (strcmp(key, "max_cand") == 0) lua_pushinteger(L, g_max_candidates);
    else if (strcmp(key, "n_threads") == 0) lua_pushinteger(L, g_n_threads);
    else if (strcmp(key, "n_threads_batch") == 0) lua_pushinteger(L, g_n_threads_batch);
    else if (strcmp(key, "n_seq_max") == 0) lua_pushinteger(L, g_n_seq_max);
    else lua_pushnil(L);
    return 1;
}

static int lua_newindex(lua_State * L) {
    const char * key = luaL_checkstring(L, 2);
    if (strcmp(key, "model_path") == 0) g_model_path = luaL_checkstring(L, 3);
    else if (strcmp(key, "max_ctx") == 0) g_max_ctx_tokens = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "max_cand") == 0) g_max_candidates = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "n_threads") == 0) g_n_threads = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "n_threads_batch") == 0) g_n_threads_batch = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "n_ctx") == 0) g_n_ctx = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "n_seq_max") == 0) g_n_seq_max = (int)luaL_checkinteger(L, 3);
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
    lua_pushinteger(L, g_max_candidates);
    lua_setfield(L, -2, "max_cand");
    lua_pushinteger(L, g_n_threads);
    lua_setfield(L, -2, "n_threads");
    lua_pushinteger(L, g_n_threads_batch);
    lua_setfield(L, -2, "n_threads_batch");
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
