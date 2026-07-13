#!/usr/bin/env python3
"""
预处理 wiki 语料 → 评估样本主文件（全量位置采样）

1. 加载拼读双拼词库 → word→code, code→words
2. 从 wiki 随机采样 100K 句
3. 用词库注入 jieba 分词，找出每句中所有 dict 词的位置
4. 全部位置收集后打乱，取 10 万条作为主样本集
5. 每行输出：上文\t正确词\t编码\t候选1,候选2,...\t全量候选数
   - 候选 = 同码词列表前 9 个（排除正确词自身）
   - 后续任意 N 样本只需 head -N 即可

用法: python prep_samples.py [--max-samples 100000] [--sentences 100000]
"""

import random
import sys
from pathlib import Path
from collections import defaultdict

WIKI_PATH = "D:/分词注音工程/分读音词频统计/data/sentences_new.txt"
DICT_PATH = "d:/OneDrive/typing/拼读双拼/配置文件/pdsp.dict.yaml"
OUT_DIR   = Path("d:/OneDrive/typing/llm_rerank")

MAX_SAMPLES = 100000
N_SENTENCES = 100000

# ── 1. Load dict ──
print("Loading dict...")
word_to_code = {}
code_to_words = defaultdict(list)
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
        if word not in word_to_code:
            word_to_code[word] = set()
        # 收录所有编码：简码（如有）+ 全码
        if len(parts) > 2:
            word_to_code[word].add(parts[1])  # 简码（1 码或 2 码）
            word_to_code[word].add(parts[2])  # 全码（2 码或 3 码）
        else:
            word_to_code[word].add(parts[1])

# 单字筛选：无 1 码 + 前 2 码唯一 + 有 3 码
#   1 码字 → 直接跳过（打法固定，不参与重排）
#   前 2 码 > 1 种 → 多编码字（多音字），跳过
#   有 3 码形式 → 以 3 码作为评测编码
single_char_code = {}   # word → 3-code (评测用)
for w, codes in word_to_code.items():
    if len(w) != 1:
        continue
    has_len1 = any(len(c) == 1 for c in codes)
    if has_len1:
        continue  # 有简码，跳过
    # 提取所有 ≥2 码的前 2 码
    prefixes = set(c[:2] for c in codes if len(c) >= 2)
    if len(prefixes) != 1:
        continue  # 多编码字（多音），跳过
    # 取 3 码形式作为评测编码，没有则跳过
    code3 = next((c for c in codes if len(c) == 3), None)
    if code3 is None:
        continue
    single_char_code[w] = code3

# 多字词
multi_char_code = {}
for w, codes in word_to_code.items():
    if len(w) == 1:
        continue
    multi_char_code[w] = list(codes)[0]

# 构建 code→words 映射（仅评测编码，简码不参与）
for w, code in single_char_code.items():
    code_to_words[code].append(w)
for w, code in multi_char_code.items():
    code_to_words[code].append(w)

print(f"  Multi-char: {len(multi_char_code)}, single-char (3-code unique): {len(single_char_code)}")
print(f"  Codes: {len(code_to_words)}")

# ── 2. jieba with dict ──
import jieba
for word in single_char_code:
    jieba.add_word(word)
for word in multi_char_code:
    jieba.add_word(word)
print("  jieba ready")

# ── 3. Sample sentences, find ALL dict-word positions ──
print(f"Sampling {N_SENTENCES} sentences...")
random.seed(42)
with open(WIKI_PATH, encoding="utf-8") as f:
    all_lines = [l.rstrip("\n\r") for l in f if l.strip()]
sentences = random.sample(all_lines, min(N_SENTENCES, len(all_lines)))
print(f"  Corpus: {len(all_lines)} total, sampled {len(sentences)}")

all_hits = []  # (context, word, code, candidates_str, total)
for si, sent in enumerate(sentences):
    if si % 10000 == 0:
        print(f"  segmenting... {si}/{len(sentences)}")

    words = list(jieba.cut(sent))
    char_pos = 0
    hits_in_sent = []
    for w in words:
        w = w.strip()
        if not w:
            continue
        pos = sent.find(w, char_pos)
        if pos < 0:
            char_pos += len(w)
            continue
        # 单字用 single_char_code，多字词用 multi_char_code
        if w in single_char_code:
            hits_in_sent.append((char_pos, w, single_char_code[w]))
        elif w in multi_char_code:
            hits_in_sent.append((char_pos, w, multi_char_code[w]))
        char_pos = char_pos + len(w)

    for char_pos, word, code in hits_in_sent:
        all_words = code_to_words[code]
        total = len(all_words)
        dict_pos = all_words.index(word)
        # 前 9 个候选（排除正确词自身），逗号分隔
        cands = [cw for cw in all_words if cw != word][:9]
        cand_str = ",".join(cands)
        context = sent[:char_pos]
        all_hits.append((context, word, code, dict_pos, cand_str, total))

print(f"  Total hits: {len(all_hits)}")

# ── 4. Shuffle and cap ──
random.shuffle(all_hits)
if len(all_hits) > MAX_SAMPLES:
    all_hits = all_hits[:MAX_SAMPLES]
print(f"  Final samples: {len(all_hits)}")

# ── 5. Save ──
out_path = OUT_DIR / "eval_samples.tsv"
with open(out_path, "w", encoding="utf-8") as f:
    for ctx, word, code, pos, cands, total in all_hits:
        f.write(f"{ctx}\t{word}\t{code}\t{pos}\t{cands}\t{total}\n")
print(f"Saved: {out_path}")

# Stats
from collections import Counter
wdist = Counter(total for _, _, _, _, _, total in all_hits)
print(f"Same-code dist: 1={wdist[1]} 2={wdist[2]} 3={wdist[3]} 4={wdist[4]} 5={wdist[5]} 6+={sum(v for k,v in wdist.items() if k>=6)}")
