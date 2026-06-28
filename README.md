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
| Python 3.10+ | 安装时务必勾选「Add Python to PATH」 |
| 磁盘空间 | ~1.5 GB（模型 500MB + Python 依赖 ~500MB） |
| 内存 | ~1.5 GB 可用内存 |

## 安装步骤

### 第一步：安装 LLM 服务

```
右键 server\setup.ps1 → 使用 PowerShell 运行          → 一键安装（约 5-15 分钟）
双击 server\start_server.bat                            → 启动推理服务（窗口自动关闭）
```

**setup.ps1 做了什么：**
- 安装 3 个 Python 包（llama-cpp-python, pywin32, numpy）
- 复制 `rime_pipe.dll` 到 `C:\Program Files\Rime\weasel-*\`
- 从魔搭（modelscope.cn）下载 `Qwen3.5-0.8B-Q4_K_M.gguf` 到 `d:\gguf_models\`

### 第二步：配置你的输入法方案

将 `lua\` 目录下的两个 `.lua` 文件复制到你的 RIME 方案 `lua\` 文件夹中。
在你的方案 `schema.yaml` 中添加（参考 `schema-patch.yaml`）：

```yaml
engine:
  processors:
    - lua_processor@*llm_context
  filters:
    - lua_filter@*llm_rerank
```

### 第三步：重新部署

右键小狼毫托盘图标 → **重新部署**。LLM 选中的候选会显示 ⚡ 标记。

## 启停

| 操作 | 方法 |
|------|------|
| 启动 | 双击 `server\start_server.bat` |
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
│   ├── setup.ps1             # 一键安装（右键 → PowerShell 运行）
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
