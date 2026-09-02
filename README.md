# RIME LLM 候选重排（rime-llm-rerank）

使用本地部署的小型 LLM 为任意 RIME **四码定长**输入方案（五笔、郑码、仓颉、拼读双拼等）提供打字时的智能候选排序。LLM 与编码方案无关——它只看到最终的中文候选词列表，利用上文的语义把正确词排到候选第一位，减少手动选重。

| 关键指标 | 值 |
|------|------|
| 首选率（10 tok / 5 候选） | **93.4%**（单字 96.8%） |
| 感知延迟 | **~43 ms**（CPU，预解码后） |
| 内存占用 | ~497 MB |
| 模型 | Qwen3.5-0.8B Q4_K_M（508 MB，GGUF） |
| 选重率 | 可降至原方案（字典序）的 **1/3** |
| 依赖 | 零（纯本地 CPU 推理） |

核心手段：**跨熵（CE）评分**而非文本生成——候选 token 全部并行解码，最多 3 次 `llama_decode`，与候选数无关；**预解码**利用 commit 到编码打完的时间差，把上下文解码从按键延迟中消掉。

---

# 一、研究主要结论

**方法**：对同码候选做 `argmax P(wᵢ | ctx)` 的交叉熵评分（只排序、不生成、编码无关、本地 CPU）。三项核心技术：

1. **分层并行解码**——所有候选共享同一段上文，上文只解码一次、首 token 同帧出分，N 候选 ≤ 3 次 `llama_decode`（朴素逐候选 274ms → 生产 43ms）。约束：每序列增量 1 token（Qwen3.5 的 SSM 跨序列干扰）。
2. **预解码 + KV 代次机制**——commit 后异步预解码上文，按键时只算候选部分（感知延迟减半）；代次计数杜绝编辑流中旧缓存误用。
3. **长词评分外推**——4+ 字候选只解前 3 token，尾部按 λ=0.6 外推，零额外解码成本。

**实验结论**：

- 首选率 93.4%（10 tok / 5 cand，20000 样本）；单字 96.8%。tok 10→20 饱和、cand 5→9 仅 +0.5pp 但延迟翻倍——10/5 为性价比最优点。
- 模型规模：2B 仅 +0.3pp 但延迟 3×、体积 2.6×——**0.8B 即最优**。
- 词频融合 `freq_weight=0.25`：真实候选窗回放首选率 97.08%→**98.20%**（个人高频词拯救）。
- GPU 版放弃（CUDA graph 重编译/省电波动/特定输入卡死）；模型能力上限 ~94.3%。

完整研究文档（方法细节、tok×cand 全量扫参表、词频融合研究）在本地研究资料库 `D:\llm-rerank-research\`（评测工具链与语料同在其中）。

---

# 二、用户说明

## 前置条件

- 小狼毫（Weasel）0.17.x 已安装，且 `rime.dll` 为官方原版（含 Lua 支持）
- 使用四码定长方案（拼读双拼、五笔、郑码、仓颉等）
- 下载模型 `Qwen3.5-0.8B-Q4_K_M.gguf`（约 500 MB），默认路径 `%APPDATA%\Rime\`（RIME 用户文件夹；自定义位置用 `model_path` 指定）

## 一键部署（推荐）

**插件版安装器**（本仓库 `installer\` 目录；源码版 2026-08-27 起改用 [rime-llm-ime](https://github.com/zhanghaozhecn/rime-llm-ime) 的 setup.exe 安装包，不再带 PS 安装器）。界面为**四个按钮**：**复制文件**（停算法服务 + 清理上次残留 → 二进制一律改名腾位 `*.llm_old` 替换 → 启服务）、**下载模型**（ModelScope 断点续传，目标 = 模型路径框，留空 = 默认）与**方案配置加 / 去 LLM**（只改选中的方案文件，幂等，完成后自动重新部署）；模型路径输入框留空 = 默认 `%APPDATA%\Rime\Qwen3.5-0.8B-Q4_K_M.gguf`（2026-08-31 澄清：RIME 用户文件夹根），填写则写入配置生效行。不碰注册表。

**前提**：已安装官方小狼毫；方案配置已含 LLM 组件行（拼读双拼方案自带——`processors` 最前 `lua_processor@*llm_processor`、`filters` 的 `uniquifier` 后 `lua_filter@*llm_filter`；其他方案参照"手动安装"第三步自行添加）。

1. `git clone` 本仓库到目标电脑（或下载仓库 zip 解压——插件版文件在 `user\`，已入库）
2. **双击 `installer\install_plugin.bat`**（自动请求管理员权限）
3. 选择方案文件（下拉列出 `%APPDATA%\Rime\*.schema.yaml`，可浏览外部 yaml 自动拷入）；模型路径留空 = 默认
4. 缺模型时点击 **下载模型**：从 ModelScope 下载到模型路径（约 500MB，断点续传——中断/失败后重新点击自动续传）
5. 点击 **复制文件**：停算法服务 → `rime_llm.dll` 等 → 小狼毫安装目录；`llm_filter.lua` / `llm_processor.lua` → `%APPDATA%\Rime\lua\` → 启服务
6. 点击 **方案配置加 LLM**：schema 幂等插入组件行（`processors` 最前 `lua_processor@*llm_processor`、`filters` 的 `uniquifier` 后 `lua_filter@*llm_filter`、顶层 `llm_rerank:` 节）→ 自动重新部署（**方案配置去 LLM** 按钮为逆操作，剥离这些行/节）
7. 验证：首选候选 comment 出现 `AI` 标记；日志 `%APPDATA%\Rime\rime_llm_events.txt`（未生效时托盘小狼毫 → 右键 → 重新部署）

**切换版本**（插件版 ↔ 源码版）：重装官方小狼毫（恢复官方二进制）→ 源码版跑 [rime-llm-ime](https://github.com/zhanghaozhecn/rime-llm-ime) 的安装包 / 插件版跑本仓库安装器（其**方案配置加 LLM** 会先剥离另一版组件行再插入，跨版自动转换，无需恢复原始方案配置）。

**输入法图标消失时**：运行源码版安装目录下的 `repair_tsf.ps1`（随 [rime-llm-ime](https://github.com/zhanghaozhecn/rime-llm-ime) 安装包装入，右键"使用 PowerShell 运行"自动提权重注册 TSF——插件版安装不碰注册表，此症状只源于源码版操作或系统问题）。

命令行模式：`install_plugin.ps1 -CliAction install|copy-files|schema-add|schema-remove|download-model|status -SchemaName pdsp.schema.yaml -ModelPath <模型路径>`（源码版同；`install` = 复制文件 + 配置加 LLM 全流程）。

## 手动安装

### 第一步：下载模型

打开 https://www.modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/files ，下载 `Qwen3.5-0.8B-Q4_K_M.gguf`（约 500 MB），放到 `%APPDATA%\Rime\`（默认路径 = RIME 用户文件夹根；放其他位置需在方案中设置 `llm_rerank.model_path`）。

> 放其他路径需在 schema 中设置 `llm_rerank.model_path`。

### 第二步：复制插件

**CPU（所有机器可用，零依赖）：** 将 `user\rime_llm.dll` 复制到小狼毫安装目录（需管理员）：

```
user\rime_llm.dll  →  C:\Program Files\Rime\weasel-0.17.4\
```

> GPU 版（rime_llm_cuda）因实用性问题仅本地留存，不发布。

### 第三步：配置 RIME

1. 将 `user\` 下两个 `.lua` 文件复制到方案 `lua\` 目录（即 `%APPDATA%\Rime\lua\`）
2. 在 `schema.yaml` 中添加：

```yaml
engine:
  processors:
    - lua_processor@*llm_processor
  filters:
    - lua_filter@*llm_filter
```

3. 右键小狼毫 → **重新部署**

LLM 选中的候选显示 `AI` 标记。事件日志（每行：`时间|计数|编码|候选列表|上文|LLM结果|延迟ms|上文来源`）：

```powershell
Get-Content "$env:APPDATA\Rime\rime_llm_events.txt" -Tail 5
```

## 配置参数

在方案的 `schema.yaml` 中配置（全部可选）：

```yaml
llm_rerank:
  min_code_len: 4      # 最小编码长度触发 LLM
  min_tokens: 1        # 最少上文 token 才重排
  max_tokens: 10       # 截取的上文 token 数（1-20），10 为性价比最优点
  max_candidates: 5    # 并行评分候选数（2-9），5 为延迟/准确率最佳平衡
  # expected_length_weight: 0 # 适用于双拼等两码出一字的方案：当 `候选词字数=编码数÷2` 或 `候选词字数=(编码数-1)÷2` 时，此候选词获得排序加权。0=关闭（默认）；1=所有匹配候选词优先，内部按加权后评分排序
  # freq_weight: 0.25  # 用户词频融合权重 (0=关闭); freq_k: 5 饱和常数
  #   total = (1-w)·LLM(min-max归一) + w·count/(count+k), 词频自动统计
  # cpu_cores: 4      # 可选。CPU 线程数，默认 4（=GGML 默认）。bench_threads.exe 实测后自行调整
  # model_path: ""     # 可选。模型路径，默认内置 Qwen3.5-0.8B Q4_K_M。换模型只需改此处
  enabled: true        # true=启用 LLM 重排 | false=关闭（不加载 DLL 不推理）
```

| 参数 | 默认 | 说明 |
|------|:---:|------|
| `enabled` | false | `true` 启用 LLM 重排 / `false` 关闭（不加载 DLL，候选原样透传） |
| `min_code_len` | 4 | 编码达到此长度才触发 LLM（与 `max_code_len` 组成触发区间） |
| `max_code_len` | 0 | 编码长度上限（0=不限制）；超出此长度不推理 |
| `expected_length_weight` | 0 | 双拼等“两码一字”方案的预期字长匹配权重。输入 `L` 码时，`L/2` 或 `(L-1)/2` 字候选获得“本次有效 LLM 分数跨度 × 权重”的加成；失败哨兵分数不参与跨度计算，也不获得加成。加权分数相同时，匹配候选优先。`0` 关闭（默认）。（`long_word_first` 已删，2026-08-27 两版参数统一。） |
| `freq_weight` | 0.25 | 用户词频融合权重。`total = (1-w)·LLM评分(窗内min-max归一) + w·count/(count+k)`。词频由 lua 自动统计（RIME 用户目录 `user_freq.tsv`，仅中文词，每 20 词落盘）。真实候选窗回放实证（6000 抽样）：w=0.25 首选率 97.08%→98.20%。调大更个性化、调小更依语义；`0` 关闭。 |
| `freq_k` | 5 | 词频饱和常数：`count/(count+k)`。c=1→0.17、c=5→0.5、c=20→0.8。k 越大高频词越难饱和（更保守）。 |
| `min_tokens` | 1 | 上文 token 不够时不重排 |
| `max_tokens` | 10 | 截取的上文 token 数（10→17 仅 +1.1 pp 但 CPU 延迟翻倍，10 为性价比最优点） |
| `max_candidates` | 5 | 并行评分候选数（5→9 仅 +0.5 pp 但延迟翻倍，5 为最佳平衡） |
| `cpu_cores` | 4 | CPU 线程数（固定，无运行时动态调整）。**设备实测**：运行 `bin/bench_threads.exe` 查看延迟表后自行填入 |
| `model_path` | (内置默认 = 用户文件夹根) | 模型路径。换模型只需设置此项，改后下一次按键自动卸载旧模型并重载新路径 |

## 线程数实测（可选）

`bin/bench_threads.exe`（预编译）在**本机实测**各线程数的推理延迟（评估负载 = 10-token 上文 + 3×2-token + 2×3-token 候选，预解码排除，只计真实按键延迟）：

```
bin/bench_threads.exe [模型路径]
```

1. **建议在系统空闲时运行**（有编译/下载/游戏在跑会压平曲线、延迟失真）
2. 约 1 分钟后输出 1~10（或最大核数）各线程数延迟表，工具**不做推荐**——自行权衡"延迟 vs 线程占用"，取曲线拐点附近的最小线程数，填入 `llm_rerank.cpu_cores`
3. 托盘右键 → 重新部署 → 生效

不跑本工具也可用默认值 4。自行编译源码：`cpp/build_bench_threads.bat`（需本机 llama.cpp 构建）。

## 关闭与卸载

- **临时关闭**：把安装目录 `rime_llm*.dll` 改后缀（如 `.dll.bak`），重新部署即恢复字典序；或 schema 中 `enabled: false`（不加载 DLL 不推理）。LLM 插件仅占 ~497 MB 内存，对现代电脑影响不大，建议常驻。
- **完全卸载**：GUI 安装器"还原插件版"（自动剥离 schema 组件与配置节 + 重新部署，不删文件）；残留文件手动清理：安装目录 `rime_llm*.dll` + `llama.dll` + `ggml*.dll`、`%APPDATA%\Rime\lua\` 下两个 lua。

## 常见问题

- **Q: 装了没效果？** 确认 ① schema 组件位置正确（filter 在 uniquifier 后、固顶 filter 前）② `enabled: true` ③ 重新部署过 ④ 模型路径存在。打满 4 码后首选候选 comment 应有 `AI` 标记。
- **Q: 候选变乱序/被顶掉？** 检查固顶词 filter（pin_fix_filter 等）是否在 `lua_filter@*llm_filter` **之后**——先固顶后重排，固顶词会被 LLM 顶掉。
- **Q: 每击键延迟明显？** 运行 `bin/bench_threads.exe` 实测线程数；确认 `max_tokens`/`max_candidates` 未调高；确认预解码生效（事件日志延迟应 ~36 ms 而非 ~80 ms）。
- **Q: 编辑器里插入的英文/数字算上文吗？** 算。上文中允许字母存在，仅去空白；外挂无法感知光标前完整文本，英文数字是合法上文（见代码注释）。
- **Q: 日志在哪？** `%APPDATA%\Rime\rime_llm_events.txt`（lua 事件，含上文来源）；`%APPDATA%\Rime\rime_llm_log.txt`（C++ 推理日志，限频记录）。

---

# 三、开发者说明

## 架构总览

```
打字按键 → llm_processor.lua (processors 最前)
              ├─ 上屏历史收集 (commit_history, commit_base 基座)
              ├─ 编辑键判定 → 重置上文 + 清缓存 + 重新预解码
              └─ 上下文变化 → llm.prepare() 异步预解码 (后台线程)
                    ↓
候选生成 → llm_filter.lua (filters: uniquifier 后)
              ├─ 候选窗快照 (训练语料)
              ├─ 缓存命中? (ctx, input) → 直接复用排序结果
              └─ llm.score() → C++ 分层并行解码 → 重排 + AI 标记
                    ↓
C++ rime_llm.dll: llama.cpp C API, Lua 5.4 嵌入 (luaopen_rime_llm)
```

数据流：lua（filter/processor）↔ C++ DLL（评分）通过 Lua C API 交互；日志走文件（`rime_llm_log.txt` / `rime_llm_events.txt`）；训练语料走 `llm_training.txt`（上屏时追加）。

## 代码布局

```
rime-llm-rerank\
├── user\                      # 发布安装文件
│   ├── llm_filter.lua          #   候选重排 filter（打分/缓存/日志/AI 标记）
│   ├── llm_processor.lua       #   上屏历史收集 + 预解码 processor
│   ├── rime_llm.dll           #   预编译插件
│   └── *.dll                  #   llama.cpp 依赖 DLL（CPU 版）
├── cpp\                       # 源码（CMakeLists.txt 构建）
│   ├── rime_llm.cpp           #   生产插件（评分核心，坑见注释）
│   ├── sim_rerank.cpp         #   评测仿真器（研究工具链使用，stdin JSON → 排序/分数）
│   ├── test_core.cpp          #   回归测试（CE 正确性/准确率/延迟基线）
│   ├── bench_*.cpp / eval_*.cpp # 研究评测器（线程测定/扫参/单字/长词外推）
│   └── lua/                   #   Lua 5.4 嵌入源码
├── bin\bench_threads.exe      # 预编译线程测定工具
└── installer\                 # 插件版安装器（分仓：只带本版文件）
                                # install_plugin.bat 提权入口 + install_plugin.ps1
                                # + common.ps1 共用逻辑（与源码版仓库保持一致）
```

> **研究工具链与语料不在本仓库**：评测 python 工具、样本语料在本地研究资料库
> `D:\llm-rerank-research\`（完整研究文档同在该处）。sim_rerank 等研究评测器在本仓库 `cpp\` 构建
> （与生产共用 CMake），研究脚本按绝对路径调用其构建产物。

## 核心算法要点

分层并行解码、预解码、KV 代次、长词外推的完整原理见研究资料库 README「方法」节；实现层的坑（索引语义、代次连锁失配、`llama_memory_clear` 参数、`llama_tokenize` 负返回、lua 缓存误命中、编辑键重置根因、候选窗快照动机等）已写入代码注释，改代码前先读 `cpp/rime_llm.cpp` 的 `score_batch`/`prepare` 与两个 lua 文件顶部的注释。

## 编译

需要 Visual Studio Build Tools 2022 + CMake + Ninja + llama.cpp 源码。

编译前修改 `CMakeLists.txt` 中的 `LLAMA_ROOT`（llama.cpp 路径）。**CPU 版**：

```powershell
cd cpp
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -S . -B build_cpu
ninja -C build_cpu rime_llm
```

post-build 自动复制 DLL 到 `user\`。部署前需先**退出小狼毫**（右键托盘 → 退出），复制 DLL 及其依赖，再重新启动、重新部署。

> GPU 版（`rime_llm_cuda.cpp`）源码与构建仅本地留存，不发布。
> **cl 直编含中文源码必须加 `/utf-8`**（GBK 误读会把换行吞进注释，曾致 JSON 输出缺逗号）。

## 调试接口

- **事件日志**：`rime_llm_events.txt`——每次真实评分一行，`时间|计数|编码|候选列表|上文|结果|延迟ms|上文来源`；C++ 日志 `rime_llm_log.txt` 限频记录（每 10 次 + 慢请求），含 S1/S2/S3 各段耗时与 `prep=` 命中标记——排查"预解码是否生效"看此字段。
- **`get_scores()`**：C++ 插件在 `score()` 后保存原始分数，`llm.get_scores()` 返回 `{[候选词]=分数}` 的 Lua 表，仅用于调试分析（lua filter 层不消费）。

```lua
local ranked = llm.score(ctx, cands)     -- 排序表（正常使用）
local scores = llm.get_scores()          -- 数值分数（调试用）
```

- **`test_core.exe`**：CE 正确性（分层 vs gold 对比）+ 准确率/延迟回归基线（`test_baseline.json`），改评分逻辑后必跑。

## 安装器原理

`installer\common.ps1`（`install_plugin.bat` 提权启动本仓库入口；2026-08-27 起为本仓库独有，不再跨仓同步）：GUI 四按钮各起一个 CLI 子进程——`copy-files`（停服务 + 清残留 → 二进制一律改名腾位 `*.llm_old`，复制失败回滚 → 启服务）、`download-model`（curl.exe 断点续传 ModelScope → `.download` 分片 → 完成转正；子进程每 5 秒打进度行到日志）、`schema-add`（**先剥离后插入**——方案原状无论无 LLM / 本版 / 另一版组件均先剥净再全新插入，跨版自动转换；模型路径未填时保留原有生效 `model_path`，非空时写入新值）、`schema-remove`（剥离两版组件行与 `llm_rerank` 节）；配置类动作完成后自动重新部署（15 秒有界等待，超时留后台）。不碰注册表、不调 WeaselSetup。所有 schema 读写为 UTF-8 无 BOM。

---

# 许可证

本项目采用[署名许可协议](./LICENSE)：可自由使用（含商业用途），**无需作者同意**；用于商业用途时须注明作者来源（zhanghaozhecn，仓库：https://github.com/zhanghaozhecn/rime-llm-rerank）。
