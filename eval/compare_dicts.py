#!/usr/bin/env python3
"""
多词库统一对比评测
HanLP 分词一次 → 各词库独立查码 → 合并 LLM 重排 → 对比首选率

用法:
  # 准备分段缓存
  python eval/compare_dicts.py --segment

  # 多词库对比
  python eval/compare_dicts.py --compare \
      --dict "d:/.../pdsp.dict.yaml" --name "拼读双拼" \
      --dict "d:/.../zrlong.dict.yaml" --name "自然龙" \
      --dict "d:/.../wubi86_jidian.dict.yaml" --name "极点五笔"

  # 也支持 eval_rerank 风格的单文本
  python eval/compare_dicts.py --text "..." --dict ... --name ... --dict ... --name ...
"""
import argparse, json, subprocess, sys, os, random, time, re
from pathlib import Path
from collections import defaultdict, OrderedDict

ROOT      = Path(__file__).resolve().parent   # eval/
PROJ      = ROOT.parent                        # 项目根
SIM_EXE   = PROJ / "cpp/build_sim/Release/sim_rerank.exe"
# 本机/跨项目资源：环境变量可覆盖（见 CLAUDE.md）
CORPUS    = Path(os.environ.get("RIME_LLM_CORPUS",
              "D:/OneDrive/typing/bert_seg/data/sentences_filtered.txt"))
DATA_DIR  = Path(os.environ.get("RIME_LLM_DATA_DIR",
              "D:/OneDrive/typing/bert_seg/data/batch_eval"))
N_SAMPLES = 10000
SEED      = 42
MODEL_PATH = os.environ.get("GGUF_MODEL", "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf")

# ── CLI ──
parser = argparse.ArgumentParser(description="多词库统一对比评测")
parser.add_argument("--segment", action="store_true", help="仅生成 HanLP 分段缓存")
parser.add_argument("--compare", action="store_true", help="多词库对比")
parser.add_argument("--text", help="直接输入单篇文本评测")
parser.add_argument("--dict", action="append", default=[],
                    help="词库路径（可多次指定）")
parser.add_argument("--name", action="append", default=[],
                    help="词库名称（与 --dict 一一对应）")
parser.add_argument("--model", default=MODEL_PATH, help="LLM 模型路径")
parser.add_argument("--n", type=int, default=N_SAMPLES, help="句子样本数")
parser.add_argument("--sample-words", type=int, default=20000, help="词抽样数（默认20000）")
parser.add_argument("--min-len", type=int, default=20)
parser.add_argument("--max-len", type=int, default=200)
parser.add_argument("--workers", type=int, default=3, help="并行 LLM worker 数")
args = parser.parse_args()

# ═══════════════════════════════════════════
# 1. SEGMENT ONLY
# ═══════════════════════════════════════════
if args.segment:
    import hanlp
    N = args.n
    seg_cache = DATA_DIR / f"segments_{N}.jsonl"

    random.seed(SEED)
    all_sents = []
    with open(CORPUS, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if args.min_len <= len(s) <= args.max_len:
                all_sents.append(s)
    sampled = random.sample(all_sents, min(N, len(all_sents)))

    print(f"HanLP 分词 ({len(sampled)} 句)...")
    tok = hanlp.load(hanlp.pretrained.tok.COARSE_ELECTRA_SMALL_ZH)

    def is_cjk(ch): return '一' <= ch <= '鿿'

    def segment(text):
        words = tok(text)
        result = []
        for w in words:
            parts, buf, in_cjk = [], [], None
            for ch in w:
                cjk = '一' <= ch <= '鿿'
                if in_cjk is not None and cjk != in_cjk:
                    parts.append(''.join(buf)); buf = []
                in_cjk = cjk; buf.append(ch)
            if buf: parts.append(''.join(buf))
            result.extend(parts)
        return [w for w in result if w]

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with open(seg_cache, "w", encoding="utf-8") as f:
        for si, sent in enumerate(sampled):
            words = segment(sent)
            f.write(json.dumps(words, ensure_ascii=False) + "\n")
            if (si + 1) % 1000 == 0:
                print(f"  {si+1}/{len(sampled)}")
    print(f"  缓存已保存: {seg_cache}")

# ═══════════════════════════════════════════
# 2. LOAD DICT
# ═══════════════════════════════════════════
def load_dict(path):
    """返回 (word_to_codes, code_to_words)"""
    w2c = defaultdict(list)
    c2w = defaultdict(OrderedDict)
    with open(path, encoding="utf-8") as f:
        in_body = False
        for line in f:
            line = line.rstrip("\n\r")
            if line == "...": in_body = True; continue
            if not in_body or not line or line.startswith("#"): continue
            parts = line.split("\t")
            if len(parts) < 2: continue
            w, c = parts[0], parts[1]
            if len(w) < 2: continue
            if not args.text and len(c) != 4:
                # 批量模式：pdsp（拼读双拼）固定 4 码，非 4 码行跳过；外部词库放宽
                # 识别方式：文件名 stem 含 "pdsp"（项目内拷贝或 OneDrive 规范源均可）
                if "pdsp" in Path(path).stem:
                    continue
            w2c[w].append(c)
            if w not in c2w[c]:
                c2w[c][w] = len(c2w[c])
    return w2c, c2w

# ═══════════════════════════════════════════
# 3. BUILD WORD TABLE
# ═══════════════════════════════════════════
def build_word_table(sent_words_list, dicts_info):
    """
    dicts_info: [(name, w2c, c2w), ...]
    返回:
      words: [{word, ctx, dicts: {name: {cands, rd} | None}}]
      stats: [{name, total_words, missing, in_dict, single, multi}]
    """
    words = []
    dict_names = [d[0] for d in dicts_info]
    stats = {name: {"total": 0, "missing": 0, "in_dict": 0, "single": 0, "multi": 0}
             for name in dict_names}

    for sent_words in sent_words_list:
        ctx = []
        for w in sent_words:
            if len(w) < 2:
                ctx.append(w)
                continue

            entry = {"w": w, "ctx": "".join(ctx), "dicts": {}}
            for name, w2c, c2w in dicts_info:
                stats[name]["total"] += 1
                codes = w2c.get(w, [])
                if not codes:
                    stats[name]["missing"] += 1
                    entry["dicts"][name] = None
                    continue
                stats[name]["in_dict"] += 1
                code = codes[0]
                cands = list(c2w[code].keys())[:5]
                if len(cands) <= 1:
                    stats[name]["single"] += 1
                    entry["dicts"][name] = {"cands": cands, "rd": 1}
                else:
                    stats[name]["multi"] += 1
                    rd = cands.index(w) + 1 if w in cands else "?"
                    entry["dicts"][name] = {"cands": cands, "rd": rd}

            words.append(entry)
            ctx.append(w)

    return words, stats

# ═══════════════════════════════════════════
# 4. RUN LLM (unified)
# ═══════════════════════════════════════════
def run_llm_unified(words, dicts_info):
    """
    为所有词库的多候选条目构建统一的 sim_rerank 输入。
    同一条目可能在多个词库中有不同候选集，各自独立送评。
    返回: {dict_name: {word_index: llm_ranked}}
    """
    dict_names = [d[0] for d in dicts_info]
    # 构建条目列表: (dict_idx, word_idx, ctx, cands)
    entries = []
    for wi, w in enumerate(words):
        for di, (name, _, _) in enumerate(dicts_info):
            d = w["dicts"].get(name)
            if d and len(d["cands"]) > 1:  # 多候选才送 LLM
                entries.append((di, wi, w["ctx"], d["cands"]))

    if not entries:
        return {name: {} for name in dict_names}

    print(f"LLM 重排: {len(entries)} 条 ({len(dicts_info)} 词库合并)...", flush=True)

    # 合并所有条目为一个 sim_input
    payload = "\n".join(
        json.dumps({"context": ctx, "cands": cands}, ensure_ascii=False)
        for _, _, ctx, cands in entries
    )

    import tempfile, shutil, concurrent.futures
    tmpdir = Path(tempfile.mkdtemp(prefix="cmp_dicts_"))

    # Split into chunks for parallel processing
    workers = args.workers
    chunk_size = (len(entries) + workers - 1) // workers
    chunks = []
    entry_lines = payload.split("\n")
    for i in range(workers):
        start = i * chunk_size
        end = min(start + chunk_size, len(entries))
        if start >= len(entries): break
        cf = tmpdir / f"chunk_{i}.txt"
        cf.write_text("\n".join(entry_lines[start:end]), encoding="utf-8")
        chunks.append((i, start, end, cf))
    workers = len(chunks)

    t0 = time.perf_counter()

    def run_chunk(ci, start, end, cf):
        proc = subprocess.run(
            [SIM_EXE, args.model],
            input=cf.read_text(encoding="utf-8"),
            capture_output=True, text=True, encoding="utf-8", timeout=43200)
        if proc.returncode != 0:
            raise RuntimeError(f"chunk {ci}: {proc.stderr[-200:]}")
        lines = [l.strip() for l in proc.stdout.strip().split("\n") if l.strip().startswith("[")]
        return ci, start, lines

    results_by_chunk = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(run_chunk, *c): c[0] for c in chunks}
        for future in concurrent.futures.as_completed(futures):
            ci, start, lines = future.result()
            results_by_chunk[ci] = (start, lines)
            print(f"  [{len(results_by_chunk)}/{workers}] chunk {ci} ({len(lines)} 条)")

    # Merge
    merged = []
    for ci in sorted(results_by_chunk):
        _, lines = results_by_chunk[ci]
        merged.extend(lines)
    shutil.rmtree(tmpdir, ignore_errors=True)

    t1 = time.perf_counter()
    print(f"LLM 完成: {len(merged)} 条, 耗时 {t1-t0:.0f}s")

    # Parse back to per-dict results
    llm_results = {name: {} for name in dict_names}
    for (di, wi, ctx, cands), line in zip(entries, merged):
        name = dict_names[di]
        try:
            llm_results[name][wi] = json.loads(line)
        except:
            pass

    return llm_results

# ═══════════════════════════════════════════
# 5. COMPUTE STATS
# ═══════════════════════════════════════════
def compute_stats(words, dicts_info, llm_results, pre_stats):
    """返回每个词库的详细指标"""
    dict_names = [d[0] for d in dicts_info]
    results = []

    for di, (name, _, _) in enumerate(dicts_info):
        ps = pre_stats[name]
        total = ps["total"]
        in_dict = ps["in_dict"]
        missing = ps["missing"]
        single = ps["single"]
        multi = ps["multi"]

        # Dict first-choice: single_cand are auto-correct, + rd==1 from multi
        dc = single  # all single-cand are correct by definition
        dw = 0
        llm_ok = single
        llm_bad = 0
        fixed = 0
        broken = 0

        lr = llm_results.get(name, {})

        for wi, w in enumerate(words):
            d = w["dicts"].get(name)
            if not d or len(d["cands"]) <= 1:
                continue  # already counted in single/llm_ok
            rd = d["rd"]
            if rd == 1:
                dc += 1
            else:
                dw += 1

            ranked = lr.get(wi)
            if ranked:
                if ranked[0] == w["w"]:
                    llm_ok += 1
                    if rd != 1:
                        fixed += 1
                else:
                    llm_bad += 1
                    if rd == 1:
                        broken += 1

        results.append({
            "name": name,
            "total_words": total,
            "missing": missing, "missing_pct": missing / max(1, total) * 100,
            "in_dict": in_dict,
            "single_cand": single, "single_pct": single / max(1, in_dict) * 100,
            "multi_cand": multi,
            "dict_first": dc,
            "dict_wrong": dw,
            "dict_rate": dw / max(1, in_dict) * 100,
            "llm_first": llm_ok,
            "llm_wrong": llm_bad,
            "llm_rate": llm_bad / max(1, in_dict) * 100,
            "llm_fixed": fixed, "llm_broken": broken,
            "improvement": (dw - llm_bad) / max(1, dw) * 100 if dw > 0 else 0,
        })

    return results

# ═══════════════════════════════════════════
# 6. COMPARE (main)
# ═══════════════════════════════════════════
if args.compare or args.text:
    if not args.dict:
        print("错误: 请至少指定一个 --dict")
        sys.exit(1)

    # Align names
    dict_paths = args.dict
    dict_names = args.name if args.name else [Path(p).stem for p in dict_paths]
    if len(dict_names) < len(dict_paths):
        dict_names += [Path(p).stem for p in dict_paths[len(dict_names):]]

    # Load dicts
    print(f"加载 {len(dict_paths)} 个词库...")
    dicts_info = []
    for path, name in zip(dict_paths, dict_names):
        w2c, c2w = load_dict(path)
        dicts_info.append((name, w2c, c2w))
        print(f"  {name}: {len(w2c):,} 词 {len(c2w):,} 编码")

    if args.text:
        # Single text mode
        import hanlp
        tok = hanlp.load(hanlp.pretrained.tok.COARSE_ELECTRA_SMALL_ZH)
        def is_cjk(ch): return '一' <= ch <= '鿿'
        def segment(text):
            words = tok(text)
            result = []
            for w in words:
                parts, buf, in_cjk = [], [], None
                for ch in w:
                    cjk = '一' <= ch <= '鿿'
                    if in_cjk is not None and cjk != in_cjk:
                        parts.append(''.join(buf)); buf = []
                    in_cjk = cjk; buf.append(ch)
                if buf: parts.append(''.join(buf))
                result.extend(parts)
            return [w for w in result if w]
        sent_words_list = [segment(args.text)]
    else:
        # Batch mode: use segment cache
        N = args.n
        seg_cache = DATA_DIR / f"segments_{N}.jsonl"
        if not seg_cache.exists():
            print(f"错误: 分段缓存不存在，先运行 --segment")
            print(f"  缺少: {seg_cache}")
            sys.exit(1)
        print(f"读取分段缓存: {seg_cache.name}")
        sent_words_list = []
        with open(seg_cache, encoding="utf-8") as f:
            for line in f:
                sent_words_list.append(json.loads(line.strip()))
        print(f"  {len(sent_words_list)} 句")

    # ── 词抽样：从所有分句中提取多字词，随机抽样 N 个 ──
    print("提取多字词...", end=" ", flush=True)
    all_words = []  # [{w, ctx}, ...]
    for sent_words in sent_words_list:
        ctx = []
        for w in sent_words:
            if len(w) >= 2:
                all_words.append({"w": w, "ctx": "".join(ctx)})
            ctx.append(w)
    total_available = len(all_words)
    print(f"共 {total_available} 个")

    sample_n = min(args.sample_words, total_available)
    random.seed(SEED)
    sampled_words = random.sample(all_words, sample_n)
    print(f"随机抽样: {sample_n} 个词")
    # 重建为 sent_words 兼容格式（每个词独立一行）
    sampled_sents = [[sw["w"]] for sw in sampled_words]
    # 修正：需要保留 ctx 信息，用特殊方式传给 build_word_table
    # 简化：直接构建 words 列表
    words = []
    for sw in sampled_words:
        entry = {"w": sw["w"], "ctx": sw["ctx"], "dicts": {}}
        for name, w2c, c2w in dicts_info:
            codes = w2c.get(sw["w"], [])
            if not codes:
                entry["dicts"][name] = None
                continue
            code = codes[0]
            cands = list(c2w[code].keys())[:5]
            if len(cands) <= 1:
                entry["dicts"][name] = {"cands": cands, "rd": 1}
            else:
                rd = cands.index(sw["w"]) + 1 if sw["w"] in cands else "?"
                entry["dicts"][name] = {"cands": cands, "rd": rd}
        words.append(entry)

    # 预统计
    pre_stats = {}
    for name, _, _ in dicts_info:
        missing = sum(1 for w in words if w["dicts"].get(name) is None)
        in_dict = sample_n - missing
        single = sum(1 for w in words if w["dicts"].get(name) and len(w["dicts"][name]["cands"]) <= 1)
        multi = in_dict - single
        pre_stats[name] = {"total": sample_n, "missing": missing, "in_dict": in_dict,
                           "single": single, "multi": multi}
    total_multi_char = sample_n
    print(f"样本: {sample_n} 词\n")
    # 显示预统计
    print(f"{'词库':<12} {'抽样':<8} {'在库':<8} {'缺失':<8} {'缺失率':<8} {'独一':<8} {'多候选':<8}")
    print("-" * 68)
    for name, _, _ in dicts_info:
        ps = pre_stats[name]
        print(f"{name:<12} {ps['total']:<8} {ps['in_dict']:<8} {ps['missing']:<8} "
              f"{ps['missing']/max(1,ps['total'])*100:<7.1f}% "
              f"{ps['single']:<8} {ps['multi']:<8}")

    # Run LLM
    llm_results = run_llm_unified(words, dicts_info)

    # Compute stats
    results = compute_stats(words, dicts_info, llm_results, pre_stats)

    # Output
    print(f"\n{'='*80}")
    print(f"首选率对比 (生产配置: 上文10token, 最多5候选)")
    print(f"{'='*80}")
    print(f"{'词库':<12} {'总词':<6} {'缺失率':<8} {'字典首选':<10} {'字典选重率':<10} {'LLM首选':<10} {'LLM选重率':<10} {'改善':<8} {'修正':<6} {'改错':<6}")
    print("-" * 90)
    for r in results:
        print(f"{r['name']:<12} {r['total_words']:<6} {r['missing_pct']:<7.1f}% "
              f"{r['dict_first']}/{r['in_dict']:<6} {r['dict_rate']:<9.1f}% "
              f"{r['llm_first']}/{r['in_dict']:<6} {r['llm_rate']:<9.1f}% "
              f"{r['improvement']:<7.0f}% {r['llm_fixed']:<6} {r['llm_broken']:<6}")

    # Save
    out = {
        "config": {"max_tokens": 10, "max_candidates": 5, "model": args.model,
                    "n_samples": len(sent_words_list)},
        "results": results
    }
    out_file = DATA_DIR / "comparison_results.json"
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"\n结果已保存: {out_file}")

else:
    parser.print_help()
