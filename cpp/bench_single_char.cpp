/*
 * bench_single_char.cpp — 0.8B CPU 单字首选率（tok=10, cand=5）
 * 只评估 3 码单编码单字（code len=3）
 */
#define NOMINMAX
#include <windows.h>
#include "llama.h"

#include <string>
#include <vector>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <cstdarg>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <sstream>

static std::string g_model_path = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static int g_n_ctx = 128;
static int g_n_seq_max = 12;
static int g_n_threads = 7;

static llama_model       * g_model = nullptr;
static llama_context     * g_ctx   = nullptr;
static const llama_vocab * g_vocab = nullptr;

static void log_msg(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap); printf("\n"); fflush(stdout);
}

static std::vector<llama_token> tokenize(const char* text) {
    std::vector<llama_token> toks(128);
    int n = llama_tokenize(g_vocab, text, (int)strlen(text), toks.data(), (int)toks.size(), true, true);
    if (n < 0) { toks.resize(-n); n = llama_tokenize(g_vocab, text, (int)strlen(text), toks.data(), (int)toks.size(), true, true); }
    toks.resize(std::max(0, n));
    return toks;
}

static double cross_entropy(float* logits, int vs, int tid) {
    float m = -1e30f; for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
    double se = 0; for (int k = 0; k < vs; k++) se += exp((double)(logits[k] - m));
    return -((double)(logits[tid] - m) - log(se));
}

struct Sample {
    std::string context, correct_word, code;
    int pos_in_list, total_same_code;
    std::vector<std::string> same_code_words;
};

int main() {
    log_msg("=== Single-char 3-code Accuracy: tok=10 cand=5 ===");
    log_msg("Model: 0.8B Q4_K_M, threads=%d", g_n_threads);

    // Load model
    llama_backend_init();
    llama_model_params mp = llama_model_default_params(); mp.use_mmap = 1;
    g_model = llama_model_load_from_file(g_model_path.c_str(), mp);
    if (!g_model) { log_msg("ERROR: load model"); return 1; }
    g_vocab = llama_model_get_vocab(g_model);

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = g_n_ctx; cp.n_threads = g_n_threads; cp.n_threads_batch = g_n_threads; cp.n_seq_max = g_n_seq_max;
    g_ctx = llama_new_context_with_model(g_model, cp);
    if (!g_ctx) { log_msg("ERROR: create ctx"); return 1; }

    // Warmup
    { llama_memory_clear(llama_get_memory(g_ctx), false); llama_token t[4];
      int n = llama_tokenize(g_vocab, "\n", 1, t, 4, true, true);
      if (n > 0) { llama_batch b = llama_batch_get_one(t, n); llama_decode(g_ctx, b); } }

    // Load samples, filter for single-char (code len=3)
    std::vector<Sample> samples;
    std::ifstream sf("eval_samples.tsv");
    if (!sf.is_open()) { log_msg("ERROR: eval_samples.tsv"); return 1; }
    std::string line; int skipped = 0;
    while (std::getline(sf, line)) {
        std::stringstream ss(line);
        Sample s; std::string ps, ts, cand_csv;
        std::getline(ss, s.context, '\t'); std::getline(ss, s.correct_word, '\t');
        std::getline(ss, s.code, '\t'); std::getline(ss, ps, '\t');
        std::getline(ss, cand_csv, '\t'); std::getline(ss, ts, '\t');
        if (s.code.size() != 3) { skipped++; continue; } // 只取单字(3码)
        s.pos_in_list = std::stoi(ps); s.total_same_code = std::stoi(ts);
        std::stringstream cs(cand_csv); std::string w;
        while (std::getline(cs, w, ',')) if (!w.empty()) s.same_code_words.push_back(w);
        samples.push_back(s);
    }
    log_msg("Loaded %zu single-char samples (skipped %d multi-char)", samples.size(), skipped);
    if (samples.empty()) return 0;

    // Evaluate
    int64_t correct = 0, total = 0;
    int MAX_TOK = 10, MAX_CAND = 5;
    auto t_start = std::chrono::high_resolution_clock::now();
    int vs = llama_n_vocab(g_vocab);

    for (int si = 0; si < (int)samples.size(); si++) {
        auto& s = samples[si];
        auto ctx_ids = tokenize(s.context.c_str());
        if (ctx_ids.empty()) continue;
        if ((int)ctx_ids.size() > MAX_TOK) ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - MAX_TOK);
        int ctx_len = (int)ctx_ids.size();

        // Tokenize candidates (same-code words)
        auto correct_ids = tokenize(s.correct_word.c_str());
        if (correct_ids.empty()) correct_ids.push_back(0);
        std::vector<std::vector<llama_token>> other_cands;
        for (auto& w : s.same_code_words) {
            auto ids = tokenize(w.c_str()); if (ids.empty()) ids.push_back(0);
            other_cands.push_back(ids);
        }

        int W = s.total_same_code;
        int correct_pos = s.pos_in_list;
        int nc = std::min(MAX_CAND, W);

        // Auto-correct
        if (W == 1) { correct++; total++; continue; }
        // Auto-wrong
        if (correct_pos >= nc) { total++; continue; }

        // Build cand subset with correct word at correct position
        std::vector<std::vector<llama_token>> cand_subset;
        int oi = 0;
        for (int pos = 0; pos < nc; pos++) {
            if (pos == correct_pos) cand_subset.push_back(correct_ids);
            else cand_subset.push_back(other_cands[oi++]);
        }

        // ctx decode
        auto* mem = llama_get_memory(g_ctx);
        llama_memory_clear(mem, false);
        llama_batch cb = llama_batch_init(ctx_len, 0, 1);
        for (int j = 0; j < ctx_len; j++) {
            cb.token[j] = ctx_ids[j]; cb.pos[j] = j;
            cb.n_seq_id[j] = 1; cb.seq_id[j][0] = 0;
        }
        cb.logits[ctx_len - 1] = 1; cb.n_tokens = ctx_len;
        std::vector<float> ctx_logits;
        if (llama_decode(g_ctx, cb) != 0) { llama_batch_free(cb); continue; }
        float* cl = llama_get_logits_ith(g_ctx, ctx_len - 1);
        if (!cl) { llama_batch_free(cb); continue; }
        ctx_logits.assign(cl, cl + vs);
        llama_batch_free(cb);

        // Score: 1st token CE
        std::vector<double> ce_sum(nc, 0);
        for (int i = 0; i < nc; i++) ce_sum[i] = cross_entropy(ctx_logits.data(), vs, cand_subset[i][0]);

        // Step 2
        std::vector<int> idx2, idx3;
        for (int i = 0; i < nc; i++) {
            if (cand_subset[i].size() >= 2) idx2.push_back(i);
            if (cand_subset[i].size() >= 3) idx3.push_back(i);
        }
        int M = (int)idx2.size(), K = (int)idx3.size();
        std::vector<int> cand_to_seq(nc, -1);

        if (M > 0) {
            for (int ss = 0; ss < M; ss++) {
                llama_memory_seq_cp(mem, 0, ss + 1, 0, -1);
                cand_to_seq[idx2[ss]] = ss + 1;
            }
            llama_batch b2 = llama_batch_init(M, 0, M);
            for (int ss = 0; ss < M; ss++) {
                int ci = idx2[ss];
                b2.token[ss] = cand_subset[ci][0]; b2.pos[ss] = ctx_len;
                b2.n_seq_id[ss] = 1; b2.seq_id[ss][0] = ss + 1; b2.logits[ss] = 1;
            }
            b2.n_tokens = M;
            if (llama_decode(g_ctx, b2) == 0) {
                for (int ss = 0; ss < M; ss++) {
                    int ci = idx2[ss]; float* l = llama_get_logits_ith(g_ctx, ss);
                    if (l) ce_sum[ci] += cross_entropy(l, vs, cand_subset[ci][1]);
                    else ce_sum[ci] = -1e10;
                }
            } else { for (int ci : idx2) ce_sum[ci] = -1e10; }
            llama_batch_free(b2);
        }
        if (K > 0) {
            llama_batch b3 = llama_batch_init(K, 0, K);
            for (int ss = 0; ss < K; ss++) {
                int ci = idx3[ss];
                b3.token[ss] = cand_subset[ci][1]; b3.pos[ss] = ctx_len + 1;
                b3.n_seq_id[ss] = 1; b3.seq_id[ss][0] = cand_to_seq[ci]; b3.logits[ss] = 1;
            }
            b3.n_tokens = K;
            if (llama_decode(g_ctx, b3) == 0) {
                for (int ss = 0; ss < K; ss++) {
                    int ci = idx3[ss]; float* l = llama_get_logits_ith(g_ctx, ss);
                    if (l) ce_sum[ci] += cross_entropy(l, vs, cand_subset[ci][2]);
                    else ce_sum[ci] = -1e10;
                }
            } else { for (int ci : idx3) ce_sum[ci] = -1e10; }
            llama_batch_free(b3);
        }

        int best = 0;
        for (int i = 1; i < nc; i++) if (ce_sum[i] < ce_sum[best]) best = i;
        total++;
        if (best == correct_pos) correct++;

        if ((si + 1) % 500 == 0) {
            auto t_now = std::chrono::high_resolution_clock::now();
            double ela = std::chrono::duration<double>(t_now - t_start).count();
            double rate = (si + 1) / ela;
            double eta = (samples.size() - si - 1) / rate;
            log_msg("  %d/%zu (%.1f%%)  rate=%.1f/s  ETA=%.0fs  acc=%.1f%%",
                si + 1, samples.size(), 100.0*(si+1)/samples.size(), rate, eta, 100.0*correct/total);
        }
    }

    auto t_end = std::chrono::high_resolution_clock::now();
    double total_sec = std::chrono::duration<double>(t_end - t_start).count();
    log_msg("Done. %.0fs  correct=%lld/%lld  accuracy=%.2f%%",
        total_sec, correct, total, 100.0 * correct / total);

    llama_free(g_ctx); llama_model_free(g_model); llama_backend_free();
    return 0;
}
