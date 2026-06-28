# RIME LLM 候选重排

一个本地 AI 模型（Qwen3.5-0.8B），为任意 RIME **四码定长**方案（五笔、郑码、仓颉、拼读双拼等）提供打字时的智能候选排序。

LLM 与编码方案无关——它只看到最终的中文候选词列表。

## 效果（拼读双拼 100 万样本实测）

| 指标 | 关闭 | 开启 | 提升 |
|------|:----:|:----:|:---:|
| 首选命中率 | 82.8% | **94.0%** | +11.3pp |
| 打字延迟 | 0ms | **~100ms** | 几乎无感 |

## 你需要

| 条件 | 说明 |
|------|------|
| Windows 系统 | 仅支持 Windows（命名管道通信） |
| Python 3.12 | 必须 3.12（llama-cpp-python 不支持 3.14+）。安装时勾选「Add to PATH」 |
| 磁盘空间 | ~1.5 GB（模型 500MB + Python 依赖 ~500MB） |
| 内存 | ~1.5 GB 可用内存 |

## 安装步骤

### 第一步：安装 Python 依赖

```powershell
pip install pywin32 numpy modelscope

# 方案一：预编译包（不支持 AVX-512 的旧 CPU 可能失败）
pip install llama-cpp-python==0.3.30 --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cpu

# 方案二：方案一失败时，从源码编译（需先装 VS Build Tools）
#   1. 下载安装 Visual Studio Build Tools：https://visualstudio.microsoft.com/visual-cpp-build-tools/
#      （勾选「C++ 桌面开发」）
#   2. $env:CMAKE_ARGS="-DGGML_AVX512=OFF -DGGML_AVX2=ON -DGGML_NATIVE=OFF"
#      pip install llama-cpp-python==0.3.30 --force-reinstall --no-cache-dir
```

> 预编译 wheel 使用 AVX-512 指令集，旧 CPU（10 代酷睿之前）可能不支持。如果 `start_server.bat` 启动后 python 进程立即退出，说明 CPU 不兼容，换方案二。

下载慢换清华源：`-i https://pypi.tuna.tsinghua.edu.cn/simple`

### 第二步：安装管道 DLL

将 `server\rime_pipe.dll` 复制到小狼毫安装目录（需管理员权限）：

```powershell
copy /Y server\rime_pipe.dll "C:\Program Files\Rime\weasel-0.17.4\rime_pipe.dll"
```

### 第三步：下载模型（约 500MB）

```powershell
mkdir d:\gguf_models
python -c "from modelscope import snapshot_download; import shutil,glob,os; d=snapshot_download('unsloth/Qwen3.5-0.8B-GGUF', cache_dir='d:/gguf_models', allow_file_pattern='*Q4_K_M*'); [shutil.move(f, 'd:/gguf_models/'+os.path.basename(f)) for f in glob.glob(d+'/*.gguf')]"
```

下载完成后，模型文件位于 `d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf`。

### 第四步：配置你的输入法方案

将 `lua\` 目录下的两个 `.lua` 文件复制到你的 RIME 方案 `lua\` 文件夹中。
在你的方案 `schema.yaml` 中添加：

```yaml
engine:
  processors:
    - lua_processor@*llm_context
  filters:
    - lua_filter@*llm_rerank
```

### 第五步：启动服务 + 重新部署

双击 `server\start_server.bat` → 右键小狼毫托盘 → **重新部署**。LLM 选中的候选显示 ⚡。

## 启停

| 操作 | 方法 |
|------|------|
| 启动 | 双击 `server\start_server.bat`（窗口自动关闭，后台运行） |
| 停止 | 双击 `server\stop_server.bat` |
| 临时关闭 | 创建文件 `%TEMP%\rime_llm_off`（删除即恢复） |

## 目录结构

```
rime-llm-rerank\
├── lua\
│   ├── llm_context.lua      # 收集上屏文字
│   └── llm_rerank.lua       # LLM 候选重排
├── server\
│   ├── pipe_server.py        # 推理服务（4 进程并行）
│   ├── rime_pipe.dll         # 命名管道客户端
│   ├── start_server.bat      # 启动
│   └── stop_server.bat       # 停止
├── schema-patch.yaml         # 配置示例
├── dev/                        # 开发者工具
│   ├── rime_pipe.c             #   C 管道客户端源码
│   ├── eval_and_analyze.py     #   GPU 评估 + 失败分析
│   ├── bench_tok_cand.py       #   延迟基准
│   └── bench_configs.py        #   配置基准
└── README.md
```

## 常见问题

**Q: 启动服务后打字没变化？**
A: 右键小狼毫 → 重新部署。确认 `lua\` 文件已复制到方案目录。

**Q: 如何确认正在运行？**
```powershell
Get-Content "$env:TEMP\rime_latency.txt"
# 正常输出: count=342  max=132ms  last=107ms
```

**Q: 延迟超过 200ms？**
A: 检查是否有其他程序占满 CPU。正常范围 80-130ms。

**Q: 开机自动启动？**
A: 右键 `start_server.bat` → 创建快捷方式 → 把快捷方式放到 `shell:startup` 文件夹。
