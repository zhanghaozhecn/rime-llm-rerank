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
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdarg>
#include <algorithm>

// ============================================================
// 配置默认值
// ============================================================
static std::string  g_model_path      = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static int          g_min_tokens      = 1;
static int          g_max_ctx_tokens  = 10; // tok=10 准确率 93.4%，10→17 收益仅 +1.1pp 但延迟翻倍
static int          g_n_threads       = 0;  // 0=auto: max(4, ceil(hw_threads/3))，用户设置后覆盖

// 自动检测默认线程数：总线程数的 1/3 向上取整，最少 4
static int auto_threads() {
    unsigned int hw = std::thread::hardware_concurrency();
    if (hw == 0) return 6;  // 无法检测时回退 6
    int t = (int)std::ceil(hw / 3.0);
    return (t < 4) ? 4 : t;
}
static int          g_n_ctx           = 64;
static int          g_n_seq_max       = 12;  // 模板 seq 0 + 最多 11 worker seq

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
// 预解码状态：prepare() 在 commit 后异步执行 Step 1 + KV copy
// score() 检测 ctx 一致时直接跳到 Step 2
// ============================================================
static std::vector<llama_token> g_prep_ctx;     // 预解码的上下文 token
static std::vector<float>       g_prep_logits;  // ctx_last logits
static bool                      g_prep_ready = false; // prepare() 已完成
static std::atomic<int>         g_prep_seq{0};  // 请求序列号，跳过过期请求

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

        // 解析线程数：0 = 自动检测
        int n_thr = g_n_threads;
        if (n_thr <= 0) n_thr = auto_threads();
        log_msg("threads: hw=%u auto=%d user=%d final=%d",
                std::thread::hardware_concurrency(), auto_threads(), g_n_threads, n_thr);

        llama_context_params cparams = llama_context_default_params();
        cparams.n_ctx           = g_n_ctx;
        cparams.n_threads       = n_thr;
        cparams.n_threads_batch = n_thr;
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
            llama_memory_clear(llama_get_memory(g_ctx), false);
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
        log_msg("model ready (n_ctx=%d threads=%d)", g_n_ctx, n_thr);
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
// Softmax CE 辅助：-log(softmax(x)[target])
// ============================================================
static double cross_entropy(float * logits, int vs, int target_id) {
    float m = -1e30f;
    for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
    double se = 0;
    for (int k = 0; k < vs; k++) se += exp((double)(logits[k] - m));
    return -((double)(logits[target_id] - m) - log(se));
}

// ============================================================
// 核心评分：ctx 仅 1 次 decode + KV copy + 多序列分层并行候选 decode
//
// Step 1: decode ctx → 保存 logits → 所有候选的第 1 个 token CE 从此计算
// Step 2: KV copy ctx → M 个 seq，并行 decode 候选首 token → 第 2 token CE
// Step 3: 同一批 seq 继续 decode → 第 3 token CE
//
// 原理：P(tok_i0|ctx) 对所有 i 共享同一个 ctx_last hidden state
//       多 token 候选每个 seq 仅 1 个新 token，SSM 跨序列干扰可忽略
//       ith = batch 数组索引（不是 logits 标记序号）
// ============================================================
static void score_batch(const std::vector<llama_token> & ctx_ids,
                         const std::vector<std::vector<llama_token>> & cands,
                         std::vector<double> & scores_out) {
    scores_out.assign(cands.size(), -1e10);
    int n_cands = (int)cands.size();
    if (n_cands == 0) return;

    auto t0 = std::chrono::high_resolution_clock::now();
    std::lock_guard<std::mutex> lock(g_mutex);
    auto t1 = std::chrono::high_resolution_clock::now();
    double wait_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    int ctx_len = (int)ctx_ids.size();
    int vs = llama_n_vocab(g_vocab);

    // 按 token 数分组
    std::vector<int> idx2, idx3;
    for (int i = 0; i < n_cands; i++) {
        if (cands[i].size() >= 2) idx2.push_back(i);
        if (cands[i].size() >= 3) idx3.push_back(i);
    }
    int M = (int)idx2.size();
    int K = (int)idx3.size();
    std::vector<int> cand_to_seq(n_cands, -1);  // candidate index → seq id

    // 检测预解码状态：ctx 完全匹配 → 跳过 Step 1
    bool use_prep = g_prep_ready && ctx_ids == g_prep_ctx;
    std::vector<float> ctx_logits;
    double ms1 = 0;

    if (!use_prep) {
        // ---- 完整流程：Step 1 ctx decode ----
        auto ts1_0 = std::chrono::high_resolution_clock::now();
        llama_memory_clear(llama_get_memory(g_ctx), false);
        llama_batch ctx_batch = llama_batch_init(ctx_len, 0, 1);
        for (int j = 0; j < ctx_len; j++) {
            ctx_batch.token[j] = ctx_ids[j]; ctx_batch.pos[j] = j;
            ctx_batch.n_seq_id[j] = 1; ctx_batch.seq_id[j][0] = 0;
        }
        ctx_batch.logits[ctx_len - 1] = 1;
        ctx_batch.n_tokens = ctx_len;
        if (llama_decode(g_ctx, ctx_batch) == 0) {
            float* cl = llama_get_logits_ith(g_ctx, ctx_len - 1);
            if (cl) ctx_logits.assign(cl, cl + vs);
        }
        llama_batch_free(ctx_batch);

        if (ctx_logits.empty()) return;  // decode failed
        auto ts1_1 = std::chrono::high_resolution_clock::now();
        ms1 = std::chrono::duration<double, std::milli>(ts1_1 - ts1_0).count();
    } else {
        // 预解码命中：直接使用已保存的 logits
        ctx_logits = g_prep_logits;
    }

    // 所有候选的第 1 个 token CE
    std::vector<double> ce_sum(n_cands, 0);
    for (int i = 0; i < n_cands; i++) {
        ce_sum[i] = cross_entropy(ctx_logits.data(), vs, cands[i][0]);
    }

    // ---- Step 2: 多 token 候选的首 token 并行 decode（每 seq 1 token）----
    double ms2a = 0, ms2b = 0;
    if (M > 0) {
        auto ts2_0 = std::chrono::high_resolution_clock::now();
        // KV copy ctx (seq 0) → worker seqs 1..M
        for (int s = 0; s < M; s++) {
            llama_memory_seq_cp(llama_get_memory(g_ctx), 0, s + 1, 0, -1);
            cand_to_seq[idx2[s]] = s + 1;
        }
        auto ts2_kv = std::chrono::high_resolution_clock::now();

        llama_batch b2 = llama_batch_init(M, 0, M);
        for (int s = 0; s < M; s++) {
            int ci = idx2[s];
            b2.token[s] = cands[ci][0];
            b2.pos[s] = ctx_len;
            b2.n_seq_id[s] = 1;
            b2.seq_id[s][0] = s + 1;
            b2.logits[s] = 1;
        }
        b2.n_tokens = M;
        if (llama_decode(g_ctx, b2) == 0) {
            for (int s = 0; s < M; s++) {
                int ci = idx2[s];
                float* l = llama_get_logits_ith(g_ctx, s);
                if (l) ce_sum[ci] += cross_entropy(l, vs, cands[ci][1]);
                else   ce_sum[ci] = -1e10;
            }
        } else {
            for (int ci : idx2) ce_sum[ci] = -1e10;
        }
        llama_batch_free(b2);
        auto ts2_1 = std::chrono::high_resolution_clock::now();
        ms2a = std::chrono::duration<double, std::milli>(ts2_kv - ts2_0).count();
        ms2b = std::chrono::duration<double, std::milli>(ts2_1 - ts2_kv).count();
    }

    // ---- Step 3: 3-token 候选的次 token 并行 decode ----
    if (K > 0) {
        llama_batch b3 = llama_batch_init(K, 0, K);
        for (int s = 0; s < K; s++) {
            int ci = idx3[s];
            int seq_id = cand_to_seq[ci];  // same seq as step 2
            b3.token[s] = cands[ci][1];
            b3.pos[s] = ctx_len + 1;
            b3.n_seq_id[s] = 1;
            b3.seq_id[s][0] = seq_id;
            b3.logits[s] = 1;
        }
        b3.n_tokens = K;
        if (llama_decode(g_ctx, b3) == 0) {
            for (int s = 0; s < K; s++) {
                int ci = idx3[s];
                float* l = llama_get_logits_ith(g_ctx, s);
                if (l) ce_sum[ci] += cross_entropy(l, vs, cands[ci][2]);
                else   ce_sum[ci] = -1e10;
            }
        } else {
            for (int ci : idx3) ce_sum[ci] = -1e10;
        }
        llama_batch_free(b3);
    }

    // ---- 输出分数 ----
    for (int i = 0; i < n_cands; i++) {
        scores_out[i] = ce_sum[i] > -1e9 ? -ce_sum[i] : -1e10;
    }

    // 预解码状态已消耗
    if (use_prep) g_prep_ready = false;

    auto t_end = std::chrono::high_resolution_clock::now();
    double total_ms = std::chrono::duration<double, std::milli>(t_end - t0).count();
    log_msg("score: wait=%.0fms S1=%.0fms KV=%.0fms S2=%.0fms total=%.0fms prep=%d ctx_tok=%d cand=%d",
            wait_ms, ms1, ms2a, ms2b, total_ms, use_prep ? 1 : 0, ctx_len, n_cands);
}

// ============================================================
// 预解码：在 commit 后异步执行 Step 1 + KV copy
// seq 用于跳过过期请求（新的 prepare 已到达，旧的直接放弃）
// ============================================================
static void prepare(const std::vector<llama_token> & ctx_ids, int seq) {
    std::lock_guard<std::mutex> lock(g_mutex);

    int ctx_len = (int)ctx_ids.size();

    // 过期请求：新的 prepare 已到来，放弃本次计算
    if (seq != g_prep_seq.load()) {
        log_msg("prepare: SKIP stale seq=%d current=%d ctx_tok=%d", seq, g_prep_seq.load(), ctx_len);
        return;
    }
    log_msg("prepare: start ctx_tok=%d seq=%d", ctx_len, seq);
    int vs = llama_n_vocab(g_vocab);
    auto* mem = llama_get_memory(g_ctx);

    // 清除上次的预解码
    g_prep_ready = false;
    g_prep_ctx.clear();
    g_prep_logits.clear();

    // Step 1: decode ctx → seq 0
    llama_memory_clear(mem, false);
    llama_batch ctx_batch = llama_batch_init(ctx_len, 0, 1);
    for (int j = 0; j < ctx_len; j++) {
        ctx_batch.token[j] = ctx_ids[j]; ctx_batch.pos[j] = j;
        ctx_batch.n_seq_id[j] = 1; ctx_batch.seq_id[j][0] = 0;
    }
    ctx_batch.logits[ctx_len - 1] = 1;
    ctx_batch.n_tokens = ctx_len;

    if (llama_decode(g_ctx, ctx_batch) != 0) {
        llama_batch_free(ctx_batch);
        return;  // decode 失败，score 时走完整流程
    }
    float* cl = llama_get_logits_ith(g_ctx, ctx_len - 1);
    if (!cl) { llama_batch_free(ctx_batch); return; }
    g_prep_logits.assign(cl, cl + vs);
    llama_batch_free(ctx_batch);

    // 不预复制 KV——n_ctx=64 太小，且 KV copy 本身很快
    // score() 检测 ctx 一致时跳过 Step 1，但仍执行 KV copy + Step 2

    g_prep_ctx = ctx_ids;
    g_prep_ready = true;
    log_msg("prepare: done ctx_tok=%d seq=%d", ctx_len, seq);
}

// ============================================================
// Lua API
// ============================================================
static int lua_prepare(lua_State * L) {
    if (!g_loaded.load()) {
        lua_pushboolean(L, 0);
        return 1;
    }
    const char * context = luaL_checkstring(L, 1);
    auto ctx_ids = tokenize(context);
    if ((int)ctx_ids.size() < g_min_tokens) {
        lua_pushboolean(L, 0);
        return 1;
    }
    if ((int)ctx_ids.size() > g_max_ctx_tokens)
        ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - g_max_ctx_tokens);

    // 递增序列号，之前的过期 prepare 会在获取 mutex 后自行跳过
    int seq = ++g_prep_seq;

    // 异步执行预解码，不阻塞输入法 processor
    std::thread([ctx_ids, seq]() {
        prepare(ctx_ids, seq);
    }).detach();

    lua_pushboolean(L, 1);
    return 1;
}

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

    // 按分数降序排列
    std::vector<int> order(scores.size());
    for (int i = 0; i < (int)order.size(); i++) order[i] = i;
    std::sort(order.begin(), order.end(),
              [&](int a, int b) { return scores[a] > scores[b]; });

    g_last_scores = scores;
    g_last_cands  = cand_texts;

    lua_newtable(L);
    for (int i = 0; i < (int)order.size(); i++) {
        lua_pushstring(L, cand_texts[order[i]].c_str());
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
    else if (strcmp(key, "prepare") == 0)   lua_pushcfunction(L, lua_prepare);
    else if (strcmp(key, "model_path") == 0) lua_pushstring(L, g_model_path.c_str());
    else if (strcmp(key, "max_ctx") == 0)   lua_pushinteger(L, g_max_ctx_tokens);
    else if (strcmp(key, "min_tokens") == 0) lua_pushinteger(L, g_min_tokens);
    else if (strcmp(key, "n_threads") == 0) lua_pushinteger(L, g_n_threads > 0 ? g_n_threads : auto_threads());
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

    lua_pushcfunction(L, lua_prepare);
    lua_setfield(L, -2, "prepare");

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
