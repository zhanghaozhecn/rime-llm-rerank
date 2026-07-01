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

## 你需要

- Windows 系统
- 约 1GB 磁盘空间（模型 500MB）
- C++ 后端 ~800MB 内存 / Python 后端 ~1.5GB

## 安装（三步）

### 第一步：下载模型

打开 https://www.modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/files

点击下载 `Qwen3.5-0.8B-Q4_K_M.gguf`（约 500MB），放到 `D:\gguf_models\` 目录下。

> 放其他路径需设环境变量 `RIME_LLM_MODEL` 指向模型文件。

### 第二步：选择后端

#### C++ 后端（推荐）

无需安装任何依赖。将 `cpp\user\rime_llm.dll` 复制到小狼毫安装目录：

```
复制: cpp\user\rime_llm.dll
   →  C:\Program Files\Rime\weasel-0.17.4\
```

> 需要管理员权限。不想用 C++ 后端时，删除此 DLL 即可。

#### Python 后端（备选）

1. 安装 [Python 3.12.10](https://www.python.org/downloads/release/python-31210/)（勾选 Add to PATH）
2. 安装 [Visual Studio Build Tools 2022](https://visualstudio.microsoft.com/visual-cpp-build-tools/)（勾选「使用 C++ 的桌面开发」+「C++ CMake tools」）
3. 打开 PowerShell，运行：

```powershell
pip install pywin32 numpy modelscope
$env:CMAKE_ARGS="-DGGML_AVX2=ON"
pip install llama-cpp-python==0.3.30 --no-cache-dir
```
4. 将 `python\user\rime_pipe.dll` 复制到 `C:\Program Files\Rime\weasel-0.17.4\`
5. 双击 `python\user\start_server.bat` 启动后台服务

### 第三步：配置 RIME

1. 将 `common\` 下的两个 `.lua` 文件复制到 RIME 方案 `lua\` 目录
2. 在方案的 `schema.yaml` 中添加：

```yaml
engine:
  processors:
    - lua_processor@*llm_context
  filters:
    - lua_filter@*llm_rerank
```

3. 右键小狼毫托盘 → **重新部署**

LLM 选中的候选显示 ⚡。滤器自动检测：有 C++ DLL 则优先使用，否则使用 Python 服务。

## 后端对比

| | C++ | Python |
|------|------|------|
| 安装 | 复制 DLL | 装 Python + 编译 |
| 启动 | 无需 | 双击 bat |
| 延迟 (4tok/4cand) | ~98ms | ~100ms |
| 开机启动 | 无需 | 设 startup 快捷方式 |

## 目录结构

```
rime-llm-rerank\
├── common\                   # 共用（两个后端都需要）
│   ├── llm_rerank.lua        #   候选重排滤器 (auto backend)
│   └── llm_context.lua       #   上屏文字收集
├── cpp\                      # C++ 后端
│   ├── user\
│   │   └── rime_llm.dll      #   预编译插件
│   └── dev\                  #   源码 + 构建（需 llama.cpp）
├── python\                   # Python 后端
│   ├── user\
│   │   ├── pipe_server.py    #   推理服务（4 进程）
│   │   ├── rime_pipe.dll     #   管道客户端
│   │   ├── start_server.bat
│   │   └── stop_server.bat
│   └── dev\
│       ├── rime_pipe.c       #   管道客户端源码
│       └── eval_and_analyze.py  # GPU 评估
├── schema-patch.yaml
└── README.md
```

## 常见问题

**Q: 如何确认正在运行？**
```powershell
Get-Content "$env:TEMP\rime_latency.txt"
# count=342  max=132ms  last=107ms  backend=cpp
```

**Q: 延迟异常？** 正常 80-130ms。超过 200ms 检查 CPU 是否被占满。
