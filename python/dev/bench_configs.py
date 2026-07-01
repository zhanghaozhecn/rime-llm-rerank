#!/usr/bin/env python3
"""对比不同 worker×thread 组合的延迟"""
import time, numpy as np, sys, os, json
from multiprocessing import Process, Queue as MPQueue
from itertools import product

MODEL_PATH = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
N_WARMUP = 3
N_TEST = 15

def worker(in_q, out_q, wid, n_threads):
    sys.stderr = open(os.devnull, 'w')
    from llama_cpp import Llama
    llm = Llama(model_path=MODEL_PATH, n_ctx=64, n_threads=n_threads,
                verbose=False, logits_all=True)
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

def bench(n_workers, n_threads_per, n_cands):
    in_qs = [MPQueue() for _ in range(n_workers)]
    out_q = MPQueue()
    workers = []
    for i in range(n_workers):
        p = Process(target=worker, args=(in_qs[i], out_q, i, n_threads_per))
        p.start(); workers.append(p)
    for _ in range(n_workers): out_q.get()

    sys.stderr = open(os.devnull, 'w')
    from llama_cpp import Llama
    llm = Llama(model_path=MODEL_PATH, n_ctx=64, n_threads=1, verbose=False)
    sys.stderr = sys.__stderr__

    all_cands = ["权利","权力","全力","人民","发展","发达","发布","发生","技术"]
    cands = all_cands[:n_cands]
    ctx_ids = llm.tokenize("每个人都有追求幸福的".encode(), add_bos=False)[-5:]
    w_list = [(w, llm.tokenize(w.encode(), add_bos=False)) for w in cands]

    for _ in range(N_WARMUP):
        for i in range(n_cands):
            in_qs[i % n_workers].put((i, ctx_ids, w_list[i][1]))
        for _ in range(n_cands): out_q.get()

    times = []
    for _ in range(N_TEST):
        t0 = time.perf_counter()
        for i in range(n_cands):
            in_qs[i % n_workers].put((i, ctx_ids, w_list[i][1]))
        for _ in range(n_cands): out_q.get()
        times.append((time.perf_counter() - t0) * 1000)

    for q in in_qs: q.put(None)
    for p in workers: p.join()
    del llm

    times.sort()
    rounds = (n_cands + n_workers - 1) // n_workers
    return np.mean(times), np.median(times), rounds

if __name__ == "__main__":
    configs = [(4,3), (4,4), (5,3), (5,4), (6,3), (6,4)]
    cand_counts = [4, 5, 6, 7, 8]

    # 表头
    header = f"{'w×t':>6}"
    for c in cand_counts:
        header += f"  {c}cand"
    print(header)
    print("-" * (6 + 8 * len(cand_counts)))

    for n_w, n_t in configs:
        total_threads = n_w * n_t
        if total_threads > 20: continue  # 不超过CPU线程数
        row = f"{n_w}×{n_t}:{total_threads:>2}t"
        for n_c in cand_counts:
            try:
                mean, median, rounds = bench(n_w, n_t, n_c)
                row += f"  {mean:>4.0f}ms"
            except Exception as e:
                row += f"  {'ERR':>6}"
                break
        print(row)
        sys.stdout.flush()
