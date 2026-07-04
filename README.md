# RIME LLM 候选重排

一个本地 AI 模型（Qwen3.5-0.8B），为任意 RIME **四码定长**方案（五笔、郑码、仓颉、拼读双拼等）提供打字时的智能候选排序。

LLM 与编码方案无关——它只看到最终的中文候选词列表。

## 效果

测试条件：拼读双拼 4 码方案，Qwen3.5-0.8B Q4_K_M，CPU 推理。

| 场景 | 基线（字典序） | LLM 重排 | 提升 |
|------|:----------:|:--------:|:---:|
| Benchmark (10000 随机) | 86.9% | **95.7%** | +8.8pp |
| 赛文模拟打字 | 88.0% | **95.7%** | +7.7pp |
| **赛文真实打字** | 98.8% | **95.3%** | -3.5pp |

真实打字中字典基线很高（拼读双拼重码率低），LLM 主要用于纠正罕见歧义。

## 推理延迟

CPU 推理，自动检测线程数：

| 配置 | 延迟 |
|------|:---:|
| 4tok/4cand | ~120ms |
| 8tok/4cand | ~135ms |

## 安装（三步）

### 第一步：下载模型

打开 https://www.modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/files

点击下载 `Qwen3.5-0.8B-Q4_K_M.gguf`（约 500MB），放到 `D:\gguf_models\`。

> 放其他路径需设环境变量 `RIME_LLM_MODEL`。

### 第二步：复制插件

将 `cpp\user\rime_llm.dll` 复制到小狼毫安装目录（需管理员）：

```
cpp\user\rime_llm.dll  →  C:\Program Files\Rime\weasel-0.17.4\
```

插件自动检测 CPU 线程数，无需配置。

### 第三步：配置 RIME

1. 将 `common\` 下的两个 `.lua` 文件复制到方案 `lua\` 目录
2. 在 `schema.yaml` 中添加：

```yaml
engine:
  processors:
    - lua_processor@*llm_context
  filters:
    - lua_filter@*llm_rerank
```

3. 右键小狼毫 → **重新部署**

LLM 选中的候选显示 `AI`。延迟日志：

```powershell
Get-Content "$env:TEMP\rime_latency.txt"
# count=342  max=132ms  last=107ms
```

## 配置参数

在方案的 `schema.yaml` 中配置（全部可选）：

```yaml
llm_rerank:
  min_code_len: 4      # 最小编码长度触发 LLM
  min_tokens: 1        # 最少上文 token 才重排
  max_tokens: 4        # 截取的上文 token 数（1-20）
  max_candidates: 4    # 并行评分候选数（2-9）
  idle_clear_sec: 10   # 同应用闲置多少秒清空上文（5-300）
  cpu_cores: 14        # CPU 线程数（省略则自动检测）
```

| 参数 | 默认 | 说明 |
|------|:---:|------|
| `min_code_len` | 4 | 编码达到此长度才触发 LLM |
| `min_tokens` | 1 | 上文 token 不够时不重排 |
| `max_tokens` | 4 | 截取的上文 token 数 |
| `max_candidates` | 4 | 并行评分候选数（2-9） |
| `idle_clear_sec` | 10 | 同应用闲置 N 秒清空上文 |
| `cpu_cores` | auto | 线程数（省略则自动检测） |

## 目录结构

```
rime-llm-rerank\
├── common\                   # 滤器文件（复制到 RIME lua\）
│   ├── llm_rerank.lua        #   候选重排（标记 "AI"）
│   └── llm_context.lua       #   上屏文字收集（按应用隔离，10s 闲置清除）
├── cpp\
│   ├── user\
│   │   └── rime_llm.dll      #   预编译插件（复制到 RIME 目录）
│   └── dev\                  #   源码 + 构建
│       ├── rime_llm.cpp       #   插件主源码
│       ├── CMakeLists.txt     #   CMake 配置
│       └── rebuild.bat        #   一键编译+部署
└── README.md
```

## 常见问题

**Q: 延迟异常？** 正常 80-150ms。超过 200ms 检查 CPU 是否被占满。

**Q: 如何关闭？** 删除 `C:\Program Files\Rime\weasel-0.17.4\rime_llm.dll`，重新部署即恢复字典序。

**Q: 标记变成 "AI" 了？** 是的，GPU 路线已放弃，统一用 "AI" 标记 LLM 选中的候选。

## 编译

需要 Visual Studio Build Tools 2022 + CMake + llama.cpp 编译产物。

llama.cpp 镜像：`D:\llama.cpp-mirror\`（`git clone https://gitcode.com/ggerganov/llama.cpp.git`）

```powershell
cd cpp\dev
cmake -G "Visual Studio 17 2022" -A x64 -S . -B build
cmake --build build --config Release
```

或直接运行 `rebuild.bat` 一键编译并部署到 RIME。
