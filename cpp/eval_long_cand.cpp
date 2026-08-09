// eval_long_cand.cpp - evaluate the 4+ token candidate scoring
// Compare full CE (decode ALL candidate tokens) vs truncated (first 3)
// vs truncated + extrapolation, on real corpus samples with context.
//
// Usage: eval_long_cand.exe <tsv> [max_samples]
// tsv lines: ctx \t word \t code \t pos \t cand1,cand2,... \t n
//
// Build (x64, MT):
//   cl /O2 /std:c++17 /EHsc /DNDEBUG eval_long_cand.cpp
//      /I D:\llama.cpp-mirror\include /I D:\llama.cpp-mirror\ggml\include
//      D:\llama.cpp-mirror\build-mt\src\Release\llama.lib
//      D:\llama.cpp-mirror\build-mt\ggml\src\Release\ggml.lib
//      D:\llama.cpp-mirror\build-mt\ggml\src\Release\ggml-base.lib
//      D:\llama.cpp-mirror\build-mt\ggml\src\Release\ggml-cpu.lib
//      /link /LTCG

#define NOMINMAX
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <windows.h>

#include "llama.h"

static const char *kModel = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static const int kMaxCtxTokens = 10;
static const int kNSeqMax = 16;
static double g_ext_lambda = 1.0;  // extrapolation strength (argv[3])

static llama_model *g_model;
static llama_context *g_ctx;
static const llama_vocab *g_vocab;

static std::vector<llama_token> tokenize(const std::string &s) {
  std::vector<llama_token> toks(256);
  int n = llama_tokenize(g_vocab, s.c_str(), (int)s.size(), toks.data(),
                         (int)toks.size(), true, true);
  if (n < 0) {
    toks.resize(-n);
    n = llama_tokenize(g_vocab, s.c_str(), (int)s.size(), toks.data(),
                       (int)toks.size(), true, true);
  }
  toks.resize(n > 0 ? n : 0);
  return toks;
}

static std::string normalize_ctx(const std::string &s) {
  std::string t = s;
  size_t p = t.find_last_of("\r\n");
  if (p != std::string::npos)
    t = t.substr(p + 1);
  t.erase(std::remove_if(t.begin(), t.end(),
                         [](unsigned char c) { return std::isspace(c) != 0; }),
          t.end());
  return t;
}

// CE of target from logits
static double cross_entropy(float *logits, int vs, int target) {
  float m = -1e30f;
  for (int k = 0; k < vs; k++)
    if (logits[k] > m)
      m = logits[k];
  double se = 0;
  for (int k = 0; k < vs; k++)
    se += exp((double)(logits[k] - m));
  return -((double)(logits[target] - m) - log(se));
}

// Full CE: decode every candidate token (all layers, parallel seqs)
// Return per-candidate total CE (NaN on failure).
static std::vector<double> score_full(const std::vector<llama_token> &ctx_ids,
                                      const std::vector<std::vector<llama_token>> &cands,
                                      int vs) {
  int ctx_len = (int)ctx_ids.size();
  int n = (int)cands.size();
  std::vector<double> ce(n, 0.0);
  bool ok = true;

  // Step 1: ctx decode on seq 0
  llama_memory_clear(llama_get_memory(g_ctx), false);
  llama_batch b1 = llama_batch_init(ctx_len, 0, 1);
  for (int j = 0; j < ctx_len; j++) {
    b1.token[j] = ctx_ids[j];
    b1.pos[j] = j;
    b1.n_seq_id[j] = 1;
    b1.seq_id[j][0] = 0;
  }
  b1.logits[ctx_len - 1] = 1;
  b1.n_tokens = ctx_len;
  if (llama_decode(g_ctx, b1) != 0) {
    llama_batch_free(b1);
    return std::vector<double>(n, -1e10);
  }
  float *cl = llama_get_logits_ith(g_ctx, ctx_len - 1);
  if (!cl) {
    llama_batch_free(b1);
    return std::vector<double>(n, -1e10);
  }
  for (int i = 0; i < n; i++)
    ce[i] = cross_entropy(cl, vs, cands[i][0]);
  llama_batch_free(b1);

  // KV copy ctx -> worker seqs
  for (int s = 0; s < n; s++)
    llama_memory_seq_cp(llama_get_memory(g_ctx), 0, s + 1, 0, -1);

  // layers j = 0..maxLen-2: decode cand[j] -> CE(cand[j+1])
  int max_len = 0;
  for (auto &c : cands)
    max_len = std::max(max_len, (int)c.size());
  for (int j = 0; j + 1 < max_len && ok; j++) {
    std::vector<int> part;  // candidates with len >= j+2
    for (int i = 0; i < n; i++)
      if ((int)cands[i].size() >= j + 2)
        part.push_back(i);
    int m = (int)part.size();
    if (m == 0)
      continue;
    llama_batch b = llama_batch_init(m, 0, m);
    for (int s = 0; s < m; s++) {
      int i = part[s];
      b.token[s] = cands[i][j];
      b.pos[s] = ctx_len + j;
      b.n_seq_id[s] = 1;
      b.seq_id[s][0] = i + 1;
      b.logits[s] = 1;
    }
    b.n_tokens = m;
    if (llama_decode(g_ctx, b) != 0) {
      ok = false;
    } else {
      for (int s = 0; s < m; s++) {
        int i = part[s];
        float *l = llama_get_logits_ith(g_ctx, s);
        if (l)
          ce[i] += cross_entropy(l, vs, cands[i][j + 1]);
        else
          ok = false;
      }
    }
    llama_batch_free(b);
  }
  if (!ok)
    return std::vector<double>(n, -1e10);
  return ce;
}

// Truncated CE: first 3 tokens only (current production behavior),
// optionally extrapolate the tail by average CE.
static std::vector<double> score_trunc(const std::vector<llama_token> &ctx_ids,
                                       const std::vector<std::vector<llama_token>> &cands,
                                       int vs, bool extrapolate) {
  int ctx_len = (int)ctx_ids.size();
  int n = (int)cands.size();
  std::vector<double> ce(n, 0.0);

  llama_memory_clear(llama_get_memory(g_ctx), false);
  llama_batch b1 = llama_batch_init(ctx_len, 0, 1);
  for (int j = 0; j < ctx_len; j++) {
    b1.token[j] = ctx_ids[j];
    b1.pos[j] = j;
    b1.n_seq_id[j] = 1;
    b1.seq_id[j][0] = 0;
  }
  b1.logits[ctx_len - 1] = 1;
  b1.n_tokens = ctx_len;
  if (llama_decode(g_ctx, b1) != 0) {
    llama_batch_free(b1);
    return std::vector<double>(n, -1e10);
  }
  float *cl = llama_get_logits_ith(g_ctx, ctx_len - 1);
  if (!cl) {
    llama_batch_free(b1);
    return std::vector<double>(n, -1e10);
  }
  for (int i = 0; i < n; i++)
    ce[i] = cross_entropy(cl, vs, cands[i][0]);
  llama_batch_free(b1);

  for (int s = 0; s < n; s++)
    llama_memory_seq_cp(llama_get_memory(g_ctx), 0, s + 1, 0, -1);

  // layer 0: decode cand[0] -> CE(cand[1])
  {
    std::vector<int> part;
    for (int i = 0; i < n; i++)
      if ((int)cands[i].size() >= 2)
        part.push_back(i);
    int m = (int)part.size();
    if (m > 0) {
      llama_batch b = llama_batch_init(m, 0, m);
      for (int s = 0; s < m; s++) {
        int i = part[s];
        b.token[s] = cands[i][0];
        b.pos[s] = ctx_len;
        b.n_seq_id[s] = 1;
        b.seq_id[s][0] = i + 1;
        b.logits[s] = 1;
      }
      b.n_tokens = m;
      if (llama_decode(g_ctx, b) != 0)
        return std::vector<double>(n, -1e10);
      for (int s = 0; s < m; s++) {
        int i = part[s];
        float *l = llama_get_logits_ith(g_ctx, s);
        if (!l)
          return std::vector<double>(n, -1e10);
        ce[i] += cross_entropy(l, vs, cands[i][1]);
      }
      llama_batch_free(b);
    }
  }
  // layer 1: decode cand[1] -> CE(cand[2])
  {
    std::vector<int> part;
    for (int i = 0; i < n; i++)
      if ((int)cands[i].size() >= 3)
        part.push_back(i);
    int m = (int)part.size();
    if (m > 0) {
      llama_batch b = llama_batch_init(m, 0, m);
      for (int s = 0; s < m; s++) {
        int i = part[s];
        b.token[s] = cands[i][1];
        b.pos[s] = ctx_len + 1;
        b.n_seq_id[s] = 1;
        b.seq_id[s][0] = i + 1;
        b.logits[s] = 1;
      }
      b.n_tokens = m;
      if (llama_decode(g_ctx, b) != 0)
        return std::vector<double>(n, -1e10);
      for (int s = 0; s < m; s++) {
        int i = part[s];
        float *l = llama_get_logits_ith(g_ctx, s);
        if (!l)
          return std::vector<double>(n, -1e10);
        ce[i] += cross_entropy(l, vs, cands[i][2]);
      }
      llama_batch_free(b);
    }
  }
  // extrapolate the missing tail for 4+ token candidates
  if (extrapolate) {
    for (int i = 0; i < n; i++) {
      if ((int)cands[i].size() > 3) {
        double avg_ce = ce[i] / 3.0;
        ce[i] += avg_ce * ((int)cands[i].size() - 3) * g_ext_lambda;
      }
    }
  }
  return ce;
}

static std::vector<std::string> split(const std::string &s, char sep) {
  std::vector<std::string> out;
  size_t start = 0;
  for (size_t i = 0; i <= s.size(); i++) {
    if (i == s.size() || s[i] == sep) {
      out.push_back(s.substr(start, i - start));
      start = i + 1;
    }
  }
  return out;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <tsv> [max_samples]\n", argv[0]);
    return 1;
  }
  int max_samples = argc > 2 ? atoi(argv[2]) : 20000;
  if (argc > 3)
    g_ext_lambda = atof(argv[3]);

  llama_backend_init();
  llama_model_params mp = llama_model_default_params();
  mp.use_mmap = 1;
  g_model = llama_model_load_from_file(kModel, mp);
  if (!g_model) {
    fprintf(stderr, "model load failed\n");
    return 1;
  }
  g_vocab = llama_model_get_vocab(g_model);
  llama_context_params cp = llama_context_default_params();
  cp.n_ctx = 512;
  cp.n_threads = 7;
  cp.n_threads_batch = 7;
  cp.n_seq_max = kNSeqMax;
  g_ctx = llama_new_context_with_model(g_model, cp);
  if (!g_ctx) {
    fprintf(stderr, "ctx create failed\n");
    return 1;
  }
  int vs = llama_n_vocab(g_vocab);

  struct Sample {
    std::string ctx, word;
    std::vector<std::string> cands_str;
    std::vector<llama_token> ctx_ids;
    std::vector<std::vector<llama_token>> cand_ids;
    int n;
  };
  std::vector<Sample> samples;
  long total = 0, valid = 0, has4plus = 0;

  FILE *f = fopen(argv[1], "r");
  if (!f) {
    fprintf(stderr, "open %s failed\n", argv[1]);
    return 1;
  }
  char line[65536];
  // Pass 1: read + tokenize, keep only samples with a 4+ token candidate
  // (full scoring is expensive; <=3-token samples score identically in
  // all three modes, they only contribute the "how rare" statistics).
  while (fgets(line, sizeof(line), f) && (max_samples <= 0 || total < max_samples)) {
    total++;
    std::string s(line);
    if (!s.empty() && s.back() == '\n')
      s.pop_back();
    if (!s.empty() && s.back() == '\r')
      s.pop_back();
    auto cols = split(s, '\t');
    if (cols.size() < 5)
      continue;
    std::string ctx_raw = cols[0], word = cols[1];
    auto cands_str = split(cols[4], ',');
    if (cands_str.size() < 2)
      continue;  // no competition
    std::string ctx = normalize_ctx(ctx_raw);
    if (ctx.empty())
      continue;
    std::vector<llama_token> ctx_ids = tokenize(ctx);
    if ((int)ctx_ids.size() < 1)
      continue;
    if ((int)ctx_ids.size() > kMaxCtxTokens)
      ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - kMaxCtxTokens);

    std::vector<std::vector<llama_token>> cand_ids;
    bool any4plus = false;
    for (auto &c : cands_str) {
      auto ids = tokenize(c);
      if (ids.empty())
        ids.push_back(0);
      if ((int)ids.size() > 3)
        any4plus = true;
      cand_ids.push_back(ids);
    }
    int n = (int)cand_ids.size();
    if (n > kNSeqMax - 1)
      n = kNSeqMax - 1, cand_ids.resize(n);
    valid++;
    if (any4plus) {
      has4plus++;
      samples.push_back({ctx, word, cands_str, ctx_ids, cand_ids, n});
    }
    if (valid % 20000 == 0)
      fprintf(stderr, "... pass1 %ld lines (valid %ld, 4+ %ld)\n", total,
              valid, has4plus);
  }
  fclose(f);

  printf("== eval_long_cand (%s) ==\n", argv[1]);
  printf("lines: %ld, valid (ctx+cands>=2): %ld\n", total, valid);
  printf("samples with 4+ token candidate: %ld (%.2f%% of valid)\n", has4plus,
         valid ? 100.0 * has4plus / valid : 0);
  long compete = 0;
  for (auto &sp : samples) {
    bool c = false;
    for (int i = 1; i < sp.n; i++)
      if ((int)sp.cand_ids[i].size() <= 3)
        c = true;
    if (c)
      compete++;
  }
  printf("  competing with <=3-token candidates: %ld (%.2f%%)\n", compete,
         has4plus ? 100.0 * compete / has4plus : 0);

  // Pass 2: full scoring on the 4+ samples only.
  // Extrapolation is computed in-memory for several lambdas (one scoring
  // pass; extrapolation is pure arithmetic on the 3 computed CEs).
  const double kLambdas[] = {0.25, 0.5, 0.75, 1.0};
  const int kNL = 4;
  long lc_agree_trunc = 0, lc_full_first = 0, scored = 0;
  long lc_agree_ext[kNL] = {0};
  long lc_ext_overlong[kNL] = {0}, lc_ext_shortup[kNL] = {0};
  long lc_trunc_overlong = 0, lc_trunc_shortup = 0;
  for (auto &sp : samples) {
    auto ce_full = score_full(sp.ctx_ids, sp.cand_ids, vs);
    auto ce_trunc = score_trunc(sp.ctx_ids, sp.cand_ids, vs, false);
    if (ce_full[0] < -1e9 || ce_trunc[0] < -1e9)
      continue;
    int bf = 0, bt = 0;
    for (int i = 1; i < sp.n; i++) {
      if (ce_full[i] < ce_full[bf])
        bf = i;
      if (ce_trunc[i] < ce_trunc[bt])
        bt = i;
    }
    scored++;
    if (bf == 0)
      lc_full_first++;
    if (bt == bf)
      lc_agree_trunc++;
    auto is_long = [&](int i) { return (int)sp.cand_ids[i].size() > 3; };
    if (bt != bf) {
      if (is_long(bt) && !is_long(bf))
        lc_trunc_overlong++;
      if (!is_long(bt) && is_long(bf))
        lc_trunc_shortup++;
    }
    for (int L = 0; L < kNL; L++) {
      double lam = kLambdas[L];
      std::vector<double> ce_e = ce_trunc;
      for (int i = 0; i < sp.n; i++)
        if ((int)sp.cand_ids[i].size() > 3)
          ce_e[i] += (ce_trunc[i] / 3.0) * ((int)sp.cand_ids[i].size() - 3) * lam;
      int be = 0;
      for (int i = 1; i < sp.n; i++)
        if (ce_e[i] < ce_e[be])
          be = i;
      if (be == bf)
        lc_agree_ext[L]++;
      if (be != bf) {
        if (is_long(be) && !is_long(bf))
          lc_ext_overlong[L]++;
        if (!is_long(be) && is_long(bf))
          lc_ext_shortup[L]++;
      }
    }
    if (scored % 200 == 0)
      fprintf(stderr, "... pass2 %ld/%zu scored\n", scored, samples.size());
  }

  if (scored > 0) {
    printf("\nlong-candidate samples (4+ token present, n=%ld scored):\n",
           scored);
    printf("  first-choice agreement with full:\n");
    printf("    trunc: %.2f%%\n", 100.0 * lc_agree_trunc / scored);
    for (int L = 0; L < kNL; L++) {
      long diff = scored - lc_agree_ext[L];
      printf("    ext(lam=%.2f): agree %.2f%%  (diff n=%ld: long-up %ld "
             "long-down %ld)\n",
             kLambdas[L], 100.0 * lc_agree_ext[L] / scored, diff,
             lc_ext_overlong[L], lc_ext_shortup[L]);
    }
    printf("  full first=1 rate: %.2f%%\n", 100.0 * lc_full_first / scored);
    long trunc_diff = scored - lc_agree_trunc;
    if (trunc_diff > 0)
      printf("  trunc disagreement (n=%ld): long-up %ld (%.1f%%) long-down "
             "%ld (%.1f%%)\n",
             trunc_diff, lc_trunc_overlong,
             100.0 * lc_trunc_overlong / trunc_diff, lc_trunc_shortup,
             100.0 * lc_trunc_shortup / trunc_diff);
  }
  llama_free(g_ctx);
  llama_model_free(g_model);
  llama_backend_free();
  return 0;
}
