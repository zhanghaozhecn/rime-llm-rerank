/*
 * bench_latency.cpp — CPU 延迟扫参：tok(1-20) × cand(2-9)
 * 使用与生产完全相同的 score_batch（分层并行解码）
 */
#define NOMINMAX
#include <windows.h>
#include "llama.h"

#include <string>
#include <vector>
#include <thread>
#include <cstdio>
#include <cstring>
#include <cstdarg>
#include <algorithm>
#include <cmath>
#include <fstream>

// ============================================================
// 配置
// ============================================================
static std::string g_model_path = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static int g_n_ctx = 64, g_n_seq_max = 12;

static int auto_threads() {
    unsigned int hw = std::thread::hardware_concurrency();
    if (hw == 0) return 6;
    int t = (int)std::ceil(hw / 3.0);
    return (t < 4) ? 4 : t;
}

static llama_model       * g_model = nullptr;
static llama_context     * g_ctx   = nullptr;
static const llama_vocab * g_vocab = nullptr;

// ============================================================
// 日志
// ============================================================
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

// ============================================================
// CE
// ============================================================
static double cross_entropy(float* logits, int vs, int tid) {
    float m = -1e30f; for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
    double se = 0; for (int k = 0; k < vs; k++) se += exp((double)(logits[k] - m));
    return -((double)(logits[tid] - m) - log(se));
}

// ============================================================
// 分层并行 score_batch — 与 rime_llm.cpp 完全一致
// ============================================================
static void score_batch(const std::vector<llama_token> & ctx_ids,
                         const std::vector<std::vector<llama_token>> & cands,
                         std::vector<double> & scores_out) {
    scores_out.assign(cands.size(), -1e10);
    int n_cands = (int)cands.size();
    if (n_cands == 0) return;

    int ctx_len = (int)ctx_ids.size();
    int vs = llama_n_vocab(g_vocab);
    auto* mem = llama_get_memory(g_ctx);

    // 分组
    std::vector<int> idx2, idx3;
    for (int i = 0; i < n_cands; i++) {
        if (cands[i].size() >= 2) idx2.push_back(i);
        if (cands[i].size() >= 3) idx3.push_back(i);
    }
    int M = (int)idx2.size();
    int K = (int)idx3.size();
    std::vector<int> cand_to_seq(n_cands, -1);

    // Step 1: ctx decode
    llama_memory_clear(mem, false);
    llama_batch ctx_batch = llama_batch_init(ctx_len, 0, 1);
    for (int j = 0; j < ctx_len; j++) {
        ctx_batch.token[j] = ctx_ids[j]; ctx_batch.pos[j] = j;
        ctx_batch.n_seq_id[j] = 1; ctx_batch.seq_id[j][0] = 0;
    }
    ctx_batch.logits[ctx_len - 1] = 1;
    ctx_batch.n_tokens = ctx_len;
    std::vector<float> ctx_logits;
    if (llama_decode(g_ctx, ctx_batch) == 0) {
        float* cl = llama_get_logits_ith(g_ctx, ctx_len - 1);
        if (cl) ctx_logits.assign(cl, cl + vs);
    }
    llama_batch_free(ctx_batch);
    if (ctx_logits.empty()) return;

    std::vector<double> ce_sum(n_cands, 0);
    for (int i = 0; i < n_cands; i++) {
        ce_sum[i] = cross_entropy(ctx_logits.data(), vs, cands[i][0]);
    }

    // Step 2: multi-token 1st token
    if (M > 0) {
        for (int s = 0; s < M; s++) {
            llama_memory_seq_cp(mem, 0, s + 1, 0, -1);
            cand_to_seq[idx2[s]] = s + 1;
        }
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
    }

    // Step 3: 3-token 2nd token
    if (K > 0) {
        llama_batch b3 = llama_batch_init(K, 0, K);
        for (int s = 0; s < K; s++) {
            int ci = idx3[s];
            int seq_id = cand_to_seq[ci];
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

    for (int i = 0; i < n_cands; i++) {
        scores_out[i] = ce_sum[i] > -1e9 ? -ce_sum[i] : -1e10;
    }
}

// ============================================================
// 统计
// ============================================================
struct Stats {
    double p50, mean, p95, p99;
};

static Stats compute_stats(std::vector<double>& times) {
    std::sort(times.begin(), times.end());
    int n = (int)times.size();
    Stats s;
    s.p50  = times[n / 2];
    s.mean = 0; for (double t : times) s.mean += t; s.mean /= n;
    s.p95  = times[(int)(n * 0.95)];
    s.p99  = times[(int)(n * 0.99)];
    return s;
}

// ============================================================
// main
// ============================================================
int main() {
    log_msg("=== Latency Sweep: tok(1-20) x cand(2-9), CPU, layered decode ===");

    // Init
    llama_backend_init();
    llama_model_params mp = llama_model_default_params();
    mp.use_mmap = 1;
    g_model = llama_model_load_from_file(g_model_path.c_str(), mp);
    if (!g_model) { log_msg("ERROR: load model failed"); return 1; }
    g_vocab = llama_model_get_vocab(g_model);

    llama_context_params cp = llama_context_default_params();
    int n_thr = auto_threads();
    cp.n_ctx = g_n_ctx; cp.n_threads = n_thr; cp.n_threads_batch = n_thr; cp.n_seq_max = g_n_seq_max;
    g_ctx = llama_new_context_with_model(g_model, cp);
    if (!g_ctx) { log_msg("ERROR: create context failed"); llama_model_free(g_model); return 1; }

    // Warmup model
    {
        llama_memory_clear(llama_get_memory(g_ctx), false);
        const char* warmup = "\n";
        llama_token tok[4];
        int n = llama_tokenize(g_vocab, warmup, (int)strlen(warmup), tok, 4, true, true);
        if (n > 0) {
            llama_batch b = llama_batch_get_one(tok, n);
            llama_decode(g_ctx, b);
        }
    }
    log_msg("Model ready (thr=%d), starting sweep...", n_thr);

    int vs = llama_n_vocab(g_vocab);
    int total_cells = 20 * 8;  // tok=1..20 × cand=2..9
    int done = 0;

    printf("\n=== Latency Table (p50 ms) ===\n");
    printf("%-8s", "tok\\cand");
    for (int cand = 2; cand <= 9; cand++) printf("c=%-2d   ", cand);
    printf("\n");

    FILE* fout = fopen("bench_latency_result.txt", "w");
    fprintf(fout, "=== Latency Sweep: tok(1-20) x cand(2-9), CPU thr=%d (auto: max(4,ceil(hw/3))) ===\n", n_thr);
    fprintf(fout, "tok\\cand");
    for (int cand = 2; cand <= 9; cand++) fprintf(fout, "\tcand=%d", cand);
    fprintf(fout, "\n");

    for (int tok = 1; tok <= 20; tok++) {
        printf("%-8d", tok);
        fprintf(fout, "tok=%d", tok);

        for (int cand = 2; cand <= 9; cand++) {
            // 生成随机 ctx（tok 个 token）
            std::vector<llama_token> ctx_ids(tok);
            for (int j = 0; j < tok; j++) ctx_ids[j] = 100 + (j % 1000);  // arbitrary valid tokens

            // 生成候选（全部 2-token，最坏情况）
            std::vector<std::vector<llama_token>> cands(cand);
            for (int c = 0; c < cand; c++) {
                cands[c].push_back(200 + c * 10);
                cands[c].push_back(200 + c * 10 + 1);
            }

            // Warmup
            std::vector<double> dummy;
            for (int w = 0; w < 20; w++) {
                score_batch(ctx_ids, cands, dummy);
            }

            // Measure
            LARGE_INTEGER freq;
            QueryPerformanceFrequency(&freq);
            std::vector<double> times;
            times.reserve(100);

            for (int m = 0; m < 100; m++) {
                LARGE_INTEGER t0, t1;
                QueryPerformanceCounter(&t0);
                score_batch(ctx_ids, cands, dummy);
                QueryPerformanceCounter(&t1);
                double ms = (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart;
                times.push_back(ms);
            }

            Stats s = compute_stats(times);
            printf("%-7.1f", s.p50);
            fprintf(fout, "\t%.1f", s.p50);

            done++;
            if (done % 10 == 0) {
                log_msg("  progress: %d/%d cells", done, total_cells);
            }
        }
        printf("\n");
        fprintf(fout, "\n");
        fflush(fout);
    }

    // 完整统计表 (p50/mean/p95/p99)
    printf("\n=== Full Stats (p50 / mean / p95 / p99) ===\n");
    for (int tok : {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 15, 20}) {
        printf("--- tok=%d ---\n", tok);
        for (int cand : {2, 3, 4, 5, 6, 7, 8, 9}) {
            std::vector<llama_token> ctx_ids(tok);
            for (int j = 0; j < tok; j++) ctx_ids[j] = 100 + (j % 1000);

            std::vector<std::vector<llama_token>> cands(cand);
            for (int c = 0; c < cand; c++) {
                cands[c].push_back(200 + c * 10);
                cands[c].push_back(200 + c * 10 + 1);
            }

            std::vector<double> dummy;
            for (int w = 0; w < 10; w++) score_batch(ctx_ids, cands, dummy);

            LARGE_INTEGER freq;
            QueryPerformanceFrequency(&freq);
            std::vector<double> times;
            times.reserve(200);

            for (int m = 0; m < 200; m++) {
                LARGE_INTEGER t0, t1;
                QueryPerformanceCounter(&t0);
                score_batch(ctx_ids, cands, dummy);
                QueryPerformanceCounter(&t1);
                times.push_back((double)(t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart);
            }

            Stats s = compute_stats(times);
            printf("  cand=%d  p50=%.1f  mean=%.1f  p95=%.1f  p99=%.1f\n",
                   cand, s.p50, s.mean, s.p95, s.p99);
        }
    }

    fclose(fout);

    // Cleanup
    llama_free(g_ctx);
    llama_model_free(g_model);
    llama_backend_free();

    log_msg("Done. Results: bench_latency_result.txt");
    return 0;
}
