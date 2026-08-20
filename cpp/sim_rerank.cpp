/*
 * sim_rerank.cpp — 用生产 DLL 同款算法仿真 LLM 重排
 * 读取 JSON 输入（context + candidates list），输出 LLM 重排结果
 *
 * 输入格式 (stdin, 一行一个 JSON):
 *   {"context": "上文文本", "cands": ["候选1", "候选2", ...]}
 *
 * 输出格式 (stdout, 对每行输入):
 *   ["首选", "次选", ...]
 *
 * 编译: 与 rime_llm.cpp 相同方式（llama.lib + GGUF 模型）
 */
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "llama.h"

#include <string>
#include <vector>
#include <cstdio>
#include <cstring>
#include <cstdarg>
#include <algorithm>
#include <cmath>
#include <sstream>
#include <random>
#include <iostream>
#include <chrono>

// Config
static const char* DEFAULT_MODEL_PATH = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static const int   N_CTX     = 64;
static const int   N_THREADS = 6;
static const int   MAX_CTX_TOK = 10;

static llama_model*       g_model = nullptr;
static llama_context*     g_ctx   = nullptr;
static const llama_vocab* g_vocab = nullptr;

// Tokenize
static std::vector<llama_token> tokenize(const char* text) {
    std::vector<llama_token> toks(128);
    int n = llama_tokenize(g_vocab, text, (int)strlen(text), toks.data(), (int)toks.size(), true, true);
    if (n < 0) { toks.resize(-n); n = llama_tokenize(g_vocab, text, (int)strlen(text), toks.data(), (int)toks.size(), true, true); }
    toks.resize(std::max(0, n));
    return toks;
}

// Cross-entropy for a single token
static double cross_entropy(float* logits, int vs, int tid) {
    float m = -1e30f;
    for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
    double se = 0;
    for (int k = 0; k < vs; k++) se += exp((double)(logits[k] - m));
    return -((double)(logits[tid] - m) - log(se));
}

// Gold scoring: single-seq per candidate (authoritative)
static std::vector<double> score_candidates(
    const std::vector<llama_token>& ctx_ids,
    const std::vector<std::vector<llama_token>>& cand_ids)
{
    int n = (int)cand_ids.size(), ctx_len = (int)ctx_ids.size(), vs = llama_n_vocab(g_vocab);
    std::vector<double> scores(n, -1e10);

    for (int i = 0; i < n; i++) {
        llama_memory_clear(llama_get_memory(g_ctx), true);
        int wlen = (int)cand_ids[i].size();
        llama_batch b = llama_batch_init(ctx_len + wlen, 0, 1);
        for (int j = 0; j < ctx_len; j++) {
            b.token[j] = ctx_ids[j]; b.pos[j] = j;
            b.n_seq_id[j] = 1; b.seq_id[j][0] = 0;
        }
        b.logits[ctx_len - 1] = 1;
        for (int j = 0; j < wlen; j++) {
            int p = ctx_len + j; b.token[p] = cand_ids[i][j];
            b.pos[p] = p; b.n_seq_id[p] = 1; b.seq_id[p][0] = 0; b.logits[p] = 1;
        }
        b.n_tokens = ctx_len + wlen;
        if (llama_decode(g_ctx, b) != 0) { llama_batch_free(b); continue; }
        double ce = 0;
        for (int j = 0; j < wlen; j++) {
            float* l = llama_get_logits_ith(g_ctx, ctx_len - 1 + j);
            if (!l) { ce = -1e10; break; }
            ce += cross_entropy(l, vs, cand_ids[i][j]);
        }
        scores[i] = ce > -1e9 ? -ce : -1e10;
        llama_batch_free(b);
    }
    return scores;
}

// Simple JSON parser: extract string value for key
static std::string json_get_string(const std::string& json, const char* key) {
    std::string search = std::string("\"") + key + "\"";
    size_t p = json.find(search);
    if (p == std::string::npos) return "";
    p = json.find("\"", p + search.size());
    if (p == std::string::npos) return "";
    size_t start = p + 1;
    // Handle escaped quotes
    std::string result;
    for (size_t i = start; i < json.size(); i++) {
        if (json[i] == '\\' && i + 1 < json.size()) { result += json[++i]; continue; }
        if (json[i] == '"') break;
        result += json[i];
    }
    return result;
}

// Extract string array for key
static std::vector<std::string> json_get_array(const std::string& json, const char* key) {
    std::vector<std::string> result;
    std::string search = std::string("\"") + key + "\"";
    size_t p = json.find(search);
    if (p == std::string::npos) return result;
    p = json.find("[", p);
    if (p == std::string::npos) return result;
    size_t start = p + 1;
    std::string item;
    bool in_string = false;
    for (size_t i = start; i < json.size(); i++) {
        char c = json[i];
        if (c == '"' && (i == start || json[i-1] != '\\')) { in_string = !in_string; continue; }
        if (!in_string) {
            if (c == ',' || c == ']') {
                if (!item.empty()) { result.push_back(item); item.clear(); }
                if (c == ']') break;
                continue;
            }
            if (c == ' ' || c == '\n' || c == '\t') continue;
        }
        if (in_string) item += c;
    }
    return result;
}

int main(int argc, char* argv[]) {
    const char* model_path = (argc > 1) ? argv[1] : DEFAULT_MODEL_PATH;
    // --scores: 输出 {"ranked":[...],"scores":{词:原始分,...}} (权重分析用;
    // 默认仍输出纯 ranked 数组, eval_rerank.py 依赖不变)
    bool emit_scores = false;
    for (int i = 1; i < argc; i++)
        if (strcmp(argv[i], "--scores") == 0) emit_scores = true;
    fprintf(stderr, "Model: %s%s\n", model_path, emit_scores ? " (--scores)" : "");

    // Init model
    auto t0 = std::chrono::high_resolution_clock::now();
    llama_backend_init();
    llama_model_params mparams = llama_model_default_params();
    mparams.use_mmap = 1;
    g_model = llama_model_load_from_file(model_path, mparams);
    if (!g_model) { fprintf(stderr, "FATAL: model load failed\n"); return 3; }
    g_vocab = llama_model_get_vocab(g_model);

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = N_CTX;
    cparams.n_threads = N_THREADS;
    cparams.n_threads_batch = N_THREADS;
    g_ctx = llama_new_context_with_model(g_model, cparams);
    if (!g_ctx) { fprintf(stderr, "FATAL: context create failed\n"); return 3; }
    auto t1 = std::chrono::high_resolution_clock::now();
    auto load_ms = std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();
    fprintf(stderr, "Model loaded in %lld ms (n_ctx=%d threads=%d)\n", load_ms, N_CTX, N_THREADS);

    // Process stdin line by line
    std::string line;
    int count = 0;
    double total_ms = 0;
    while (std::getline(std::cin, line)) {
        if (line.empty()) continue;

        std::string context = json_get_string(line, "context");
        if (context.empty()) context = " ";
        auto cand_texts = json_get_array(line, "cands");
        if (cand_texts.empty()) { printf("[]\n"); continue; }

        // Tokenize context (trim to MAX_CTX_TOK)
        auto ctx_ids = tokenize(context.c_str());
        if ((int)ctx_ids.size() > MAX_CTX_TOK)
            ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - MAX_CTX_TOK);

        // Tokenize candidates
        std::vector<std::vector<llama_token>> cand_ids;
        for (auto& c : cand_texts)
            cand_ids.push_back(tokenize(c.c_str()));

        // Score
        auto t_s0 = std::chrono::high_resolution_clock::now();
        auto scores = score_candidates(ctx_ids, cand_ids);
        auto t_s1 = std::chrono::high_resolution_clock::now();
        total_ms += std::chrono::duration_cast<std::chrono::microseconds>(t_s1 - t_s0).count() / 1000.0;

        // Rank
        std::vector<int> order(cand_texts.size());
        for (int i = 0; i < (int)order.size(); i++) order[i] = i;
        std::sort(order.begin(), order.end(),
            [&](int a, int b) { return scores[a] > scores[b]; });

        // Output
        if (emit_scores) {
            printf("{\"ranked\":[");
            for (int i = 0; i < (int)order.size(); i++) {
                if (i > 0) printf(",");
                std::string escaped;
                for (char c : cand_texts[order[i]]) {
                    if (c == '"' || c == '\\') escaped += '\\';
                    escaped += c;
                }
                printf("\"%s\"", escaped.c_str());
            }
            printf("],\"scores\":{");
            bool first = true;
            for (int i = 0; i < (int)cand_texts.size(); i++) {
                if (scores[i] <= -1e9) continue;  // 失败哨兵不输出
                if (!first) printf(",");
                first = false;
                std::string escaped;
                for (char c : cand_texts[i]) {
                    if (c == '"' || c == '\\') escaped += '\\';
                    escaped += c;
                }
                printf("\"%s\":%.6f", escaped.c_str(), scores[i]);
            }
            printf("}}\n");
        } else {
            printf("[");
            for (int i = 0; i < (int)order.size(); i++) {
                if (i > 0) printf(",");
                // Escape quotes in output
                std::string escaped;
                for (char c : cand_texts[order[i]]) {
                    if (c == '"' || c == '\\') escaped += '\\';
                    escaped += c;
                }
                printf("\"%s\"", escaped.c_str());
            }
            printf("]\n");
        }
        fflush(stdout);

        count++;
        if (count % 10 == 0)
            fprintf(stderr, "  processed %d entries\n", count);
    }

    double avg_ms = count > 0 ? total_ms / count : 0;
    fprintf(stderr, "Done. %d entries, %.1f ms avg, %.0f ms total\n", count, avg_ms, total_ms);

    llama_free(g_ctx);
    llama_model_free(g_model);
    llama_backend_free();
    return 0;
}
