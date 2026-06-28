#!/usr/bin/env python3
"""多进程并行推理：4进程各加载一份模型（mmap共享），Queue通信"""
import time, random, numpy as np, sys, os
from multiprocessing import Process, Queue as MPQueue

MODEL_PATH = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
N_WORKERS = 4
N_WARMUP = 5
N_TEST = 30

# 单token候选（最简，验证方案可行性）
CTX_POOL = ["NAND闪存合约价将", "每个人都有追求幸福的", "中国经济增长速度"]
CAND_POOL = [
    ["权利", "权力", "全力", "人民"],
    ["发展", "发达", "发布", "发生"],
    ["技术", "技能", "技巧", "技艺"],
]

def worker(in_q, out_q, wid):
    """子进程：加载模型，循环处理任务"""
    sys.stderr = open(os.devnull, 'w')  # 抑制 llama.cpp 日志
    from llama_cpp import Llama
    llm = Llama(model_path=MODEL_PATH, n_ctx=64, n_threads=2,
                verbose=False, logits_all=True)
    out_q.put(("ready", wid))

    while True:
        msg = in_q.get()
        if msg is None:
            break
        task_id, ctx_ids, w_ids = msg
        t0 = time.perf_counter()
        llm.reset()
        llm.eval(ctx_ids + w_ids)
        # CE loss of last token
        row = llm.scores[len(ctx_ids) - 1]
        if row is not None and len(row) > 0:
            m = float(np.max(row)); e = np.exp(row - m)
            loss = float(-(row[w_ids[-1]] - m - np.log(np.sum(e))))
        else:
            loss = 0.0
        elapsed = (time.perf_counter() - t0) * 1000
        out_q.put((task_id, -loss, elapsed))

def parallel_eval(in_queues, out_queue, ctx_ids, cands):
    """并行评分"""
    for i, (w, w_ids) in enumerate(cands):
        in_queues[i % N_WORKERS].put((i, ctx_ids, w_ids))

    results = [None] * len(cands)
    for _ in range(len(cands)):
        task_id, score, elapsed = out_queue.get()
        results[task_id] = (cands[task_id][0], score, elapsed)

    ranked = sorted(results, key=lambda x: -x[1])
    return ranked, sum(r[2] for r in results) / len(results)

def sequential_eval(llm, ctx_ids, cands):
    """串行评分"""
    t0 = time.perf_counter()
    scores = {}
    for w, w_ids in cands:
        llm.reset()
        llm.eval(ctx_ids + w_ids)
        row = llm.scores[len(ctx_ids) - 1]
        if row is not None and len(row) > 0:
            m = float(np.max(row)); e = np.exp(row - m)
            loss = float(-(row[w_ids[-1]] - m - np.log(np.sum(e))))
        else:
            loss = 0.0
        scores[w] = -loss
    elapsed = (time.perf_counter() - t0) * 1000
    ranked = sorted(scores.items(), key=lambda x: -x[1])
    return ranked, elapsed

if __name__ == "__main__":
    print("启动 workers...", flush=True)
    in_qs = [MPQueue() for _ in range(N_WORKERS)]
    out_q = MPQueue()
    workers_list = []
    for i in range(N_WORKERS):
        p = Process(target=worker, args=(in_qs[i], out_q, i))
        p.start(); workers_list.append(p)

    for _ in range(N_WORKERS):
        msg = out_q.get()
        print(f"  Worker {msg[1]} ready", flush=True)

    # 加载主进程模型（串行对比用）
    print("加载主进程模型...", end=" ", flush=True)
    from llama_cpp import Llama
    sys.stderr = open(os.devnull, 'w')
    llm_main = Llama(model_path=MODEL_PATH, n_ctx=64, n_threads=4,
                     verbose=False, logits_all=True)
    print("OK", flush=True)

    # 预热
    print(f"预热...", end=" ", flush=True)
    for _ in range(N_WARMUP):
        ctx_ids = llm_main.tokenize(random.choice(CTX_POOL).encode(), add_bos=False)[-5:]
        cands = [(w, llm_main.tokenize(w.encode(), add_bos=False)) for w in random.choice(CAND_POOL)[:4]]
        parallel_eval(in_qs, out_q, ctx_ids, cands)
    print("OK", flush=True)

    # Benchmark
    print(f"测试 {N_TEST} 轮...", flush=True)
    seq_times, par_times = [], []
    mismatch = 0

    for rnd in range(N_TEST):
        ctx_ids = llm_main.tokenize(random.choice(CTX_POOL).encode(), add_bos=False)[-5:]
        cands = [(w, llm_main.tokenize(w.encode(), add_bos=False)) for w in random.choice(CAND_POOL)[:4]]

        r_seq, t_seq = sequential_eval(llm_main, ctx_ids, cands)
        seq_times.append(t_seq)

        r_par, t_par = parallel_eval(in_qs, out_q, ctx_ids, cands)
        par_times.append(t_par)

        if r_seq[0][0] != r_par[0][0]:
            mismatch += 1

    seq_times.sort(); par_times.sort()
    print(f"\n{'':>8} {'mean':>7} {'median':>7} {'p95':>7} {'min':>6} {'max':>6}")
    print(f"{'串行':>8} {np.mean(seq_times):>6.0f}ms {np.median(seq_times):>6.0f}ms "
          f"{np.percentile(seq_times,95):>6.0f}ms {seq_times[0]:>5.0f}ms {seq_times[-1]:>5.0f}ms")
    print(f"{'并行':>8} {np.mean(par_times):>6.0f}ms {np.median(par_times):>6.0f}ms "
          f"{np.percentile(par_times,95):>6.0f}ms {par_times[0]:>5.0f}ms {par_times[-1]:>5.0f}ms")
    print(f"\n加速: {np.mean(seq_times)/np.mean(par_times):.2f}x  节省: {np.mean(seq_times)-np.mean(par_times):.0f}ms")
    if mismatch: print(f"结果不一致: {mismatch}/{N_TEST}")

    # 清理
    for q in in_qs: q.put(None)
    for p in workers_list: p.join()
