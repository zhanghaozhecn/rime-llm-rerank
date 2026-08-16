#!/usr/bin/env python3
"""
词典 vs LLM 首选率对比（多方案，打包候选，生产配置）

策略：同词跨方案合并候选集 → LLM 一次评分 → 各方案分别统计

用法:
  python eval_prefer.py --dict 拼读双拼.txt --dict 小鹤双拼.txt --dict 五笔.txt
"""
import argparse, json, subprocess, sys, time, random, re
from pathlib import Path
from collections import defaultdict, OrderedDict
import tempfile, shutil, concurrent.futures

DIR = Path(__file__).resolve().parent
SIM_EXE = DIR / "cpp/build_sim/Release/sim_rerank.exe"
MODEL   = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
SEG_CACHE = Path("D:/OneDrive/typing/bert_seg/data/batch_eval/segments_10000.jsonl")
SEED   = 42; MAX_CAND = 5

parser = argparse.ArgumentParser(description="多方案词典 vs LLM 首选率对比")
parser.add_argument("--dict", action="append", default=[])
parser.add_argument("--name", action="append", default=[])
parser.add_argument("--n", type=int, default=20000)
parser.add_argument("--workers", type=int, default=2)
args = parser.parse_args()
if not args.dict: parser.print_help(); sys.exit(1)

names = args.name or [Path(p).stem for p in args.dict]
while len(names) < len(args.dict): names.append(Path(args.dict[len(names)]).stem)

# ═══════════════════════════════════════════
# 1. 加载编码表
# ═══════════════════════════════════════════
print("加载编码表...")
dicts_info = []  # [(name, word→code, code→[words])]
for path, name in zip(args.dict, names):
    w2c = {}; c2w = defaultdict(OrderedDict)
    fp = Path(path) if Path(path).is_absolute() else DIR / path
    with open(fp, encoding="utf-8") as f:
        for line in f:
            parts = line.strip().split("\t")
            if len(parts) < 2: continue
            w, c = parts[0], parts[1]
            if w in w2c: continue
            w2c[w] = c
            if w not in c2w[c]: c2w[c][w] = len(c2w[c])
    dicts_info.append((name, w2c, c2w))
    multi = sum(1 for c, ws in c2w.items() if len(ws) > 1)
    print(f"  {name}: {len(w2c):,} 词, {len(c2w):,} 编码, {multi} 重码")

# ═══════════════════════════════════════════
# 2. 抽样词
# ═══════════════════════════════════════════
print(f"\n读取分段缓存...")
sent_words = []
with open(SEG_CACHE, encoding="utf-8") as f:
    for line in f: sent_words.append(json.loads(line.strip()))

all_entries = []
for words in sent_words:
    ctx = []  # Note: ctx variable shadows outer scope? No, it's local
    for w in words:
        if len(w) >= 2: all_entries.append({"w": w, "ctx": "".join(ctx)})
        ctx.append(w)

random.seed(SEED)
sampled = random.sample(all_entries, min(args.n, len(all_entries)))
print(f"  抽样: {len(sampled):,} / {len(all_entries):,}")

# ═══════════════════════════════════════════
# 3. 查码 + 打包合并候选
# ═══════════════════════════════════════════
print(f"查码 + 打包候选...", end=" ", flush=True)
pre_stats = {}
for name, _, _ in dicts_info:
    pre_stats[name] = {"total": len(sampled), "missing": 0, "in_dict": 0,
                        "single": 0, "multi": 0}

llm_input = []   # [(word_idx, ctx, union_cands)]  — 每个词最多一条
word_meta = []   # [{w, ctx, dict_results: {name: {cands, rd}}}]

for wi, sw in enumerate(sampled):
    entry = {"w": sw["w"], "ctx": sw["ctx"], "dicts": {}}
    union = set()
    for di, (name, w2c, c2w) in enumerate(dicts_info):
        ps = pre_stats[name]
        code = w2c.get(sw["w"])
        if not code:
            ps["missing"] += 1; entry["dicts"][name] = None; continue
        ps["in_dict"] += 1
        cands = list(c2w[code].keys())[:MAX_CAND]
        if len(cands) <= 1:
            ps["single"] += 1
            entry["dicts"][name] = {"cands": cands, "rd": 1}
        else:
            ps["multi"] += 1
            rd = cands.index(sw["w"]) + 1 if sw["w"] in cands else "?"
            entry["dicts"][name] = {"cands": cands, "rd": rd}
            union.update(cands)
    word_meta.append(entry)
    # 任一方有多候选则送 LLM
    if union:
        # dict.fromkeys 保持插入序 (set 顺序受 PYTHONHASHSEED 影响不可复现)
        union_list = list(dict.fromkeys(union))[:MAX_CAND]  # 最多 5 候选
        llm_input.append((wi, sw["ctx"], union_list))

print(f"{len(llm_input)} 条 LLM 输入\n")
print(f"{'方案':<10} {'抽样':<8} {'在库':<8} {'缺失':<8} {'独一':<8} {'需LLM':<8}")
for name, _, _ in dicts_info:
    ps = pre_stats[name]
    print(f"{name:<10} {ps['total']:<8} {ps['in_dict']:<8} {ps['missing']:<8} "
          f"{ps['single']:<8} {ps['multi']:<8}")

# ═══════════════════════════════════════════
# 4. LLM 重排
# ═══════════════════════════════════════════
print(f"\nLLM 重排: {len(llm_input)} 条...", flush=True)
payload = "\n".join(json.dumps({"context": ctx, "cands": cands}, ensure_ascii=False)
                     for _, ctx, cands in llm_input)

tmpdir = Path(tempfile.mkdtemp(prefix="eval_prefer_"))
workers = args.workers
lines_in = payload.split("\n")
chunk_size = (len(llm_input) + workers - 1) // workers
chunks = []
for ci in range(workers):
    s = ci * chunk_size; e = min(s + chunk_size, len(llm_input))
    if s >= len(llm_input): break
    cf = tmpdir / f"chunk_{ci}.txt"
    cf.write_text("\n".join(lines_in[s:e]), encoding="utf-8")
    chunks.append((ci, s, e, cf))

t0 = time.perf_counter()
results_by_chunk = {}
def run_chunk(ci, s, e, cf):
    proc = subprocess.run([SIM_EXE, MODEL], input=cf.read_text(encoding="utf-8"),
                          capture_output=True, text=True, encoding="utf-8", timeout=43200)
    if proc.returncode != 0: raise RuntimeError(f"chunk {ci}: {proc.stderr[-200:]}")
    lines = [l.strip() for l in proc.stdout.strip().split("\n") if l.strip().startswith("[")]
    return ci, s, lines

with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
    futures = {pool.submit(run_chunk, *c): c[0] for c in chunks}
    for future in concurrent.futures.as_completed(futures):
        ci, s, lines = future.result()
        results_by_chunk[ci] = (s, lines)
        print(f"  [{len(results_by_chunk)}/{workers}] chunk {ci} ({len(lines)} 条)")

merged = []
for ci in sorted(results_by_chunk): _, lines = results_by_chunk[ci]; merged.extend(lines)
shutil.rmtree(tmpdir, ignore_errors=True)
t1 = time.perf_counter()
print(f"LLM 完成: {len(merged)} 条, 耗时 {t1-t0:.0f}s")

# ── 分配 LLM 结果到各方案 ──
llm_ranked = {}  # word_idx → ranked list
for (wi, ctx, union_cands), line in zip(llm_input, merged):
    try: llm_ranked[wi] = json.loads(line)
    except: pass

# ═══════════════════════════════════════════
# 5. 统计
# ═══════════════════════════════════════════
print(f"\n{'='*80}")
print(f"首选率对比 (生产配置: 上文10token, 最多{MAX_CAND}候选)")
print(f"{'='*80}")
print(f"{'方案':<10} {'总词':<6} {'缺失率':<8} {'字典首选':<10} {'字典选重':<10} {'LLM首选':<10} {'LLM选重':<10} {'改善':<8} {'修正':<6} {'改错':<6}")
print("-" * 92)

for di, (name, _, _) in enumerate(dicts_info):
    ps = pre_stats[name]; in_dict = ps["in_dict"]; single = ps["single"]
    dc = single; dw = 0; llm_ok = single; llm_bad = 0; fixed = 0; broken = 0

    for wi, w in enumerate(word_meta):
        d = w["dicts"].get(name)
        if not d or len(d["cands"]) <= 1: continue
        rd = d["rd"]
        if rd == 1: dc += 1
        else: dw += 1

        ranked = llm_ranked.get(wi)
        if ranked:
            # 在该方案的候选子集中，LLM 排名最高的
            cand_set = set(d["cands"])
            best = next((c for c in ranked if c in cand_set), None)
            if best == w["w"]:
                llm_ok += 1
                if rd != 1: fixed += 1
            elif best:
                llm_bad += 1
                if rd == 1: broken += 1

    dict_rate = dw / max(1, in_dict) * 100
    llm_rate = llm_bad / max(1, in_dict) * 100
    imp = (dw - llm_bad) / max(1, dw) * 100 if dw > 0 else 0
    miss = ps["missing"] / max(1, ps["total"]) * 100

    print(f"{name:<10} {ps['total']:<6} {miss:<7.1f}% "
          f"{dc}/{in_dict:<6} {dict_rate:<9.1f}% "
          f"{llm_ok}/{in_dict:<6} {llm_rate:<9.1f}% "
          f"{imp:<7.0f}% {fixed:<6} {broken:<6}")
