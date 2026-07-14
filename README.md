# RIME LLM 候选重排

一个本地 AI 模型（Qwen3.5-0.8B），为任意 RIME **四码定长**方案（五笔、郑码、仓颉、拼读双拼等）提供打字时的智能候选排序。

LLM 与编码方案无关——它只看到最终的中文候选词列表。

## 效果与延迟

默认配置 **10 token 上文 + 5 候选**，Qwen3.5-0.8B Q4_K_M。准确率 93.4%。参数根据 20000 样本扫参确定：cand=5→9 仅 +0.5pp 但 CPU 延迟翻倍，5 为延迟/准确率最佳平衡点。

采用**预解码 + 分层并行解码**：上文在 commit 后立即异步预解码（Step 1），编码完成时只需候选 token decode（Step 2）。总 decode 次数：ctx 1 次 + 候选层 1-2 次。

### 感知延迟（用户体感）

| 指标 | CPU (thr=7) | GPU (P0) |
|------|:---:|:---:|
| 准确率 (10tok/5cand) | **93.4%** | **93.4%** |
| 感知延迟 (10tok/5cand) | **~43ms** | **~23ms** |
| 其中 ctx decode (S1) | 0ms（预解码） | 0ms（预解码） |
| 候选 decode (S2) | ~36ms | ~16ms |
| 准确率 (10tok/5cand) | 93.4% | 93.4%（同算法） |
| 内存/VRAM | ~497MB | ~1.2GB |
| 依赖 | 零 | NVIDIA GPU + CUDA 12 |

> ⚠️ **延迟为相对参考**，受 CPU/GPU 型号和线程数影响，不同机器差异显著。**准确率是唯一跨机器的绝对指标。**
>
> GPU 版需在 NVIDIA 控制面板中将 `WeaselServer.exe` 设为「最高性能优先」，否则 P8→P0 降频导致延迟剧烈波动。

### 预解码原理

打字时，上文在 commit 后即已确定，而候选需要等编码打完才知道。利用这个时间差：

1. **commit 时**：异步执行 ctx decode + 缓存 logits（~50ms CPU / ~10ms GPU）
2. **编码打完**：skip ctx decode，直接 KV copy + 候选 decode（~36ms CPU / ~16ms GPU）
3. **感知延迟**：从「ctx+候选」降到「仅候选」，约减半

### 延迟扫参（全部 2-token 候选 = 最坏情况，不含预解码）

#### thr × cand（tok=10，p50 ms，CPU）

| thr\cand | cand=2 | cand=3 | cand=4 | **cand=5** | cand=6 | cand=7 | cand=8 | cand=9 |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 3 | 171 | 190 | 202 | 231 | 264 | 276 | 287 | 302 |
| 4 | 154 | 169 | 180 | 211 | 225 | 243 | 262 | 282 |
| **6** | 137 | 150 | 161 | **178** | 195 | 213 | 217 | 235 |
| 8 | 121 | 135 | 145 | 167 | 186 | 207 | 217 | 238 |

- 延迟随 cand 平滑增长，每增 1 候选 ≈ +14ms（thr=6）
- 线程 3→6 持续收益，6→8 几乎持平
- tok（上下文长度）每增 1 仅 +~5ms

### 准确率（20000 样本，CPU Q4_K_M，同码词扫参）

**有效首选率**：LLM 在同码词中将正确词排到第一位的概率。同码词只有一个时自动正确（无竞争），正确词不在前 N 候选时自动错误。指标反映 LLM 在真实同码竞争中的排序能力。

| tok\cand | cand=2 | cand=3 | cand=4 | cand=5 | cand=6 | cand=7 | cand=8 | cand=9 |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1 | 83.8 | 84.1 | 84.3 | 84.3 | 84.3 | 84.3 | 84.3 | 84.3 |
| 2 | 86.1 | 87.6 | 88.2 | 88.4 | 88.4 | 88.5 | 88.6 | 88.6 |
| 3 | 87.1 | 88.9 | 89.7 | 89.9 | 90.0 | 90.2 | 90.2 | 90.2 |
| 4 | 87.7 | 89.8 | 90.7 | 90.9 | 91.1 | 91.3 | 91.3 | 91.3 |
| 5 | 88.1 | 90.5 | 91.3 | 91.6 | 91.8 | 92.0 | 92.1 | 92.1 |
| 6 | 88.6 | 91.0 | 91.9 | 92.3 | 92.5 | 92.6 | 92.7 | 92.7 |
| 7 | 88.8 | 91.4 | 92.3 | 92.6 | 92.9 | 93.0 | 93.1 | 93.1 |
| 8 | 88.9 | 91.6 | 92.6 | 93.0 | 93.2 | 93.4 | 93.4 | 93.5 |
| 9 | 89.1 | 92.0 | 92.9 | 93.3 | 93.5 | 93.7 | 93.8 | 93.8 |
| **10** | **89.2** | **92.1** | **93.0** | **93.4** | **93.6** | **93.8** | **93.9** | **93.9** |
| 11 | 89.2 | 92.2 | 93.1 | 93.5 | 93.8 | 94.0 | 94.0 | 94.0 |
| 12 | 89.3 | 92.2 | 93.2 | 93.7 | 93.9 | 94.1 | 94.2 | 94.2 |
| 13 | 89.3 | 92.2 | 93.3 | 93.8 | 94.0 | 94.2 | 94.3 | 94.3 |
| 14 | 89.3 | 92.2 | 93.3 | 93.7 | 94.0 | 94.2 | 94.2 | 94.3 |
| 15 | 89.4 | 92.3 | 93.4 | 93.8 | 94.0 | 94.2 | 94.3 | 94.4 |
| 16 | 89.3 | 92.2 | 93.2 | 93.6 | 93.9 | 94.1 | 94.2 | 94.3 |
| 17 | 89.5 | 92.3 | 93.4 | 93.9 | 94.2 | 94.4 | 94.4 | 94.5 |
| 18 | 89.3 | 92.2 | 93.4 | 93.9 | 94.2 | 94.4 | 94.4 | 94.5 |
| 19 | 89.4 | 92.3 | 93.3 | 93.8 | 94.1 | 94.2 | 94.2 | 94.3 |
| 20 | 89.3 | 92.1 | 93.2 | 93.7 | 94.0 | 94.2 | 94.2 | 94.3 |

**关键结论：**
- 生产默认 **10tok/5cand = 93.4%**，与独立 1000 样本验证（93.2%）高度一致
- tok=1→5 跳升 ~7pp，5→10 微升 ~2pp，**10→20 饱和**——10 tok 已是最优上文窗口
- cand 增至 9 时达 93.9%，但每增 1 候选延迟 +~13ms，5→9 的 0.5pp 收益不划算
- 天花板 ~94.3%（tok≈13-15），是 Qwen3.5-0.8B Q4_K_M 在此任务上的上限
- 评估方法：wiki 语料 jieba 分词 + dict 同码词采样，分层并行解码（与生产一致），CPU 后端总耗时 7.7h

> 延迟主因是候选数而非上下文长度。最坏情况下（全部 2-token 候选），每增 1 候选延迟 +~14ms（thr=6）。线程 6→8 几乎无收益。

### 2B 模型对比（20000 样本，CPU Q4_K_M）

Qwen3.5-2B Q4_K_M (1.3GB) vs 0.8B (508MB)，10tok/5cand：

| tok\cand | cand=2 | cand=3 | cand=4 | cand=5 |
|:---:|:---:|:---:|:---:|:---:|
| 1 | 83.9 | 84.6 | 84.9 | 84.9 |
| 2 | 86.4 | 88.1 | 88.8 | 88.9 |
| 3 | 87.6 | 89.4 | 90.3 | 90.5 |
| 4 | 88.1 | 90.2 | 91.2 | 91.4 |
| 5 | 88.4 | 90.8 | 91.8 | 92.1 |
| 6 | 88.7 | 91.1 | 92.3 | 92.6 |
| 7 | 88.9 | 91.5 | 92.7 | 93.0 |
| 8 | 89.1 | 91.6 | 92.8 | 93.2 |
| 9 | 89.2 | 91.9 | 93.1 | 93.4 |
| 10 | 89.3 | 92.1 | 93.3 | 93.7 |

| | 0.8B | 2B | 差异 |
|------|:---:|:---:|:---:|
| 准确率 (10tok/5cand) | 93.4% | 93.7% | +0.3pp |
| CPU 延迟 | ~43ms | ~130ms | 3× |
| 模型大小 | 508MB | 1.3GB | 2.6× |

**结论：2B 几乎无优势**，+0.3pp 不抵 3× 延迟和 2.6× 体积。0.8B 是最优选择。

### 单字 3 码首选率（5535 样本，10tok/5cand）

单字只取"单编码字"（无简码、前 2 码唯一、有 3 码形码），消除多音字编码歧义后评测：

| | 基线（dict 序） | LLM 重排 | 提升 |
|------|:---:|:---:|:---:|
| 含 W=1 | 89.8% | **96.8%** | +7.0pp |
| 仅 W≥2（真实竞争） | 83.6% | **94.8%** | +11.2pp |

单字同码竞争核心在形码，LLM 通过上文区分形码变体效果显著。

## 安装（三步）

### 第一步：下载模型

打开 https://www.modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/files

点击下载 `Qwen3.5-0.8B-Q4_K_M.gguf`（约 500MB），放到 `D:\gguf_models\`。

> 放其他路径需在 schema 中设置 `model_path` 或配置环境变量。

### 第二步：复制插件

**CPU（所有机器可用，零依赖）：** 将 `user\rime_llm.dll` 复制到小狼毫安装目录（需管理员）：

```
user\rime_llm.dll  →  C:\Program Files\Rime\weasel-0.17.4\
```

**GPU（需 NVIDIA 显卡 + CUDA Toolkit 12.8，更快更稳定）：**

1. 安装 [CUDA Toolkit 12.8](https://developer.nvidia.com/cuda-12-8-0-download-archive)
2. 复制 `user\` 下所有 DLL 到小狼毫目录
3. 从 CUDA Toolkit 安装目录（如 `C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8\bin\`）复制以下文件到小狼毫目录：
   - `cudart64_12.dll`
   - `cublas64_12.dll`
   - `cublasLt64_12.dll`

```
user\rime_llm_cuda.dll  →  C:\Program Files\Rime\weasel-0.17.4\
user\ggml*.dll          →  ...（llama.cpp 依赖）
user\llama.dll          →  ...
<CUDA>\bin\cudart64_12.dll   →  ...（CUDA runtime）
<CUDA>\bin\cublas64_12.dll   →  ...（cuBLAS）
<CUDA>\bin\cublasLt64_12.dll →  ...
```

> ⚠️ 需在 NVIDIA 控制面板中将 `WeaselServer.exe` 设为「最高性能优先」，否则延迟波动严重。CUDA 版本必须为 12.8，其他版本未经测试。

插件默认 6 线程 + 10 token 上文，通常无需调整。如需自定义见下方配置参数。

### 第三步：配置 RIME

1. 将 `user\` 下的两个 `.lua` 文件复制到方案 `lua\` 目录
2. 在 `schema.yaml` 中添加：

```yaml
engine:
  processors:
    - lua_processor@*llm_processor
  filters:
    - lua_filter@*llm_filter
```

3. 右键小狼毫 → **重新部署**

LLM 选中的候选显示 `AI`。事件日志：

```powershell
Get-Content "$env:TEMP\rime_llm_events.txt" -Tail 5
```

每行格式：`时间|计数|编码|候选列表|上文|LLM结果|延迟ms`

## 配置参数

在方案的 `schema.yaml` 中配置（全部可选）：

```yaml
llm_rerank:
  min_code_len: 4      # 最小编码长度触发 LLM
  min_tokens: 1        # 最少上文 token 才重排
  max_tokens: 10       # 截取的上文 token 数（1-20），10 为性价比最优点
  max_candidates: 5    # 并行评分候选数（2-9），5 为延迟/准确率最佳平衡
  # cpu_cores: 0      # 可选。CPU 线程数，不设置=7（实测多台饱和）（max(4,ceil(总线程/3))）
  # model_path: ""     # 可选。模型路径，不设置=内置默认 Qwen3.5-0.8B Q4_K_M。换模型只需改此处
  backend: cpu         # "cpu" 或 "gpu"（需对应 DLL 已部署）
```

| 参数 | 默认 | 说明 |
|------|:---:|------|
| `min_code_len` | 4 | 编码达到此长度才触发 LLM |
| `min_tokens` | 1 | 上文 token 不够时不重排 |
| `max_tokens` | 10 | 截取的上文 token 数（10→17 仅 +1.1pp 但 CPU 延迟翻倍，10 为性价比最优点） |
| `max_candidates` | 5 | 并行评分候选数（5→9 仅 +0.5pp 但延迟翻倍，5 为最佳平衡） |
| `cpu_cores` | auto | CPU 线程数。不设置=7（实测多台饱和）：`max(4, ceil(总线程数/3))`，如 20 线程→7 |
| `model_path` | (内置默认) | 模型路径。不设置=Lua/C++ 双重默认。换模型只需在 schema 中设置此项 |
| `backend` | cpu | `cpu` 或 `gpu`，需对应 DLL 已部署到小狼毫目录 |

## 目录结构

```
rime-llm-rerank\
├── user\                      # 用户安装文件（复制到 RIME）
│   ├── llm_filter.lua          #   候选重排 filter
│   ├── llm_processor.lua       #   上屏文字收集 + 预解码 processor
│   ├── rime_llm.dll           #   预编译 CPU 插件
│   ├── rime_llm_cuda.dll      #   预编译 GPU 插件（可选）
│   └── *.dll                  #   llama.cpp + CUDA 依赖 DLL
├── cpp\                       # 源码 + Lua 嵌入
│   ├── rime_llm.cpp           #   CPU 插件源码
│   ├── rime_llm_cuda.cpp      #   GPU 插件源码
│   ├── CMakeLists.txt         #   CMake 配置（CPU + GPU 目标）
│   └── l*.c / l*.h            #   Lua 5.4 源码
└── README.md
```

## 调试接口

C++ 插件提供 `get_scores()` 方法，在 `score()` 调用后返回 `{[候选词] = 分数}` 的 Lua 表。仅用于调试和分析，Lua filter 层不消费。

```lua
local ranked = llm.score(ctx, cands)     -- 排序表（正常使用）
local scores = llm.get_scores()          -- 数值分数（调试用）
```

## 常见问题

**Q: CPU 延迟异常？** 正常（全部 2-token 候选）5 候选 ~178ms，9 候选 ~235ms（thr=6）。超过 300ms 检查 CPU 是否被占满或线程数配置。默认7（实测多台饱和）线程数 = `max(4, ceil(总线程/3))`，可按需手动调大。

**Q: GPU 延迟波动大？** 检查 NVIDIA 控制面板是否为 `WeaselServer.exe` 设置了「最高性能优先」。未设置时 GPU 在 P8（待机）和 P0（性能）之间频繁切换，P8→P0 转换耗时 50-200ms，导致延迟从 30ms 跳到 200ms。

**Q: 如何关闭？** 将 `rime_llm*.dll` 重命名为其他后缀（如 `.dll.bak`），重新部署即恢复字典序。LLM 插件仅占约 497 MB 内存（GPU 版约 1.2GB 显存），对现代电脑影响不大，建议常驻。

## 编译

需要 Visual Studio Build Tools 2022 + CMake + Ninja + llama.cpp。

编译前需修改 `CMakeLists.txt` 中的 llama.cpp 路径。

**CPU（链接标准 llama.cpp）：**

```powershell
cd cpp
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -S . -B build_cpu
ninja -C build_cpu rime_llm
```

**GPU（需 CUDA 12.8 + llama.cpp CUDA build）：**

```powershell
# 先编译 llama.cpp CUDA 版: cmake -G Ninja -DGGML_CUDA=ON -S . -B build-cuda
cd cpp
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -S . -B build_gpu ^
  -DLLAMA_CUDA_ROOT="D:/llama.cpp-mirror/build-cuda"
ninja -C build_gpu rime_llm_cuda
```

编译得到的 DLL 需复制到小狼毫程序目录。部署前需先**退出小狼毫**（右键托盘图标 → 退出），复制 DLL 及其依赖，再重新启动。

## 开发者笔记

插件用 C 调用 Lua 5.4 嵌入式 API（`luaopen_*` 入口），链接 llama.cpp 完成推理。以下按代码骨架走一遍关键步骤和踩过的坑。

### 1. 框架：Lua 模块入口 + 异步模型加载

```cpp
// luaopen_rime_llm: require("rime_llm") 的入口
extern "C" __declspec(dllexport) int luaopen_rime_llm(lua_State *L) {
    lua_newtable(L);
    // 注册 score / is_ready / get_scores 等方法
    lua_pushcfunction(L, lua_score); lua_setfield(L, -2, "score");
    load_model_async();  // 后台线程加载模型，不阻塞输入法启动
    return 1;
}
```

`load_model_async()` 在独立线程中调用 `llama_model_load_from_file` + `llama_new_context_with_model`，加载完成后设置 `g_loaded=true`。Lua 调用 `score()` 时如果模型尚未就绪则返回 nil，filter 层会跳过重排（不回退 CPU，保持静默）。

### 2. 核心：分层并行解码

Naive 方案每候选独立 decode「上下文+候选词」，N 候选需要 N+1 次 `llama_decode`，延迟 ~274ms。分层算法的关键洞察：**所有候选共享同一段上下文**，ctx 只需 decode 一次。

```cpp
static void score_batch(ctx_ids, cands, scores_out) {
    int ctx_len = ctx_ids.size(), vs = llama_n_vocab(g_vocab);

    // Step 1: decode ctx 一次，保存最后一帧 logits
    llama_memory_clear(mem, false);  // 仅重置元数据，不归零（见第 5 节）
    llama_batch ctx_batch = llama_batch_init(ctx_len, 0, 1);
    // ... fill tokens, pos, seq_id ...
    ctx_batch.logits[ctx_len - 1] = 1;  // 只取最后一帧
    llama_decode(ctx, ctx_batch);
    float* ctx_logits = llama_get_logits_ith(ctx, ctx_len - 1);
    // → 所有候选的 P(tok0|ctx) 从这一帧计算（共享，省 N×ctx decode）
    for (int i = 0; i < n_cands; i++)
        ce_sum[i] = cross_entropy(ctx_logits, vs, cands[i][0]);

    // Step 2: KV copy → seq 1..M，并行 decode 各候选的首 token
    for (int s = 0; s < M; s++) {
        llama_memory_seq_cp(mem, 0, s+1, 0, -1);  // seq 0 的 KV 复制到 seq s+1
    }
    // batch 中 M 个 seq 各放一个候选的首 token，一次 decode 完成全部
    llama_decode(ctx, b2);
    for (int s = 0; s < M; s++)
        ce_sum[idx2[s]] += cross_entropy(llama_get_logits_ith(ctx, s), ...);

    // Step 3: 同上，继续在各自 seq 上 decode 第二个 token（如有三 token 候选）
    // 总共最多 3 次 decode，与候选数无关
}
```

**坑：`llama_get_logits_ith(ctx, i)` 的 `i` 是 batch 数组索引，不是"第 i 个标记了 logits 的 token"。** 在单序列场景 `ith = ctx_len-1+j`（预测 cand[j] 需要看处理完 ctx + cand[0..j-1] 后的 logits）；多序列场景 `ith = s`（batch 中第 s 个序列）。此前所有低准确率（~40%）均源于误用 `ith=j`。

### 3. SSM 跨序列干扰

Qwen3.5 是 Attention + SSM 混合架构。Mamba 层的隐状态在 `llama_decode` 的多序列 batch 中会跨序列耦合——全量 ctx 多序列时，各序列的正确词 logits 被其他序列的 token 污染，准确率仅 71%。

分层算法将每序列的增量限制为 1 个 token，SSM 干扰降至 ~0.5%，准确率恢复到 98.5%。不要试图在 GPU 扫参中做跨样本超大 batch——`bench_gpu2` 已证实 250+ seq 时准确率掉到 74%。

### 4. GPU P0 锁频

GPU 待机 P8（210MHz/1.6W），推理时升到 P0（2250MHz/19W），转换耗时 50-200ms。打字间隔秒级时每次推理都触发升降频，延迟在 46-234ms 剧烈波动。**必须 NVIDIA 控制面板锁定 P0 或用 `nvidia-smi -lgc 2250`。** 锁定后延迟稳定 ~33ms（σ≈3ms）。

### 5. `llama_memory_clear` 的第二个参数

`true` = 零化整个 KV cache。生产 DLL 每击键一次无所谓，但 benchmark 做 40 万次 decode 时，归零操作会让 GPU 持续满载、笔记本散热崩溃。统一使用 `false`（仅重置元数据标记为"未使用"）。新序列的因果注意力掩码天然隔离旧数据，无需显式归零。

### 6. 大规模扫参的稳定性

`bench_sweep2`（20000 样本 × 20 tok × 9 cand）曾两次系统死机：
- 第一次：3.2M 次独立 `layered_score` 调用 + `memory_clear(true)`，GPU 过载
- 第二次：优化到 400K 次 decode + `false`，但未节流，笔记本 RTX 4060 连续 P0 超 1 小时触发过热保护
- 最终方案：400K decode + `false` + 每 10 样本 `Sleep(100ms)` + 每 500 样本 checkpoint，稳定跑完 ~2 小时

### 7. 语料采集：码分配时机

`llm_processor.lua` 中 `pending_code`（手动选词码）和 `last_full`（4 码顶屏码）在**输入变空的瞬间**捕获。但一次上屏事件可能包含多个条目（词+标点+空格），码只应分配给含中文的条目，纯英文/标点应跳过，否则"d, c, lua"等会拿到前一个中文词的码。单字 3 码截为前 2 码——第 3 码是形码，由字本身决定，对训练无额外信息。
