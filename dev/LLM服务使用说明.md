# 拼读双拼 LLM 候选重排 — 使用说明

## 这是什么？

一个本地运行的 AI 模型（Qwen3.5-0.8B），在你打字时自动根据上文选择最合适的候选词。

**效果**：全词首选命中率 88% → 96%，体感延迟 ~106ms。

## 你需要有的

| 东西 | 路径 / 说明 |
|------|-------------|
| 模型文件 | `d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf`（约 500MB） |
| Python | 需装 `llama-cpp-python`, `pywin32`, `numpy` |
| 管道 DLL | `C:\Program Files\Rime\weasel-0.17.4\rime_pipe.dll` |

## 使用步骤

### 1. 启动服务

双击 `start_server.bat`，窗口会自动消失（服务在后台运行）。

### 2. 重新部署

右键小狼毫托盘 → **重新部署**。

### 3. 开始打字

切换到拼读双拼方案。LLM 选中的候选显示 ⚡，固顶词显示 ⛯，两者重合时显示 ⛯⚡。

### 4. 停止服务

双击 `stop_server.bat`。

## 架构

```
RIME engine filters (按序):
  hint_filter → llm_rerank → pin_fix_filter → uniquifier

llm_rerank:     全候选送LLM → 首选移到#1 + ⚡
pin_fix_filter: 读pin_fix.txt → 固顶词移到#1 + ⛯

服务端:
  pipe_server.py → 4进程并行×2线程, mmap权重共享
  rime_pipe.dll  → 命名管道 \\.\pipe\rime_ll3
```

## 调参

改 `pipe_server.py` 顶部：

```python
MAX_CONTEXT_TOKENS = 4   # 上文token数（2-7可选）
MAX_CANDIDATES = 4       # 候选数（4-6可选，5+翻倍延迟）
N_WORKERS = 4            # 并行进程数
N_THREADS_PER = 2        # 每进程线程数
```

改完重启即可，无需改 Lua。

## 延迟参考

正常范围 80-130ms，受 CPU 负载波动。

```powershell
Get-Content "$env:TEMP\rime_latency.txt"
# 输出: count=342  max=132ms  last=107ms
```

## 如何开关

```powershell
# 临时关闭
New-Item -Path "$env:TEMP\rime_llm_off" -ItemType File
# 重新开启
Remove-Item "$env:TEMP\rime_llm_off"
```

## 故障排查

**服务启动报错**
```powershell
# 确认依赖
pip install llama-cpp-python pywin32 numpy
# 确认模型文件存在
Test-Path "d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf"
```

**管道错误 231 / 拒绝访问**
```powershell
taskkill /F /IM python.exe
# 然后重新启动
```

**DLL 更新**
```powershell
taskkill /F /IM python.exe
Copy-Item -Force ".\rime_pipe.dll" -Destination "C:\Program Files\Rime\weasel-0.17.4\rime_pipe.dll"
```
