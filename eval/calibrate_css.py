#!/usr/bin/env python3
"""
CSS 校准: 分段→抽样→LLM推理→拟合校准曲线
"""
import sys, os, random, json, subprocess as sp
from pathlib import Path
from collections import defaultdict
import numpy as np

ROOT = Path(__file__).resolve().parent   # eval/
PROJ = ROOT.parent                        # 项目根
# 本机/跨项目资源：环境变量可覆盖（见 CLAUDE.md）
TOOLCHAIN = Path(os.environ.get("RIME_LLM_TOOLCHAIN", "D:/OneDrive/typing/处理脚本"))
sys.path.insert(0, str(TOOLCHAIN))
from eval_css import *

# ── Config ──
SENTENCES = Path(os.environ.get("RIME_LLM_SENTENCES",
              r"D:\分词注音工程\分读音词频统计\data\sentences_clean_1pct.txt"))
N_SAMPLE = 10_000   # 采样句数
N_WORDS  = 5_000
DICT_PATH = TOOLCHAIN / "输出码表" / "拼读双拼.txt"
SIM_EXE   = PROJ / "cpp/build_sim/Release/sim_rerank.exe"
VENV_PY   = os.environ.get("RIME_LLM_VENV_PY",
              "D:/OneDrive/typing/bert_seg/.venv/Scripts/python.exe")

# ═══════════════════ 1. 分词 ═══════════════════

def segment(lines):
    print("分词 (HanLP)...", end=" ", flush=True)
    text = "".join(lines)
    result = sp.run(
        [VENV_PY, "-c", f"""
import hanlp, json
tok = hanlp.load(hanlp.pretrained.tok.COARSE_ELECTRA_SMALL_ZH)
words = tok(json.loads(open(0).read()))
out = []
for w in words:
    parts, buf, in_cjk = [], [], None
    for ch in w:
        cjk = '一' <= ch <= '鿿'
        if in_cjk is not None and cjk != in_cjk:
            parts.append(''.join(buf)); buf = []
        in_cjk = cjk; buf.append(ch)
    if buf: parts.append(''.join(buf))
    out.extend(parts)
print(json.dumps(out, ensure_ascii=False))
"""],
        input=json.dumps(text, ensure_ascii=False),
        capture_output=True, text=True, timeout=300,
        env={**os.environ, "HF_ENDPOINT": "https://hf-mirror.com"}
    )
    for line in result.stdout.strip().split("\n"):
        try:
            words = json.loads(line)
            if isinstance(words, list) and len(words) > 10:
                print(f"{len(words)} 词")
                return words
        except: pass
    print("分词失败")
    return []

# ═══════════════════ 2. 编码+CSS ═══════════════════

def build_candidate_pool(seg_words, word_to_code, css_scores, freq):
    """从分词结果中提取多候选词，附带 CSS + 频率"""
    pool = []
    ctx = []
    for w in seg_words:
        if len(w) == 2 and w in word_to_code:
            code = word_to_code[w]
            if code in css_scores and css_scores[code]["n_cands"] > 1:
                pool.append({
                    "word": w,
                    "code": code,
                    "css": css_scores[code]["max_cos"],
                    "n_cands": css_scores[code]["n_cands"],
                    "freq": freq.get(w, 999999),
                    "ctx": "".join(ctx[-5:])
                })
        ctx.append(w)
    return pool

# ═══════════════════ 3. LLM 推理 ═══════════════════

def run_llm(pool, code_to_words):
    """对抽样词跑 LLM 推理，返回 [(word, css, dict_ok, llm_ok)]"""
    random.shuffle(pool)
    sample = pool[:N_WORDS]

    payloads = []
    for item in sample:
        cands = list(code_to_words.get(item["code"], {}).keys())[:5]
        if item["word"] not in cands:
            cands.append(item["word"])
        payloads.append(json.dumps({"context": item["ctx"], "cands": cands}, ensure_ascii=False))

    print(f"LLM 推理 ({len(sample)} 条)...", end=" ", flush=True)
    payload = "\n".join(payloads)
    proc = sp.run([SIM_EXE], input=payload, capture_output=True, text=True, encoding="utf-8", timeout=600)

    results = []
    for item, line in zip(sample, proc.stdout.strip().split("\n")):
        line = line.strip()
        if not line.startswith("["): continue
        try: ranked = json.loads(line)
        except: continue
        cands = list(code_to_words.get(item["code"], {}).keys())[:5]
        if item["word"] not in cands: cands.append(item["word"])
        dict_ok = (len(cands) > 0 and item["word"] == cands[0])
        try: llm_ok = (ranked.index(item["word"]) == 0)
        except: llm_ok = False
        results.append((item["word"], item["code"], item["css"], dict_ok, llm_ok))

    return results

# ═══════════════════ 4. 校准 ═══════════════════

def calibrate(results):
    buckets = [(0.0,0.3),(0.3,0.5),(0.5,0.65),(0.65,0.8),(0.8,0.9),(0.9,1.0)]
    print(f"\n{'CSS区间':<14} {'样本':<8} {'字典选重%':<12} {'LLM选重%':<12} {'改善%':<10}")
    print("-"*58)
    cal = []
    for lo, hi in buckets:
        items = [r for r in results if lo <= r[2] < hi]
        t = len(items)
        if t < 5: continue
        dict_err = sum(1 for r in items if not r[3]) / t * 100
        llm_err  = sum(1 for r in items if not r[4]) / t * 100
        improve  = dict_err - llm_err
        mid = (lo + hi) / 2
        print(f"{lo}-{hi:<10} {t:<8} {dict_err:<12.1f} {llm_err:<12.1f} {improve:<10.1f}")
        cal.append((mid, llm_err))
    return cal

# ═══════════════════ Main ═══════════════════

def main():
    # 1. 采样句
    print("1. 采样句子...")
    lines = open(SENTENCES, encoding="utf-8").readlines()
    sampled = random.sample(lines, min(5000, len(lines)))
    print(f"   {len(sampled):,} 句")

    # 2. 分词
    words = segment(sampled)

    # 3. 加载词表+CSS
    print("2. 加载词表+CSS...")
    wv = WordVectors()
    all_words = load_words(min_len=2, max_len=2)
    code_maps = load_code_tables(all_words)
    pdsp = code_maps["拼读双拼"]
    # 构建 word→code 映射 (取首选编码)
    word_to_code = {}
    for code, word_list in pdsp.items():
        for w in word_list:
            if w not in word_to_code:
                word_to_code[w] = code
    css_data = compute_css(pdsp, wv)

    # 4. 构建候选池
    freq = {}
    with open(TOOLCHAIN / "基础数据" / "混合词频_100万.txt", encoding="utf-8") as f:
        f.readline()
        for line in f:
            parts = line.strip().split("\t")
            if len(parts) >= 2:
                freq[parts[1]] = float(parts[0])

    pool = build_candidate_pool(words, word_to_code, css_data["scores"], freq)
    print(f"   候选池: {len(pool):,} 多候选词")

    # 5. LLM 推理
    if not Path(SIM_EXE).exists():
        print("sim_rerank.exe 不存在，跳过 LLM")
        return

    # 分层抽样: 确保每个 CSS 区间有足够样本
    css_bins = [(0,0.5),(0.5,0.7),(0.7,0.85),(0.85,1.1)]
    stratified = []
    for lo, hi in css_bins:
        bucket = [p for p in pool if lo <= p["css"] < hi]
        n = min(len(bucket), N_WORDS // len(css_bins))
        stratified.extend(random.sample(bucket, n) if len(bucket) > n else bucket)
    random.shuffle(stratified)
    print(f"   分层抽样: {len(stratified)} 条")

    results = run_llm(stratified, {code: {w: i for i,w in enumerate(words)} for code, words in pdsp.items()})

    # 6. 校准曲线
    print("\n3. 校准曲线:")
    cal = calibrate(results)

    # 保存
    out = ROOT / "css_calibration.json"
    with open(out, "w") as f:
        json.dump({"calibration": [[float(m), float(e)] for m,e in cal], "n": len(results)}, f)
    print(f"\n校准数据: {out}")

if __name__ == "__main__":
    main()
