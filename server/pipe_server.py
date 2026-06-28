#!/usr/bin/env python3
"""命名管道推理服务 — 多进程并行 + mmap 权重共享"""
import json, time, numpy as np, sys, os, ctypes
from multiprocessing import Process, Queue as MPQueue
import win32pipe, win32file, pywintypes

PIPE_NAME = r"\\.\pipe\rime_llm"
MODEL_PATH = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
N_CTX = 64
N_WORKERS = 4
N_THREADS_PER = 2  # 4workers×2threads=8线程，0.8B模型最优

# —— 服务端控制参数 ——
MAX_CONTEXT_TOKENS = 4  # 4tok×4cand=107ms
MAX_CANDIDATES = 4

# ============================================================
# Worker 进程
# ============================================================
def worker(in_q, out_q, wid):
    """独立进程：加载模型，处理评分任务"""
    sys.stderr = open(os.devnull, 'w')
    from llama_cpp import Llama
    llm = Llama(model_path=MODEL_PATH, n_ctx=N_CTX, n_threads=N_THREADS_PER,
                verbose=False, logits_all=True)
    out_q.put(("ready", wid))

    while True:
        msg = in_q.get()
        if msg is None:
            break
        task_id, ctx_ids, w_ids = msg
        t0 = time.perf_counter()

        # 计算交叉熵损失
        loss = 0.0
        llm.reset()
        llm.eval(ctx_ids + w_ids)
        for j in range(len(w_ids)):
            pos = len(ctx_ids) + j - 1
            if pos < N_CTX:
                row = llm.scores[pos]
                if row is not None and len(row) > 0:
                    m = float(np.max(row))
                    e = np.exp(row - m)
                    loss += float(-(row[w_ids[j]] - m - np.log(np.sum(e))))

        elapsed = (time.perf_counter() - t0) * 1000
        out_q.put((task_id, -loss, elapsed))

# ============================================================
# 主进程
# ============================================================
if __name__ == "__main__":
    # 轻量 tokenizer：仅加载 vocab，不创建推理上下文（省~80MB）
    sys.stderr = open(os.devnull, 'w')
    from llama_cpp import llama_cpp as llcpp
    model_token = llcpp.llama_load_model_from_file(MODEL_PATH.encode(),
                                                    llcpp.llama_model_default_params())
    vocab = llcpp.llama_model_get_vocab(model_token)
    eos_id = getattr(llcpp, 'llama_token_eos', lambda m: 248046)(model_token)
    print(f"Tokenizer 就绪 (vocab only, 无推理上下文)")

    def tokenize(text):
        b = text.encode('utf-8')
        tokens = (ctypes.c_int * 128)()
        n = llcpp.llama_tokenize(vocab, b, len(b), tokens, 128, True, True)
        return list(tokens[:n]) if n > 0 else [eos_id]
    sys.stderr = sys.__stderr__

    # 启动 workers
    print(f"启动 {N_WORKERS} 个推理 worker...")
    in_qs = [MPQueue() for _ in range(N_WORKERS)]
    out_q = MPQueue()
    workers = []
    for i in range(N_WORKERS):
        p = Process(target=worker, args=(in_qs[i], out_q, i))
        p.start(); workers.append(p)

    for _ in range(N_WORKERS):
        msg = out_q.get()
        print(f"  Worker {msg[1]} ready")

    # 预热
    cx = tokenize("\n")
    for i in range(N_WORKERS):
        wid = tokenize("测试")
        in_qs[i].put((0, cx, wid))
    for _ in range(N_WORKERS):
        out_q.get()

    print(f"模型就绪 (Q4_K_M, {N_WORKERS}×{N_THREADS_PER}线程并行, Named Pipe)")

    # 记录所有 PID 供 stop_server.bat 精准终止
    pid_file = os.path.join(os.environ.get("TEMP", "C:\\Windows\\Temp"), "rime_llm_pids.txt")
    all_pids = [os.getpid()] + [p.pid for p in workers]
    with open(pid_file, "w") as f:
        f.write("\n".join(str(p) for p in all_pids))
    print(f"  PID: {all_pids}")

    # ---- 并行评分 ----
    def score(context: str, candidates: list[str]) -> list[str]:
        candidates = candidates[:MAX_CANDIDATES]
        if not context or not context.strip():
            context = "\n"

        ctx_ids = tokenize(context)
        if len(ctx_ids) > MAX_CONTEXT_TOKENS:
            ctx_ids = ctx_ids[-MAX_CONTEXT_TOKENS:]

        cand_data = []
        for w in candidates:
            w_ids = tokenize(w)
            cand_data.append((w, w_ids))

        # 分发到 workers
        n = len(cand_data)
        for i in range(n):
            in_qs[i % N_WORKERS].put((i, ctx_ids, cand_data[i][1]))

        # 收集结果
        results = [None] * n
        for _ in range(n):
            task_id, score_val, _ = out_q.get()
            results[task_id] = (cand_data[task_id][0], score_val)

        ranked = sorted(results, key=lambda x: -x[1])
        return [w for w, _ in ranked]

    # ---- 管道服务 ----
    def handle(pipe):
        try:
            _, data = win32file.ReadFile(pipe, 65536)
            body = data.decode('utf-8')
            req = json.loads(body)
            # 停止信号：收到 {"stop":true} 直接返回
            if req.get("stop"):
                return
            t0 = time.perf_counter()
            ranked = score(req.get("context", ""), req.get("candidates", []))
            ms = (time.perf_counter() - t0) * 1000
            resp = json.dumps({"first": ranked[0] if ranked else "", "latency_ms": ms},
                              ensure_ascii=False)
            win32file.WriteFile(pipe, resp.encode('utf-8'))
        except Exception as e:
            try:
                win32file.WriteFile(pipe, json.dumps({"error": str(e)}, ensure_ascii=False).encode())
            except: pass
        finally:
            try: win32file.FlushFileBuffers(pipe)
            except: pass
            try: win32file.DisconnectNamedPipe(pipe)
            except: pass
            try: win32file.CloseHandle(pipe)
            except: pass

    print(f"\n管道服务启动: {PIPE_NAME}")
    while True:
        try:
            pipe = win32pipe.CreateNamedPipe(
                PIPE_NAME,
                win32pipe.PIPE_ACCESS_DUPLEX,
                win32pipe.PIPE_TYPE_MESSAGE | win32pipe.PIPE_READMODE_MESSAGE | win32pipe.PIPE_WAIT,
                win32pipe.PIPE_UNLIMITED_INSTANCES,
                65536, 65536, 0, None)
        except pywintypes.error as e:
            if "231" in str(e) or "所有" in str(e):
                print("  管道暂被占用，5s 后重试...")
                time.sleep(5)
                continue
            raise
        win32pipe.ConnectNamedPipe(pipe, None)
        handle(pipe)
