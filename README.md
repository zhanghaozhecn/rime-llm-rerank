# RIME LLM 候选重排

一个本地 AI 模型（Qwen3.5-0.8B），为任意 RIME **四码定长**方案（五笔、郑码、仓颉、拼读双拼等）提供打字时的智能候选排序。

LLM 与编码方案无关——它只看到最终的中文候选词列表。

## 效果与延迟

默认配置 **10 token 上文 + 5 候选**，Qwen3.5-0.8B Q4_K_M。

采用分层并行解码：上下文仅处理一次，候选 token 多序列并行 decode（最多 3 次 decode）。

| 指标 | CPU | GPU (P0) |
|------|:---:|:---:|
| 延迟 (10tok/5cand) | ~108ms | **~33ms** |
| 延迟 (10tok/9cand) | ~162ms | — |
| 准确率 (6tok/5cand) | 98.5% | 98.5%（同算法） |
| 内存/VRAM | ~497MB | ~1.2GB |
| 依赖 | 零 | NVIDIA GPU + CUDA 12 |

> GPU 版需在 NVIDIA 控制面板中将 `WeaselServer.exe` 设为「最高性能优先」，否则 GPU 降频导致延迟剧烈波动（50-200ms）。

### 准确率（10 万随机样本 GPU bf16，基线 85.4%）

| tok\cand | cand=2 | cand=3 | cand=4 | cand=5 |
|:---:|:---:|:---:|:---:|:---:|
| 3 | 91.2% | 92.5% | 92.9% | 93.2% |
| 4 | 91.8% | 93.3% | 93.8% | 94.1% |
| 5 | 92.1% | 93.8% | 94.3% | 94.6% |
| 6 | 92.6% | 94.3% | 94.9% | **95.2%** |
| 7 | 92.6% | 94.4% | 95.0% | 95.4% |
| 8 | 92.8% | 94.6% | 95.3% | **95.7%** |

> 延迟每增 1 候选约 +13ms，每增 1 线程约 −5ms（1→6），上下文长度几乎不影响延迟。

## 安装（三步）

### 第一步：下载模型

打开 https://www.modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/files

点击下载 `Qwen3.5-0.8B-Q4_K_M.gguf`（约 500MB），放到 `D:\gguf_models\`。

> 放其他路径需设环境变量 `RIME_LLM_MODEL`。

### 第二步：复制插件

**CPU（所有机器可用，零依赖）：** 将 `user\rime_llm.dll` 复制到小狼毫安装目录（需管理员）：

```
user\rime_llm.dll  →  C:\Program Files\Rime\weasel-0.17.4\
```

**GPU（需 NVIDIA 显卡 + CUDA 12，更快更稳定）：** 复制 `user\` 下所有 DLL 到同一目录：

```
user\rime_llm_cuda.dll  →  C:\Program Files\Rime\weasel-0.17.4\
user\ggml*.dll          →  ...（llama.cpp 依赖）
user\llama.dll          →  ...
user\cudart64_12.dll    →  ...（CUDA runtime）
user\cublas*.dll        →  ...（cuBLAS）
```

> ⚠️ GPU 版部署后需在 NVIDIA 控制面板中将 `WeaselServer.exe` 的电源管理模式设为「最高性能优先」，否则延迟波动严重。

插件默认 6 线程 + 10 token 上文，通常无需调整。如需自定义见下方配置参数。

### 第三步：配置 RIME

1. 将 `user\` 下的两个 `.lua` 文件复制到方案 `lua\` 目录
2. 在 `schema.yaml` 中添加：

```yaml
engine:
  processors:
    - lua_processor@*llm_context
  filters:
    - lua_filter@*llm_rerank
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
  max_tokens: 10       # 截取的上文 token 数（1-20）
  max_candidates: 5    # 并行评分候选数（2-9）
  cpu_cores: 6         # CPU 线程数（1-8，默认 6）
  backend: cpu         # "cpu" 或 "gpu"（需对应 DLL 已部署）
```

| 参数 | 默认 | 说明 |
|------|:---:|------|
| `min_code_len` | 4 | 编码达到此长度才触发 LLM |
| `min_tokens` | 1 | 上文 token 不够时不重排 |
| `max_tokens` | 10 | 截取的上文 token 数（上下文长度几乎不影响延迟） |
| `max_candidates` | 5 | 并行评分候选数（每增 1 候选 +~13ms） |
| `cpu_cores` | 6 | 线程数（1→6 持续收益，6→8 平坦） |
| `backend` | cpu | `cpu` 或 `gpu`，需对应 DLL 已部署到小狼毫目录 |

## 目录结构

```
rime-llm-rerank\
├── user\                      # 用户安装文件（复制到 RIME）
│   ├── llm_rerank.lua         #   候选重排 filter
│   ├── llm_context.lua        #   上屏文字收集 processor
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

**Q: CPU 延迟异常？** 正常 5 候选 ~108ms，9 候选 ~162ms。超过 200ms 检查 CPU 是否被占满或线程数配置是否合理。

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
