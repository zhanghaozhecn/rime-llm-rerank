// eval_s3_skip: evaluate skipping Step 3 (3rd-token decode) by
// extrapolating it with average CE * lambda, vs full CE scoring.
// Full scoring decodes every candidate token; s3skip scores only 2
// layers (CE1 + S2) and extrapolates the tail for >=3-token candidates.
// Metrics on samples that contain >=3-token candidates:
//   first_agree  = fraction where full first choice == s3skip first choice
//   up/down      = 3-token candidates whose rank rises/falls vs full
//
// Build (same as eval_long_cand):
//   cl /O2 /std:c++17 /EHsc /DNDEBUG /MT eval_s3_skip.cpp
//      /I D:\llama.cpp-mirror\include /I D:\llama.cpp-mirror\ggml\include
//      D:\llama.cpp-mirror\build-mt\src\Release\llama.lib
//      D:\llama.cpp-mirror\build-mt\ggml\src\Release\ggml.lib
//      D:\llama.cpp-mirror\build-mt\ggml\src\Release\ggml-base.lib
//      D:\llama.cpp-mirror\build-mt\ggml\src\Release\ggml-cpu.lib
//      /Fe:eval_s3_skip.exe /link /LTCG advapi32.lib
// usage: eval_s3_skip.exe <tsv> [max_samples]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <chrono>

#include "llama.h"

static const char *kModel = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static const int kNSeqMax = 16;
static llama_model *g_model;
static llama_context *g_ctx;
static const llama_vocab *g_vocab;

static std::vector<llama_token> tokenize(const std::string &s) {
  std::vector<llama_token> toks(256);
  int n = llama_tokenize(g_vocab, s.c_str(), (int)s.size(), toks.data(),
                         (int)toks.size(), false, false);
  if (n > (int)toks.size())
    return std::vector<llama_token>();
  toks.resize(std::max(0, n));
  return toks;
}

static double cross_entropy(float *logits, int vs, int target_id) {
  float m = -1e30f;
  for (int k = 0; k < vs; k++)
    if (logits[k] > m)
      m = logits[k];
  double se = 0;
  for (int k = 0; k < vs; k++)
    se += exp((double)(logits[k] - m));
  return -((double)(logits[target_id] - m) - log(se));
}

// Full CE: decode every candidate token (all layers, parallel seqs)
static std::vector<double> score_full(const std::vector<llama_token> &ctx_ids,
                                      const std::vector<std::vector<llama_token>> &cands,
                                      int vs) {
  int ctx_len = (int)ctx_ids.size();
  int n = (int)cands.size();
  std::vector<double> ce(n, 0.0);
  bool ok = true;

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

  int max_len = 0;
  for (auto &c : cands)
    max_len = std::max(max_len, (int)c.size());
  for (int j = 0; j + 1 < max_len && ok; j++) {
    std::vector<int> part;
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

// 2-layer scoring (CE1 + S2), extrapolate tail of >=3-token candidates:
// ce += avg(ce1,ce2) * (len-2) * lambda
static std::vector<double> score_s3skip(const std::vector<llama_token> &ctx_ids,
                                        const std::vector<std::vector<llama_token>> &cands,
                                        int vs, double lambda) {
  int ctx_len = (int)ctx_ids.size();
  int n = (int)cands.size();
  std::vector<double> ce(n, 0.0);
  bool ok = true;

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

  // layer 1 (S2): decode cand[0] -> CE(cand[1]) for >=2-token candidates
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
    if (llama_decode(g_ctx, b) != 0) {
      ok = false;
    } else {
      for (int s = 0; s < m; s++) {
        int i = part[s];
        float *l = llama_get_logits_ith(g_ctx, s);
        if (l)
          ce[i] += cross_entropy(l, vs, cands[i][1]);
        else
          ok = false;
      }
    }
    llama_batch_free(b);
  }

  // extrapolate tail for >=3-token candidates
  if (ok) {
    for (int i = 0; i < n; i++) {
      int len = (int)cands[i].size();
      if (len >= 3) {
        double avg2 = ce[i] / 2.0;
        ce[i] += avg2 * (len - 2) * lambda;
      }
    }
  }
  if (!ok)
    return std::vector<double>(n, -1e10);
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

static int argmax_first(const std::vector<double> &s) {
  int best = -1;
  double bv = -1e30;
  for (int i = 0; i < (int)s.size(); i++)
    if (s[i] > bv) {
      bv = s[i];
      best = i;
    }
  return best;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <tsv> [max_samples]\n", argv[0]);
    return 1;
  }
  int max_samples = argc > 2 ? atoi(argv[2]) : 5000;

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

  FILE *f = fopen(argv[1], "r");
  if (!f) {
    fprintf(stderr, "open %s failed\n", argv[1]);
    return 1;
  }
  char line[65536];
  long total = 0, n3plus = 0, n4plus = 0;

  struct Agg {
    long n = 0, agree = 0, up = 0, down = 0;
  } agg[4];  // [0]=lam 0.5, [1]=0.7, [2]=0.85, [3]=1.0
  double lams[4] = {0.5, 0.7, 0.85, 1.0};

  long t0 = (long)time(NULL);
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
    std::string ctx_raw = cols[0];
    std::vector<llama_token> ctx_ids = tokenize(ctx_raw);
    if (ctx_ids.empty())
      continue;
    auto cand_strs = split(cols[4], ',');
    std::vector<std::vector<llama_token>> cand_ids;
    bool has3 = false, has4 = false;
    for (auto &c : cand_strs) {
      auto ids = tokenize(c);
      if (ids.empty())
        ids.push_back(0);
      cand_ids.push_back(ids);
      if (ids.size() >= 3)
        has3 = true;
      if (ids.size() >= 4)
        has4 = true;
    }
    if (cand_ids.size() < 2)
      continue;
    if (!has3)
      continue;  // only samples with >=3-token candidates are affected

    n3plus++;
    if (has4)
      n4plus++;

    std::vector<double> full = score_full(ctx_ids, cand_ids, vs);
    if (full[0] < -1e9)
      continue;  // decode failed
    int best_full = argmax_first(full);

    for (int k = 0; k < 4; k++) {
      std::vector<double> s3 = score_s3skip(ctx_ids, cand_ids, vs, lams[k]);
      if (s3[0] < -1e9)
        continue;
      agg[k].n++;
      if (argmax_first(s3) == best_full)
        agg[k].agree++;
      // direction: rank change of 3-token candidates vs full
      for (int i = 0; i < (int)cand_ids.size(); i++) {
        if (cand_ids[i].size() != 3)
          continue;
        int r_full = 0, r_s3 = 0;
        for (int j = 0; j < (int)cand_ids.size(); j++) {
          if (full[j] > full[i])
            r_full++;
          if (s3[j] > s3[i])
            r_s3++;
        }
        if (r_s3 < r_full)
          agg[k].up++;
        else if (r_s3 > r_full)
          agg[k].down++;
      }
    }
    if (total % 200 == 0)
      fprintf(stderr, "  %ld samples, %.1fs\n", total,
              (double)(time(NULL) - t0));
  }
  fclose(f);

  printf("samples with >=3-token cands: %ld (4+: %ld)\n", n3plus, n4plus);
  for (int k = 0; k < 4; k++) {
    if (agg[k].n == 0)
      continue;
    printf("lam=%.2f: n=%ld first_agree=%.2f%%  up=%ld down=%ld (net %+ld)\n",
           lams[k], agg[k].n,
           100.0 * agg[k].agree / agg[k].n,
           agg[k].up, agg[k].down, agg[k].up - agg[k].down);
  }
  return 0;
}
