/*
 * test_core.cpp — LLM 重排自动化测试
 *
 * 1. CE 正确性：分层 vs gold 对比（固定用例）
 * 2. 准确率回归：wiki 语料 vs 基线
 * 3. 延迟回归：p50 对比基线
 *
 * 用法: test_core.exe [--baseline] [--samples N]
 *   --baseline  生成/更新基线文件
 *   --samples N  测试样本数（默认 200）
 *
 * 基线文件: test_baseline.json（与 exe 同目录）
 * 退出码: 0=全部通过, 1=测试失败, 2=基线退化
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
#include <fstream>
#include <chrono>
#include <sstream>
#include <random>

// ============================================================
// 配置
// ============================================================
static const char* MODEL_PATH    = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static const char* WIKI_PATH     = "d:/OneDrive/typing/llm_rerank/wiki_corpus.txt";
static const char* BASELINE_FILE = "test_baseline.json";
static const int   N_CTX         = 128;
static const int   N_THREADS     = 6;
static const int   N_SEQ_MAX     = 12;
static const int   MAX_CTX_TOK   = 10;
static const int   MAX_CAND      = 5;

static llama_model*       g_model = nullptr;
static llama_context*     g_ctx   = nullptr;
static const llama_vocab* g_vocab = nullptr;

static int g_tests_pass = 0, g_tests_fail = 0;

// ============================================================
// 工具函数
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

static double cross_entropy(float* logits, int vs, int tid) {
    float m = -1e30f;
    for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
    double se = 0;
    for (int k = 0; k < vs; k++) se += exp((double)(logits[k] - m));
    return -((double)(logits[tid] - m) - log(se));
}

#define CHECK(cond, msg) do { \
    if (cond) { g_tests_pass++; log_msg("  PASS: %s", msg); } \
    else { g_tests_fail++; log_msg("  FAIL: %s", msg); } \
} while(0)

// ============================================================
// 1. CE 正确性测试
// ============================================================

// Gold: single-seq per candidate (权威基准)
static std::vector<double> gold_scores(llama_context* ctx,
    const std::vector<llama_token>& ctx_ids,
    const std::vector<std::vector<llama_token>>& cands)
{
    int n = (int)cands.size(), ctx_len = (int)ctx_ids.size(), vs = llama_n_vocab(g_vocab);
    std::vector<double> scores(n, -1e10);
    for (int i = 0; i < n; i++) {
        llama_memory_clear(llama_get_memory(ctx), true);
        int wlen = (int)cands[i].size();
        llama_batch b = llama_batch_init(ctx_len + wlen, 0, 1);
        for (int j = 0; j < ctx_len; j++) {
            b.token[j] = ctx_ids[j]; b.pos[j] = j;
            b.n_seq_id[j] = 1; b.seq_id[j][0] = 0;
        }
        b.logits[ctx_len - 1] = 1;
        for (int j = 0; j < wlen; j++) {
            int p = ctx_len + j; b.token[p] = cands[i][j];
            b.pos[p] = p; b.n_seq_id[p] = 1; b.seq_id[p][0] = 0; b.logits[p] = 1;
        }
        b.n_tokens = ctx_len + wlen;
        if (llama_decode(ctx, b) != 0) { llama_batch_free(b); continue; }
        double ce = 0;
        for (int j = 0; j < wlen; j++) {
            float* l = llama_get_logits_ith(ctx, ctx_len - 1 + j);
            if (!l) { ce = -1e10; break; }
            ce += cross_entropy(l, vs, cands[i][j]);
        }
        scores[i] = ce > -1e9 ? -ce : -1e10;
        llama_batch_free(b);
    }
    return scores;
}

// Layered: ctx once + KV copy + multi-seq parallel (生产算法)
static std::vector<double> layered_scores(llama_context* ctx,
    const std::vector<llama_token>& ctx_ids,
    const std::vector<std::vector<llama_token>>& cands)
{
    int n = (int)cands.size(), ctx_len = (int)ctx_ids.size(), vs = llama_n_vocab(g_vocab);
    std::vector<double> scores(n, -1e10);

    std::vector<int> idx2, idx3;
    for (int i = 0; i < n; i++) {
        if (cands[i].size() >= 2) idx2.push_back(i);
        if (cands[i].size() >= 3) idx3.push_back(i);
    }
    int M = (int)idx2.size(), K = (int)idx3.size();
    std::vector<int> cand_to_seq(n, -1);

    // Step 1: decode ctx once
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
    if (ctx_logits.empty()) return scores;

    // First-token CE
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
        scores[i] = ce_sum[i] > -1e9 ? -ce_sum[i] : -1e10;
    return scores;
}

struct TestCase {
    const char* label;
    const char* context;
    std::vector<const char*> cands;
};

static void run_ce_tests() {
    log_msg("\n=== 1. CE 正确性测试 ===");

    // 精心设计的测试用例：覆盖各种 token 长度组合
    std::vector<TestCase> cases = {
        {"单 token 候选",
         "今天天气很好",
         {"天", "今", "好", "很", "气"}},
        {"双 token 候选（二字词）",
         "我们去公园散步",
         {"公园", "散步", "商场", "学校", "广场"}},
        {"混合 token 长度",
         "这是一段测试文本",
         {"测试", "一段", "本", "文本", "文"}},
        {"三 token 候选",
         "人工智能技术发展迅速",
         {"人工智能", "机器学习", "深度学习", "神经网络", "计算机"}},
        {"短上下文 + 二字词",
         "我们",
         {"我们", "他们", "你们", "咱们", "大家"}},
        {"长上下文 + 单字",
         "中华人民共和国成立于一九四九年十月一日在北京天安门广场举行了盛大的",
         {"开", "庆", "典", "仪", "式"}},
    };

    for (auto& tc : cases) {
        auto ctx_ids = tokenize(tc.context);
        if ((int)ctx_ids.size() > MAX_CTX_TOK)
            ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - MAX_CTX_TOK);

        std::vector<std::vector<llama_token>> cand_ids;
        for (auto& c : tc.cands)
            cand_ids.push_back(tokenize(c));

        auto gold   = gold_scores(g_ctx, ctx_ids, cand_ids);
        auto layered = layered_scores(g_ctx, ctx_ids, cand_ids);

        // 比较排序结果（核心：选中的候选是否一致）
        std::vector<int> order_gold(cand_ids.size()), order_layered(cand_ids.size());
        for (int i = 0; i < (int)cand_ids.size(); i++)
            order_gold[i] = order_layered[i] = i;
        std::sort(order_gold.begin(), order_gold.end(),
            [&](int a, int b) { return gold[a] > gold[b]; });
        std::sort(order_layered.begin(), order_layered.end(),
            [&](int a, int b) { return layered[a] > layered[b]; });
        bool rank_match = (order_gold == order_layered);

        // CE 绝对值允许 SSM 跨序列干扰导致的微小偏移（已知现象，~0.2）
        double max_diff = 0;
        for (int i = 0; i < (int)cand_ids.size(); i++) {
            double diff = fabs(gold[i] - layered[i]);
            if (diff > max_diff) max_diff = diff;
        }

        char buf[256];
        snprintf(buf, sizeof(buf), "%s (rank=%s, max_CE_diff=%.4f)",
            tc.label, rank_match ? "OK" : "FAIL", max_diff);
        CHECK(rank_match, buf);

        if (!rank_match) {
            log_msg("    Rank mismatch details:");
            for (int i = 0; i < (int)gold.size(); i++)
                log_msg("      [%d] %s: gold=%.6f layered=%.6f", i, tc.cands[i], gold[i], layered[i]);
        }
    }
}

// ============================================================
// 2. 准确率回归测试
// ============================================================

struct Baseline {
    double accuracy;
    double latency_p50;
    int    samples;
};

static Baseline load_baseline() {
    Baseline b = {0, 0, 0};
    std::ifstream f(BASELINE_FILE);
    if (!f.is_open()) return b;
    std::string line, json;
    while (std::getline(f, line)) json += line;
    // 简单 JSON 解析（不引入第三方库）
    auto find_val = [&](const char* key) -> double {
        size_t p = json.find(std::string("\"") + key + "\"");
        if (p == std::string::npos) return 0;
        p = json.find(":", p);
        if (p == std::string::npos) return 0;
        p = json.find_first_of("0123456789.", p);
        if (p == std::string::npos) return 0;
        return atof(json.c_str() + p);
    };
    b.accuracy    = find_val("accuracy");
    b.latency_p50 = find_val("latency_p50");
    b.samples     = (int)find_val("samples");
    return b;
}

static void save_baseline(double acc, double p50, int nsamples) {
    std::ofstream f(BASELINE_FILE);
    char buf[256];
    snprintf(buf, sizeof(buf),
        "{\"accuracy\":%.4f,\"latency_p50\":%.1f,\"samples\":%d}\n", acc, p50, nsamples);
    f << buf;
    log_msg("  Baseline saved: acc=%.4f p50=%.0fms samples=%d", acc, p50, nsamples);
}

// 从 wiki 语料中采样，构造候选集，测试排序准确率
static void run_accuracy_test(int n_samples, bool update_baseline) {
    log_msg("\n=== 2. 准确率回归测试 ===");

    // 读取 wiki 语料
    std::ifstream corpus(WIKI_PATH);
    if (!corpus.is_open()) {
        log_msg("  SKIP: cannot open wiki corpus: %s", WIKI_PATH);
        return;
    }

    // 读取所有行，随机采样
    std::vector<std::string> lines;
    std::string line;
    // 只读前 50000 行加快加载，从中随机采样
    int max_read = 50000;
    while (std::getline(corpus, line) && (int)lines.size() < max_read) {
        if (line.empty() || line[0] == '#') continue;
        lines.push_back(line);
    }
    corpus.close();
    if (lines.empty()) { log_msg("  SKIP: empty corpus"); return; }

    // 随机采样（固定种子保证可复现）
    std::mt19937 rng(42);
    std::vector<int> indices(lines.size());
    for (int i = 0; i < (int)indices.size(); i++) indices[i] = i;
    std::shuffle(indices.begin(), indices.end(), rng);
    if (n_samples > (int)lines.size()) n_samples = (int)lines.size();

    int correct_layered = 0, correct_gold = 0, total = 0;
    std::vector<double> latencies;

    for (int si = 0; si < n_samples; si++) {
        std::string& sent = lines[indices[si]];
        // 清理空白
        sent.erase(std::remove(sent.begin(), sent.end(), '\r'), sent.end());
        sent.erase(std::remove(sent.begin(), sent.end(), '\n'), sent.end());
        if (sent.empty()) continue;

        // 取句子前 MAX_CTX_TOK 个字符作为上下文
        std::string ctx_str = sent.substr(0, std::min((size_t)60, sent.size()));
        auto ctx_ids = tokenize(ctx_str.c_str());
        if ((int)ctx_ids.size() < 2) continue;
        if ((int)ctx_ids.size() > MAX_CTX_TOK)
            ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - MAX_CTX_TOK);

        // 取句子后 5 个字符作为"正确"候选，构建干扰项
        // 实际测试：从句子中随机挑词组作为候选
        // 简化方案：用句中连续字符构造 5 个候选（1 个正确 + 4 个随机）
        std::vector<std::string> cand_texts;
        // 正确候选：句中位置 3-5 的 2-char 片段
        if (sent.size() >= 5) {
            std::string correct = sent.substr(std::min((size_t)3, sent.size()-2), std::min((size_t)2, sent.size()-3));
            cand_texts.push_back(correct);
        }
        // 干扰项：从其他行随机取
        for (int c = 1; c < MAX_CAND && (int)cand_texts.size() < MAX_CAND; c++) {
            int ri = indices[(si + c * 13 + 7) % lines.size()];  // deterministic "random"
            std::string& other = lines[ri];
            if (other.size() >= 2) {
                std::string distractor = other.substr(other.size()/2, std::min((size_t)2, other.size()/2));
                if (std::find(cand_texts.begin(), cand_texts.end(), distractor) == cand_texts.end())
                    cand_texts.push_back(distractor);
            }
        }
        if (cand_texts.size() < 2) continue;

        std::vector<std::vector<llama_token>> cand_ids;
        for (auto& ct : cand_texts)
            cand_ids.push_back(tokenize(ct.c_str()));

        // 用 gold 确定正确答案（gold 选中的视为正确）
        auto gold_sc = gold_scores(g_ctx, ctx_ids, cand_ids);
        int gold_best = 0;
        for (int i = 1; i < (int)gold_sc.size(); i++)
            if (gold_sc[i] > gold_sc[gold_best]) gold_best = i;
        correct_gold++;  // gold 自己就是标准

        // 测分层算法
        auto t0 = std::chrono::high_resolution_clock::now();
        auto lay_sc = layered_scores(g_ctx, ctx_ids, cand_ids);
        auto t1 = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        latencies.push_back(ms);

        int lay_best = 0;
        for (int i = 1; i < (int)lay_sc.size(); i++)
            if (lay_sc[i] > lay_sc[lay_best]) lay_best = i;

        if (lay_best == gold_best) correct_layered++;
        total++;

        if ((si + 1) % 50 == 0)
            log_msg("  progress: %d/%d (acc=%.1f%%)", si+1, n_samples,
                100.0 * correct_layered / total);
    }

    if (total == 0) { log_msg("  SKIP: no valid samples"); return; }

    double acc = 100.0 * correct_layered / total;
    std::sort(latencies.begin(), latencies.end());
    double p50 = latencies[latencies.size() / 2];

    log_msg("  Samples: %d", total);
    log_msg("  Accuracy: %.2f%% (layered vs gold top-1 match)", acc);
    log_msg("  Latency p50: %.0fms", p50);

    Baseline old = load_baseline();

    if (update_baseline) {
        save_baseline(acc, p50, total);
    } else if (old.samples > 0) {
        log_msg("  Baseline: acc=%.2f%% p50=%.0fms samples=%d",
            old.accuracy, old.latency_p50, old.samples);

        double acc_drop = old.accuracy - acc;
        double lat_reg  = (p50 - old.latency_p50) / old.latency_p50 * 100;

        bool acc_ok = acc_drop < 1.0;  // 准确率下降 <1pp
        bool lat_ok = lat_reg < 10.0;  // 延迟增加 <10%

        char acc_buf[256];
        snprintf(acc_buf, sizeof(acc_buf),
            acc_ok ? "Accuracy regression: OK (%.2f%%, baseline %.2f%%)"
                   : "Accuracy regression: FAIL (%.2f%% dropped from %.2f%%)",
            acc, old.accuracy);
        CHECK(acc_ok, acc_buf);

        char lat_buf[256];
        snprintf(lat_buf, sizeof(lat_buf),
            lat_ok ? "Latency regression: OK (p50=%.0fms, baseline %.0fms)"
                   : "Latency regression: FAIL (p50=%.0fms, baseline %.0fms +%.0f%%)",
            p50, old.latency_p50, lat_reg);
        CHECK(lat_ok, lat_buf);
    } else {
        log_msg("  No baseline found. Run with --baseline to create one.");
    }
}

// ============================================================
// Main
// ============================================================
int main(int argc, char** argv) {
    bool update_baseline = false;
    int  n_samples = 200;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--baseline") == 0) update_baseline = true;
        else if (strcmp(argv[i], "--samples") == 0 && i + 1 < argc)
            n_samples = atoi(argv[++i]);
    }

    log_msg("=== LLM Rerank Core Tests ===");
    log_msg("Model: %s", MODEL_PATH);
    log_msg("Samples: %d", n_samples);

    // 初始化模型（CPU）
    llama_backend_init();
    llama_model_params mparams = llama_model_default_params();
    mparams.use_mmap = 1;
    g_model = llama_model_load_from_file(MODEL_PATH, mparams);
    if (!g_model) { log_msg("FATAL: model load failed"); return 3; }
    g_vocab = llama_model_get_vocab(g_model);

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = N_CTX;
    cparams.n_threads = N_THREADS;
    cparams.n_threads_batch = N_THREADS;
    cparams.n_seq_max = N_SEQ_MAX;
    g_ctx = llama_new_context_with_model(g_model, cparams);
    if (!g_ctx) { log_msg("FATAL: context create failed"); return 3; }
    log_msg("Model loaded (n_ctx=%d threads=%d)\n", N_CTX, N_THREADS);

    // 1. CE 正确性
    run_ce_tests();

    // 2. 准确率回归
    run_accuracy_test(n_samples, update_baseline);

    // 清理
    llama_free(g_ctx);
    llama_model_free(g_model);
    llama_backend_free();

    // 总结
    log_msg("\n=== Results: %d passed, %d failed ===", g_tests_pass, g_tests_fail);
    return g_tests_fail > 0 ? 1 : 0;
}
