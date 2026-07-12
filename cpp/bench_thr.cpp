/*
 * bench_thr.cpp — 测试最佳线程数 + 单序列 vs 多序列准确率对比
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
#include <fstream>
#include <unordered_map>
#include <unordered_set>

static std::string g_model_path = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static int g_n_ctx = 96, g_n_seq_max = 9, g_max_tok = 6, g_n_cand = 5;
static llama_model* g_model = nullptr;
static const llama_vocab* g_vocab = nullptr;

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

// Single-seq: per candidate, ctx+cand merged batch (correct gold standard)
static double test_single(llama_context* ctx, const std::vector<llama_token>& ctx_ids,
                           const std::vector<std::vector<llama_token>>& cands,
                           int* best_out, int correct_idx) {
    int n = (int)cands.size(); int ctx_len = (int)ctx_ids.size();
    int vs = llama_n_vocab(g_vocab);
    double best_score = -1e10; *best_out = -1;
    for (int i = 0; i < n; i++) {
        llama_memory_clear(llama_get_memory(ctx), true);
        int wlen = (int)cands[i].size();
        llama_batch b = llama_batch_init(ctx_len + wlen, 0, 1);
        for (int j = 0; j < ctx_len; j++) {
            b.token[j] = ctx_ids[j]; b.pos[j] = j; b.n_seq_id[j]=1; b.seq_id[j][0]=0;
        }
        b.logits[ctx_len-1] = 1;
        for (int j = 0; j < wlen; j++) {
            int p = ctx_len + j; b.token[p] = cands[i][j]; b.pos[p] = p;
            b.n_seq_id[p]=1; b.seq_id[p][0]=0; b.logits[p]=1;
        }
        b.n_tokens = ctx_len + wlen;
        if (llama_decode(ctx, b) != 0) { llama_batch_free(b); continue; }
        double ce = 0;
        for (int j = 0; j < wlen; j++) {
            float* l = llama_get_logits_ith(ctx, ctx_len - 1 + j);  // batch index!
            if (!l) { ce = -1e10; break; }
            ce += cross_entropy(l, vs, cands[i][j]);
        }
        double score = ce > -1e9 ? -ce : -1e10;
        if (score > best_score) { best_score = score; *best_out = i; }
        llama_batch_free(b);
    }
    return *best_out == correct_idx ? 1.0 : 0.0;
}

// Multi-seq: single batch, ctx×N
static double test_multi(llama_context* ctx, const std::vector<llama_token>& ctx_ids,
                          const std::vector<std::vector<llama_token>>& cands,
                          int* best_out, int correct_idx) {
    int n = (int)cands.size(); int ctx_len = (int)ctx_ids.size();
    int vs = llama_n_vocab(g_vocab);
    llama_memory_clear(llama_get_memory(ctx), true);
    int total = 0; for (auto& c : cands) total += ctx_len + (int)c.size();
    llama_batch b = llama_batch_init(total, 0, n);
    int idx = 0;
    for (int i = 0; i < n; i++) {
        int wlen = (int)cands[i].size();
        for (int j = 0; j < ctx_len; j++) {
            b.token[idx]=ctx_ids[j]; b.pos[idx]=j; b.n_seq_id[idx]=1; b.seq_id[idx][0]=i; idx++;
        }
        b.logits[idx-1]=1;
        for (int j = 0; j < wlen; j++) {
            b.token[idx]=cands[i][j]; b.pos[idx]=ctx_len+j; b.n_seq_id[idx]=1; b.seq_id[idx][0]=i;
            b.logits[idx]=1; idx++;
        }
    }
    b.n_tokens = idx;
    if (llama_decode(ctx, b) != 0) { llama_batch_free(b); return 0; }
    double best_score = -1e10; *best_out = -1;
    int row_start = 0;  // batch index where seq i starts
    for (int i = 0; i < n; i++) {
        int wlen = (int)cands[i].size(); double ce = 0;
        for (int j = 0; j < wlen; j++) {
            float* l = llama_get_logits_ith(ctx, row_start + ctx_len - 1 + j);  // batch index!
            if (!l) { ce = -1e10; break; }
            ce += cross_entropy(l, vs, cands[i][j]);
        }
        double score = ce > -1e9 ? -ce : -1e10;
        if (score > best_score) { best_score = score; *best_out = i; }
        row_start += ctx_len + wlen;  // each seq consumes ctx + cand tokens
    }
    llama_batch_free(b);
    return *best_out == correct_idx ? 1.0 : 0.0;
}

// Hybrid: ctx shared + per-candidate for multi-token
static double test_hybrid(llama_context* ctx, const std::vector<llama_token>& ctx_ids,
                           const std::vector<std::vector<llama_token>>& cands,
                           int* best_out, int correct_idx) {
    int n = (int)cands.size(); int ctx_len = (int)ctx_ids.size();
    int vs = llama_n_vocab(g_vocab);

    // Separate single/multi token
    std::vector<int> single_idx, multi_idx;
    for (int i = 0; i < n; i++) {
        if (cands[i].size() == 1) single_idx.push_back(i);
        else multi_idx.push_back(i);
    }

    std::vector<float> saved_logits;
    // Step 1: ctx only decode
    if (!single_idx.empty()) {
        llama_memory_clear(llama_get_memory(ctx), true);
        llama_batch cb = llama_batch_init(ctx_len, 0, 1);
        for (int j = 0; j < ctx_len; j++) {
            cb.token[j] = ctx_ids[j]; cb.pos[j] = j; cb.n_seq_id[j]=1; cb.seq_id[j][0]=0;
        }
        cb.logits[ctx_len-1] = 1; cb.n_tokens = ctx_len;
        if (llama_decode(ctx, cb) == 0) {
            float* l = llama_get_logits_ith(ctx, ctx_len - 1);
            if (l) saved_logits.assign(l, l + vs);
        }
        llama_batch_free(cb);
    }

    // Step 2: score single-token from saved logits
    std::vector<double> scores(n, -1e10);
    for (int idx : single_idx) {
        if (saved_logits.empty()) break;
        scores[idx] = -cross_entropy(saved_logits.data(), vs, cands[idx][0]);
    }

    // Step 3: multi-token full decode
    for (int idx : multi_idx) {
        llama_memory_clear(llama_get_memory(ctx), true);
        int wlen = (int)cands[idx].size();
        llama_batch b = llama_batch_init(ctx_len + wlen, 0, 1);
        for (int j = 0; j < ctx_len; j++) {
            b.token[j] = ctx_ids[j]; b.pos[j] = j; b.n_seq_id[j]=1; b.seq_id[j][0]=0;
        }
        b.logits[ctx_len-1] = 1;
        for (int j = 0; j < wlen; j++) {
            int p = ctx_len + j; b.token[p] = cands[idx][j]; b.pos[p] = p;
            b.n_seq_id[p]=1; b.seq_id[p][0]=0; b.logits[p]=1;
        }
        b.n_tokens = ctx_len + wlen;
        if (llama_decode(ctx, b) != 0) { llama_batch_free(b); continue; }
        double ce = 0;
        for (int j = 0; j < wlen; j++) {
            float* l = llama_get_logits_ith(ctx, ctx_len - 1 + j);
            if (!l) { ce = -1e10; break; }
            ce += cross_entropy(l, vs, cands[idx][j]);
        }
        scores[idx] = ce > -1e9 ? -ce : -1e10;
        llama_batch_free(b);
    }

    double best_score = -1e10; *best_out = -1;
    for (int i = 0; i < n; i++) {
        if (scores[i] > best_score) { best_score = scores[i]; *best_out = i; }
    }
    return *best_out == correct_idx ? 1.0 : 0.0;
}

int main() {
    log_msg("=== Thread + Method Benchmark ===");
    llama_backend_init();
    llama_model_params mp = llama_model_default_params(); mp.use_mmap = 1;
    g_model = llama_model_load_from_file(g_model_path.c_str(), mp);
    if (!g_model) { log_msg("ERROR load model"); return 1; }
    g_vocab = llama_model_get_vocab(g_model);

    // Read dict for real code-mates
    std::unordered_map<std::string, std::vector<std::string>> code_words;
    {
        std::ifstream f("C:/Users/Administrator/AppData/Roaming/Rime/pdsp.dict.yaml");
        std::string line; bool hdr = true;
        while (std::getline(f, line)) {
            if (hdr) { if (line == "...") hdr = false; continue; }
            if (line.empty() || line[0] == '#') continue;
            size_t t1 = line.find('\t'); if (t1 == std::string::npos) continue;
            std::string w = line.substr(0, t1);
            size_t t2 = line.find('\t', t1 + 1);
            std::string c = line.substr(t1 + 1, t2 == std::string::npos ? std::string::npos : t2 - t1 - 1);
            if (c.size() == 4 && w.size() >= 6) code_words[c].push_back(w);
        }
    }
    std::unordered_map<std::string, std::vector<std::string>> hom;
    std::unordered_set<std::string> search;
    for (auto& [c, ws] : code_words) {
        std::vector<std::string> u; std::unordered_set<std::string> seen;
        for (auto& w : ws) if (seen.insert(w).second) u.push_back(w);
        if (u.size() >= 2) hom[c] = u;
        for (auto& w : u) search.insert(w);
    }
    log_msg("Codes with 2+ cands: %d", (int)hom.size());

    // Sample test pairs
    std::ifstream cf("d:/temp_wiki_50k.txt");
    std::string line;
    std::vector<std::tuple<std::string, std::string, std::vector<std::string>>> pairs;
    std::unordered_set<std::string> seen_pairs;
    while (std::getline(cf, line) && (int)pairs.size() < 100) {
        if (line.size() < 6) continue;
        std::string w = line.substr(line.size() - 6);
        if (!search.count(w)) continue;
        // find code
        std::string code;
        for (auto& [c, ws] : code_words) {
            bool found = false;
            for (auto& cw : ws) if (cw == w) { code = c; found = true; break; }
            if (found) break;
        }
        if (code.empty() || !hom.count(code)) continue;
        auto& all = hom[code];
        std::vector<std::string> cands;
        std::unordered_set<std::string> seen_c;
        for (auto& cw : all) if (seen_c.insert(cw).second) cands.push_back(cw);
        if ((int)cands.size() < 2 || (int)cands.size() > 5) continue;
        // pad to 5 with first cand
        while ((int)cands.size() < 5) cands.push_back(cands[0]);
        std::string prev = line.substr(0, line.size() - 6);
        if (prev.size() > 30) prev = prev.substr(prev.size() - 30);
        std::string key = prev + "|" + w;
        if (seen_pairs.insert(key).second)
            pairs.push_back({prev, w, cands});
    }
    log_msg("Test pairs: %d", (int)pairs.size());
    if (pairs.empty()) { log_msg("No pairs!"); return 1; }

    // Test thread counts + methods
    for (int thr : {2, 4, 6, 8}) {
        llama_context_params cp = llama_context_default_params();
        cp.n_ctx = g_n_ctx; cp.n_threads = thr; cp.n_threads_batch = thr; cp.n_seq_max = g_n_seq_max;
        auto* ctx = llama_new_context_with_model(g_model, cp);
        if (!ctx) { log_msg("ERROR ctx thr=%d", thr); continue; }

        LARGE_INTEGER freq; QueryPerformanceFrequency(&freq);
        double ms_single = 0, ms_multi = 0, ms_hybrid = 0;
        int ok_single = 0, ok_multi = 0, ok_hybrid = 0;

        for (int si = 0; si < (int)pairs.size(); si++) {
            auto& [prev, correct, cand_ws] = pairs[si];
            auto ctx_ids = tokenize(prev.c_str());
            if ((int)ctx_ids.size() > g_max_tok) ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - g_max_tok);
            if (ctx_ids.empty()) continue;
            std::vector<std::vector<llama_token>> cands;
            for (auto& cw : cand_ws) { auto ids = tokenize(cw.c_str()); if (ids.empty()) ids.push_back(0); cands.push_back(ids); }
            int correct_idx = -1;
            for (int i = 0; i < (int)cand_ws.size(); i++) if (cand_ws[i] == correct) { correct_idx = i; break; }
            if (correct_idx < 0) continue;

            // warmup
            if (si == 0) { int dummy; test_single(ctx, ctx_ids, cands, &dummy, correct_idx);
                           test_multi(ctx, ctx_ids, cands, &dummy, correct_idx);
                           test_hybrid(ctx, ctx_ids, cands, &dummy, correct_idx); }

            LARGE_INTEGER t0, t1;
            int best;
            QueryPerformanceCounter(&t0);
            ok_single += (int)test_single(ctx, ctx_ids, cands, &best, correct_idx);
            QueryPerformanceCounter(&t1);
            ms_single += (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart;

            QueryPerformanceCounter(&t0);
            ok_multi += (int)test_multi(ctx, ctx_ids, cands, &best, correct_idx);
            QueryPerformanceCounter(&t1);
            ms_multi += (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart;

            QueryPerformanceCounter(&t0);
            ok_hybrid += (int)test_hybrid(ctx, ctx_ids, cands, &best, correct_idx);
            QueryPerformanceCounter(&t1);
            ms_hybrid += (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart;
        }
        int total = (int)pairs.size();
        log_msg("thr=%d single_acc=%.0f%% %.0fms | multi_acc=%.0f%% %.0fms | hybrid_acc=%.0f%% %.0fms",
                thr, 100.0*ok_single/total, ms_single/total,
                100.0*ok_multi/total, ms_multi/total,
                100.0*ok_hybrid/total, ms_hybrid/total);
        llama_free(ctx);
    }
    llama_model_free(g_model); llama_backend_free();
    log_msg("Done.");
    return 0;
}
