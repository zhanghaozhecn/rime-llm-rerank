#!/usr/bin/env python3
"""
批量评测：字典序 vs LLM 重排（多模型对比）
从 wiki 语料抽样 N 句 → HanLP 分词 → 字典查码 → sim_rerank 评分 → 统计

用法:
  # --prepare 生成测试数据（采样+分词+字典查码）→ --run 单模型 → --compare 多模型对比
  python eval/batch_rerank.py --prepare
  python eval/batch_rerank.py --run "模型路径"
  python eval/batch_rerank.py --compare
"""
import argparse, json, subprocess, sys, os, random, time
from pathlib import Path
from collections import defaultdict, OrderedDict

ROOT      = Path(__file__).resolve().parent   # eval/
PROJ      = ROOT.parent                        # 项目根
DICT_PATH = PROJ / "pdsp_dict.yaml"   # 词库拷贝（--dict 覆盖）
SIM_EXE   = PROJ / "cpp/build_sim/Release/sim_rerank.exe"
# 本机/跨项目资源：环境变量可覆盖（见 CLAUDE.md）
CORPUS    = Path(os.environ.get("RIME_LLM_CORPUS",
              "D:/OneDrive/typing/bert_seg/data/sentences_filtered.txt"))
DATA_DIR  = Path(os.environ.get("RIME_LLM_DATA_DIR",
              "D:/OneDrive/typing/bert_seg/data/batch_eval"))
N_SAMPLES = 10000
SEED      = 42

# ── CLI ──
parser = argparse.ArgumentParser(description="批量评测 字典序 vs LLM 重排")
parser.add_argument("--prepare", action="store_true", help="生成测试数据（采样+分词+字典查码）")
parser.add_argument("--run", metavar="MODEL_PATH", help="单模型评测")
parser.add_argument("--compare", action="store_true", help="对比所有已跑模型")
parser.add_argument("--dict", help="自定义词库路径（默认拼读双拼）")
parser.add_argument("--n", type=int, default=N_SAMPLES, help=f"样本数 (默认 {N_SAMPLES})")
parser.add_argument("--workers", type=int, default=8, help="并行 worker 数 (默认 8)")
parser.add_argument("--min-len", type=int, default=20, help="最短句子长度")
parser.add_argument("--max-len", type=int, default=200, help="最长句子长度")
args = parser.parse_args()

if args.dict:
    DICT_PATH = Path(args.dict)
DICT_SLUG = Path(DICT_PATH).stem  # e.g. "pdsp", "zrlong", "wubi86_jidian"
is_custom_dict = bool(args.dict)

# ═══════════════════════════════════════════
# 1. PREPARE: 采样 + 分词 + 字典查码
# ═══════════════════════════════════════════
if args.prepare:
    N = args.n
    print(f"[1/4] 加载字典...", end=" ", flush=True)
    word_to_codes = defaultdict(list); code_to_words = defaultdict(OrderedDict)
    with open(DICT_PATH, encoding="utf-8") as f:
        in_body = False
        for line in f:
            line = line.rstrip("\n\r")
            if line == "...": in_body = True; continue
            if not in_body or not line or line.startswith("#"): continue
            parts = line.split("\t")
            if len(parts) < 2: continue
            w, c = parts[0], parts[1]
            if len(w) < 2 or len(c) != 4: continue
            word_to_codes[w].append(c)
            if w not in code_to_words[c]:
                code_to_words[c][w] = len(code_to_words[c])
    print(f"{len(word_to_codes):,} 词 {len(code_to_words):,} 编码")

    print(f"[2/4] 采样 {N} 句 (长度 {args.min_len}-{args.max_len})...", end=" ", flush=True)
    random.seed(SEED)
    all_sents = []
    with open(CORPUS, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if args.min_len <= len(s) <= args.max_len:
                all_sents.append(s)
    print(f"语料池 {len(all_sents):,} 句")

    if len(all_sents) < N:
        print(f"警告: 语料池不足 {N} 句，使用全部 {len(all_sents)} 句")
        sampled = all_sents
    else:
        sampled = random.sample(all_sents, N)

    # ── 分段缓存：只做一次 HanLP，跨词库复用 ──
    seg_cache = DATA_DIR / f"segments_{N}.jsonl"
    if seg_cache.exists():
        print(f"[3/4] 读取分段缓存 ({seg_cache.name})...", end=" ", flush=True)
        sent_words = []
        with open(seg_cache, encoding="utf-8") as f:
            for line in f:
                sent_words.append(json.loads(line.strip()))
        print(f"{len(sent_words)} 句")
    else:
        print(f"[3/4] HanLP 分词 ({len(sampled)} 句)...", flush=True)
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

        sent_words = []
        for si, sent in enumerate(sampled):
            words = segment(sent)
            sent_words.append(words)
            if (si + 1) % 1000 == 0:
                print(f"  {si+1}/{len(sampled)} 句")

        # 保存缓存
        with open(seg_cache, "w", encoding="utf-8") as f:
            for words in sent_words:
                f.write(json.dumps(words, ensure_ascii=False) + "\n")
        print(f"  分段缓存已保存: {seg_cache.name}")

    # ── 字典查码 ──
    print(f"[3.5/4] 字典查码 [{DICT_SLUG}]...", end=" ", flush=True)
    results = []  # list of (sentence_str, [multi_cand_entries])
    total_words = 0; total_in_dict = 0; total_multi = 0; total_single = 0

    for words in sent_words:
        sent = "".join(words)
        entries = []
        ctx = []
        for w in words:
            if len(w) < 2: ctx.append(w); continue
            codes = word_to_codes.get(w, [])
            total_words += 1
            if not codes:
                ctx.append(w); continue
            total_in_dict += 1
            code = codes[0]
            cands = list(code_to_words[code].keys())[:5]  # 生产配置：最多5候选
            if len(cands) > 1:
                rd = cands.index(w)+1 if w in cands else "?"
                entries.append({"w": w, "code": code, "cands": cands,
                                "rd": rd, "ctx": "".join(ctx)})
                total_multi += 1
            else:
                total_single += 1
            ctx.append(w)
        if entries:
            results.append((sent, entries))
    print(f"{total_multi} 条多候选")

    DATA_DIR.mkdir(parents=True, exist_ok=True)

    # Save test data: one JSON per multi-cand entry (sim_rerank format)
    test_file = DATA_DIR / f"test_{N}_{DICT_SLUG}.jsonl"
    sim_file  = DATA_DIR / f"sim_input_{N}_{DICT_SLUG}.txt"
    meta_file = DATA_DIR / f"meta_{N}_{DICT_SLUG}.json"

    with open(test_file, "w", encoding="utf-8") as f:
        for sent, entries in results:
            for e in entries:
                f.write(json.dumps({"sentence": sent, **e}, ensure_ascii=False) + "\n")

    with open(sim_file, "w", encoding="utf-8") as f:
        for _, entries in results:
            for e in entries:
                f.write(json.dumps({"context": e["ctx"], "cands": e["cands"]}, ensure_ascii=False) + "\n")

    meta = {"n_samples": len(sampled), "n_sentences_with_multi": len(results),
            "total_words": total_words, "in_dict": total_in_dict,
            "single_cand": total_single, "multi_cand": total_multi}
    with open(meta_file, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

    print(f"\n[4/4] 保存完成:")
    print(f"  句子: {len(sampled)} → 含多候选的句子: {len(results)}")
    print(f"  分词: {total_words} 词 (在词库: {total_in_dict})")
    print(f"  独一候选: {total_single}, 多候选: {total_multi}")
    print(f"  测试数据: {test_file}")
    print(f"  sim 输入: {sim_file}")
    print(f"  元数据:   {meta_file}")

# ═══════════════════════════════════════════
# 2. RUN: 单模型评测（并行分块）
# ═══════════════════════════════════════════
elif args.run:
    import concurrent.futures
    import tempfile
    import shutil

    model_path = args.run
    model_name = Path(model_path).stem
    N = args.n
    workers = args.workers
    sim_file = DATA_DIR / f"sim_input_{N}_{DICT_SLUG}.txt"
    test_file = DATA_DIR / f"test_{N}_{DICT_SLUG}.jsonl"
    meta_file = DATA_DIR / f"meta_{N}_{DICT_SLUG}.json"

    if not sim_file.exists():
        print(f"错误: 测试数据不存在，先运行 --prepare --dict <词库路径>")
        print(f"  缺少: {sim_file}")
        sys.exit(1)

    with open(meta_file, encoding="utf-8") as f:
        meta = json.load(f)
    total_multi = meta["multi_cand"]
    print(f"模型: {model_name}")
    print(f"测试数据: {meta['n_samples']} 句, {total_multi} 条多候选")
    print(f"字典序首选率: {meta['single_cand']}/{meta['in_dict']} = {meta['single_cand']/max(1,meta['in_dict'])*100:.1f}%")
    print(f"并行 worker: {workers}")

    # Load test entries
    print(f"加载测试数据...", end=" ", flush=True)
    test_entries = []
    with open(test_file, encoding="utf-8") as f:
        for line in f:
            test_entries.append(json.loads(line.strip()))
    total = len(test_entries)
    print(f"{total} 条")

    # Split into chunks
    chunk_size = (total + workers - 1) // workers
    chunks = []
    for i in range(workers):
        start = i * chunk_size
        end = min(start + chunk_size, total)
        if start >= total: break
        chunks.append((start, end))
    workers = len(chunks)
    print(f"分 {workers} 块, 每块 ~{chunk_size} 条")

    # Write chunk files
    tmpdir = Path(tempfile.mkdtemp(prefix="batch_rerank_"))
    chunk_files = []
    for ci, (start, end) in enumerate(chunks):
        cf = tmpdir / f"chunk_{ci}.txt"
        with open(cf, "w", encoding="utf-8") as f:
            for entry in test_entries[start:end]:
                f.write(json.dumps({"context": entry["ctx"], "cands": entry["cands"]}, ensure_ascii=False) + "\n")
        chunk_files.append((ci, start, end, cf))

    def run_chunk(ci, start, end, cf):
        """Run sim_rerank on one chunk, return (ci, start, lines)"""
        payload = cf.read_text(encoding="utf-8")
        proc = subprocess.run([SIM_EXE, model_path], input=payload,
                              capture_output=True, text=True, encoding="utf-8", timeout=43200)
        if proc.returncode != 0:
            raise RuntimeError(f"chunk {ci} failed: {proc.stderr[-200:]}")
        lines = [l.strip() for l in proc.stdout.strip().split("\n") if l.strip().startswith("[")]
        return ci, start, lines

    print(f"LLM 重排中 ({workers} 并行)...", flush=True)
    t0 = time.perf_counter()

    # Collect results in order
    results_by_chunk = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(run_chunk, ci, start, end, cf): ci
                   for ci, start, end, cf in chunk_files}
        for future in concurrent.futures.as_completed(futures):
            ci, start, lines = future.result()
            results_by_chunk[ci] = (start, lines)
            n_done = len(results_by_chunk)
            print(f"  [{n_done}/{workers}] chunk {ci} 完成 ({len(lines)} 条)")

    t1 = time.perf_counter()
    wall_time = t1 - t0

    # Merge results in order
    merged = []
    for ci in sorted(results_by_chunk):
        start, lines = results_by_chunk[ci]
        merged.extend(lines)
    print(f"合并: {len(merged)} 条, 耗时 {wall_time:.0f}s")

    # Cleanup temp files
    shutil.rmtree(tmpdir, ignore_errors=True)

    if len(merged) != total:
        print(f"警告: 输出 {len(merged)} ≠ 输入 {total}, 对齐到较短长度")
        n = min(len(merged), total)
        merged = merged[:n]; test_entries = test_entries[:n]

    # Parse LLM results
    for entry, line in zip(test_entries, merged):
        try: entry["llm_ranked"] = json.loads(line)
        except: pass

    # Compute stats
    dc = sum(1 for e in test_entries if e.get("rd") == 1)
    dw = sum(1 for e in test_entries if e.get("rd") != 1)
    total_eval = len(test_entries)
    llm_ok = sum(1 for e in test_entries if e.get("llm_ranked") and e["llm_ranked"][0] == e["w"])
    llm_bad = sum(1 for e in test_entries if e.get("llm_ranked") and e["llm_ranked"][0] != e["w"])
    fixed  = [e for e in test_entries if e.get("rd") != 1 and e.get("llm_ranked") and e["llm_ranked"][0] == e["w"]]
    broken = [e for e in test_entries if e.get("rd") == 1 and e.get("llm_ranked") and e["llm_ranked"][0] != e["w"]]

    # Save result
    result = {
        "model": model_name, "model_path": model_path,
        "total": total_eval, "dict_correct": dc, "dict_wrong": dw,
        "dict_rate": dw / max(1, total_eval) * 100,
        "llm_correct": llm_ok, "llm_wrong": llm_bad,
        "llm_rate": llm_bad / max(1, total_eval) * 100,
        "llm_fixed": len(fixed), "llm_broken": len(broken),
        "improvement": (dw - llm_bad) / max(1, dw) * 100,
        "wall_time_s": wall_time, "workers": workers,
    }

    result_file = DATA_DIR / f"result_{model_name}_{DICT_SLUG}.json"
    with open(result_file, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    dict_rate = meta['in_dict'] - meta['single_cand']
    single_rate = meta['single_cand'] / max(1, meta['in_dict']) * 100
    print(f"\n{'='*60}")
    print(f"  字典序: {single_rate:.1f}% 首选 ({meta['single_cand']}/{meta['in_dict']})")
    print(f"          {dict_rate/max(1,meta['in_dict'])*100:.1f}% 需选重 ({dict_rate} 条)")
    print(f"  LLM:    {llm_ok}/{total_eval} 首选 = {llm_bad/max(1,total_eval)*100:.1f}% 选重率")
    print(f"  修正={len(fixed)} 改错={len(broken)} 改善={result['improvement']:.0f}%")
    print(f"  Wall time: {wall_time:.0f}s ({workers} 并行)")
    print(f"  结果: {result_file}")

# ═══════════════════════════════════════════
# 3. COMPARE: 多模型对比
# ═══════════════════════════════════════════
elif args.compare:
    N = args.n
    result_files = sorted(DATA_DIR.glob("result_*.json"))
    if not result_files:
        print("错误: 没有找到结果文件，先运行 --run")
        sys.exit(1)

    # 与 --prepare 的文件名一致（meta_{N}_{DICT_SLUG}.json）
    meta_file = DATA_DIR / f"meta_{N}_{DICT_SLUG}.json"
    if meta_file.exists():
        with open(meta_file, encoding="utf-8") as f:
            meta = json.load(f)
        print(f"测试集: {meta['n_samples']} 句 wiki 语料, {meta['multi_cand']} 条多候选")
        dict_rate = (meta['in_dict'] - meta['single_cand']) / max(1, meta['in_dict']) * 100
        print(f"字典序选重率: {dict_rate:.1f}%")
    print()

    models = []
    for rf in result_files:
        with open(rf, encoding="utf-8") as f:
            models.append(json.load(f))

    # Header
    print(f"{'模型':<35} {'参数':<8} {'量化':<8} {'加载ms':<8} {'延迟ms':<8} {'字典率':<8} {'LLM率':<8} {'改善':<8} {'修正':<6} {'改错':<6}")
    print("-" * 110)
    for m in sorted(models, key=lambda x: x["llm_rate"]):
        name = m["model"]
        # Try to extract params and quant from name
        params = "?"; quant = "?"
        import re
        pm = re.search(r'(\d+\.?\d*)B', name)
        if pm: params = pm.group(0)
        qm = re.search(r'(Q\d_[KMO]\d?)', name)
        if qm: quant = qm.group(1)
        print(f"{name:<35} {params:<8} {quant:<8} {m.get('load_ms','?'):<8} "
              f"{m.get('avg_latency_ms','?'):<8} "
              f"{m['dict_rate']:<8.1f}% {m['llm_rate']:<8.1f}% "
              f"{m['improvement']:<7.0f}% {m['llm_fixed']:<6} {m['llm_broken']:<6}")

else:
    parser.print_help()
