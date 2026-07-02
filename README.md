# RIME LLM 候选重排

一个本地 AI 模型（Qwen3.5-0.8B），为任意 RIME **四码定长**方案（五笔、郑码、仓颉、拼读双拼等）提供打字时的智能候选排序。

LLM 与编码方案无关——它只看到最终的中文候选词列表。

## 效果

测试条件：拼读双拼 4 码方案，10000 随机样本，4 token 上文，无固顶词，RTX 4060。

| 模式 | 基线（字典序） | LLM 重排 | 提升 |
|------|:----------:|:--------:|:---:|
| 仅二字词 | 92.1% | **96.7%** | +4.6pp |
| 全词 | 86.9% | **95.7%** | +8.9pp |

### 上文长度对准确率的影响

| 上文 token | 1 | 2 | 3 | **4** | 6 | 8 | 10 | 15+ |
|:--------:|:-:|:-:|:-:|:--:|:-:|:-:|:--:|:---:|
| 仅二字词 | 94.0 | 95.6 | 96.5 | **96.7** | 97.3 | 97.6 | 97.5 | 97.7 |
| 全词 | 91.9 | 94.2 | 95.5 | **95.7** | 96.4 | 96.7 | 96.9 | 97.1 |

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

LLM 选中的候选显示 ⚡。延迟 ~98ms。延迟日志：

```powershell
Get-Content "$env:TEMP\rime_latency.txt"    # count=342  max=132ms  last=107ms  backend=cpp
```

## 配置参数

在方案的 `schema.yaml` 中配置（全部可选，不设则用默认值）：

```yaml
llm_rerank:
  code_pattern: "^[a-z]{4}$"    # 正则：匹配才触发 LLM（如 "^[a-z]{3,4}$"）
  min_tokens: 2                 # 最少上文 token 才重排（1 或 2）
  max_tokens: 4                 # 截取的上文 token 数（1-20）
  max_candidates: 9             # 传给 LLM 的候选数
  cpu_cores: 0                  # 物理核数（0 = 自动检测）
  cpu_threads: 0                # 逻辑线程数（0 = 自动检测）
```

| 参数 | 默认 | 说明 |
|------|:---:|------|
| `code_pattern` | `^[a-z]{4}$` | 只对匹配的编码触发 LLM |
| `min_tokens` | 1 | 上文 token 不够时不重排 |
| `max_tokens` | 4 | 截取的上文 token 数，越大越慢 |
| `max_candidates` | 4 | 并行评分候选数（2-9） |
| `cpu_cores` | 0 | 物理核数（0=自动，检测失败→4） |
| `cpu_threads` | 0 | 逻辑线程数（0=自动，检测失败→8） |

## 目录结构

```
rime-llm-rerank\
├── common\                   # 滤器文件（复制到 RIME lua\）
│   ├── llm_rerank.lua        #   候选重排
│   └── llm_context.lua       #   上屏文字收集
├── cpp\
│   ├── user\
│   │   └── rime_llm.dll      #   预编译插件（复制到 RIME 目录）
│   └── dev\                  #   源码（需 llama.cpp 才能编译）
├── schema-patch.yaml
└── README.md
```

## 常见问题

**Q: 延迟异常？** 正常 80-130ms。超过 200ms 检查 CPU 是否被占满。

**Q: 如何关闭？** 删除 `C:\Program Files\Rime\weasel-0.17.4\rime_llm.dll`，重新部署即恢复字典序。
