/*
 * bench_thr_cand.cpp — 验证延迟阶梯与线程数的关系
 * 固定 tok=10，扫 cand=2..9 × thr=1,2,4,6,8
 */
#define NOMINMAX
#include <windows.h>
#include "llama.h"

#include <string>
#include <vector>
#include <cstdio>
#include <cstring>
#include <cstdarg>
#include <algorithm>
#include <cmath>

static std::string g_model_path = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static llama_model       * g_model = nullptr;
static const llama_vocab * g_vocab = nullptr;

static void log_msg(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap); printf("\n"); fflush(stdout);
}

static double cross_entropy(float* logits, int vs, int tid) {
    float m = -1e30f; for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
    double se = 0; for (int k = 0; k < vs; k++) se += exp((double)(logits[k] - m));
    return -((double)(logits[tid] - m) - log(se));
}

// 分层并行 score_batch（与生产一致）
static void score_batch(llama_context* ctx, const std::vector<llama_token>& ctx_ids,
                         const std::vector<std::vector<llama_token>>& cands,
                         std::vector<double>& scores_out) {
    scores_out.assign(cands.size(), -1e10);
    int n_cands = (int)cands.size();
    if (n_cands == 0) return;

    int ctx_len = (int)ctx_ids.size();
    int vs = llama_n_vocab(g_vocab);
    auto* mem = llama_get_memory(ctx);

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
    if (llama_decode(ctx, ctx_batch) == 0) {
        float* cl = llama_get_logits_ith(ctx, ctx_len - 1);
        if (cl) ctx_logits.assign(cl, cl + vs);
    }
    llama_batch_free(ctx_batch);
    if (ctx_logits.empty()) return;

    std::vector<double> ce_sum(n_cands, 0);
    for (int i = 0; i < n_cands; i++) {
        ce_sum[i] = cross_entropy(ctx_logits.data(), vs, cands[i][0]);
    }

    // Step 2
    if (M > 0) {
        for (int s = 0; s < M; s++) {
            llama_memory_seq_cp(mem, 0, s + 1, 0, -1);
            cand_to_seq[idx2[s]] = s + 1;
        }
        llama_batch b2 = llama_batch_init(M, 0, M);
        for (int s = 0; s < M; s++) {
            int ci = idx2[s];
            b2.token[s] = cands[ci][0]; b2.pos[s] = ctx_len;
            b2.n_seq_id[s] = 1; b2.seq_id[s][0] = s + 1; b2.logits[s] = 1;
        }
        b2.n_tokens = M;
        if (llama_decode(ctx, b2) == 0) {
            for (int s = 0; s < M; s++) {
                int ci = idx2[s];
                float* l = llama_get_logits_ith(ctx, s);
                if (l) ce_sum[ci] += cross_entropy(l, vs, cands[ci][1]);
                else   ce_sum[ci] = -1e10;
            }
        } else { for (int ci : idx2) ce_sum[ci] = -1e10; }
        llama_batch_free(b2);
    }

    // Step 3
    if (K > 0) {
        llama_batch b3 = llama_batch_init(K, 0, K);
        for (int s = 0; s < K; s++) {
            int ci = idx3[s];
            b3.token[s] = cands[ci][1]; b3.pos[s] = ctx_len + 1;
            b3.n_seq_id[s] = 1; b3.seq_id[s][0] = cand_to_seq[ci]; b3.logits[s] = 1;
        }
        b3.n_tokens = K;
        if (llama_decode(ctx, b3) == 0) {
            for (int s = 0; s < K; s++) {
                int ci = idx3[s];
                float* l = llama_get_logits_ith(ctx, s);
                if (l) ce_sum[ci] += cross_entropy(l, vs, cands[ci][2]);
                else   ce_sum[ci] = -1e10;
            }
        } else { for (int ci : idx3) ce_sum[ci] = -1e10; }
        llama_batch_free(b3);
    }

    for (int i = 0; i < n_cands; i++)
        scores_out[i] = ce_sum[i] > -1e9 ? -ce_sum[i] : -1e10;
}

int main() {
    log_msg("=== thr x cand Latency Sweep (tok=10) ===");
    llama_backend_init();
    llama_model_params mp = llama_model_default_params(); mp.use_mmap = 1;
    g_model = llama_model_load_from_file(g_model_path.c_str(), mp);
    if (!g_model) { log_msg("ERROR: load model"); return 1; }
    g_vocab = llama_model_get_vocab(g_model);

    printf("\n=== Latency p50 (ms), tok=10 ===\n");
    printf("%-8s", "thr\\cand");
    for (int cand = 2; cand <= 9; cand++) printf("c=%-2d   ", cand);
    printf("\n");

    for (int thr : {3, 4, 6, 8}) {
        llama_context_params cp = llama_context_default_params();
        cp.n_ctx = 64; cp.n_threads = thr; cp.n_threads_batch = thr; cp.n_seq_max = 12;
        auto* ctx = llama_new_context_with_model(g_model, cp);
        if (!ctx) { log_msg("ERROR: create ctx thr=%d", thr); continue; }

        // Warmup
        {
            llama_memory_clear(llama_get_memory(ctx), false);
            llama_token tok[4];
            int n = llama_tokenize(g_vocab, "\n", 1, tok, 4, true, true);
            if (n > 0) { llama_batch b = llama_batch_get_one(tok, n); llama_decode(ctx, b); }
        }

        printf("%-8d", thr);

        for (int cand = 2; cand <= 9; cand++) {
            // 固定 ctx（10 个随机 token）
            std::vector<llama_token> ctx_ids(10);
            for (int j = 0; j < 10; j++) ctx_ids[j] = 100 + (j % 1000);

            // 随机候选（全部 2-token，最坏情况）
            std::vector<std::vector<llama_token>> cands(cand);
            for (int c = 0; c < cand; c++) {
                cands[c].push_back(200 + c * 10);
                cands[c].push_back(200 + c * 10 + 1);
            }

            // Warmup
            std::vector<double> dummy;
            for (int w = 0; w < 10; w++) score_batch(ctx, ctx_ids, cands, dummy);

            // Measure
            LARGE_INTEGER freq; QueryPerformanceFrequency(&freq);
            std::vector<double> times; times.reserve(200);
            for (int m = 0; m < 200; m++) {
                LARGE_INTEGER t0, t1;
                QueryPerformanceCounter(&t0);
                score_batch(ctx, ctx_ids, cands, dummy);
                QueryPerformanceCounter(&t1);
                times.push_back((double)(t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart);
            }

            std::sort(times.begin(), times.end());
            double p50 = times[times.size() / 2];
            printf("%-7.0f", p50);
            fflush(stdout);
        }
        printf("\n");
        fflush(stdout);
        llama_free(ctx);
    }

    llama_model_free(g_model); llama_backend_free();
    log_msg("Done.");
    return 0;
}
