/*
 * prof_s2.cpp — segment-level attribution of the production scoring path
 * (score_batch in rime_llm.cpp). Answers: where does the "S2 fixed base"
 * (~25-30ms) go, and what is the true marginal cost per dedup row?
 *
 * Replicates the production call sequence EXACTLY:
 *   S1  ensure_ctx_kv : memory_clear + decode ctx(20) + logits copy + normalizer
 *   CE1 ce_target     : all candidates' first-token CE on shared ctx logits
 *   KV  seq_cp 0->u   : one worker seq per step2 row (shared-marker, cheap?)
 *   S2  decode U rows : batched first tokens (dedup by first token)
 *   CE2 normalizer+CE : per row (shared (max,lse))
 *   S3  fork+decode V : batched second tokens (dedup by (c0,c1); worst case
 *                       V=U distinct bases -> no extra forks)
 *   CLN seq_rm 1..U   : worker release (prep stays valid)
 *
 * Splits each llama_decode into wall time vs in-graph compute via
 * llama_perf_context (t_eval_ms, n_reused / n_reallocs counters of this
 * mirror), so "fixed base" = graph-reuse state + batch build + KV cell mgmt
 * + logits output + thread wake all become visible.
 *
 * A/B axes (each a CLI flag, defaults = production values):
 *   --threads 4,5,6,8      (default 5 = bench_threads rec on this machine)
 *   --ctx 512,128          (default 512,128 — old measured 64->100ms vs
 *                           128->40ms, so n_ctx itself is a suspect)
 *   --unified              (kv_unified=true; production default is FALSE,
 *                           i.e. split KV x n_seq_max=20 buffers)
 *   --seqmax 20            (production n_seq_max)
 *   --rows 1,2,4,6,8,12    (U sweep -> fixed base + marginal ms/row)
 *
 * usage: prof_s2.exe [model_path] [flags above] [--trials N] [--out FILE]
 *                    [--whole-only] [--no-wait]
 *   --whole-only : skip ext + U sweep (quick A/B runs)
 *   model default: d:/gguf_models/Qwen3-0.6B-Base-Q4_K_M.gguf (bench default)
 * Output: human blocks + one machine-readable [PROF] line per config.
 *
 * Build: cpp\build_prof_s2.bat (same cl line as bench_threads, build-mt libs).
 */
#define NOMINMAX
#include <windows.h>
#include "llama.h"
#include <cstdio>
#include <cstdlib>
#include <cstdarg>
#include <cstring>
#include <cmath>
#include <array>
#include <string>
#include <vector>
#include <algorithm>
#include <fstream>
#include <io.h>
#include <share.h>

static FILE *g_out = nullptr;

// console + result file, flushed per line (same pattern as bench_threads)
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

static const char *kDefaultModel = "d:/gguf_models/Qwen3-0.6B-Base-Q4_K_M.gguf";
static const int kCtxTokens = 20;   // production max_tokens default (ctx20)
static const int kNCands = 6;       // production ce_budget default -> k=6
static const float kLseSkipNat = 20.0f;  // rime_llm.cpp kLseSkipNat
static const double kCeW1 = 1.0, kCeW2 = 1.10, kCeW3 = 0.60;  // production

static llama_model *g_model;
static const llama_vocab *g_vocab;
static volatile double g_sink = 0;  // keep CE math alive for the optimizer

// ------------------------------------------------------------------ QPC
static LARGE_INTEGER g_qpf;
static double ms_since(LARGE_INTEGER t0, LARGE_INTEGER t1) {
  return (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / g_qpf.QuadPart;
}
struct Tmr {
  LARGE_INTEGER a;
  void start() { QueryPerformanceCounter(&a); }
  double stop() const {
    LARGE_INTEGER b;
    QueryPerformanceCounter(&b);
    return ms_since(a, b);
  }
};

// median / quartiles (samples are appended then sorted once)
struct Med {
  std::vector<double> v;
  void add(double x) { v.push_back(x); }
  void sort() { std::sort(v.begin(), v.end()); }
  double med() const { return v.empty() ? 0 : v[v.size() / 2]; }
  double p25() const {
    return v.empty() ? 0 : v[std::min((size_t)v.size() / 4, v.size() - 1)];
  }
  double p75() const {
    return v.empty() ? 0
                     : v[std::min(v.size() - 1, (size_t)(3 * v.size() / 4))];
  }
};
struct Seg {
  Med s1, s1e, ce1, kv2, s2d, s2e, ce2, s3f, s3d, s3e, ce3, cln, whole;
  void sort() {
    s1.sort();
    s1e.sort();
    ce1.sort();
    kv2.sort();
    s2d.sort();
    s2e.sort();
    ce2.sort();
    s3f.sort();
    s3d.sort();
    s3e.sort();
    ce3.sort();
    cln.sort();
    whole.sort();
  }
};

// ---------------------------------------------- llama.cpp log filtering
// Keep ERROR always; additionally capture the context-create INFO lines that
// report kv_unified / KV / compute buffer sizes (they carry the memory story).
static FILE *g_logcap = nullptr;
static void cap_log(enum ggml_log_level level, const char *text, void *) {
  if (level >= GGML_LOG_LEVEL_ERROR) {
    fputs(text, stderr);
    return;
  }
  if (g_logcap &&
      (strstr(text, "kv_unified") || strstr(text, "buffer size") ||
       strstr(text, "n_seq_max"))) {
    fputs(text, g_logcap);
    fflush(g_logcap);
  }
}

// -------------------------------------------------- workload (bench shape)
static std::vector<llama_token> tokenize(const char *text) {
  std::vector<llama_token> toks(256);
  int n = llama_tokenize(g_vocab, text, (int)strlen(text), toks.data(),
                         (int)toks.size(), false, false);
  if (n > (int)toks.size())
    return std::vector<llama_token>();
  toks.resize(std::max(0, n));
  return toks;
}

// k 3-token candidates, first tokens pairwise distinct (prefix dedup can
// never merge them -> step2/step3 decode k rows = worst case; bench shape).
static std::vector<std::vector<llama_token>> build_cands(int k, int vs) {
  std::vector<llama_token> pool;
  for (llama_token id = 1; id < vs; id++) {
    if (llama_vocab_is_control(g_vocab, id) || llama_vocab_is_eog(g_vocab, id))
      continue;
    const char *t = llama_vocab_get_text(g_vocab, id);
    if (!t || !*t || t[0] == '<')
      continue;
    pool.push_back(id);
  }
  std::vector<std::vector<llama_token>> v;
  if ((int)pool.size() < 3)
    return v;
  size_t stride = std::max<size_t>(1, pool.size() / (size_t)k);
  for (int s = 0; s < k; s++) {
    size_t base = (size_t)s * stride;
    if (base >= pool.size())
      break;
    v.push_back({pool[base], pool[(base + stride / 3 + 1) % pool.size()],
                 pool[(base + 2 * stride / 3 + 2) % pool.size()]});
  }
  return v;
}

// ------------------------------------------- CE post (production math)
static void logits_normalizer(const float *logits, int vs, float &m,
                              double &lse) {
  m = -1e30f;
  for (int k = 0; k < vs; k++)
    if (logits[k] > m)
      m = logits[k];
  const float cut = m - kLseSkipNat;
  double se = 0;
  for (int k = 0; k < vs; k++)
    if (logits[k] >= cut)
      se += expf(logits[k] - m);
  lse = log(se);
}
static double ce_target(const float *logits, int target_id, float m,
                        double lse) {
  return -((double)(logits[target_id] - m) - lse);
}

// timed decode with in-graph compute split (perf reset -> decode -> read).
// Returns wall ms; *eval_ms = llama.cpp's own graph-compute ms for this call.
static double timed_decode(llama_context *ctx, llama_batch &b,
                           double *eval_ms) {
  llama_perf_context_reset(ctx);
  Tmr t;
  t.start();
  int rc = llama_decode(ctx, b);
  double wall = t.stop();
  auto pd = llama_perf_context(ctx);
  if (eval_ms)
    *eval_ms = pd.t_eval_ms + pd.t_p_eval_ms;  // 1-token batches count as
  // "eval", multi-token as "p_eval" — sum both to get graph-compute ms.
  if (rc != 0) {
    out("  !! decode failed (rc!=0)\n");
    wall = -1;
  }
  return wall;
}

// one production-shape scoring trial. s1_mode: 0=prep-hit (S1 ~0),
// 1=full rebuild, 2=extend (prefix-grow path, falls back to full).
// Segments written into sg; acc sums wall time of what ran.
// ce3_out/score_out (optional): per-candidate raw CE components (not
// weight-scaled, like production ce3) and fused score = -Σ(w_k·c_k).
// Candidate gating mirrors production exactly: rows built from idx2/idx3
// (size>=2 / >=3); 1-token candidates score CE1 only.
static bool whole_trial(llama_context *ctx,
                        const std::vector<llama_token> &ctx_ids,
                        const std::vector<std::vector<llama_token>> &cands,
                        int vs, Seg &sg, int s1_mode,
                        std::vector<std::array<double, 3>> *ce3_out = nullptr,
                        std::vector<double> *score_out = nullptr) {
  const int ctx_len = (int)ctx_ids.size();
  const int n = (int)cands.size();
  double acc = 0;  // wall-time accumulation for the whole-path median
  Tmr t;
  static std::vector<float> prep_logits;  // like g_prep_logits
  static float prep_m = 0;
  static double prep_lse = 0;
  std::vector<double> ce_sum(n, 0.0);
  if (ce3_out)
    ce3_out->assign(n, {NAN, NAN, NAN});
  if (score_out)
    score_out->assign(n, -1e10);

  // ---- S1: ensure_ctx_kv — s1_mode 0=hit / 1=full / 2=extend-if-possible ----
  static std::vector<llama_token> prep_ids;
  static bool prep_ok = false;
  bool hit = prep_ok && ctx_ids == prep_ids;
  bool ext = !hit && prep_ok && ctx_ids.size() > prep_ids.size() &&
             std::equal(prep_ids.begin(), prep_ids.end(), ctx_ids.begin());
  auto full_rebuild = [&]() -> bool {
    t.start();
    llama_memory_clear(llama_get_memory(ctx), false);
    llama_batch b = llama_batch_init(ctx_len, 0, 1);
    for (int j = 0; j < ctx_len; j++) {
      b.token[j] = ctx_ids[j];
      b.pos[j] = j;
      b.n_seq_id[j] = 1;
      b.seq_id[j][0] = 0;
      b.logits[j] = (j + 1 == ctx_len) ? 1 : 0;
    }
    b.n_tokens = ctx_len;
    double ev = 0;
    double d = timed_decode(ctx, b, &ev);
    llama_batch_free(b);
    if (d < 0)
      return false;
    const float *cl = llama_get_logits_ith(ctx, ctx_len - 1);
    if (!cl)
      return false;
    prep_logits.assign(cl, cl + vs);  // production: g_prep_logits.assign
    logits_normalizer(prep_logits.data(), vs, prep_m, prep_lse);
    prep_ids = ctx_ids;
    prep_ok = true;
    double w = t.stop();
    sg.s1.add(w);
    sg.s1e.add(ev);
    acc += w;
    return true;
  };
  auto ext_step = [&]() -> bool {
    t.start();
    int from = (int)prep_ids.size();
    llama_batch b = llama_batch_init(ctx_len - from, 0, 1);
    for (int j = from; j < ctx_len; j++) {
      b.token[j - from] = ctx_ids[j];
      b.pos[j - from] = j;
      b.n_seq_id[j - from] = 1;
      b.seq_id[j - from][0] = 0;
      b.logits[j - from] = (j + 1 == ctx_len) ? 1 : 0;
    }
    b.n_tokens = ctx_len - from;
    double ev = 0;
    double d = timed_decode(ctx, b, &ev);
    llama_batch_free(b);
    if (d < 0)
      return false;
    const float *cl = llama_get_logits_ith(ctx, ctx_len - from - 1);
    if (!cl)
      return false;
    prep_logits.assign(cl, cl + vs);
    logits_normalizer(prep_logits.data(), vs, prep_m, prep_lse);
    prep_ids = ctx_ids;
    double w = t.stop();
    sg.s1.add(w);
    sg.s1e.add(ev);
    acc += w;
    return true;
  };
  bool ok1 = true;
  if (s1_mode == 0 && hit) {
    // cached prep logits/normalizer — zero cost (production prep-hit path)
  } else if (s1_mode == 2 && ext) {
    ok1 = ext_step();
    if (!ok1) {  // production: extend failure falls back to full rebuild once
      prep_ok = false;
      ok1 = full_rebuild();
    }
  } else {
    ok1 = full_rebuild();
  }
  if (!ok1)
    return false;

  auto seg = [&](Med &m) {
    double w = t.stop();
    m.add(w);
    acc += w;
  };

  // ---- CE1: all candidates on shared ctx logits (cached normalizer) ----
  t.start();
  for (int i = 0; i < n; i++) {
    double c1 = ce_target(prep_logits.data(), cands[i][0], prep_m, prep_lse);
    ce_sum[i] = kCeW1 * c1;
    if (ce3_out)
      (*ce3_out)[i][0] = c1;
    g_sink += kCeW1 * c1;
  }
  seg(sg.ce1);

  // ---- candidate gating (production: idx2/idx3 by token count) ----
  std::vector<int> idx2, idx3;
  for (int i = 0; i < n; i++) {
    if (cands[i].size() >= 2)
      idx2.push_back(i);
    if (cands[i].size() >= 3)
      idx3.push_back(i);
  }

  // ---- step2 rows: dedup by first token (production r2_tok/r2_cands) ----
  std::vector<llama_token> r2;
  std::vector<std::vector<int>> r2_cands;
  for (int ci : idx2) {
    size_t u = 0;
    while (u < r2.size() && r2[u] != cands[ci][0])
      u++;
    if (u == r2.size()) {
      r2.push_back(cands[ci][0]);
      r2_cands.emplace_back();
    }
    r2_cands[u].push_back(ci);
  }
  const int U = (int)r2.size();
  if (U > 0) {  // production guard: all-1-token candidate sets skip step2/3
    // ---- KV: seq_cp 0 -> 1..U ----
    t.start();
    for (int u = 0; u < U; u++)
      llama_memory_seq_cp(llama_get_memory(ctx), 0, u + 1, 0, -1);
    seg(sg.kv2);

    // ---- S2: batched decode of U first tokens ----
    t.start();
  llama_batch b2 = llama_batch_init(U, 0, U);
  for (int u = 0; u < U; u++) {
    b2.token[u] = r2[u];
    b2.pos[u] = ctx_len;
    b2.n_seq_id[u] = 1;
    b2.seq_id[u][0] = u + 1;
    b2.logits[u] = 1;
  }
  b2.n_tokens = U;
  double ev2 = 0;
  double d2 = timed_decode(ctx, b2, &ev2);
  llama_batch_free(b2);
  if (d2 < 0) {
    for (int s = 1; s <= U; s++)
      llama_memory_seq_rm(llama_get_memory(ctx), s, 0, -1);
    return false;
  }
  seg(sg.s2d);
  sg.s2e.add(ev2);

  // ---- CE2: normalizer per row + targets (production math) ----
  t.start();
  for (int u = 0; u < U; u++) {
    float *l = llama_get_logits_ith(ctx, u);
    if (!l) {
      for (int ci : r2_cands[u])
        ce_sum[ci] = -1e10;
      continue;
    }
    float rm;
    double rlse;
    logits_normalizer(l, vs, rm, rlse);
    for (int ci : r2_cands[u]) {
      double c2 = -((double)(l[cands[ci][1]] - rm) - rlse);
      ce_sum[ci] += kCeW2 * c2;
      if (ce3_out)
        (*ce3_out)[ci][1] = c2;
      g_sink += kCeW2 * c2;
    }
  }
  seg(sg.ce2);
  }  // U > 0

  // ---- S3: rows dedup by (c0,c1) pair, fork via seq_cp after the first
  //      pair per base (production rows3/base_cnt/fresh logic) ----
  struct Row3 {
    int base;
    llama_token tok1;
    std::vector<int> cands;
  };
  std::vector<Row3> rows3;
  for (int ci : idx3) {
    int base = -1;
    for (int u = 0; u < U; u++)
      if (r2[u] == cands[ci][0]) {
        base = u;
        break;
      }
    int v = 0;
    while (v < (int)rows3.size() &&
           !(rows3[v].base == base && rows3[v].tok1 == cands[ci][1]))
      v++;
    if (v == (int)rows3.size())
      rows3.push_back({base, cands[ci][1], {}});
    rows3[v].cands.push_back(ci);
  }
  const int V = (int)rows3.size();
  t.start();
  std::vector<int> seqv(V);
  int seq_top = U;
  {
    std::vector<int> base_cnt(U, 0);
    int fresh = U;
    for (int v = 0; v < V; v++) {
      if (++base_cnt[rows3[v].base] == 1)
        seqv[v] = rows3[v].base + 1;  // reuse step2 seq
      else {
        seqv[v] = ++fresh;
        llama_memory_seq_cp(llama_get_memory(ctx), rows3[v].base + 1, seqv[v],
                            0, -1);
      }
    }
    seq_top = fresh;
  }
  seg(sg.s3f);

  bool s3_ok = true;
  if (V > 0) {
    t.start();
    llama_batch b3 = llama_batch_init(V, 0, V);
    for (int v = 0; v < V; v++) {
      b3.token[v] = rows3[v].tok1;
      b3.pos[v] = ctx_len + 1;
      b3.n_seq_id[v] = 1;
      b3.seq_id[v][0] = seqv[v];
      b3.logits[v] = 1;
    }
    b3.n_tokens = V;
    double ev3 = 0;
    double d3 = timed_decode(ctx, b3, &ev3);
    llama_batch_free(b3);
    if (d3 < 0) {
      s3_ok = false;
    } else {
      seg(sg.s3d);
      sg.s3e.add(ev3);
      t.start();
      for (int v = 0; v < V; v++) {
        float *l = llama_get_logits_ith(ctx, v);
        if (!l) {
          for (int ci : rows3[v].cands)
            ce_sum[ci] = -1e10;
          continue;
        }
        float rm;
        double rlse;
        logits_normalizer(l, vs, rm, rlse);
        for (int ci : rows3[v].cands) {
          double c3 = -((double)(l[cands[ci][2]] - rm) - rlse);
          ce_sum[ci] += kCeW3 * c3;
          if (ce3_out)
            (*ce3_out)[ci][2] = c3;
          g_sink += kCeW3 * c3;
        }
      }
      seg(sg.ce3);
    }
  } else {
    sg.s3d.add(0);
    sg.ce3.add(0);
  }
  if (!s3_ok) {
    for (auto &r : rows3)
      for (int ci : r.cands)
        ce_sum[ci] = -1e10;
    for (int s = 1; s <= seq_top; s++)
      llama_memory_seq_rm(llama_get_memory(ctx), s, 0, -1);
    return false;
  }

  // ---- CLN: release worker seqs (production 1..seq_top) ----
  t.start();
  for (int s = 1; s <= seq_top; s++)
    llama_memory_seq_rm(llama_get_memory(ctx), s, 0, -1);
  seg(sg.cln);

  if (score_out)
    for (int i = 0; i < n; i++)
      (*score_out)[i] = ce_sum[i] > -1e9 ? -ce_sum[i] : -1e10;
  sg.whole.add(acc);
  return true;
}

// sweep trial: seq_cp xU + decode(U) + CE(U) + cleanup, all timed separately
struct SweepSeg {
  Med cp, dec, ev, ce, cln;
};
static void sweep_trial(llama_context *ctx, int ctx_len, int U, int vs,
                        const std::vector<llama_token> &r2, SweepSeg &sg) {
  Tmr t;
  t.start();
  for (int u = 0; u < U; u++)
    llama_memory_seq_cp(llama_get_memory(ctx), 0, u + 1, 0, -1);
  sg.cp.add(t.stop());

  t.start();
  llama_batch b = llama_batch_init(U, 0, U);
  for (int u = 0; u < U; u++) {
    b.token[u] = r2[u];
    b.pos[u] = ctx_len;
    b.n_seq_id[u] = 1;
    b.seq_id[u][0] = u + 1;
    b.logits[u] = 1;
  }
  b.n_tokens = U;
  double ev = 0;
  double d = timed_decode(ctx, b, &ev);
  llama_batch_free(b);
  if (d < 0)
    return;
  sg.dec.add(d);
  sg.ev.add(ev);

  t.start();
  for (int u = 0; u < U; u++) {
    float *l = llama_get_logits_ith(ctx, u);
    if (!l)
      continue;
    float rm;
    double rlse;
    logits_normalizer(l, vs, rm, rlse);
    g_sink += ce_target(l, r2[(u + 1) % U], rm, rlse);
  }
  sg.ce.add(t.stop());

  t.start();
  for (int s = 1; s <= U; s++)
    llama_memory_seq_rm(llama_get_memory(ctx), s, 0, -1);
  sg.cln.add(t.stop());
}

// ---------------------------------------------------- CE invariance check
// Verifies CE numbers and fused ORDER are unchanged between kv_unified=false
// (production default) and true, on realistic Chinese workloads covering:
// shared-first-token dedup rows, 1-token candidates (CE1-only), the
// prefix-extend S1 path, and prep-hit repeats (worker-seq state pollution).
struct WL {
  const char *name;
  const char *ctx_text;          // tail-kCtxTokens tokens (when ids empty)
  std::vector<llama_token> ids;  // explicit ctx ids (extend-pair tests)
  int s1_mode;                   // fresh pass S1 mode (1=full, 2=extend)
  std::vector<const char *> words;
};
struct CandCE {
  double c1, c2, c3, score;
};
struct WLResult {
  std::string name;
  std::vector<std::vector<llama_token>> cands;
  std::vector<std::string> texts;
  std::vector<CandCE> a;  // fresh pass
  std::vector<CandCE> b;  // immediate prep-hit repeat (same ctx)
};

static std::vector<WL> build_workloads() {
  std::vector<WL> w;
  w.push_back({"W1",
               "我们明天早上八点在公司门口集合然后一起去图书馆借几本关于计算机系统的"
               "书顺便买点水果回来",
               {}, 1,
               {"集合", "会议", "计划", "回家", "图书馆", "图书", "计算机",
                "计算", "天气", "今天", "水果"}});
  w.push_back({"W2",
               "今天天气很好我们决定去公园散步然后吃午饭顺便买一杯咖啡再回家写报告",
               {}, 1,
               {"今天天气", "今天", "天天", "天空", "散步", "午饭", "然后"}});
  w.push_back({"W3", "你好", {}, 1,
               {"你好", "你们", "的", "了", "在", "很好"}});
  // W4/W5: prefix-extend pair — W5 ctx = W4 ctx + 2 more tokens -> the
  // extend S1 path runs, then CE must match the full-rebuild numbers.
  const char *base =
      "他说昨天的会议已经结束了新的安排会在明天公布请大家准时参加会议讨论";
  std::vector<llama_token> full = tokenize(base);
  if (full.size() >= 10) {
    size_t n4 = std::min<size_t>(18, full.size() - 2);
    std::vector<llama_token> short_ids(full.begin(), full.begin() + n4);
    w.push_back({"W4", "", short_ids, 1,
                 {"会议", "结束", "安排", "公布", "准时", "讨论"}});
    size_t n5 = std::min<size_t>(20, full.size());
    std::vector<llama_token> long_ids(full.begin(), full.begin() + n5);
    w.push_back({"W5", "", long_ids, 2,
                 {"会议", "结束", "安排", "公布", "准时", "讨论"}});
  }
  w.push_back({"W6",
               "他匆匆忙忙地跑进车站但是火车已经开走了他只能改签下一班车次",
               {}, 1,
               {"火车", "车站", "匆匆", "改签", "车次", "已经"}});
  return w;
}

static double cdelta(double s, double u) {
  bool ns = (s != s), nu = (u != u);  // NaN detection
  if (ns && nu)
    return 0.0;  // both missing (1-token cand, no CE2/CE3)
  if (ns || nu)
    return 1e9;
  return fabs(s - u);
}

static bool run_ce_suite(llama_context *ctx, const std::vector<WL> &wls,
                         std::vector<WLResult> &res_out, int vs) {
  res_out.clear();
  for (const auto &w : wls) {
    WLResult r;
    r.name = w.name;
    std::vector<llama_token> ids = w.ids;
    if (ids.empty()) {
      ids = tokenize(w.ctx_text);
      if ((int)ids.size() > kCtxTokens)
        ids.erase(ids.begin(), ids.end() - kCtxTokens);
    }
    if (ids.empty()) {
      out("  %s: skipped (empty ctx)\n", w.name);
      continue;
    }
    for (const char *wd : w.words) {
      auto t = tokenize(wd);
      if (t.empty())
        continue;
      if ((int)t.size() > 3)
        t.resize(3);  // production: 只算前三 token
      r.texts.push_back(wd);
      r.cands.push_back(t);
    }
    Seg dummy;
    std::vector<std::array<double, 3>> ce3;
    std::vector<double> sc;
    if (!whole_trial(ctx, ids, r.cands, vs, dummy, w.s1_mode, &ce3, &sc))
      return false;
    for (size_t i = 0; i < r.cands.size(); i++)
      r.a.push_back({ce3[i][0], ce3[i][1], ce3[i][2], sc[i]});
    if (!whole_trial(ctx, ids, r.cands, vs, dummy, 0, &ce3, &sc))
      return false;
    for (size_t i = 0; i < r.cands.size(); i++)
      r.b.push_back({ce3[i][0], ce3[i][1], ce3[i][2], sc[i]});
    res_out.push_back(std::move(r));
  }
  return true;
}

static void compare_ce(const std::vector<WLResult> &S,
                       const std::vector<WLResult> &U, double &maxabs,
                       int &flips, double &repmax) {
  maxabs = 0;
  flips = 0;
  repmax = 0;
  auto order = [](const WLResult &r) {
    std::vector<int> idx(r.cands.size());
    for (size_t i = 0; i < idx.size(); i++)
      idx[i] = (int)i;
    std::stable_sort(idx.begin(), idx.end(), [&](int x, int y) {
      return r.a[x].score > r.a[y].score;
    });
    return idx;
  };
  for (size_t w = 0; w < S.size() && w < U.size(); w++) {
    const WLResult &s = S[w], &u = U[w];
    double wmax = 0;
    for (size_t i = 0; i < s.cands.size(); i++) {
      double d[4] = {cdelta(s.a[i].c1, u.a[i].c1),
                     cdelta(s.a[i].c2, u.a[i].c2),
                     cdelta(s.a[i].c3, u.a[i].c3),
                     cdelta(s.a[i].score, u.a[i].score)};
      for (double x : d)
        if (x > wmax)
          wmax = x;
      double rs = std::max({cdelta(s.a[i].c1, s.b[i].c1),
                            cdelta(s.a[i].c2, s.b[i].c2),
                            cdelta(s.a[i].c3, s.b[i].c3),
                            cdelta(s.a[i].score, s.b[i].score)});
      double ru = std::max({cdelta(u.a[i].c1, u.b[i].c1),
                            cdelta(u.a[i].c2, u.b[i].c2),
                            cdelta(u.a[i].c3, u.b[i].c3),
                            cdelta(u.a[i].score, u.b[i].score)});
      if (rs > repmax)
        repmax = rs;
      if (ru > repmax)
        repmax = ru;
    }
    auto os = order(s), ou = order(u);
    bool same = (os == ou);
    if (!same)
      flips++;
    if (wmax > maxabs)
      maxabs = wmax;
    out("  %-3s cands=%2d split_vs_uni maxDelta=%.3e order=%s\n",
        s.name.c_str(), (int)s.cands.size(), wmax, same ? "same" : "DIFF");
    if (w == 0) {  // anti false-positive: prove scores are real, not sentinels
      double lo = 1e30, hi = -1e30;
      for (size_t i = 0; i < s.cands.size(); i++)
        if (s.a[i].score > -1e9) {
          if (s.a[i].score < lo)
            lo = s.a[i].score;
          if (s.a[i].score > hi)
            hi = s.a[i].score;
        }
      out("      W1 real score range (split): [%.3f, %.3f] (sentinel=-1e10)\n",
          lo, hi);
    }
    if (!same) {
      for (size_t i = 0; i < os.size(); i++)
        out("      #%d: split[%s]=%.6f  uni[%s]=%.6f\n", (int)i + 1,
            s.texts[os[i]].c_str(), s.a[os[i]].score, u.texts[ou[i]].c_str(),
            u.a[ou[i]].score);
    }
  }
}

// ------------------------------------------------------------- reporting
// (per-config block is printed inline below)

// ------------------------------------------------------------ CLI utils
static std::vector<int> parse_list(const char *s) {
  std::vector<int> v;
  char buf[128];
  strncpy(buf, s, sizeof(buf) - 1);
  buf[sizeof(buf) - 1] = 0;
  char *p = buf;
  while (*p) {
    int x = atoi(p);
    if (x > 0)
      v.push_back(x);
    while (*p && *p != ',')
      p++;
    if (*p == ',')
      p++;
  }
  return v;
}

static std::wstring widen(const char *s) {
  int n = MultiByteToWideChar(CP_ACP, 0, s, -1, NULL, 0);
  if (n <= 0)
    return std::wstring();
  std::wstring w(n - 1 > 0 ? n - 1 : 0, L'\0');
  MultiByteToWideChar(CP_ACP, 0, s, -1, &w[0], n);
  return w;
}

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
  FILE *f = _wfsopen((dir + L"prof_s2_result.txt").c_str(), L"wb", _SH_DENYNO);
  if (f)
    return f;
  wchar_t tmp[MAX_PATH];
  DWORD n = GetTempPathW(MAX_PATH, tmp);
  if (n > 0)
    return _wfsopen((std::wstring(tmp) + L"prof_s2_result.txt").c_str(), L"wb",
                    _SH_DENYNO);
  return NULL;
}

static void wait_exit(bool no_wait) {
  if (no_wait)
    return;
  if (!_isatty(_fileno(stdin)) || !_isatty(_fileno(stdout)))
    return;
  printf("\nPress Enter to exit...\n");
  fflush(stdout);
  getchar();
}

int main(int argc, char **argv) {
  QueryPerformanceFrequency(&g_qpf);
  llama_log_set(cap_log, nullptr);
  const char *model_path = kDefaultModel;
  const char *out_arg = NULL;
  std::vector<int> thr_list = {5};
  std::vector<int> ctx_list = {512, 128};
  std::vector<int> rows = {1, 2, 4, 6, 8, 12};
  int trials = 41;
  int seqmax = 20;
  bool unified = false;
  bool whole_only = false;
  bool ce_check = false;
  bool no_wait = false;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--threads") && i + 1 < argc)
      thr_list = parse_list(argv[++i]);
    else if (!strcmp(argv[i], "--ctx") && i + 1 < argc)
      ctx_list = parse_list(argv[++i]);
    else if (!strcmp(argv[i], "--rows") && i + 1 < argc)
      rows = parse_list(argv[++i]);
    else if (!strcmp(argv[i], "--trials") && i + 1 < argc) {
      trials = atoi(argv[++i]);
      if (trials < 5)
        trials = 5;
    } else if (!strcmp(argv[i], "--seqmax") && i + 1 < argc)
      seqmax = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--unified"))
      unified = true;
    else if (!strcmp(argv[i], "--whole-only"))
      whole_only = true;
    else if (!strcmp(argv[i], "--ce-check"))
      ce_check = true;
    else if (!strcmp(argv[i], "--out") && i + 1 < argc)
      out_arg = argv[++i];
    else if (!strcmp(argv[i], "--no-wait"))
      no_wait = true;
    else if (argv[i][0] != '-')
      model_path = argv[i];
  }
  if (thr_list.empty())
    thr_list.push_back(5);
  if (ctx_list.empty())
    ctx_list.push_back(512);

  g_out = open_out(out_arg);
  if (g_out)
    fprintf(stderr, "results written to: %s\n",
            out_arg && *out_arg ? out_arg : "(exe dir or %TEMP%)");

  out("== prof_s2: production score_batch segment profiler ==\n");
  out("model: %s\n", model_path);
  out("threads=%s ctx=%s seqmax=%d unified=%d trials=%d rows=%s\n", [&] {
    static char b[64];
    char *p = b;
    for (size_t i = 0; i < thr_list.size(); i++)
      p += sprintf(p, "%s%d", i ? "," : "", thr_list[i]);
    return b;
  }(), [&] {
    static char b[64];
    char *p = b;
    for (size_t i = 0; i < ctx_list.size(); i++)
      p += sprintf(p, "%s%d", i ? "," : "", ctx_list[i]);
    return b;
  }(), seqmax, (int)unified, trials, [&] {
    static char b[64];
    char *p = b;
    for (size_t i = 0; i < rows.size(); i++)
      p += sprintf(p, "%s%d", i ? "," : "", rows[i]);
    return b;
  }());

  llama_backend_init();
  llama_model_params mp = llama_model_default_params();
  mp.load_mode = LLAMA_LOAD_MODE_MMAP;  // production
  g_model = llama_model_load_from_file(model_path, mp);
  if (!g_model) {
    fprintf(stderr, "model load failed: %s\n", model_path);
    if (g_out)
      fclose(g_out);
    wait_exit(no_wait);
    return 1;
  }
  g_vocab = llama_model_get_vocab(g_model);
  const int vs = llama_vocab_n_tokens(g_vocab);

  const char *ctx_text =
      "我们明天早上八点在公司门口集合然后一起去图书馆借几本关于计算机系统的书顺便买点水果回来";
  std::vector<llama_token> ctx_ids = tokenize(ctx_text);
  if ((int)ctx_ids.size() > kCtxTokens)
    ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - kCtxTokens);
  std::vector<std::vector<llama_token>> cands = build_cands(kNCands, vs);
  if ((int)cands.size() < kNCands) {
    fprintf(stderr, "ERROR: cannot build %d candidates\n", kNCands);
    if (g_out)
      fclose(g_out);
    return 1;
  }
  // step2 rows for the sweep (same distinct-first-token shape)
  std::vector<llama_token> r2;
  for (int i = 0; i < (int)rows.size() && i < kNCands; i++) {
    // rows up to 12 exceed k=6 distinct cands -> synthesize extra tokens
    r2.push_back(cands[i % kNCands][0]);
  }
  for (int i = (int)r2.size(); i < rows.back() && i < seqmax - 1; i++) {
    // extend with further distinct tokens from the vocab pool
    for (llama_token id = 1; i >= (int)r2.size(); id++) {
      if (llama_vocab_is_control(g_vocab, id) || llama_vocab_is_eog(g_vocab, id))
        continue;
      const char *t = llama_vocab_get_text(g_vocab, id);
      if (!t || !*t || t[0] == '<')
        continue;
      bool dup = false;
      for (int q = 0; q < (int)r2.size(); q++)
        if (r2[q] == id)
          dup = true;
      if (!dup) {
        r2.push_back(id);
        break;
      }
    }
  }
  out("workload: ctx_tok=%d, %d cands x 3 tok (distinct firsts); sweep U<=%d\n",
      (int)ctx_ids.size(), (int)cands.size(), (int)r2.size());

  // ---- CE invariance check: split (production) vs unified, per thread count ----
  if (ce_check) {
    out("\n== CE invariance: kv_unified=false (production) vs true ==\n");
    std::vector<WL> wls = build_workloads();
    int cand_total = 0;
    for (auto &w : wls) {
      std::vector<llama_token> tids = w.ids;
      if (tids.empty()) {
        tids = tokenize(w.ctx_text);
        if ((int)tids.size() > kCtxTokens)
          tids.erase(tids.begin(), tids.end() - kCtxTokens);
      }
      out("  %s: ctx_tok=%d words=%d\n", w.name, (int)tids.size(),
          (int)w.words.size());
      cand_total += (int)w.words.size();
    }
    double gmax = 0, grep = 0;
    int gflips = 0;
    bool suite_ok = true;
    std::vector<WLResult> split_res;
    for (int thr : {5, 8}) {
      for (int uni = 0; uni <= 1; uni++) {
        llama_context_params cp = llama_context_default_params();
        cp.n_ctx = 512;
        cp.n_threads = thr;
        cp.n_threads_batch = thr;
        cp.n_seq_max = seqmax;
        cp.kv_unified = uni ? true : false;
        cp.no_perf = false;
        llama_context *c = llama_init_from_model(g_model, cp);
        if (!c) {
          out("  ctx create FAILED (thr=%d uni=%d)\n", thr, uni);
          suite_ok = false;
          break;
        }
        std::vector<WLResult> res;
        bool ok = run_ce_suite(c, wls, res, vs);
        llama_free(c);
        if (!ok) {
          out("  suite FAILED (thr=%d uni=%d)\n", thr, uni);
          suite_ok = false;
          break;
        }
        if (uni == 0)
          split_res = res;  // hold split results until unified of same thr
        else {
          double ma = 0, rp = 0;
          int fl = 0;
          out(" threads=%d:\n", thr);
          compare_ce(split_res, res, ma, fl, rp);
          if (ma > gmax)
            gmax = ma;
          if (rp > grep)
            grep = rp;
          gflips += fl;
        }
      }
      if (!suite_ok)
        break;
    }
    const char *verdict =
        !suite_ok ? "SUITE-FAILED"
                  : (gflips > 0 ? "FAIL-ORDER"
                                : (gmax == 0.0
                                       ? "IDENTICAL"
                                       : (gmax < 1e-3 ? "OK-TINY"
                                                      : "DIFF-LARGE")));
    out("[CECHECK] workloads=%d cands=%d max_abs_delta=%.3e order_flips=%d "
        "repeat_max_delta=%.3e verdict=%s\n",
        (int)wls.size(), cand_total, gmax, gflips, grep, verdict);
    llama_model_free(g_model);
    llama_backend_free();
    if (g_out)
      fclose(g_out);
    wait_exit(no_wait);
    return 0;
  }

  bool sweep_done = false;
  for (int thr : thr_list) {
    for (int nctx : ctx_list) {
      out("\n== config: threads=%d n_ctx=%d n_seq_max=%d kv_unified=%d ==\n",
          thr, nctx, seqmax, (int)unified);
      llama_context_params cp = llama_context_default_params();
      cp.n_ctx = nctx;
      cp.n_threads = thr;
      cp.n_threads_batch = thr;
      cp.n_seq_max = seqmax;
      cp.kv_unified = unified;
      cp.no_perf = false;
      llama_context *ctx = llama_init_from_model(g_model, cp);
      if (!ctx) {
        out("  context create FAILED\n");
        continue;
      }
      // warmup (graph build / buffers): one full production pass
      {
        Seg dummy;
        whole_trial(ctx, ctx_ids, cands, vs, dummy, true);
        whole_trial(ctx, ctx_ids, cands, vs, dummy, false);
      }
      const int ntr = trials;

      // ---- whole path (new ctx: S1 full rebuild) ----
      Seg sg;
      for (int i = 0; i < ntr; i++)
        whole_trial(ctx, ctx_ids, cands, vs, sg, true);
      // ---- hit path (same ctx: prep hit, S1 ~0) ----
      Seg hg;
      for (int i = 0; i < ntr; i++)
        whole_trial(ctx, ctx_ids, cands, vs, hg, false);
      // ---- extend path (S1 = +1 token decode) ----
      Med ext;
      if (!whole_only) {
        static std::vector<float> extbuf;  // capacity reuse, like g_prep_logits
        std::vector<llama_token> p19(ctx_ids.begin(), ctx_ids.end() - 1);
        for (int i = 0; i < ntr; i++) {
          llama_memory_clear(llama_get_memory(ctx), false);
          llama_batch bp = llama_batch_init((int)p19.size(), 0, 1);
          for (int j = 0; j < (int)p19.size(); j++) {
            bp.token[j] = p19[j];
            bp.pos[j] = j;
            bp.n_seq_id[j] = 1;
            bp.seq_id[j][0] = 0;
            bp.logits[j] = 0;
          }
          bp.n_tokens = (int)p19.size();
          llama_decode(ctx, bp);  // untimed prime (pos 0..18)
          llama_batch_free(bp);
          llama_batch be = llama_batch_init(1, 0, 1);
          be.token[0] = ctx_ids.back();
          be.pos[0] = (int)p19.size();
          be.n_seq_id[0] = 1;
          be.seq_id[0][0] = 0;
          be.logits[0] = 1;
          be.n_tokens = 1;
          Tmr t;
          t.start();
          double d = timed_decode(ctx, be, nullptr);
          llama_batch_free(be);
          if (d < 0)
            break;
          const float *cl = llama_get_logits_ith(ctx, 0);
          if (cl) {
            float m;
            double lse;
            extbuf.assign(cl, cl + vs);
            logits_normalizer(extbuf.data(), vs, m, lse);
          }
          ext.add(t.stop());
        }
      }
      sg.sort();
      hg.sort();
      ext.sort();

      out("  whole(new ctx) med %.2f ms:\n", sg.whole.med());
      out("    s1_full=%0.2f (eval %0.2f) s2_eval=%0.1f s3_eval=%0.1f\n",
          sg.s1.med(), sg.s1e.med(), sg.s2e.med(), sg.s3e.med());
      out("  hit(same ctx) med %.2f ms:\n", hg.whole.med());
      out("    ce1=%0.2f kv2=%0.2f s2=%0.2f(eval %0.1f) ce2=%0.2f s3f=%0.2f s3=%0.2f(eval %0.1f) ce3=%0.2f cln=%0.2f\n",
          hg.ce1.med(), hg.kv2.med(), hg.s2d.med(), hg.s2e.med(), hg.ce2.med(),
          hg.s3f.med(), hg.s3d.med(), hg.s3e.med(), hg.ce3.med(), hg.cln.med());
      if (!whole_only)
        out("  ext(+1 tok) med %.2f ms\n", ext.med());

      // ---- U sweep: fixed base + marginal per row ----
      char pline[512];
      double u1 = 0, u6 = 0, u8 = 0, marg = 0, ev6 = 0, kvcp6 = 0, ce6 = 0;
      if (!whole_only && !sweep_done) {
        out("  U-sweep (decode wall / in-graph eval / CE post / seq_cp):\n");
        std::vector<double> umed;
        for (int U : rows) {
          if (U > (int)r2.size() || U >= seqmax)
            continue;
          SweepSeg s;
          for (int i = 0; i < ntr; i++)
            sweep_trial(ctx, (int)ctx_ids.size(), U, vs, r2, s);
          s.dec.sort();
          s.ev.sort();
          s.ce.sort();
          s.cp.sort();
          umed.push_back(s.dec.med());
          out("    U=%2d dec %6.2f ms (eval %6.2f)  ce %5.2f  cp %5.2f\n", U,
              s.dec.med(), s.ev.med(), s.ce.med(), s.cp.med());
          if (U == 1) {
            u1 = s.dec.med();
            ce6 = s.ce.med();
          }
          if (U == 6) {
            u6 = s.dec.med();
            ev6 = s.ev.med();
            kvcp6 = s.cp.med();
            ce6 = s.ce.med();
          }
          if (U == 8)
            u8 = s.dec.med();
        }
        if (u1 > 0 && u8 > 0)
          marg = (u8 - u1) / 7.0;
        sweep_done = true;
      }

      // graph-reuse counters from perf (since last reset; indicative)
      auto pd = llama_perf_context(ctx);
      out("  perf: reused=%d realloc_same=%d realloc_diff=%d\n", pd.n_reused,
          pd.n_reallocs_same, pd.n_reallocs_diff);

      snprintf(pline, sizeof(pline),
               "[PROF] thr=%d ctx=%d uni=%d whole=%.1f hit=%.1f s1=%.1f "
               "ext=%.1f u1=%.1f u6=%.1f u8=%.1f marg=%.2f ev6=%.1f "
               "kvcp6=%.2f ce6=%.2f reused=%d rsame=%d rdiff=%d\n",
               thr, nctx, (int)unified, sg.whole.med(), hg.whole.med(),
               sg.s1.med(), ext.med(), u1, u6, u8, marg, ev6, kvcp6, ce6,
               pd.n_reused, pd.n_reallocs_same, pd.n_reallocs_diff);
      out("%s", pline);
      llama_free(ctx);
    }
  }

  out("\nsink=%.6f (CE checksum, nonzero = math ran)\n", (double)g_sink);
  llama_model_free(g_model);
  llama_backend_free();
  if (g_out)
    fclose(g_out);
  wait_exit(no_wait);
  return 0;
}
