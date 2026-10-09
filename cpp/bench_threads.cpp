/*
 * bench_threads.cpp — measure llama.cpp inference latency per thread count
 * for THIS device, so the user can pick llm_rerank.cpu_cores.
 *
 * Scans 4..min(8, logical-core-count) (2026-10-01 用户定案：起点 4、终点 8；
 * 1-3 线程实测不可用且 8 以上收益递减，故两端都收窄) and measures the
 * production score-batch workload: Step 1 ctx decode + KV copy + parallel
 * candidate decode + CE (same shape as llm_filter / rime_llm.dll scoring).
 *
 * Machines with fewer than 5 logical cores are NOT benchmarked at all
 * (2026-10-01 用户定案): the tool immediately recommends the max thread
 * count (=逻辑核数) and never loads the model — so the answer is instant and
 * works even with no model file on disk.
 *
 * The tool DOES recommend a value (2026-10-01 起，此前只打表）：both GUIs and
 * the console read the machine-readable last line
 *   [RESULT] log_cores=20 phys_cores=10 tested=4-8 rec=5 rec_ms=52.6 ...
 * so the recommendation rule lives in exactly one place (here), not in the
 * two settings GUIs. Rule: smallest measured thread count that is within
 * 1.05x of the best latency, capped at the physical core count — beyond the
 * physical cores extra threads are SMT siblings and buy almost nothing.
 *
 * usage: bench_threads.exe [model_path] [--out FILE] [--trials N] [--no-wait]
 *   model_path default: d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf
 *   --out FILE   result/progress file (default: next to the exe; %TEMP% if
 *                that directory is not writable, e.g. under Program Files).
 *                Flushed per line → the settings GUIs poll it as progress.
 *   --trials N   timing trials per thread count (default 99; the GUIs pass 41
 *                for a ~30 s run instead of ~1 min).
 *   --no-wait    never wait for Enter at the end (the GUIs always pass this;
 *                a redirected stdout also suppresses the wait).
 *
 * Build (MT, same as the LLM components):
 *   cpp\build_bench_threads.bat   (or the cl line in that file)
 */
#define NOMINMAX
#include <windows.h>
#include "llama.h"
#include <cstdio>
#include <cstdlib>
#include <cstdarg>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include <fstream>
#include <io.h>
#include <share.h>

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
static const int kNTrials = 99;     // CLI default; median + mid-50% reported
static const int kMinThr = 4;       // scan start (2026-10-01 用户定案)
static const int kMaxThr = 8;       // scan end   (2026-10-01 用户定案)
static const int kMinCoresToTest = 5;      // < 5 逻辑核 = 不实测，直接取最大
static const double kRecThreshold = 1.05;  // rec = 最优 × 1.05 以内的最小线程

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
  // 自动化测试钩子（正常部署不设）：覆盖逻辑核数，用来验证「不足 5 线程不做
  // 实测」这类分支——本机没法真的变成 4 核。两个 GUI 读同一个变量。
  char buf[16] = "";
  DWORD n = GetEnvironmentVariableA("RIME_LLM_FAKE_CORES", buf, sizeof(buf));
  if (n > 0 && n < sizeof(buf)) {
    int v = atoi(buf);
    if (v > 0)
      return v;
  }
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  return (int)si.dwNumberOfProcessors;
}

// 物理核数：超出物理核的线程都是 SMT 兄弟线程，对这个负载几乎不涨分，
// 所以推荐值封顶在物理核（与「?」说明里的「不要超过本机物理核」一致）。
static int physical_cores() {
  DWORD len = 0;
  GetLogicalProcessorInformationEx(RelationProcessorCore, NULL, &len);
  if (!len)
    return logical_cores();
  std::vector<unsigned char> buf(len);
  if (!GetLogicalProcessorInformationEx(RelationProcessorCore,
                                        (PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX)buf.data(),
                                        &len))
    return logical_cores();
  int cores = 0;
  DWORD off = 0;
  while (off < len) {
    auto *e = (PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX)(buf.data() + off);
    if (e->Relationship == RelationProcessorCore)
      cores++;
    off += e->Size;
  }
  return cores > 0 ? cores : logical_cores();
}

// ANSI → wide（CP_ACP）：--out 走宽字符 API，路径含非 ASCII（中文用户名下的
// %TEMP%）也能开；ASCII 路径下就是恒等变换。
static std::wstring widen(const char *s) {
  int n = MultiByteToWideChar(CP_ACP, 0, s, -1, NULL, 0);
  if (n <= 0)
    return std::wstring();
  std::wstring w(n > 0 ? n - 1 : 0, L'\0');
  MultiByteToWideChar(CP_ACP, 0, s, -1, &w[0], n);
  return w;
}

// result/progress file: --out FILE，否则 exe 同目录（不可写时退 %TEMP% ——
// 装到 Program Files 下普通用户写不进去，这是 GUI 必须能指定落点的原因）。
// 一律 _wfsopen + _SH_DENYNO：两个 GUI 要**边写边读**这个文件做进度，
// 而 _wfopen 的共享模式会拒绝读方（实测 "used by another process"）。
static FILE *open_out(const char *out_arg) {
  if (out_arg && *out_arg) {
    std::wstring w = widen(out_arg);
    FILE *f = w.empty() ? NULL : _wfsopen(w.c_str(), L"wb", _SH_DENYNO);
    if (f)
      return f;
  }
  wchar_t exe_path[MAX_PATH];
  GetModuleFileNameW(NULL, exe_path, MAX_PATH);
  std::wstring dir = exe_path;
  size_t slash = dir.find_last_of(L"\\/");
  if (slash != std::wstring::npos)
    dir = dir.substr(0, slash + 1);
  FILE *f = _wfsopen((dir + L"bench_threads_result.txt").c_str(), L"wb", _SH_DENYNO);
  if (f)
    return f;
  wchar_t tmp[MAX_PATH];
  DWORD n = GetTempPathW(MAX_PATH, tmp);
  if (n > 0) {
    f = _wfsopen((std::wstring(tmp) + L"bench_threads_result.txt").c_str(), L"wb",
                 _SH_DENYNO);
    if (f)
      return f;
  }
  return NULL;
}

// Keep the console window open when launched by double-click; skip the
// wait when stdin or stdout is piped/redirected (automation) or --no-wait.
static void wait_exit(bool no_wait) {
  if (no_wait)
    return;
  if (!_isatty(_fileno(stdin)) || !_isatty(_fileno(stdout)))
    return;
  printf("\nPress Enter to exit...\n");
  fflush(stdout);
  getchar();
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
  const char *out_arg = NULL;
  int trials = kNTrials;
  bool no_wait = false;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--out") && i + 1 < argc)
      out_arg = argv[++i];
    else if (!strcmp(argv[i], "--trials") && i + 1 < argc) {
      trials = atoi(argv[++i]);
      if (trials < 5)
        trials = 5;   // 太少 → 中位数不稳
    } else if (!strcmp(argv[i], "--no-wait")) {
      no_wait = true;
    } else if (argv[i][0] != '-') {
      model_path = argv[i];
    }
  }

  g_out = open_out(out_arg);
  if (g_out)
    fprintf(stderr, "results written to: %s\n",
            out_arg && *out_arg ? out_arg : "(exe dir or %TEMP%)");
  else
    fprintf(stderr, "WARNING: cannot open result file - console only\n");

  int cores = logical_cores();
  int phys = physical_cores();
  if (phys > cores)   // 测试钩子把逻辑核调小后，物理核不能比它大
    phys = cores;
  out("== bench_threads: per-thread latency ==\n");
  out("logical cores: %d, physical cores: %d\n", cores, phys);

  // 逻辑核 < 5：不实测，直接取最大线程数（2026-10-01 用户定案）。
  // 不加载模型、不初始化后端 → 秒回，无模型文件时也能用。
  if (cores < kMinCoresToTest) {
    out("model: (not loaded - no benchmark needed)\n");
    out("\n== summary ==\n");
    out("本机逻辑核仅 %d（不足 %d）→ 不做实测，直接推荐最大线程数 %d。\n",
        cores, kMinCoresToTest, cores);
    out("  在方案 llm_rerank 里设 cpu_cores: %d，然后重新部署。\n", cores);
    out("[RESULT] log_cores=%d phys_cores=%d tested=none rec=%d rec_ms=0.0 "
        "best=-1 best_ms=0.0 threshold=%.2f reason=low_cores\n",
        cores, phys, cores, kRecThreshold);
    if (g_out)
      fclose(g_out);
    wait_exit(no_wait);
    return 0;
  }

  int last_thr = std::min(cores, kMaxThr);   // cores >= 5 → last >= 5
  out("model: %s\n", model_path);
  out("scanning %d..%d threads (%d trials each)\n", kMinThr, last_thr, trials);

  llama_backend_init();
  llama_model_params mp = llama_model_default_params();
  mp.use_mmap = 1;
  g_model = llama_model_load_from_file(model_path, mp);
  if (!g_model) {
    // keep the console window open on double-click launch
    fprintf(stderr, "model load failed: %s\n", model_path);
    fprintf(stderr, "pass your model path as the first argument, e.g.:\n");
    fprintf(stderr, "  bench_threads.exe d:/path/to/model.gguf\n");
    if (g_out)
      fclose(g_out);
    wait_exit(no_wait);
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
    llama_model_free(g_model);
    llama_backend_free();
    if (g_out)
      fclose(g_out);
    wait_exit(no_wait);
    return 1;
  }
  out("workload: ctx_tok=%d cand=%d (tokens:", (int)ctx_ids.size(),
      (int)cands.size());
  for (auto &c : cands)
    out(" %d", (int)c.size());
  out(", incl. S3 decode)\n");

  LARGE_INTEGER freq;
  QueryPerformanceFrequency(&freq);

  std::vector<int> row_thr;
  std::vector<double> row_med;
  for (int thr = kMinThr; thr <= last_thr; thr++) {
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
    // (pause between trials to break cache-warmth effects)
    std::vector<double> samples;
    int ctx_len = (int)ctx_ids.size();
    for (int t = 0; t < trials; t++) {
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
    size_t n = samples.size();
    double med = samples[n / 2];          // median
    double p25 = samples[n / 4];          // 25th percentile
    double p75 = samples[std::min(n - 1, 3 * n / 4)];  // 75th percentile
    out("  thr=%2d: median %6.1f ms/pass (mid50 %5.1f-%5.1f)%s\n",
        thr, med, p25, p75, thr > phys ? "  [超物理核]" : "");
    row_thr.push_back(thr);
    row_med.push_back(med);
    llama_free(ctx);
  }

  if (row_thr.empty()) {
    fprintf(stderr, "ERROR: no thread count could be measured\n");
    llama_model_free(g_model);
    llama_backend_free();
    if (g_out)
      fclose(g_out);
    wait_exit(no_wait);
    return 1;
  }

  // 推荐（规则只在这里，两个 GUI 都读 [RESULT]）：实测范围内、不超过物理核
  // （下限 = 扫描起点 4）的最小线程数，且延迟在最优 × 1.05 以内；物理核内
  // 都不达标就取物理核内最快的那个。
  int best_thr = row_thr[0];
  double best_ms = row_med[0];
  for (size_t i = 1; i < row_thr.size(); i++) {
    if (row_med[i] < best_ms) {
      best_ms = row_med[i];
      best_thr = row_thr[i];
    }
  }
  int pool_max = std::max(phys, kMinThr);
  double limit = best_ms * kRecThreshold;
  int rec = -1;
  double rec_ms = 0.0;
  for (size_t i = 0; i < row_thr.size(); i++) {
    if (row_thr[i] > pool_max)
      break;
    if (row_med[i] <= limit) {
      rec = row_thr[i];
      rec_ms = row_med[i];
      break;
    }
  }
  if (rec < 0) {   // 物理核内无达标 → 取物理核内最快
    double bm = 1e30;
    for (size_t i = 0; i < row_thr.size(); i++) {
      if (row_thr[i] > pool_max)
        break;
      if (row_med[i] < bm) {
        bm = row_med[i];
        rec = row_thr[i];
        rec_ms = row_med[i];
      }
    }
  }

  out("\n== summary ==\n");
  out("NOTE: run while the system is idle - heavy background load (builds,\n");
  out("      downloads, games) flattens the curve.\n");
  out("推荐 CPU 线程数 = %d（%.1f ms/pass；最优 %.1f ms @ %d 线程，"
      "取最优 × %.2f 以内最快的线程数，且不超过物理核 %d）。\n",
      rec, rec_ms, best_ms, best_thr, kRecThreshold, phys);
  out("在方案 llm_rerank 里设 cpu_cores: %d（GUI 点『实测线程数』可直接采用），"
      "然后重新部署。\n", rec);
  out("[RESULT] log_cores=%d phys_cores=%d tested=%d-%d rec=%d rec_ms=%.1f "
      "best=%d best_ms=%.1f threshold=%.2f reason=ok\n",
      cores, phys, kMinThr, last_thr, rec, rec_ms, best_thr, best_ms,
      kRecThreshold);

  llama_model_free(g_model);
  llama_backend_free();
  if (g_out)
    fclose(g_out);
  wait_exit(no_wait);
  return 0;
}
