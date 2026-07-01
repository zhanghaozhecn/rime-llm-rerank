#!/usr/bin/env python3
"""延迟矩阵：2-7token上文 × 4-6候选，4worker×2thread"""
import time, numpy as np, sys, os
from multiprocessing import Process, Queue as MPQueue

MODEL_PATH = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
N_WORKERS = 4; N_THREADS = 2
N_WARMUP = 3; N_TEST = 15

def worker(in_q, out_q, wid):
    sys.stderr = open(os.devnull, 'w')
    from llama_cpp import Llama
    llm = Llama(model_path=MODEL_PATH, n_ctx=64, n_threads=N_THREADS, verbose=False, logits_all=True)
    out_q.put(("ready", wid))
    while True:
        msg = in_q.get()
        if msg is None: break
        task_id, ctx_ids, w_ids = msg
        llm.reset(); llm.eval(ctx_ids + w_ids)
        loss = 0.0
        for j in range(len(w_ids)):
            pos = len(ctx_ids) + j - 1
            if pos < 64:
                row = llm.scores[pos]
                if row is not None and len(row) > 0:
                    m = float(np.max(row)); e = np.exp(row - m)
                    loss += float(-(row[w_ids[j]] - m - np.log(np.sum(e))))
        out_q.put((task_id, -loss))

if __name__ == "__main__":
    in_qs = [MPQueue() for _ in range(N_WORKERS)]; out_q = MPQueue()
    workers = []
    for i in range(N_WORKERS):
        p = Process(target=worker, args=(in_qs[i], out_q, i)); p.start(); workers.append(p)
    for _ in range(N_WORKERS): out_q.get()

    sys.stderr = open(os.devnull, 'w')
    from llama_cpp import Llama
    llm = Llama(model_path=MODEL_PATH, n_ctx=64, n_threads=1, verbose=False)
    sys.stderr = sys.__stderr__

    # 长文本用于截不同token数
    full_text = "中国经济增长速度令人瞩目人工智能技术正在改变世界"
    all_cands = ["权利","权力","全力","人民","发展","发达"]

    tok_counts = [2,3,4,5,6,7]
    cand_counts = [4,5,6]

    # 表头
    print(f"\n{'tok':>4}", end="")
    for c in cand_counts:
        print(f"  {c}cand", end="")
    print(f"\n{'─'*4}  {'─'*7} {'─'*7} {'─'*7}")

    for n_tok in tok_counts:
        ctx_ids = llm.tokenize(full_text.encode(), add_bos=False)[-n_tok:]
        print(f"{n_tok:>4}", end="", flush=True)

        for n_cand in cand_counts:
            cands = all_cands[:n_cand]
            w_list = [(w, llm.tokenize(w.encode(), add_bos=False)) for w in cands]

            for _ in range(N_WARMUP):
                for i in range(n_cand):
                    in_qs[i % N_WORKERS].put((i, ctx_ids, w_list[i][1]))
                for _ in range(n_cand): out_q.get()

            times = []
            for _ in range(N_TEST):
                t0 = time.perf_counter()
                for i in range(n_cand):
                    in_qs[i % N_WORKERS].put((i, ctx_ids, w_list[i][1]))
                for _ in range(n_cand): out_q.get()
                times.append((time.perf_counter() - t0) * 1000)
            times.sort()
            print(f"  {np.median(times):>4.0f}ms", end="", flush=True)
        print()

    for q in in_qs: q.put(None)
    for p in workers: p.join()
