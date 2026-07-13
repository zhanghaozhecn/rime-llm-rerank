/*
 * bench_sweep_2b.cpp — Qwen3.5-2B Q4_K_M CPU 准确率扫参
 * tok=1..10 × cand=2..5，步进 1，带检查点
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

static std::string g_model_path = "D:/gguf_models/Qwen3.5-2B-Q4_K_M.gguf";
static int g_n_ctx = 128, g_n_seq_max = 12;
static int N_SAMPLES = 20000; // 全量扫参，预计 ~11h
static int MAX_CTX_TOK = 10;
static int MAX_CAND = 5;
static int N_THREADS = 7;

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

// 分层并行 score_batch（与生产一致）
static void score_batch(const std::vector<llama_token>& ctx_ids,
                         const std::vector<std::vector<llama_token>>& cands,
                         std::vector<double>& scores_out) {
    scores_out.assign(cands.size(), -1e10);
    int n_cands = (int)cands.size(); if (n_cands == 0) return;
    int ctx_len = (int)ctx_ids.size(), vs = llama_n_vocab(g_vocab);
    auto* mem = llama_get_memory(g_ctx);

    std::vector<int> idx2, idx3;
    for (int i = 0; i < n_cands; i++) {
        if (cands[i].size() >= 2) idx2.push_back(i);
        if (cands[i].size() >= 3) idx3.push_back(i);
    }
    int M = (int)idx2.size(), K = (int)idx3.size();
    std::vector<int> cand_to_seq(n_cands, -1);

    llama_memory_clear(mem, false);
    llama_batch ctx_batch = llama_batch_init(ctx_len, 0, 1);
    for (int j = 0; j < ctx_len; j++) {
        ctx_batch.token[j] = ctx_ids[j]; ctx_batch.pos[j] = j;
        ctx_batch.n_seq_id[j] = 1; ctx_batch.seq_id[j][0] = 0;
    }
    ctx_batch.logits[ctx_len - 1] = 1; ctx_batch.n_tokens = ctx_len;
    std::vector<float> ctx_logits;
    if (llama_decode(g_ctx, ctx_batch) == 0) {
        float* cl = llama_get_logits_ith(g_ctx, ctx_len - 1);
        if (cl) ctx_logits.assign(cl, cl + vs);
    }
    llama_batch_free(ctx_batch);
    if (ctx_logits.empty()) return;

    std::vector<double> ce_sum(n_cands, 0);
    for (int i = 0; i < n_cands; i++) ce_sum[i] = cross_entropy(ctx_logits.data(), vs, cands[i][0]);

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
        if (llama_decode(g_ctx, b2) == 0) {
            for (int s = 0; s < M; s++) {
                int ci = idx2[s];
                float* l = llama_get_logits_ith(g_ctx, s);
                if (l) ce_sum[ci] += cross_entropy(l, vs, cands[ci][1]);
                else ce_sum[ci] = -1e10;
            }
        } else { for (int ci : idx2) ce_sum[ci] = -1e10; }
        llama_batch_free(b2);
    }

    if (K > 0) {
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
        } else { for (int ci : idx3) ce_sum[ci] = -1e10; }
        llama_batch_free(b3);
    }

    for (int i = 0; i < n_cands; i++)
        scores_out[i] = ce_sum[i] > -1e9 ? -ce_sum[i] : -1e10;
}

struct Sample {
    std::string context;
    std::string correct_word;
    std::string code;
    int pos_in_list;
    std::vector<std::string> same_code_words;
    int total_same_code;
};

struct SweepState {
    int n_done = 0;
    // 正确计数 [tok][cand] — cand index 0..3 maps to cand=2..5
    int64_t correct[11][4] = {};
    int64_t total[11][4] = {};
};

static bool load_checkpoint(SweepState& st, const char* path) {
    std::ifstream f(path);
    if (!f.is_open()) return false;
    f >> st.n_done;
    for (int t = 0; t <= 10; t++)
        for (int c = 0; c < 4; c++)
            f >> st.correct[t][c] >> st.total[t][c];
    return f.good();
}

static void save_checkpoint(const SweepState& st, const char* path) {
    std::ofstream f(path);
    f << st.n_done << "\n";
    for (int t = 0; t <= 10; t++)
        for (int c = 0; c < 4; c++)
            f << st.correct[t][c] << " " << st.total[t][c] << "\n";
}

int main() {
    log_msg("=== Qwen3.5-2B Q4_K_M Accuracy Sweep: tok=1..10 x cand=2..5 ===");
    log_msg("N=%d threads=%d", N_SAMPLES, N_THREADS);

    llama_backend_init();
    llama_model_params mp = llama_model_default_params(); mp.use_mmap = 1;
    g_model = llama_model_load_from_file(g_model_path.c_str(), mp);
    if (!g_model) { log_msg("ERROR: load model"); return 1; }
    g_vocab = llama_model_get_vocab(g_model);

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = g_n_ctx; cp.n_threads = N_THREADS; cp.n_threads_batch = N_THREADS; cp.n_seq_max = g_n_seq_max;
    g_ctx = llama_new_context_with_model(g_model, cp);
    if (!g_ctx) { log_msg("ERROR: create ctx"); return 1; }

    // Warmup
    {
        llama_memory_clear(llama_get_memory(g_ctx), false);
        llama_token tok[4];
        int n = llama_tokenize(g_vocab, "\n", 1, tok, 4, true, true);
        if (n > 0) { llama_batch b = llama_batch_get_one(tok, n); llama_decode(g_ctx, b); }
    }

    // Load preprocessed samples
    std::vector<Sample> samples;
    std::ifstream sf("d:/OneDrive/typing/llm_rerank/eval_samples.tsv");
    if (!sf.is_open()) { log_msg("ERROR: cannot open eval_samples.tsv"); return 1; }
    std::string line;
    while (std::getline(sf, line) && (int)samples.size() < N_SAMPLES) {
        std::stringstream ss(line);
        Sample s;
        std::string pos_str, total_str, cand_csv;
        std::getline(ss, s.context, '\t');
        std::getline(ss, s.correct_word, '\t');
        std::getline(ss, s.code, '\t');
        std::getline(ss, pos_str, '\t');
        std::getline(ss, cand_csv, '\t');
        std::getline(ss, total_str, '\t');
        s.pos_in_list = std::stoi(pos_str);
        s.total_same_code = std::stoi(total_str);

        std::stringstream cs(cand_csv);
        std::string w;
        while (std::getline(cs, w, ','))
            if (!w.empty()) s.same_code_words.push_back(w);
        samples.push_back(s);
    }
    log_msg("Loaded %zu samples", samples.size());
    N_SAMPLES = (int)samples.size();

    // Checkpoint
    SweepState st;
    const char* ckpt_path = "sweep_2b_ckpt.txt";
    if (load_checkpoint(st, ckpt_path))
        log_msg("Resumed from checkpoint: %d/%d", st.n_done, N_SAMPLES);

    auto t_start = std::chrono::high_resolution_clock::now();
    int ckpt_interval = 2000; // 每 ~1h 保存检查点

    for (int si = st.n_done; si < N_SAMPLES; si++) {
        auto& s = samples[si];

        // Tokenize context
        auto ctx_ids = tokenize(s.context.c_str());
        if (ctx_ids.empty()) continue;
        if ((int)ctx_ids.size() > MAX_CTX_TOK)
            ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - MAX_CTX_TOK);

        // Tokenize: 构建完整候选列表（正确词在 pos_in_list 位置）
        auto correct_ids = tokenize(s.correct_word.c_str());
        if (correct_ids.empty()) correct_ids.push_back(0);

        int W = s.total_same_code;  // 总同码词数
        int correct_pos_in_full = s.pos_in_list;

        // all_cands = 前 nc 个候选（不含正确词的其他词），后续按需插入正确词
        std::vector<std::vector<llama_token>> other_cands;
        for (auto& w : s.same_code_words) {
            auto ids = tokenize(w.c_str());
            if (ids.empty()) ids.push_back(0);
            other_cands.push_back(ids);
        }

        // For each tok level, decode ctx once, then score all cand subsets
        for (int tok = 1; tok <= MAX_CTX_TOK; tok++) {
            // Truncate context
            auto ctx = ctx_ids;
            if ((int)ctx.size() > tok) ctx.erase(ctx.begin(), ctx.end() - tok);

            // Single ctx decode for this tok level
            llama_memory_clear(llama_get_memory(g_ctx), false);
            int ctx_len = (int)ctx.size();
            int vs = llama_n_vocab(g_vocab);
            auto* mem = llama_get_memory(g_ctx);

            llama_batch ctx_batch = llama_batch_init(ctx_len, 0, 1);
            for (int j = 0; j < ctx_len; j++) {
                ctx_batch.token[j] = ctx[j]; ctx_batch.pos[j] = j;
                ctx_batch.n_seq_id[j] = 1; ctx_batch.seq_id[j][0] = 0;
            }
            ctx_batch.logits[ctx_len - 1] = 1; ctx_batch.n_tokens = ctx_len;
            std::vector<float> shared_logits;
            if (llama_decode(g_ctx, ctx_batch) == 0) {
                float* cl = llama_get_logits_ith(g_ctx, ctx_len - 1);
                if (cl) shared_logits.assign(cl, cl + vs);
            }
            llama_batch_free(ctx_batch);
            if (shared_logits.empty()) continue;

            // For each cand level, test the subset
            for (int cand = 2; cand <= MAX_CAND; cand++) {
                // Auto-correct: only 1 same-code word total
                if (W == 1) {
                    st.correct[tok][cand - 2]++;
                    st.total[tok][cand - 2]++;
                    continue;
                }

                int nc = std::min(cand, W);

                // Auto-wrong: correct word not in first nc of full list
                // pos_in_list 是正确词在完整同码列表中的位置（0-indexed）
                if (correct_pos_in_full >= nc) {
                    st.total[tok][cand - 2]++;
                    continue;
                }

                // 构建候选子集：前 nc 个同码词，其中正确词在正确位置
                // same_code_words = 其他同码词（不含正确词），需要插入正确词
                std::vector<std::vector<llama_token>> cand_subset;
                int other_idx = 0;
                for (int pos = 0; pos < nc; pos++) {
                    if (pos == correct_pos_in_full) {
                        cand_subset.push_back(correct_ids);
                    } else {
                        cand_subset.push_back(other_cands[other_idx++]);
                    }
                }

                // LLM 评分
                std::vector<double> scores;
                // Build subset with M 2-token, K 3-token
                std::vector<int> idx2, idx3;
                for (int i = 0; i < nc; i++) {
                    if (cand_subset[i].size() >= 2) idx2.push_back(i);
                    if (cand_subset[i].size() >= 3) idx3.push_back(i);
                }
                int M = (int)idx2.size(), K = (int)idx3.size();
                std::vector<int> cand_to_seq(nc, -1);
                std::vector<double> ce_sum(nc, 0);

                // CE for 1st token from shared logits
                for (int i = 0; i < nc; i++)
                    ce_sum[i] = cross_entropy(shared_logits.data(), vs, cand_subset[i][0]);

                // KV copy + decode for multi-token
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
                            int ci = idx2[ss];
                            float* l = llama_get_logits_ith(g_ctx, ss);
                            if (l) ce_sum[ci] += cross_entropy(l, vs, cand_subset[ci][1]);
                            else ce_sum[ci] = -1e10;
                        }
                    } else { for (int ci : idx2) ce_sum[ci] = -1e10; }
                    llama_batch_free(b2);
                }

                if (K > 0) {
                    llama_batch b3 = llama_batch_init(K, 0, K);
                    for (int ss = 0; ss < K; ss++) {
                        int ci = idx3[ss], seq_id = cand_to_seq[ci];
                        b3.token[ss] = cand_subset[ci][1]; b3.pos[ss] = ctx_len + 1;
                        b3.n_seq_id[ss] = 1; b3.seq_id[ss][0] = seq_id; b3.logits[ss] = 1;
                    }
                    b3.n_tokens = K;
                    if (llama_decode(g_ctx, b3) == 0) {
                        for (int ss = 0; ss < K; ss++) {
                            int ci = idx3[ss];
                            float* l = llama_get_logits_ith(g_ctx, ss);
                            if (l) ce_sum[ci] += cross_entropy(l, vs, cand_subset[ci][2]);
                            else ce_sum[ci] = -1e10;
                        }
                    } else { for (int ci : idx3) ce_sum[ci] = -1e10; }
                    llama_batch_free(b3);
                }

                // Find best (lowest CE = most likely)
                int best = 0;
                for (int i = 1; i < nc; i++)
                    if (ce_sum[i] < ce_sum[best]) best = i;

                st.total[tok][cand - 2]++;
                if (best == correct_pos_in_full) st.correct[tok][cand - 2]++;
            }
        }

        st.n_done = si + 1;

        // Progress
        if ((si + 1) % 50 == 0) {
            auto t_now = std::chrono::high_resolution_clock::now();
            double elapsed = std::chrono::duration<double>(t_now - t_start).count();
            double rate = (si + 1 - (st.n_done > ckpt_interval ? 0 : 0)) / elapsed;
            // Just use si+1 / elapsed for simple rate
            double rate2 = (si + 1) / elapsed;
            double eta = (N_SAMPLES - si - 1) / rate2;
            log_msg("  %d/%d (%.1f%%)  elapsed=%.0fs  rate=%.1f/s  ETA=%.0fm",
                    si + 1, N_SAMPLES, 100.0 * (si + 1) / N_SAMPLES, elapsed, rate2, eta / 60);
        }

        // Checkpoint
        if ((si + 1) % ckpt_interval == 0) {
            save_checkpoint(st, ckpt_path);
            log_msg("  checkpoint saved at %d", si + 1);
        }
    }

    // Final results
    printf("\n=== Qwen3.5-2B Accuracy Table: tok x cand ===\n");
    printf("%-8s", "tok\\cand");
    for (int cand = 2; cand <= MAX_CAND; cand++) printf("cand=%-2d ", cand);
    printf("\n");

    FILE* fout = fopen("sweep_2b_result.txt", "w");
    fprintf(fout, "=== Qwen3.5-2B Q4_K_M Accuracy (effective top-1 rate) ===\n");
    fprintf(fout, "tok\\cand");
    for (int cand = 2; cand <= MAX_CAND; cand++) fprintf(fout, "\tcand=%d", cand);
    fprintf(fout, "\n");

    for (int tok = 1; tok <= MAX_CTX_TOK; tok++) {
        printf("%-8d", tok);
        fprintf(fout, "tok=%d", tok);
        for (int cand = 2; cand <= MAX_CAND; cand++) {
            int64_t corr = st.correct[tok][cand - 2];
            int64_t tot = st.total[tok][cand - 2];
            double pct = tot > 0 ? 100.0 * corr / tot : 0;
            printf("%-7.1f", pct);
            fprintf(fout, "\t%.1f", pct);
        }
        printf("\n");
        fprintf(fout, "\n");
    }
    fclose(fout);

    // Clean checkpoint
    remove(ckpt_path);

    auto t_end = std::chrono::high_resolution_clock::now();
    double total_sec = std::chrono::duration<double>(t_end - t_start).count();
    log_msg("Done. Total: %.0fm (%.0fs). Result: sweep_2b_result.txt", total_sec / 60, total_sec);

    llama_free(g_ctx);
    llama_model_free(g_model);
    llama_backend_free();
    return 0;
}
