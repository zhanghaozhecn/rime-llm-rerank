#!/usr/bin/env python3
"""分析 llm_training.txt 打字语料质量"""
import re
from collections import Counter
from pathlib import Path

CORPUS = Path("C:/Users/Administrator/AppData/Roaming/Rime/llm_training.txt")

if not CORPUS.exists():
    print(f"File not found: {CORPUS}")
    exit(1)

text = CORPUS.read_text(encoding="utf-8")

scenes = [s for s in text.split("\n") if s.strip()]
entries = []
for scene in scenes:
    for seg in scene.split("|"):
        seg = seg.strip()
        if not seg:
            continue
        if "\t" in seg:
            word, code = seg.split("\t", 1)
            entries.append((word, code))
        else:
            entries.append((seg, ""))

total = len(entries)
with_code = sum(1 for w, c in entries if c)
without_code = total - with_code
words_with_code = [(w, c) for w, c in entries if c]

print(f"场景数: {len(scenes)}")
print(f"总条目: {total}")
print(f"有码: {with_code} ({100*with_code/total:.1f}%)")
print(f"无码: {without_code} ({100*without_code/total:.1f}%)")
print(f"平均每场景条目: {total/len(scenes):.1f}")
print()

# 码长分布
code_lens = Counter(len(c) for w, c in words_with_code)
print("码长分布（有码条目）:")
for cl in sorted(code_lens):
    print(f"  {cl}码: {code_lens[cl]} ({100*code_lens[cl]/with_code:.1f}%)")
print()

# 码里包含非字母的比例
bad_codes = sum(1 for w, c in words_with_code if not c.isalpha() or not c.islower())
print(f"非纯小写字母的码: {bad_codes} ({100*bad_codes/with_code:.1f}%)")
print()

# 高频词-码对
print("高频 词→码 Top 30:")
for (w, c), cnt in Counter(words_with_code).most_common(30):
    print(f"  {w} → {c}: {cnt}")
print()

# 单字/标点/英文噪声
single_char = sum(1 for w, c in entries if len(w) == 1)
punct_only = sum(1 for w, c in entries if not any(ch.isalpha() or '一' <= ch <= '鿿' for ch in w))
ascii_alpha = sum(1 for w, c in entries if w.isascii() and w.isalpha())
print(f"单字条目: {single_char} ({100*single_char/total:.1f}%)")
print(f"纯标点/空格: {punct_only} ({100*punct_only/total:.1f}%)")
print(f"英文字母: {ascii_alpha} ({100*ascii_alpha/total:.1f}%)")
print()

# 退格统计
bsp_count = text.count("←")
print(f"退格次数: {bsp_count}")
print()

# 一码多词（同码对应不同词，检查编码冲突）
code_words = {}
for w, c in words_with_code:
    if len(c) >= 2:
        code_words.setdefault(c, set()).add(w)
conflict = {c: ws for c, ws in code_words.items() if len(ws) > 1}
print(f"同码多词: {len(conflict)} 个码")
if conflict:
    for c, ws in sorted(conflict.items(), key=lambda x: -len(x[1]))[:10]:
        print(f"  {c}: {ws}")

# 场景样例
print("\n--- 典型场景（有完整码的） ---")
good_scenes = [s for s in scenes if s.count("\t") >= 3]
for s in good_scenes[:5]:
    print(s[:200])

# ====== 精确定位码错配 ======
print("\n=== 疑似码错配条目 ===")
bad = []
for si, scene in enumerate(scenes):
    segs = scene.split("|")
    for ji, seg in enumerate(segs):
        if "\t" not in seg:
            continue
        parts = seg.split("\t", 1)
        if len(parts) != 2:
            continue
        word, code = parts
        if not code:
            continue
        # 标点、空格、单字拿到 3-4 码 → 明显错配
        if len(code) >= 3 and len(word) <= 1 and word.strip():
            bad.append((si, ji, word, code, scene[:150]))
        # 纯英文拿到 2+ 码 → 错配
        if len(code) >= 2 and word.isascii() and word.isalpha() and 1 <= len(word) <= 2:
            bad.append((si, ji, word, code, scene[:150]))

print(f"疑似错配: {len(bad)} 条")
for si, ji, w, c, ctx in bad[:25]:
    print(f"  [{w}] → {c}  (scene {si})")
    print(f"    {ctx}")
    print()
