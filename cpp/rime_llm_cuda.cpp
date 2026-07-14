/*
 * rime_llm_cuda.cpp — RIME LLM 候选重排 C++ 插件 (GPU/CUDA)
 * 与 CPU 版相同的分层并行算法，使用 CUDA 加速 llama.cpp 后端。
 * Lua:  require("rime_llm_cuda") → llm.score(ctx, cands)
 *
 * 编译: 使用 build_gpu (Ninja + MSVC + CUDA llama.cpp)
 */
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
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
#include <chrono>

// ============================================================
// 配置默认值 (GPU)
// ============================================================
static std::string  g_model_path      = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static int          g_min_tokens      = 1;
static int          g_max_ctx_tokens  = 10;
static int          g_n_threads       = 7;  // 实测多台机器均在 thr=7 饱和
static int          g_n_ctx           = 512; // 12 seq × ~23 tok 需要
static int          g_n_seq_max       = 12;  // 模板 seq 0 + 11 worker seq
static int          g_n_gpu_layers    = 99;  // 全部 offload 到 GPU

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

// 预解码状态：prepare() 在 commit 后异步执行 Step 1 + KV copy
static std::vector<llama_token> g_prep_ctx;
static std::vector<float>       g_prep_logits;
static bool                      g_prep_ready = false;
static std::atomic<int>         g_prep_seq{0};

// ============================================================
// 轻量日志
// ============================================================
static void log_msg(const char * fmt, ...) {
    char buf[512]; va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    char path[MAX_PATH]; GetTempPathA(sizeof(path), path);
    strcat_s(path, sizeof(path), "rime_llm_cuda_log.txt");
    FILE * f = fopen(path, "a");
    if (f) { fprintf(f, "%s\n", buf); fclose(f); }
}

// ============================================================
// 异步模型加载 (GPU)
// ============================================================
static void load_model_async() {
    if (g_loaded.load() || g_loading.load()) return;
    g_loading.store(true);

    std::thread([]() {
        log_msg("loading model (GPU): %s", g_model_path.c_str());
        llama_backend_init();

        llama_model_params mparams = llama_model_default_params();
        mparams.use_mmap = 1;
        mparams.n_gpu_layers = g_n_gpu_layers;

        g_model = llama_model_load_from_file(g_model_path.c_str(), mparams);
        if (!g_model) {
            log_msg("ERROR: failed to load model"); g_loading.store(false); return;
        }
        g_vocab = llama_model_get_vocab(g_model);

        int n_thr = g_n_threads;

        llama_context_params cparams = llama_context_default_params();
        cparams.n_ctx           = g_n_ctx;
        cparams.n_threads       = n_thr;
        cparams.n_threads_batch = n_thr;
        cparams.n_seq_max       = g_n_seq_max;

        g_ctx = llama_new_context_with_model(g_model, cparams);
        if (!g_ctx) {
            log_msg("ERROR: failed to create context");
            llama_model_free(g_model); g_model = nullptr; g_loading.store(false); return;
        }

        // warmup
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            llama_memory_clear(llama_get_memory(g_ctx), false);
            llama_token tokens[4];
            int n = llama_tokenize(g_vocab, "\n", 1, tokens, 4, true, true);
            if (n > 0) {
                llama_batch batch = llama_batch_get_one(tokens, n);
                llama_decode(g_ctx, batch);
            }
        }

        g_loaded.store(true); g_loading.store(false);
        log_msg("model ready (GPU, n_ctx=%d threads=%d gpu_layers=%d)", g_n_ctx, n_thr, g_n_gpu_layers);
    }).detach();
}

// ============================================================
// 分词
// ============================================================
static std::vector<llama_token> tokenize(const char * text) {
    std::vector<llama_token> toks(128);
    int n = llama_tokenize(g_vocab, text, (int)strlen(text), toks.data(), (int)toks.size(), true, true);
    if (n < 0) { toks.resize(-n); n = llama_tokenize(g_vocab, text, (int)strlen(text), toks.data(), (int)toks.size(), true, true); }
    toks.resize(std::max(0, n));
    return toks;
}

// ============================================================
// Softmax CE 辅助
// ============================================================
static double cross_entropy(float * logits, int vs, int target_id) {
    float m = -1e30f;
    for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
    double se = 0;
    for (int k = 0; k < vs; k++) se += exp((double)(logits[k] - m));
    return -((double)(logits[target_id] - m) - log(se));
}

// ============================================================
// 核心评分：分层并行（与 CPU 版相同算法）
// ============================================================
static void score_batch(const std::vector<llama_token> & ctx_ids,
                         const std::vector<std::vector<llama_token>> & cands,
                         std::vector<double> & scores_out) {
    scores_out.assign(cands.size(), -1e10);
    int n_cands = (int)cands.size();
    if (n_cands == 0) return;

    auto t_total_0 = std::chrono::high_resolution_clock::now();
    auto t_wait_0 = t_total_0;

    std::lock_guard<std::mutex> lock(g_mutex);

    auto t_wait_1 = std::chrono::high_resolution_clock::now();
    double wait_ms = std::chrono::duration<double, std::milli>(t_wait_1 - t_wait_0).count();

    int ctx_len = (int)ctx_ids.size();
    int vs = llama_n_vocab(g_vocab);

    std::vector<int> idx2, idx3;
    for (int i = 0; i < n_cands; i++) {
        if (cands[i].size() >= 2) idx2.push_back(i);
        if (cands[i].size() >= 3) idx3.push_back(i);
    }
    int M = (int)idx2.size(), K = (int)idx3.size();
    std::vector<int> cand_to_seq(n_cands, -1);

    // 检测预解码
    bool use_prep = g_prep_ready && ctx_ids == g_prep_ctx;
    std::vector<float> ctx_logits;
    double ms1 = 0;

    if (!use_prep) {
        // Step 1: decode ctx once
        auto t1_0 = std::chrono::high_resolution_clock::now();
        llama_memory_clear(llama_get_memory(g_ctx), false);
        llama_batch ctx_batch = llama_batch_init(ctx_len, 0, 1);
        for (int j = 0; j < ctx_len; j++) {
            ctx_batch.token[j] = ctx_ids[j]; ctx_batch.pos[j] = j;
            ctx_batch.n_seq_id[j] = 1; ctx_batch.seq_id[j][0] = 0;
        }
        ctx_batch.logits[ctx_len - 1] = 1; ctx_batch.n_tokens = ctx_len;
        int rc1 = llama_decode(g_ctx, ctx_batch);
        if (rc1 == 0) {
            float* cl = llama_get_logits_ith(g_ctx, ctx_len - 1);
            if (cl) ctx_logits.assign(cl, cl + vs);
        }
        llama_batch_free(ctx_batch);
        auto t1_1 = std::chrono::high_resolution_clock::now();
        ms1 = std::chrono::duration<double, std::milli>(t1_1 - t1_0).count();
        if (ctx_logits.empty()) { log_msg("score: S1 FAILED rc=%d", rc1); return; }
    } else {
        // 预解码命中
        ctx_logits = g_prep_logits;
    }

    // First-token CE for all candidates
    std::vector<double> ce_sum(n_cands, 0);
    for (int i = 0; i < n_cands; i++)
        ce_sum[i] = cross_entropy(ctx_logits.data(), vs, cands[i][0]);

    // Step 2: multi-token first tokens in parallel
    double ms2a = 0, ms2b = 0;
    if (M > 0) {
        auto t2_0 = std::chrono::high_resolution_clock::now();
        auto mem = llama_get_memory(g_ctx);
        for (int s = 0; s < M; s++) {
            llama_memory_seq_cp(mem, 0, s + 1, 0, -1);
            cand_to_seq[idx2[s]] = s + 1;
        }
        auto t2_kv = std::chrono::high_resolution_clock::now();
        llama_batch b2 = llama_batch_init(M, 0, M);
        for (int s = 0; s < M; s++) {
            int ci = idx2[s];
            b2.token[s] = cands[ci][0]; b2.pos[s] = ctx_len;
            b2.n_seq_id[s] = 1; b2.seq_id[s][0] = s + 1; b2.logits[s] = 1;
        }
        b2.n_tokens = M;
        if (llama_decode(g_ctx, b2) == 0) {
            for (int s = 0; s < M; s++) {
                int ci = idx2[s];
                float* l = llama_get_logits_ith(g_ctx, s);
                if (l) ce_sum[ci] += cross_entropy(l, vs, cands[ci][1]);
                else ce_sum[ci] = -1e10;
            }
        } else { for (int ci : idx2) ce_sum[ci] = -1e10; }
        llama_batch_free(b2);
        auto t2_1 = std::chrono::high_resolution_clock::now();
        ms2a = std::chrono::duration<double, std::milli>(t2_kv - t2_0).count();
        ms2b = std::chrono::duration<double, std::milli>(t2_1 - t2_kv).count();
    }

    // Step 3: 3-token second tokens in parallel
    double ms3 = 0;
    if (K > 0) {
        auto t3_0 = std::chrono::high_resolution_clock::now();
        llama_batch b3 = llama_batch_init(K, 0, K);
        for (int s = 0; s < K; s++) {
            int ci = idx3[s], seq_id = cand_to_seq[ci];
            b3.token[s] = cands[ci][1]; b3.pos[s] = ctx_len + 1;
            b3.n_seq_id[s] = 1; b3.seq_id[s][0] = seq_id; b3.logits[s] = 1;
        }
        b3.n_tokens = K;
        if (llama_decode(g_ctx, b3) == 0) {
            for (int s = 0; s < K; s++) {
                int ci = idx3[s];
                float* l = llama_get_logits_ith(g_ctx, s);
                if (l) ce_sum[ci] += cross_entropy(l, vs, cands[ci][2]);
                else ce_sum[ci] = -1e10;
            }
        } else { for (int ci : idx3)ce_sum[ci] = -1e10; }
        llama_batch_free(b3);
        auto t3_1 = std::chrono::high_resolution_clock::now();
        ms3 = std::chrono::duration<double, std::milli>(t3_1 - t3_0).count();
    }

    for (int i = 0; i < n_cands; i++)
        scores_out[i] = ce_sum[i] > -1e9 ? -ce_sum[i] : -1e10;

    if (use_prep) g_prep_ready = false;

    auto t_total_1 = std::chrono::high_resolution_clock::now();
    double total_ms = std::chrono::duration<double, std::milli>(t_total_1 - t_total_0).count();

    // Build cand token lengths string
    char tok_buf[64]; int pos = 0;
    for (int i = 0; i < n_cands && pos < 60; i++)
        pos += snprintf(tok_buf + pos, sizeof(tok_buf) - pos, "%d%s", (int)cands[i].size(), i < n_cands-1 ? "," : "");
    log_msg("score: wait=%.0fms S1=%.0fms KV=%.0fms S2=%.0fms S3=%.0fms total=%.0fms ctx_tok=%d cand_tok=[%s]",
        wait_ms, ms1, ms2a, ms2b, ms3, total_ms, ctx_len, tok_buf);
}

// ============================================================
// 预解码：在第一个编码按下时提前执行 Step 1 + KV copy
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

    g_prep_ready = false;
    g_prep_ctx.clear();
    g_prep_logits.clear();

    llama_memory_clear(mem, false);
    llama_batch ctx_batch = llama_batch_init(ctx_len, 0, 1);
    for (int j = 0; j < ctx_len; j++) {
        ctx_batch.token[j] = ctx_ids[j]; ctx_batch.pos[j] = j;
        ctx_batch.n_seq_id[j] = 1; ctx_batch.seq_id[j][0] = 0;
    }
    ctx_batch.logits[ctx_len - 1] = 1; ctx_batch.n_tokens = ctx_len;

    if (llama_decode(g_ctx, ctx_batch) != 0) { llama_batch_free(ctx_batch); return; }
    float* cl = llama_get_logits_ith(g_ctx, ctx_len - 1);
    if (!cl) { llama_batch_free(ctx_batch); return; }
    g_prep_logits.assign(cl, cl + vs);
    llama_batch_free(ctx_batch);

    g_prep_ctx = ctx_ids;
    g_prep_ready = true;
    log_msg("prepare: done ctx_tok=%d seq=%d", ctx_len, seq);
}

// ============================================================
// Lua API (与 CPU 版相同接口)
// ============================================================
static int lua_prepare(lua_State * L) {
    if (!g_loaded.load()) { lua_pushboolean(L, 0); return 1; }
    const char * context = luaL_checkstring(L, 1);
    auto ctx_ids = tokenize(context);
    if ((int)ctx_ids.size() < g_min_tokens) { lua_pushboolean(L, 0); return 1; }
    if ((int)ctx_ids.size() > g_max_ctx_tokens)
        ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - g_max_ctx_tokens);

    int seq = ++g_prep_seq;

    std::thread([ctx_ids, seq]() {
        prepare(ctx_ids, seq);
    }).detach();

    lua_pushboolean(L, 1);
    return 1;
}

static int lua_score(lua_State * L) {
    if (!g_loaded.load()) {
        if (!g_loading.load()) load_model_async();
        lua_pushnil(L); return 1;
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
    try { score_batch(ctx_ids, cand_ids, scores); }
    catch (...) { log_msg("ERROR: exception in score_batch"); lua_pushnil(L); return 1; }

    std::vector<int> order(scores.size());
    for (int i = 0; i < (int)order.size(); i++) order[i] = i;
    std::sort(order.begin(), order.end(), [&](int a, int b) { return scores[a] > scores[b]; });

    g_last_scores = scores; g_last_cands = cand_texts;

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

static int lua_index(lua_State * L) {
    const char * key = luaL_checkstring(L, 2);
    if (strcmp(key, "is_ready") == 0)       lua_pushcfunction(L, lua_is_ready);
    else if (strcmp(key, "get_scores") == 0) lua_pushcfunction(L, lua_get_scores);
    else if (strcmp(key, "score") == 0)     lua_pushcfunction(L, lua_score);
    else if (strcmp(key, "prepare") == 0)   lua_pushcfunction(L, lua_prepare);
    else if (strcmp(key, "model_path") == 0) lua_pushstring(L, g_model_path.c_str());
    else if (strcmp(key, "max_ctx") == 0)   lua_pushinteger(L, g_max_ctx_tokens);
    else if (strcmp(key, "min_tokens") == 0) lua_pushinteger(L, g_min_tokens);
    else if (strcmp(key, "n_threads") == 0) lua_pushinteger(L, g_n_threads);
    else if (strcmp(key, "n_ctx") == 0)     lua_pushinteger(L, g_n_ctx);
    else if (strcmp(key, "n_seq_max") == 0)  lua_pushinteger(L, g_n_seq_max);
    else if (strcmp(key, "n_gpu_layers") == 0) lua_pushinteger(L, g_n_gpu_layers);
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
    else if (strcmp(key, "n_gpu_layers") == 0) g_n_gpu_layers = (int)luaL_checkinteger(L, 3);
    return 0;
}

// ============================================================
// 模块入口: require("rime_llm_cuda")
// ============================================================
extern "C" __declspec(dllexport) int luaopen_rime_llm_cuda(lua_State * L) {
    lua_newtable(L);

    lua_pushcfunction(L, lua_score);      lua_setfield(L, -2, "score");
    lua_pushcfunction(L, lua_prepare);    lua_setfield(L, -2, "prepare");
    lua_pushcfunction(L, lua_is_ready);    lua_setfield(L, -2, "is_ready");
    lua_pushstring(L, g_model_path.c_str()); lua_setfield(L, -2, "model_path");
    lua_pushinteger(L, g_max_ctx_tokens); lua_setfield(L, -2, "max_ctx");
    lua_pushinteger(L, g_n_threads);      lua_setfield(L, -2, "n_threads");
    lua_pushinteger(L, g_n_ctx);          lua_setfield(L, -2, "n_ctx");
    lua_pushinteger(L, g_n_seq_max);      lua_setfield(L, -2, "n_seq_max");
    lua_pushinteger(L, g_n_gpu_layers);   lua_setfield(L, -2, "n_gpu_layers");

    lua_newtable(L);
    lua_pushcfunction(L, lua_index);       lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, lua_newindex);    lua_setfield(L, -2, "__newindex");
    lua_setmetatable(L, -2);

    load_model_async();
    return 1;
}
