/*
 * bench_threads.cpp — find the optimal llama.cpp thread count for THIS
 * device, so the user can set llm_rerank.cpu_cores accordingly.
 *
 * Scans 1..logical-core-count (capped at 16) and measures the production
 * score-batch workload: Step 1 ctx decode + KV copy + parallel candidate
 * decode + CE (same shape as llm_filter / rime_llm.dll scoring). Prints a
 * per-thread table and the recommended config line.
 *
 * usage: bench_threads.exe [model_path]
 *   model_path default: d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf
 *
 * Build (MT, same as the LLM components):
 *   cl /O2 /std:c++17 /EHsc /DNDEBUG /MT bench_threads.cpp
 *      /I D:\llama.cpp-mirror\include /I D:\llama.cpp-mirror\ggml\include
 *      D:\llama.cpp-mirror\build-mt\src\Release\llama.lib
 *      D:\llama.cpp-mirror\build-mt\ggml\src\Release\ggml.lib
 *      D:\llama.cpp-mirror\build-mt\ggml\src\Release\ggml-base.lib
 *      D:\llama.cpp-mirror\build-mt\ggml\src\Release\ggml-cpu.lib
 *      /Fe:bench_threads.exe /link /LTCG advapi32.lib
 */
#define NOMINMAX
#include <windows.h>
#include "llama.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include <fstream>

static const char *kDefaultModel = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static const int kCtxTokens = 10;   // typical TSF caret context
static const int kNCands = 5;       // max_candidates default
static const int kNTrials = 25;     // timing trials per thread count (~1 min total
                                    // with the 80ms inter-trial pause, averaged)

static llama_model *g_model;
static const llama_vocab *g_vocab;

static std::vector<llama_token> tokenize(const char *text) {
  std::vector<llama_token> toks(256);
  int n = llama_tokenize(g_vocab, text, (int)strlen(text), toks.data(),
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

// One full score-batch pass (the production workload):
// ctx decode -> CE(cand[0]) -> KV copy -> parallel decode cand[0] -> CE(cand[1])
static void score_once(llama_context *ctx, const std::vector<llama_token> &ctx_ids,
                       const std::vector<std::vector<llama_token>> &cands, int vs) {
  int ctx_len = (int)ctx_ids.size();
  int n = (int)cands.size();
  llama_memory_clear(llama_get_memory(ctx), false);
  llama_batch b1 = llama_batch_init(ctx_len, 0, 1);
  for (int j = 0; j < ctx_len; j++) {
    b1.token[j] = ctx_ids[j];
    b1.pos[j] = j;
    b1.n_seq_id[j] = 1;
    b1.seq_id[j][0] = 0;
  }
  b1.logits[ctx_len - 1] = 1;
  b1.n_tokens = ctx_len;
  if (llama_decode(ctx, b1) == 0) {
    float *cl = llama_get_logits_ith(ctx, ctx_len - 1);
    if (cl)
      cross_entropy(cl, vs, cands[0][0]);
  }
  llama_batch_free(b1);

  for (int s = 0; s < n; s++)
    llama_memory_seq_cp(llama_get_memory(ctx), 0, s + 1, 0, -1);

  llama_batch b2 = llama_batch_init(n, 0, n);
  for (int s = 0; s < n; s++) {
    b2.token[s] = cands[s][0];
    b2.pos[s] = ctx_len;
    b2.n_seq_id[s] = 1;
    b2.seq_id[s][0] = s + 1;
    b2.logits[s] = 1;
  }
  b2.n_tokens = n;
  if (llama_decode(ctx, b2) == 0) {
    for (int s = 0; s < n; s++) {
      float *l = llama_get_logits_ith(ctx, s);
      if (l)
        cross_entropy(l, vs, cands[s][1]);
    }
  }
  llama_batch_free(b2);
}

static int logical_cores() {
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  return (int)si.dwNumberOfProcessors;
}

static bool g_apply = false;

// Locate the user schema(s) containing an llm_rerank section and rewrite
// the cpu_cores line to the measured optimum. Returns number of files
// patched.
static int apply_config(int best_thr) {
  const char *env = getenv("APPDATA");
  std::string base = env ? std::string(env) + "/Rime"
                         : "C:/Users/Administrator/AppData/Roaming/Rime";
  int patched = 0;
  WIN32_FIND_DATAA fd;
  std::string pattern = base + "/*.schema.yaml";
  HANDLE h = FindFirstFileA(pattern.c_str(), &fd);
  if (h == INVALID_HANDLE_VALUE)
    return 0;
  do {
    std::string path = base + "/" + fd.cFileName;
    std::ifstream in(path);
    std::string text((std::istreambuf_iterator<char>(in)),
                     std::istreambuf_iterator<char>());
    in.close();
    if (text.find("llm_rerank") == std::string::npos)
      continue;
    size_t pos = text.find("cpu_cores");
    if (pos == std::string::npos)
      continue;
    size_t colon = text.find(':', pos);
    size_t eol = text.find('\n', colon);
    if (colon == std::string::npos || eol == std::string::npos)
      continue;
    text = text.substr(0, colon + 1) + " " + std::to_string(best_thr) +
           text.substr(eol);
    std::ofstream out(path, std::ios::trunc);
    out << text;
    out.close();
    printf("  + updated: %s (cpu_cores: %d)\n", fd.cFileName, best_thr);
    patched++;
  } while (FindNextFileA(h, &fd) != 0);
  FindClose(h);
  return patched;
}

int main(int argc, char **argv) {
  const char *model_path = kDefaultModel;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--apply") == 0)
      g_apply = true;
    else if (argv[i][0] != '-')
      model_path = argv[i];
  }
  printf("== bench_threads: find optimal thread count ==\n");
  printf("model: %s\n", model_path);
  printf("logical cores: %d\n", logical_cores());

  llama_backend_init();
  llama_model_params mp = llama_model_default_params();
  mp.use_mmap = 1;
  g_model = llama_model_load_from_file(model_path, mp);
  if (!g_model) {
    fprintf(stderr, "model load failed\n");
    return 1;
  }
  g_vocab = llama_model_get_vocab(g_model);
  int vs = llama_n_vocab(g_vocab);

  // fixed workload: 10-token context + 5 two-token candidates
  const char *ctx_text = "今天天气不错我们去公园散步聊聊天";
  std::vector<llama_token> ctx_ids = tokenize(ctx_text);
  if ((int)ctx_ids.size() > kCtxTokens)
    ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - kCtxTokens);
  const char *cand_words[5] = {"公园", "散步", "聊天", "天气", "不错"};
  std::vector<std::vector<llama_token>> cands;
  for (auto *w : cand_words) {
    auto ids = tokenize(w);
    if (ids.empty())
      ids.push_back(0);
    cands.push_back(ids);
  }
  printf("workload: ctx_tok=%d cand=%d (x2-token, like production scoring)\n",
         (int)ctx_ids.size(), (int)cands.size());

  int max_thr = std::min(logical_cores(), 16);
  struct Result {
    int thr;
    double ms;
  };
  std::vector<Result> results;

  LARGE_INTEGER freq;
  QueryPerformanceFrequency(&freq);

  for (int thr = 1; thr <= max_thr; thr++) {
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = 128;
    cp.n_threads = thr;
    cp.n_threads_batch = thr;
    cp.n_seq_max = 12;
    llama_context *ctx = llama_new_context_with_model(g_model, cp);
    if (!ctx) {
      printf("  thr=%2d: ctx create FAILED\n", thr);
      continue;
    }
    // warmup (graph build, memory alloc, etc.)
    score_once(ctx, ctx_ids, cands, vs);
    score_once(ctx, ctx_ids, cands, vs);

    // interleaved repeated trials, averaged (pause between trials to
    // break cache-warmth effects; total budget ~1 min for all counts)
    double sum = 0;
    for (int t = 0; t < kNTrials; t++) {
      LARGE_INTEGER t0, t1;
      QueryPerformanceCounter(&t0);
      score_once(ctx, ctx_ids, cands, vs);
      QueryPerformanceCounter(&t1);
      double ms = (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart;
      sum += ms;
      Sleep(80);  // inter-trial pause
    }
    double avg = sum / kNTrials;
    results.push_back({thr, avg});
    printf("  thr=%2d: %6.1f ms/pass\n", thr, avg);
    llama_free(ctx);
  }

  int best_thr = results[0].thr;
  double best_ms = results[0].ms;
  for (auto &r : results)
    if (r.ms < best_ms) {
      best_ms = r.ms;
      best_thr = r.thr;
    }

  // suggested default: the SMALLEST thread count whose latency is within
  // 90% of the optimum (latency <= best_ms / 0.90). Fewer threads for
  // nearly the same speed; the user types this into the config.
  int sug_thr = results[0].thr;
  double sug_ms = results[0].ms;
  for (auto &r : results) {
    if (r.ms <= best_ms / 0.90) {
      sug_thr = r.thr;
      sug_ms = r.ms;
      break;
    }
  }

  printf("\n== result ==\n");
  printf("NOTE: run while the system is idle - heavy background load (builds,\n");
  printf("      downloads, games) flattens the curve and skews the suggestion.\n");
  printf("optimal thread count: %d (%.1f ms/pass)\n", best_thr, best_ms);
  printf("suggested default (90%%): %d (%.1f ms/pass)\n", sug_thr, sug_ms);
  printf("config suggestion:\n");
  printf("  llm_rerank:\n");
  printf("    cpu_cores: %d\n", sug_thr);
  if (g_apply) {
    int n = apply_config(sug_thr);
    if (n > 0) {
      printf("applied to %d schema file(s). Restart the input method (re-deploy) to take effect.\n", n);
    } else {
      printf("no schema with llm_rerank section found under %%APPDATA%%/Rime - patch manually.\n");
    }
  }

  llama_model_free(g_model);
  llama_backend_free();
  return 0;
}
