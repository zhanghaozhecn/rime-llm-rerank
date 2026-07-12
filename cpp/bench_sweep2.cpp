/*
 * bench_sweep2.cpp — GPU 双因素扫参：上文 token 数 × 候选数
 *
 * 20000 样本词（多字词，不含单字），分层并行解码（与生产一致）。
 * 输出 tok=1..20 × cand=2..9 准确率表格。
 *
 * 优化：每样本每 ctx_len 一次 decode，同时评估所有 cand 子集。
 */
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "llama.h"

#include <vector>
#include <string>
#include <cstdio>
#include <cstring>
#include <cstdarg>
#include <cmath>
#include <fstream>
#include <chrono>
#include <algorithm>
#include <random>
#include <map>
#include <set>
#include <unordered_set>

// ============================================================
// Config
// ============================================================
static const char* MODEL_PATH    = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static const char* SAMPLES_PATH  = "d:/OneDrive/typing/llm_rerank/eval_samples.tsv";
static const char* DICT_PATH     = "d:/OneDrive/typing/llm_rerank/pdsp_dict.yaml";
static const char* CHECKPOINT    = "bench_sweep2_checkpoint.txt";
static const int   N_CTX         = 512;
static const int   N_THREADS     = 4;
static const int   N_GPU_LAYERS  = 0;   // CPU-only，避免笔记本 GPU 过热死机
static const int   N_SEQ_MAX     = 12;
static const int   N_SAMPLES     = 20000;
static const int   MAX_CTX_TOK   = 20;
static const int   MAX_CAND      = 9;
static const int   MIN_WORD_LEN  = 2;  // 多字词

static llama_model*       g_model = nullptr;
static llama_context*     g_ctx   = nullptr;
static const llama_vocab* g_vocab = nullptr;

// 词→首码, 码→同码词列表 (dict order, fixed)
static std::map<std::string, std::string>            g_word_to_code;
static std::map<std::string, std::vector<std::string>> g_code_to_words;
// 同码词在列表中的位置: (code, word) → index
static std::map<std::pair<std::string,std::string>, int> g_code_word_pos;

// 准确率计数
static int acc_count[21][10] = {};
static int acc_total[21][10] = {};
static int g_processed = 0;
static int g_saved_checkpoint = 0;

// ============================================================
// Log
// ============================================================
static void log_msg(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap); printf("\n"); fflush(stdout);
}

static FILE* g_log = nullptr;
static void flog(const char* fmt, ...) {
    if (!g_log) g_log = fopen("bench_sweep2_log.txt", "w");
    va_list ap; va_start(ap, fmt);
    vfprintf(g_log, fmt, ap); va_end(ap);
    fprintf(g_log, "\n"); fflush(g_log);
}

// ============================================================
// Tokenize
// ============================================================
static std::vector<llama_token> tokenize(const char* text) {
    std::vector<llama_token> toks(256);
    int n = llama_tokenize(g_vocab, text, (int)strlen(text), toks.data(), (int)toks.size(), true, true);
    if (n < 0) { toks.resize(-n); n = llama_tokenize(g_vocab, text, (int)strlen(text), toks.data(), (int)toks.size(), true, true); }
    toks.resize(std::max(0, n));
    return toks;
}

static std::string detokenize(const std::vector<llama_token>& toks) {
    std::string result;
    char buf[256];
    for (auto t : toks) {
        int n = llama_token_to_piece(g_vocab, t, buf, sizeof(buf), 0, true);
        if (n > 0) result.append(buf, n);
    }
    return result;
}

// ============================================================
// CE helper
// ============================================================
static double cross_entropy(float* logits, int vs, int tid) {
    float m = -1e30f; for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
    double se = 0; for (int k = 0; k < vs; k++) se += exp((double)(logits[k] - m));
    return -((double)(logits[tid] - m) - log(se));
}

// ============================================================
// Layered scoring (与 rime_llm_cuda.cpp 一致)
// ============================================================
static bool layered_score(llama_context* ctx,
    const std::vector<llama_token>& ctx_ids,
    const std::vector<std::vector<llama_token>>& cands,
    std::vector<double>& scores_out)
{
    int n = (int)cands.size(), ctx_len = (int)ctx_ids.size(), vs = llama_n_vocab(g_vocab);
    scores_out.assign(n, -1e10);
    if (n == 0) return false;

    std::vector<int> idx2, idx3;
    for (int i = 0; i < n; i++) {
        if (cands[i].size() >= 2) idx2.push_back(i);
        if (cands[i].size() >= 3) idx3.push_back(i);
    }
    int M = (int)idx2.size(), K = (int)idx3.size();
    std::vector<int> cand_to_seq(n, -1);

    // Step 1: decode ctx
    llama_memory_clear(llama_get_memory(ctx), true);
    llama_batch ctx_batch = llama_batch_init(ctx_len, 0, 1);
    for (int j = 0; j < ctx_len; j++) {
        ctx_batch.token[j] = ctx_ids[j]; ctx_batch.pos[j] = j;
        ctx_batch.n_seq_id[j] = 1; ctx_batch.seq_id[j][0] = 0;
    }
    ctx_batch.logits[ctx_len - 1] = 1; ctx_batch.n_tokens = ctx_len;
    std::vector<float> ctx_logits;
    if (llama_decode(ctx, ctx_batch) == 0) {
        float* cl = llama_get_logits_ith(ctx, ctx_len - 1);
        if (cl) ctx_logits.assign(cl, cl + vs);
    }
    llama_batch_free(ctx_batch);
    if (ctx_logits.empty()) return false;

    std::vector<double> ce_sum(n, 0);
    for (int i = 0; i < n; i++)
        ce_sum[i] = cross_entropy(ctx_logits.data(), vs, cands[i][0]);

    // Step 2
    if (M > 0) {
        auto mem = llama_get_memory(ctx);
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
                else ce_sum[ci] = -1e10;
            }
        } else { for (int ci : idx2) ce_sum[ci] = -1e10; }
        llama_batch_free(b2);
    }

    // Step 3
    if (K > 0) {
        llama_batch b3 = llama_batch_init(K, 0, K);
        for (int s = 0; s < K; s++) {
            int ci = idx3[s], seq_id = cand_to_seq[ci];
            b3.token[s] = cands[ci][1]; b3.pos[s] = ctx_len + 1;
            b3.n_seq_id[s] = 1; b3.seq_id[s][0] = seq_id; b3.logits[s] = 1;
        }
        b3.n_tokens = K;
        if (llama_decode(ctx, b3) == 0) {
            for (int s = 0; s < K; s++) {
                int ci = idx3[s];
                float* l = llama_get_logits_ith(ctx, s);
                if (l) ce_sum[ci] += cross_entropy(l, vs, cands[ci][2]);
                else ce_sum[ci] = -1e10;
            }
        } else { for (int ci : idx3) ce_sum[ci] = -1e10; }
        llama_batch_free(b3);
    }

    for (int i = 0; i < n; i++)
        scores_out[i] = ce_sum[i] > -1e9 ? -ce_sum[i] : -1e10;
    return true;
}

// ============================================================
// 从句子中提取多字词作为候选
// ============================================================
static bool is_chinese_char(const std::string& s) {
    for (unsigned char c : s)
        if (c < 0x80) return false;
    return true;
}

static bool is_multi_char_word(const std::string& s) {
    if (s.size() < (size_t)MIN_WORD_LEN * 3) return false;  // 至少 MIN_WORD_LEN 个 UTF-8 字符
    // 数 UTF-8 字符数
    int chars = 0;
    for (size_t i = 0; i < s.size(); ) {
        unsigned char c = s[i];
        if (c < 0x80) return false;  // 含 ASCII，不是纯中文词
        if (c < 0xE0) i += 2;
        else if (c < 0xF0) i += 3;
        else i += 4;
        chars++;
    }
    return chars >= MIN_WORD_LEN;
}

// ============================================================
// Load dict
// ============================================================
static void load_dict() {
    std::ifstream f(DICT_PATH);
    if (!f.is_open()) { log_msg("FATAL: cannot open dict: %s", DICT_PATH); return; }
    std::string line;
    bool in_body = false;
    while (std::getline(f, line)) {
        if (line.back() == '\r') line.pop_back();
        if (line == "...") { in_body = true; continue; }
        if (!in_body) continue;
        if (line.empty() || line[0] == '#') continue;
        // format: word\tcode\tstem
        size_t t1 = line.find('\t');
        if (t1 == std::string::npos) continue;
        size_t t2 = line.find('\t', t1 + 1);
        std::string word = line.substr(0, t1);
        std::string code = line.substr(t1 + 1, t2 - t1 - 1);
        if (word.empty() || code.empty()) continue;
        // 只取 4 码词（LLM 重排的目标）
        if (code.size() != 4) continue;
        // 只取每个词的首现编码（多音词取先出现的）
        if (g_word_to_code.find(word) == g_word_to_code.end()) {
            g_word_to_code[word] = code;
        }
    }
    // 构建码→词集 + 位置索引
    for (auto& kv : g_word_to_code) {
        auto& vec = g_code_to_words[kv.second];
        g_code_word_pos[{kv.second, kv.first}] = (int)vec.size();
        vec.push_back(kv.first);
    }
    // 统计同码词数分布
    std::map<int,int> dist;
    for (auto& kv : g_code_to_words) dist[(int)kv.second.size()]++;
    log_msg("Dict: %zu words, %zu codes. Same-code dist: 1=%d 2=%d 3=%d 4=%d 5=%d 6+=%d",
        g_word_to_code.size(), g_code_to_words.size(),
        dist[1], dist[2], dist[3], dist[4], dist[5],
        dist[6]+dist[7]+dist[8]+dist[9]+dist[10]);
}

// ============================================================
// Load/save checkpoint
// ============================================================
static void save_checkpoint(int n) {
    std::ofstream f(CHECKPOINT);
    f << n << "\n";
    for (int t = 1; t <= MAX_CTX_TOK; t++) {
        for (int c = 2; c <= MAX_CAND; c++) {
            f << t << " " << c << " " << acc_count[t][c] << " " << acc_total[t][c] << "\n";
        }
    }
    f.close();
    g_saved_checkpoint = n;
}

static int load_checkpoint() {
    std::ifstream f(CHECKPOINT);
    if (!f.is_open()) return 0;
    int n = 0;
    f >> n;
    for (int i = 0; i < n * (MAX_CTX_TOK) * (MAX_CAND - 1); i++) {
        int t, c, cnt, tot;
        if (!(f >> t >> c >> cnt >> tot)) break;
        if (t >= 1 && t <= MAX_CTX_TOK && c >= 2 && c <= MAX_CAND) {
            acc_count[t][c] = cnt;
            acc_total[t][c] = tot;
        }
    }
    f.close();
    log_msg("Loaded checkpoint: %d samples", n);
    return n;
}

// ============================================================
// Main sweep
// ============================================================
int main() {
    log_msg("=== GPU Sweep: tok=1..%d x cand=2..%d, N=%d ===", MAX_CTX_TOK, MAX_CAND, N_SAMPLES);

    // Init model
    llama_backend_init();
    llama_model_params mparams = llama_model_default_params();
    mparams.use_mmap = 1;
    mparams.n_gpu_layers = N_GPU_LAYERS;
    g_model = llama_model_load_from_file(MODEL_PATH, mparams);
    if (!g_model) { log_msg("FATAL: model load failed"); return 1; }
    g_vocab = llama_model_get_vocab(g_model);

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = N_CTX;
    cparams.n_threads = N_THREADS;
    cparams.n_threads_batch = N_THREADS;
    cparams.n_seq_max = N_SEQ_MAX;
    g_ctx = llama_new_context_with_model(g_model, cparams);
    if (!g_ctx) { log_msg("FATAL: context create failed"); return 1; }
    log_msg("Model loaded (GPU, n_ctx=%d threads=%d gpu_layers=%d)", N_CTX, N_THREADS, N_GPU_LAYERS);

    // Load dict
    load_dict();

    // Load preprocessed samples from prep_samples.py
    // Format: context\tword\tcode\tpos_in_list\tcand1,cand2,...\ttotal
    struct Sample {
        std::string ctx_text, correct_text, correct_code;
        std::vector<std::string> cand_texts;
        int pos_in_list, total_same_code;
    };

    log_msg("Loading preprocessed samples from %s", SAMPLES_PATH);
    std::string line;
    std::vector<Sample> samples;
    {
        std::ifstream fin(SAMPLES_PATH);
        if (!fin.is_open()) { log_msg("FATAL: cannot open samples file"); return 1; }
        while (std::getline(fin, line)) {
            if (line.back() == '\r') line.pop_back();
            if (line.empty()) continue;
            std::vector<std::string> p;
            size_t p0 = 0;
            for (int i = 0; i < 6; i++) {
                size_t p1 = line.find('\t', p0);
                size_t end = (p1 == std::string::npos) ? line.size() : p1;
                p.push_back(line.substr(p0, end - p0));
                p0 = end + 1;
            }
            if (p.size() < 6) continue;
            Sample s;
            s.ctx_text  = p[0];
            s.correct_text = p[1];
            s.correct_code = p[2];
            s.pos_in_list = atoi(p[3].c_str());
            if (!p[4].empty()) {
                size_t cp = 0;
                while (cp < p[4].size()) {
                    size_t cn = p[4].find(',', cp);
                    s.cand_texts.push_back(p[4].substr(cp, (cn == std::string::npos ? p[4].size() : cn) - cp));
                    if (cn == std::string::npos) break;
                    cp = cn + 1;
                }
            }
            s.total_same_code = atoi(p[5].c_str());
            samples.push_back(s);
        }
    }
    log_msg("Loaded %zu samples", samples.size());

    // Resume from checkpoint
    int start = load_checkpoint();
    g_processed = start;

    // Main sweep — optimized: one ctx decode per (sample, tok), all cand counts from one scoring pass
    auto t_total_0 = std::chrono::high_resolution_clock::now();
    int checkpoint_interval = 500;
    int vs = llama_n_vocab(g_vocab);

    int n_process = std::min(N_SAMPLES, (int)samples.size());
    for (int si = start; si < n_process; si++) {
        auto& s = samples[si];
        auto ctx_toks = tokenize(s.ctx_text.c_str());
        int ctx_avail = (int)ctx_toks.size();
        int W = s.total_same_code;
        int correct_pos = s.pos_in_list;

        // Build full candidate list: correct word at its dict position + pre-computed others
        // cand_texts = first 9 other same-code words (dict order, excluding correct)
        std::vector<std::string> full_list;
        int ci = 0;  // index into cand_texts
        for (int i = 0; i < W && (int)full_list.size() < W; i++) {
            if (i == correct_pos)
                full_list.push_back(s.correct_text);
            else if (ci < (int)s.cand_texts.size())
                full_list.push_back(s.cand_texts[ci++]);
        }
        // Tokenize once
        std::vector<std::vector<llama_token>> all_cand_toks;
        for (auto& w : full_list)
            all_cand_toks.push_back(tokenize(w.c_str()));

        for (int tok = 1; tok <= MAX_CTX_TOK; tok++) {
            if (tok > ctx_avail) break;
            // 取最后 tok 个 token（不足则全取）
            std::vector<llama_token> cur_ctx(ctx_toks.end() - tok, ctx_toks.end());
            int ctx_len = tok;

            // 一次性解码全量候选（最多 min(MAX_CAND, W) 个），所有 nc 共享分数
            int N_full = std::min(MAX_CAND, W);
            if (correct_pos >= N_full && W > 1) {
                // 正确词不在前 MAX_CAND 个 → 所有 nc 全错
                for (int nc = 2; nc <= MAX_CAND; nc++)
                    acc_total[tok][nc]++;
                continue;
            }

            // Build candidate list: full_list[0..N_full-1]
            std::vector<std::vector<llama_token>> cands;
            for (int i = 0; i < N_full; i++)
                cands.push_back(all_cand_toks[i]);

            // === 分层评分（一次） ===
            std::vector<int> idx2, idx3;
            for (int i = 0; i < N_full; i++) {
                if (cands[i].size() >= 2) idx2.push_back(i);
                if (cands[i].size() >= 3) idx3.push_back(i);
            }
            int M = (int)idx2.size(), K = (int)idx3.size();
            std::vector<int> cand_to_seq(N_full, -1);

            llama_memory_clear(llama_get_memory(g_ctx), false);
            llama_batch ctx_batch = llama_batch_init(ctx_len, 0, 1);
            for (int j = 0; j < ctx_len; j++) {
                ctx_batch.token[j] = cur_ctx[j]; ctx_batch.pos[j] = j;
                ctx_batch.n_seq_id[j] = 1; ctx_batch.seq_id[j][0] = 0;
            }
            ctx_batch.logits[ctx_len - 1] = 1; ctx_batch.n_tokens = ctx_len;
            std::vector<float> ctx_logits;
            if (llama_decode(g_ctx, ctx_batch) == 0) {
                float* cl = llama_get_logits_ith(g_ctx, ctx_len - 1);
                if (cl) ctx_logits.assign(cl, cl + vs);
            }
            llama_batch_free(ctx_batch);

            std::vector<double> scores(N_full, -1e10);
            if (!ctx_logits.empty()) {
                std::vector<double> ce_sum(N_full, 0);
                for (int i = 0; i < N_full; i++)
                    ce_sum[i] = cross_entropy(ctx_logits.data(), vs, cands[i][0]);

                if (M > 0) {
                    auto mem = llama_get_memory(g_ctx);
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
                        }
                    }
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
                        }
                    }
                    llama_batch_free(b3);
                }

                for (int i = 0; i < N_full; i++)
                    scores[i] = ce_sum[i] > -1e9 ? -ce_sum[i] : -1e10;
            }

            // 所有 nc 子集从同一批分数评估
            for (int nc = 2; nc <= MAX_CAND; nc++) {
                acc_total[tok][nc]++;
                if (W == 1) { acc_count[tok][nc]++; continue; }
                int N = std::min(nc, W);
                if (correct_pos >= N) continue;  // 正确词不在前 N 个，自动错
                int best = 0;
                for (int i = 1; i < N; i++)
                    if (scores[i] > scores[best]) best = i;
                if (best == correct_pos) acc_count[tok][nc]++;
            }
        }

        g_processed++;
        if (g_processed % 50 == 0) {
            auto now = std::chrono::high_resolution_clock::now();
            double elapsed = std::chrono::duration<double>(now - t_total_0).count();
            double rate = g_processed / elapsed;
            double eta = (n_process - g_processed) / rate;
            log_msg("  %d/%d (%.1f%%)  %.0fs  rate=%.1f/s  ETA=%.0fm",
                g_processed, n_process,
                100.0 * g_processed / (double)n_process,
                elapsed, rate, eta / 60);
        }

        if (g_processed - g_saved_checkpoint >= checkpoint_interval) {
            save_checkpoint(g_processed);
            log_msg("  [checkpoint: %d]", g_processed);
        }
    }

    // Final save
    save_checkpoint(g_processed);

    // ============================================================
    // Output table
    // ============================================================
    printf("\n=== Accuracy Table (%%): tok \\ cand ===\n");
    printf("tok\\cand");
    for (int c = 2; c <= MAX_CAND; c++) printf("  cand=%d", c);
    printf("\n");
    for (int t = 1; t <= MAX_CTX_TOK; t++) {
        printf("tok=%-3d", t);
        for (int c = 2; c <= MAX_CAND; c++) {
            if (acc_total[t][c] > 0)
                printf("  %5.1f%%", 100.0 * acc_count[t][c] / acc_total[t][c]);
            else
                printf("      -");
        }
        printf("\n");
    }

    // 同时写入文件
    FILE* out = fopen("bench_sweep2_result.txt", "w");
    fprintf(out, "=== Accuracy Table: tok \\ cand ===\n");
    fprintf(out, "tok\\cand");
    for (int c = 2; c <= MAX_CAND; c++) fprintf(out, "  cand=%d", c);
    fprintf(out, "\n");
    for (int t = 1; t <= MAX_CTX_TOK; t++) {
        fprintf(out, "tok=%-3d", t);
        for (int c = 2; c <= MAX_CAND; c++) {
            if (acc_total[t][c] > 0)
                fprintf(out, "  %5.1f%%", 100.0 * acc_count[t][c] / acc_total[t][c]);
            else
                fprintf(out, "      -");
        }
        fprintf(out, "\n");
    }
    // Raw counts
    fprintf(out, "\n=== Raw counts (correct/total) ===\n");
    for (int t = 1; t <= MAX_CTX_TOK; t++)
        for (int c = 2; c <= MAX_CAND; c++)
            if (acc_total[t][c] > 0)
                fprintf(out, "t=%d c=%d: %d/%d\n", t, c, acc_count[t][c], acc_total[t][c]);
    fclose(out);

    auto t_total_1 = std::chrono::high_resolution_clock::now();
    double total_sec = std::chrono::duration<double>(t_total_1 - t_total_0).count();
    log_msg("Done. Total time: %.0fm (%.0fs)", total_sec/60, total_sec);
    log_msg("Results saved to bench_sweep2_result.txt");

    llama_free(g_ctx);
    llama_model_free(g_model);
    llama_backend_free();
    return 0;
}
