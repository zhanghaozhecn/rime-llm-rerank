#!/usr/bin/env python3
"""
拼读双拼 字典序 vs LLM 重排 对比评测工具

用法:
  python eval/eval_rerank.py --text "测试文本"
  python eval/eval_rerank.py --file 测试文本.txt
  python eval/eval_rerank.py --file -          (从 stdin 读取)
  python eval/eval_rerank.py --text "测试" --dict-only    (仅字典序，不跑 LLM)

依赖:
  - BERT 分词模型 (bert_seg venv, 见 VENV_PY)
  - 拼读双拼字典 (项目根 pdsp_dict.yaml，--dict 可指定其他)
  - C++ 仿真器 (sim_rerank.exe) — 仅 --llm 时需要

输出: 逐词明细表 + 字典序/LLM 重排 选重率对比
"""
import argparse, json, subprocess, sys, os
from pathlib import Path
from collections import defaultdict, OrderedDict

# ── Paths ──
# 项目内资源一律相对脚本位置；本机/跨项目资源用环境变量可覆盖（见 CLAUDE.md）
ROOT       = Path(__file__).resolve().parent   # eval/
PROJ       = ROOT.parent                        # 项目根
DICT_PATH  = PROJ / "pdsp_dict.yaml"   # 词库拷贝（从 OneDrive 规范源同步，--dict 覆盖）
SIM_EXE    = PROJ / "cpp/build_sim/Release/sim_rerank.exe"
VENV_PY    = os.environ.get("RIME_LLM_VENV_PY",
              "D:/OneDrive/typing/bert_seg/.venv/Scripts/python.exe")

# ── CLI ──
parser = argparse.ArgumentParser(description="字典序 vs LLM 重排 对比评测")
group = parser.add_mutually_exclusive_group(required=True)
group.add_argument("--text", help="直接输入文本")
group.add_argument("--file", help="从文件读取 (- 为 stdin)")
parser.add_argument("--dict", help="自定义词库路径 (默认拼读双拼 pdsp.dict.yaml)")
parser.add_argument("--model", help="LLM 模型 GGUF 路径 (默认 Qwen3.5-0.8B)")
parser.add_argument("--dict-only", action="store_true", help="仅字典序，跳过 LLM")
parser.add_argument("--no-color", action="store_true", help="禁用颜色")
args = parser.parse_args()

if args.dict:
    DICT_PATH = Path(args.dict)
is_custom_dict = bool(args.dict)

C = {"G": "\033[92m", "R": "\033[91m", "Y": "\033[93m", "B": "\033[94m", "W": "\033[0m", "D": "\033[90m"}
if args.no_color: C = {k: "" for k in C}

# ── Read input ──
if args.text:
    text = args.text
elif args.file:
    if args.file == "-":
        text = sys.stdin.read()
    else:
        text = Path(args.file).read_text(encoding="utf-8")
print(f"{C['D']}输入: {len(text)} 字{C['W']}")

# ═══════════════════════════════════════════
# 1. Load dict
# ═══════════════════════════════════════════
print(f"{C['D']}加载字典...{C['W']}", end=" ", flush=True)
# OrderedDict 保持词库文件中的行序：评测基准是"字典序"，候选顺序敏感，
# 丢序会让字典序基准失真（此前用 dict.fromkeys 丢过序）
word_to_codes = defaultdict(list); code_to_words = defaultdict(OrderedDict)
with open(DICT_PATH, encoding="utf-8") as f:
    in_body = False
    for line in f:
        line = line.rstrip("\n\r")
        if line == "...": in_body = True; continue
        if not in_body or not line or line.startswith("#"): continue
        parts = line.split("\t")
        if len(parts) < 2: continue
        word, code = parts[0], parts[1]
        if len(word) < 2: continue
        if not is_custom_dict and len(code) != 4: continue  # pdsp 固定 4 码；外部词库放宽
        word_to_codes[word].append(code)
        if word not in code_to_words[code]:
            code_to_words[code][word] = len(code_to_words[code])
dict_label = Path(DICT_PATH).stem
print(f"{len(word_to_codes):,} 词 {len(code_to_words):,} 编码 [{dict_label}]")

# ═══════════════════════════════════════════
# 2. Segment (HanLP, via venv subprocess)
# ═══════════════════════════════════════════
print(f"{C['D']}分词中 (HanLP)...{C['W']}", end=" ", flush=True)
import subprocess as sp

def is_cjk(ch): return '一' <= ch <= '鿿'

def segment(text):
    """HanLP segmentation with mixed CJK/non-CJK token splitting."""
    result = sp.run(
        [VENV_PY, "-c", f"""
import hanlp, json, sys
tok = hanlp.load(hanlp.pretrained.tok.COARSE_ELECTRA_SMALL_ZH)
text = json.loads(sys.stdin.read())
words = tok(text)
# split mixed tokens (e.g. '450毫米' → '450' + '毫米')
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
print(json.dumps(result, ensure_ascii=False))
"""],
        input=json.dumps(text, ensure_ascii=False),
        capture_output=True, text=True,
        timeout=300,  # HanLP 首次加载模型可超分钟级；曾因默认 60s 超时误报失败
        env={**os.environ, "HF_ENDPOINT": "https://hf-mirror.com"}
    )
    for line in result.stdout.strip().split("\n"):
        try:
            parsed = json.loads(line)
            if isinstance(parsed, list):
                return [w for w in parsed if w]  # filter empty strings
        except: pass
    # Fallback: character-level
    return list(text)

words = segment(text)
print(f"{len(words)} 词")

# ═══════════════════════════════════════════
# 3. Build analysis
# ═══════════════════════════════════════════
analysis = []; ctx = []
not_in_dict = 0; single_cand = 0; multi_cand = 0
for w in words:
    if len(w) < 2: ctx.append(w); continue
    codes = word_to_codes.get(w, [])
    if not codes:
        analysis.append({"w":w,"code":"?","cands":[],"rd":"?","ctx":"".join(ctx)})
        ctx.append(w); not_in_dict += 1; continue
    code = codes[0]; cands = list(code_to_words[code].keys())
    rd = cands.index(w)+1 if w in cands else "?"
    analysis.append({"w":w,"code":code,"cands":cands,"rd":rd,"ctx":"".join(ctx)})
    ctx.append(w)
    if len(cands) == 1: single_cand += 1
    else: multi_cand += 1

print(f"  在词库: {single_cand + multi_cand}  (独一候选: {single_cand}, 多候选: {multi_cand})")
print(f"  不在词库: {not_in_dict}")

# ═══════════════════════════════════════════
# 4. LLM scoring (via C++ sim_rerank)
# ═══════════════════════════════════════════
run_llm = not args.dict_only and Path(SIM_EXE).exists()
if run_llm:
    multi = [a for a in analysis if a["code"] != "?" and len(a["cands"]) > 1]
    if multi:
        print(f"{C['D']}LLM 重排中 ({len(multi)} 条)...{C['W']}", end=" ", flush=True)
        payload = "\n".join(json.dumps({"context": a["ctx"], "cands": a["cands"][:5]}, ensure_ascii=False) for a in multi)
        sim_cmd = [SIM_EXE]
        if args.model:
            sim_cmd.append(args.model)
        proc = subprocess.run(sim_cmd, input=payload, capture_output=True, text=True, encoding="utf-8", timeout=600)
        if proc.returncode == 0:
            lines = [l.strip() for l in proc.stdout.strip().split("\n") if l.strip().startswith("[")]
            for a, line in zip(multi, lines):
                try: a["llm_ranked"] = json.loads(line)
                except: pass
            llm_ok = sum(1 for a in multi if a.get("llm_ranked"))
            # 显示 sim_rerank 的 stderr（模型加载 + 延迟统计）
            for l in proc.stderr.strip().split("\n"):
                if l.strip():
                    print(f"  {C['D']}{l.strip()}{C['W']}")
            print(f"{llm_ok} 条完成")
        else:
            print(f"{C['R']}sim_rerank 出错{C['W']}"); run_llm = False
    else:
        run_llm = False

# ═══════════════════════════════════════════
# 5. Display
# ═══════════════════════════════════════════
print(f"\n{C['B']}{'='*80}{C['W']}")
print(f"{C['B']}逐词明细{C['W']}")
print(f"{C['B']}{'='*80}{C['W']}")
header = f"{'词':<10} {'编码':<6} {'字典位':<8}"
if run_llm: header += f" {'LLM位':<8}"
header += f" {'候选数':<8} {'候选列表'}"
print(C["D"] + header + C["W"])
print(C["D"] + "-"*80 + C["W"])

dc=0; dt=0; lc=None if not run_llm else 0; lt=0

for a in analysis:
    if a["code"] == "?":
        line = f"{a['w']:<10} {'?':<6} {'不在词库':<8}"
        if run_llm: line += f" {'-':<8}"
        line += f" {'-':<8}"
        print(C["D"] + line + C["W"])
        continue

    if len(a["cands"]) < 2:
        dc+=1; dt+=1; lt+=1
        if run_llm: lc+=1
        continue

    dt+=1; lt+=1
    rd = a["rd"]
    if rd == 1: dc += 1

    rl = "?"; lr = a.get("llm_ranked")
    if lr:
        try: rl = lr.index(a["w"]) + 1
        except: pass
        if rl == 1: lc += 1
    elif not run_llm:
        lc = None

    rds = f"第{rd}" if isinstance(rd,int) else str(rd)
    rls = f"第{rl}" if isinstance(rl,int) else str(rl)
    cs = " > ".join(a["cands"])
    if len(cs) > 55: cs = cs[:52] + "..."

    # Color coding
    color = C["W"]
    if isinstance(rd, int) and rd > 1: color = C["R"]
    if run_llm and isinstance(rl, int):
        if rl == 1 and (not isinstance(rd, int) or rd > 1): color = C["G"]  # LLM fixed it
        elif rl > 1: color = C["Y"]

    line = f"{color}{a['w']:<10} {a['code']:<6} {rds:<8}"
    if run_llm: line += f" {rls:<8}"
    line += f" {len(a['cands']):<8} {cs}{C['W']}"
    print(line)

# ── Summary ──
dw = dt - dc
print(f"\n{C['B']}{'='*80}{C['W']}")
print(f"{C['B']}结果对比{C['W']}")
print(f"{C['B']}{'='*80}{C['W']}")
print(f"{'':<15} {'首选':<10} {'需选重':<10} {'选重率':<12} {'不在词库'}")
print(C["D"] + "-"*60 + C["W"])
print(f"{'字典序':<15} {dc:<10} {dw:<10} {dw/max(1,dt)*100:.1f}%{'':<7} {not_in_dict}")
if run_llm:
    lw = lt - lc
    print(f"{'LLM 重排':<15} {lc:<10} {lw:<10} {lw/max(1,lt)*100:.1f}%")
    if dw > lw:
        print(f"\n{C['G']}✓ LLM 减少 {dw-lw} 个选重 ({dw-lw}/{dw} = {(dw-lw)/max(1,dw)*100:.0f}%){C['W']}")
    elif dw < lw:
        print(f"\n{C['R']}✗ LLM 增加 {lw-dw} 个选重{C['W']}")
    else:
        print(f"\n= 无差异")

    # ── LLM 修正 / 改错 分别列出，候选上用 # 标 LLM 首选 ──
    if run_llm:
        multi = [a for a in analysis if a.get("llm_ranked") and isinstance(a["rd"], int) and len(a["cands"]) > 1]
        fixed  = [a for a in multi if a["rd"] != 1 and a["llm_ranked"][0] == a["w"]]
        broken = [a for a in multi if a["rd"] == 1 and a["llm_ranked"][0] != a["w"]]

        for tag, color, items in [("LLM 修正", C["G"], fixed), ("LLM 改错", C["R"], broken)]:
            if not items: continue
            print(f"\n{C['B']}{'─'*80}{C['W']}")
            print(f"{color}{tag} ({len(items)} 个){C['W']}")
            print(f"{C['B']}{'─'*80}{C['W']}")
            for a in items:
                lr = a["llm_ranked"]
                ctx_short = a["ctx"]
                if len(ctx_short) > 20:
                    ctx_short = "…" + ctx_short[-18:]
                # 候选列表：LLM 首选加 # 标记
                cands_str = " > ".join(
                    f"{C['Y']}#{w}{C['W']}" if w == lr[0] else
                    (f"{C['R']}{w}{C['W']}" if w == a["w"] else w)
                    for w in a["cands"][:6])
                print(f"  {a['w']} [{a['code']}]  {C['D']}{ctx_short}{C['W']}  →  {cands_str}")
elif not Path(SIM_EXE).exists():
    print(f"\n{C['Y']}  sim_rerank.exe 未编译，跳过 LLM 重排。{C['W']}")
    print(f"  cmake --build build_sim --config Release --target sim_rerank")
