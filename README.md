# RIME LLM 候选重排

一个本地 AI 模型（Qwen3.5-0.8B），为任意 RIME **四码定长**方案（五笔、郑码、仓颉、拼读双拼等）提供打字时的智能候选排序。

LLM 与编码方案无关——它只看到最终的中文候选词列表。

## 效果与延迟

默认配置 **6 token 上文 + 3 候选**，Qwen3.5-0.8B Q4_K_M，CPU 推理。

| 延迟 | 值 |
|------|:---:|
| 中位数 | ~120ms |
| P95 | ~150ms |

### 准确率（10 万随机样本，含单候选，基线 85.4%）

| tok\cand | cand=2 | cand=3 | cand=4 | cand=5 |
|:---:|:---:|:---:|:---:|:---:|
| 3 | 91.2% | 92.5% | 92.9% | 93.2% |
| 4 | 91.8% | 93.3% | 93.8% | 94.1% |
| 5 | 92.1% | 93.8% | 94.3% | 94.6% |
| 6 | 92.6% | **94.3%** | 94.9% | 95.2% |
| 7 | 92.6% | 94.4% | 95.0% | 95.4% |
| 8 | 92.8% | 94.6% | 95.3% | **95.7%** |

> 更高候选数可进一步提升准确率（8tok/5cand 达 95.7%），但延迟会显著增加。

## 安装（三步）

### 第一步：下载模型

打开 https://www.modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/files

点击下载 `Qwen3.5-0.8B-Q4_K_M.gguf`（约 500MB），放到 `D:\gguf_models\`。

> 放其他路径需设环境变量 `RIME_LLM_MODEL`。

### 第二步：复制插件

将 `user\rime_llm.dll` 复制到小狼毫安装目录（需管理员）：

```
user\rime_llm.dll  →  C:\Program Files\Rime\weasel-0.17.4\
```

插件自动检测 CPU 线程数，无需配置。

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
  max_tokens: 6        # 截取的上文 token 数（1-20）
  max_candidates: 3    # 并行评分候选数（2-9）
  cpu_cores: 14        # CPU 线程数（省略则自动检测）
```

| 参数 | 默认 | 说明 |
|------|:---:|------|
| `min_code_len` | 4 | 编码达到此长度才触发 LLM |
| `min_tokens` | 1 | 上文 token 不够时不重排 |
| `max_tokens` | 6 | 截取的上文 token 数 |
| `max_candidates` | 3 | 并行评分候选数（2-9） |
| `cpu_cores` | auto | 线程数（省略则自动检测） |

## 目录结构

```
rime-llm-rerank\
├── user\                      # 用户安装文件（复制到 RIME）
│   ├── llm_rerank.lua         #   候选重排 filter
│   ├── llm_context.lua        #   上屏文字收集 processor
│   └── rime_llm.dll           #   预编译插件
├── cpp\                       # 源码 + Lua 嵌入
│   ├── rime_llm.cpp           #   插件主源码
│   ├── CMakeLists.txt         #   CMake 配置
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

**Q: 延迟异常？** 正常中位数 ~120ms，P95 ~150ms。超过 200ms 检查 CPU 是否被占满。

**Q: 如何关闭？** 双击 `user\llm_off.bat` 后重新部署即可临时禁用（仅跳过重排，不卸载 DLL）。恢复：双击 `user\llm_on.bat`。彻底删除：移除 `rime_llm.dll`。

## 编译

需要 Visual Studio Build Tools 2022 + CMake + llama.cpp。

编译前需修改 `CMakeLists.txt` 中的 llama.cpp 路径，指向你本机的 llama.cpp 仓库（需先编译 `libllama`）。

```powershell
cd cpp
cmake -G "Visual Studio 17 2022" -A x64 -S . -B build
cmake --build build --config Release
```

编译得到的 `build\Release\rime_llm.dll` 需要复制到小狼毫程序目录。由于小狼毫运行时会锁定该文件，部署前需先**退出小狼毫**（右键托盘图标 → 退出），复制 DLL，再重新启动。
