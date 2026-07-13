#!/usr/bin/env python3
"""
预处理打字训练语料 → LLM 训练/评估样本

输入: llm_training.txt（llm_processor.lua 收集）
格式: 词1\t码1|词2\t码2|←|词3\t码3

输出: train_samples.tsv（与 eval_samples.tsv 相同格式）
      上文\t正确词\t编码\t候选位置\t候选列表\t同码总数

处理:
  1. 解析场景，按退格(←)修正序列
  2. 对有码条目从 dict 查找同码候选
  3. 单字只取单编码字（与 eval 一致）
"""

import re
from pathlib import Path
from collections import defaultdict

RIME_DIR  = Path("C:/Users/Administrator/AppData/Roaming/Rime")
DICT_PATH = Path("d:/OneDrive/typing/拼读双拼/配置文件/pdsp.dict.yaml")
OUT_PATH  = Path("d:/OneDrive/typing/llm_rerank/train_samples.tsv")

# ── 1. Load dict ──
print("Loading dict...")
word_codes = defaultdict(set)  # word → set of codes
with open(DICT_PATH, encoding="utf-8") as f:
    in_body = False
    for line in f:
        line = line.rstrip("\n\r")
        if line == "...":
            in_body = True
            continue
        if not in_body or not line or line[0] == "#":
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        word = parts[0]
        if len(parts) > 2:
            word_codes[word].add(parts[1])  # 简码
            word_codes[word].add(parts[2])  # 全码
        else:
            word_codes[word].add(parts[1])

# 单字筛选（与 eval 一致：无 1 码 + 前 2 码唯一 + 有 3 码）
single_char_code = {}  # word → 3-code
multi_char_code = {}   # word → first code
for w, codes in word_codes.items():
    if len(w) == 1:
        if any(len(c) == 1 for c in codes):
            continue
        prefixes = set(c[:2] for c in codes if len(c) >= 2)
        if len(prefixes) != 1:
            continue
        c3 = next((c for c in codes if len(c) == 3), None)
        if c3 is None:
            continue
        single_char_code[w] = c3
    else:
        multi_char_code[w] = list(codes)[0]

# code → words 映射（仅评测编码）
code_to_words = defaultdict(list)
for w, c in single_char_code.items():
    code_to_words[c].append(w)
for w, c in multi_char_code.items():
    code_to_words[c].append(w)

print(f"  Dict: {len(multi_char_code)} multi-char + {len(single_char_code)} single-char")
print(f"  Codes: {len(code_to_words)}")

# ── 2. Parse training file ──
train_file = RIME_DIR / "llm_training.txt"
if not train_file.exists():
    print(f"ERROR: {train_file} not found")
    exit(1)

print(f"Reading {train_file}...")
scenes = []
with open(train_file, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        entries = []  # [(word, code), ...] code="" means no code
        for part in line.split("|"):
            if part == "←":
                entries.append(("←", ""))
            elif "\t" in part:
                w, c = part.split("\t", 1)
                entries.append((w, c))
            else:
                entries.append((part, ""))
        scenes.append(entries)

print(f"  Scenes: {len(scenes)}, entries: {sum(len(s) for s in scenes)}")

# ── 3. Build samples ──
samples = []
stats = {"total": 0, "with_code": 0, "single_char": 0, "multi_char": 0,
         "no_dict_match": 0, "w1": 0, "skipped": 0}

for scene in scenes:
    # Apply backspace to get final sequence
    words = []  # [(text, code)]
    for text, code in scene:
        if text == "←":
            if words:
                words.pop()
        else:
            words.append((text, code))

    # Build context incrementally, generate samples
    ctx_parts = []
    for text, code in words:
        # Skip entries without Chinese (no code assigned by processor)
        has_cn = bool(re.search(r"[^\x01-\x7f]", text))
        if not has_cn:
            ctx_parts.append(text)
            continue
        if not code:
            ctx_parts.append(text)
            continue

        stats["total"] += 1
        stats["with_code"] += 1

        # Determine evaluation code
        if len(text) == 1:
            if text not in single_char_code:
                stats["skipped"] += 1
                ctx_parts.append(text)
                continue
            eval_code = single_char_code[text]
            stats["single_char"] += 1
        else:
            if text not in multi_char_code:
                stats["skipped"] += 1
                ctx_parts.append(text)
                continue
            eval_code = multi_char_code[text]
            stats["multi_char"] += 1

        # Find same-code candidates
        all_words = code_to_words.get(eval_code, [])
        total = len(all_words)
        if total == 0:
            stats["no_dict_match"] += 1
            ctx_parts.append(text)
            continue

        if text not in all_words:
            stats["no_dict_match"] += 1
            ctx_parts.append(text)
            continue

        # Position in full list
        pos = all_words.index(text)
        # Other candidates (exclude correct word, take first 9)
        cands = [w for w in all_words if w != text][:9]
        cand_str = ",".join(cands)
        context = "".join(ctx_parts)

        if total == 1:
            stats["w1"] += 1

        samples.append((context, text, eval_code, pos, cand_str, total))
        ctx_parts.append(text)

print(f"\n  Total coded entries: {stats['total']}")
print(f"  Valid samples: {len(samples)}")
print(f"  Single-char: {stats['single_char']}, multi-char: {stats['multi_char']}")
print(f"  Skipped (no dict match/多音字): {stats['skipped']}")
print(f"  W=1 (no competition): {stats['w1']}")

# ── 4. Save ──
with open(OUT_PATH, "w", encoding="utf-8") as f:
    for ctx, word, code, pos, cands, total in samples:
        f.write(f"{ctx}\t{word}\t{code}\t{pos}\t{cands}\t{total}\n")
print(f"\nSaved {len(samples)} samples to {OUT_PATH}")

# Stats
from collections import Counter
wdist = Counter(t for _, _, _, _, _, t in samples)
w1 = wdist.get(1, 0)
w2p = sum(v for k, v in wdist.items() if k >= 2)
print(f"Same-code: W=1: {w1} ({100*w1/len(samples):.1f}%), W>=2: {w2p} ({100*w2p/len(samples):.1f}%)")
