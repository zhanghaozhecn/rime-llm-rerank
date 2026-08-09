/*
 * bench_threads.cpp — measure llama.cpp inference latency per thread count
 * for THIS device, so the user can pick llm_rerank.cpu_cores.
 *
 * Scans 1..min(10, logical-core-count) and measures the production
 * score-batch workload: Step 1 ctx decode + KV copy + parallel candidate
 * decode + CE (same shape as llm_filter / rime_llm.dll scoring). Prints a
 * per-thread latency table — no recommendation, the user picks a value.
 *
 * usage: bench_threads.exe [model_path]
 *   model_path default: d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf
 *
 * Results are printed to the console AND written to bench_threads_result.txt
 * in the same directory as the exe (overwritten on each run).
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
#include <cstdarg>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include <fstream>
#include <io.h>

static FILE *g_out = nullptr;  // result file handle (same dir as exe)

// Print to the console AND to the result file (flushed per line).
static void out(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vprintf(fmt, ap);
  va_end(ap);
  if (g_out) {
    va_start(ap, fmt);
    vfprintf(g_out, fmt, ap);
    va_end(ap);
    fflush(g_out);
  }
  fflush(stdout);
}

static const char *kDefaultModel = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static const int kCtxTokens = 10;   // typical TSF caret context
static const int kNCands = 5;       // max_candidates default
static const int kNTrials = 25;     // timing trials per thread count; median +
                                    // mid-50% range reported (robust to noise)

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

// S1: ctx decode (pre-computed by prepare() in production; NOT timed)
static void ctx_decode_once(llama_context *ctx,
                            const std::vector<llama_token> &ctx_ids) {
  int ctx_len = (int)ctx_ids.size();
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
  if (llama_decode(ctx, b1) != 0)
    llama_memory_clear(llama_get_memory(ctx), false);  // retry-safe no-op
  llama_batch_free(b1);
}

// S2+S3: KV copy + parallel candidate decode + CE.
// This is the real per-keystroke latency (S1 is absorbed by prepare).
static void cand_score_once(llama_context *ctx,
                            const std::vector<std::vector<llama_token>> &cands,
                            int ctx_len, int vs) {
  int n = (int)cands.size();
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
  // S3: 3-token candidates continue decoding
  std::vector<int> idx3;
  for (int s = 0; s < n; s++)
    if ((int)cands[s].size() >= 3)
      idx3.push_back(s);
  if (!idx3.empty()) {
    llama_batch b3 = llama_batch_init((int)idx3.size(), 0, (int)idx3.size());
    for (size_t k = 0; k < idx3.size(); k++) {
      int s = idx3[k];
      b3.token[k] = cands[s][1];
      b3.pos[k] = ctx_len + 1;
      b3.n_seq_id[k] = 1;
      b3.seq_id[k][0] = s + 1;
      b3.logits[k] = 1;
    }
    b3.n_tokens = (int)idx3.size();
    if (llama_decode(ctx, b3) == 0) {
      for (size_t k = 0; k < idx3.size(); k++) {
        float *l = llama_get_logits_ith(ctx, (int)k);
        if (l)
          cross_entropy(l, vs, cands[idx3[k]][2]);
      }
    }
    llama_batch_free(b3);
  }
}

static int logical_cores() {
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  return (int)si.dwNumberOfProcessors;
}

// Keep the console window open when launched by double-click; skip the
// wait when stdin is piped/redirected (automation).
static void wait_exit() {
  if (_isatty(_fileno(stdin))) {
    printf("\nPress Enter to exit...\n");
    fflush(stdout);
    getchar();
  }
}

// Suppress llama.cpp verbose logs (model dump, graph_reserve, KV copy spam)
// that flood the console and bury the per-thread results; keep errors only.
// NOTE: this ggml version: NONE=0 DEBUG=1 INFO=2 WARN=3 ERROR=4 CONT=5.
static void quiet_log(enum ggml_log_level level, const char *text,
                      void *user_data) {
  if (level >= GGML_LOG_LEVEL_ERROR)  // ERROR + CONT continuation
    fputs(text, stderr);
}

int main(int argc, char **argv) {
  llama_log_set(quiet_log, nullptr);  // must be called before backend init
  const char *model_path = kDefaultModel;
  if (argc > 1 && argv[1][0] != '-')
    model_path = argv[1];

  // result file: same directory as the exe, overwritten on each run
  char exe_path[MAX_PATH];
  GetModuleFileNameA(NULL, exe_path, MAX_PATH);
  std::string out_path = exe_path;
  size_t slash = out_path.find_last_of("\\/");
  if (slash != std::string::npos)
    out_path = out_path.substr(0, slash + 1);
  out_path += "bench_threads_result.txt";
  g_out = fopen(out_path.c_str(), "w");
  if (g_out)
    fprintf(stderr, "results written to: %s\n", out_path.c_str());
  else
    fprintf(stderr, "WARNING: cannot open %s - console only\n", out_path.c_str());

  int cores = logical_cores();
  int max_thr = std::min(cores, 10);
  out("== bench_threads: per-thread latency ==\n");
  out("model: %s\n", model_path);
  out("logical cores: %d (scanning 1..%d)\n", cores, max_thr);
  if (max_thr < 1) {
    fprintf(stderr, "ERROR: no logical processors detected (cores=%d)\n", cores);
    wait_exit();
    return 1;
  }

  llama_backend_init();
  llama_model_params mp = llama_model_default_params();
  mp.use_mmap = 1;
  g_model = llama_model_load_from_file(model_path, mp);
  if (!g_model) {
    // keep the console window open on double-click launch
    fprintf(stderr, "model load failed: %s\n", model_path);
    fprintf(stderr, "pass your model path as the first argument, e.g.:\n");
    fprintf(stderr, "  bench_threads.exe d:/path/to/model.gguf\n");
    wait_exit();
    return 1;
  }
  g_vocab = llama_model_get_vocab(g_model);
  int vs = llama_n_vocab(g_vocab);

  // fixed workload: 10-token context + 5 candidates matching the heaviest
  // real typing case: 3 x 2-token + 2 x 3-token candidates (triggers the
  // S3 decode). Common Chinese words are single vocab tokens, so select
  // from a pool of less-common words and verify token counts at runtime.
  const char *ctx_text = "今天天气不错我们去公园散步聊聊天然后回家吃晚饭";
  std::vector<llama_token> ctx_ids = tokenize(ctx_text);
  if ((int)ctx_ids.size() > kCtxTokens)
    ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - kCtxTokens);
  const char *cand_pool[] = {
      "错事", "侧式", "测速", "仄声", "佚名", "怅惘", "缱绻", "龌龊",
      "邂逅", "蹉跎", "饕餮", "犄角", "旮旯", "囫囵", "氤氲", "黢黑",
      "计算机", "图书馆", "摄像头", "咖啡机", "高跟鞋", "潜台词", "老字号",
      "双刃剑", "里程碑", "橄榄枝", "绊脚石", "遮羞布", "紧箍咒", "试金石"};
  std::vector<std::vector<llama_token>> tok2, tok3;
  for (auto *w : cand_pool) {
    auto ids = tokenize(w);
    if (ids.size() == 2 && tok2.size() < 3)
      tok2.push_back(ids);
    else if (ids.size() == 3 && tok3.size() < 2)
      tok3.push_back(ids);
  }
  std::vector<std::vector<llama_token>> cands;
  for (auto &c : tok2)
    cands.push_back(c);
  for (auto &c : tok3)
    cands.push_back(c);
  if (cands.size() < 5) {
    fprintf(stderr, "ERROR: pool did not yield 3x2-token + 2x3-token "
                    "candidates (got %d)\n", (int)cands.size());
    wait_exit();
    return 1;
  }
  out("workload: ctx_tok=%d cand=%d (tokens:", (int)ctx_ids.size(),
      (int)cands.size());
  for (auto &c : cands)
    out(" %d", (int)c.size());
  out(", incl. S3 decode)\n");

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
      out("  thr=%2d: ctx create FAILED\n", thr);
      continue;
    }
    // warmup (graph build, memory alloc, etc.); ctx decode is the
    // pre-computed part (prepare), so each trial re-runs it OUTSIDE the
    // timed window and only S2+S3 (the real per-keystroke cost) is timed.
    ctx_decode_once(ctx, ctx_ids);
    cand_score_once(ctx, cands, (int)ctx_ids.size(), vs);
    cand_score_once(ctx, cands, (int)ctx_ids.size(), vs);

    // interleaved repeated trials; median + mid-50% (25-75th percentile)
    // range are robust to background noise even when the system looks idle
    // (pause between trials to break cache-warmth effects; ~1 min total)
    std::vector<double> samples;
    int ctx_len = (int)ctx_ids.size();
    for (int t = 0; t < kNTrials; t++) {
      LARGE_INTEGER t0, t1;
      ctx_decode_once(ctx, ctx_ids);  // S1: not timed (prepare absorbs it)
      QueryPerformanceCounter(&t0);
      cand_score_once(ctx, cands, ctx_len, vs);  // S2+S3: timed
      QueryPerformanceCounter(&t1);
      double ms = (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart;
      samples.push_back(ms);
      Sleep(80);  // inter-trial pause
    }
    std::sort(samples.begin(), samples.end());
    double med = samples[kNTrials / 2];      // median
    double p25 = samples[kNTrials / 4];      // 25th percentile
    double p75 = samples[3 * kNTrials / 4];  // 75th percentile
    out("  thr=%2d: median %6.1f ms/pass (mid50 %5.1f-%5.1f)\n",
        thr, med, p25, p75);
    llama_free(ctx);
  }

  out("\n== summary ==\n");
  out("NOTE: run while the system is idle - heavy background load (builds,\n");
  out("      downloads, games) flattens the curve.\n");
  out("Pick the thread count with the best latency/thread trade-off and set it\n");
  out("in your schema: llm_rerank.cpu_cores = N, then re-deploy. The code\n");
  out("default is 5 if the option is left unset.\n");

  llama_model_free(g_model);
  llama_backend_free();
  if (g_out)
    fclose(g_out);
  wait_exit();
  return 0;
}
