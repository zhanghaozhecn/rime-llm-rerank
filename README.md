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

```
         ┌─────────────────────────────────────────────┐
  98% ─  │                              ▄▄▄▄▄▄▄▄▄▄▄▄▄ │ ← 二字词峰值 97.7%
  97% ─  │                     ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄ │
         │               ▄▄▄▄▄▄                      │
  96% ─  │          ▄▄▄▄▄                             │ ← 二字词 96.7% @ 4 tok
         │        ▄▄                                    │
  95% ─  │     ▄▄▄                                      │ ← 全词 95.7% @ 4 tok
         │   ▄▄                                         │
  94% ─  │▄▄                                            │
         │                                              │
  93% ─  │                                              │
         ├──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┤
          1  2  3  4  5  6  7  8  9 10 11 12 13 14 15+
                       上文 token 数
  ▄ 仅二字词    ─ 全词
```

| 上文 token | 1 | 2 | 3 | **4** | 6 | 8 | 10 | 15+ |
|:--------:|:-:|:-:|:-:|:--:|:-:|:-:|:--:|:---:|
| 仅二字词 | 94.0 | 95.6 | 96.5 | **96.7** | 97.3 | 97.6 | 97.5 | 97.7 |
| 全词 | 91.9 | 94.2 | 95.5 | **95.7** | 96.4 | 96.7 | 96.9 | 97.1 |

**结论：4 token 上文性价比最优。** 继续增加 token 收益递减：4→8 token 仅 +0.9pp，但推理耗时翻倍。

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
```

然后安装 llama-cpp-python。**关键说明**：预编译 wheel 使用了 **AVX-512 指令集**。AVX-512 并非「新旧 CPU」的区别——它只在少数 CPU 上可用（Intel 服务器 Xeon、11 代酷睿、AMD Zen 4），**绝大多数消费级 CPU 都没有 AVX-512**，包括近年新出的酷睿 Ultra。因此大部分用户需要从源码编译。

**先试预编译包**（如果你的 CPU 恰好支持 AVX-512，这一步就够了）：

```powershell
pip install llama-cpp-python==0.3.30 --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cpu
```

**如果预编译包装完启动失败**（`start_server.bat` 打开后 python 进程立即退出），说明 CPU 不支持 AVX-512（这是大多数情况，不是特例），继续走源码编译：

#### 从源码编译 llama-cpp-python（大多数用户需要这一步）

**① 安装 Visual Studio Build Tools**（提供 C++ 编译器）

1. 下载：https://visualstudio.microsoft.com/visual-cpp-build-tools/
2. 运行安装程序，勾选 **「使用 C++ 的桌面开发」**（Desktop development with C++）
3. 右侧额外勾选 **「C++ CMake tools for Windows」**
4. 点击安装，等待完成（约 3-5 GB）

**② 编译安装**（关闭 AVX-512，启用 AVX2）：

```powershell
# 先卸载预编译包（如果装了的话）
pip uninstall llama-cpp-python -y

# 设置编译选项：禁用 AVX-512，启用 AVX2（主流 CPU 都支持）
$env:CMAKE_ARGS="-DGGML_AVX512=OFF -DGGML_AVX2=ON -DGGML_NATIVE=OFF"

# 从源码安装（编译约 3-5 分钟）
pip install llama-cpp-python==0.3.30 --force-reinstall --no-cache-dir
```

**③ 验证安装成功**：

```powershell
python -c "from llama_cpp import Llama; print('安装成功')"
```

如果没报错，说明编译和安装都正确。

下载慢换清华源：`-i https://pypi.tuna.tsinghua.edu.cn/simple`

### 第二步：安装管道 DLL

将 `server\rime_pipe.dll` 复制到小狼毫安装目录（需管理员权限）：

```powershell
Copy-Item -Force server\rime_pipe.dll "C:\Program Files\Rime\weasel-0.17.4\"
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
