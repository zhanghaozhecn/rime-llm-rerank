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

# 一、研究

## 1 引言

四码定长输入法（编码长度固定、编码决定候选集合）的候选排序长期依赖词频、词典顺序和用户习惯。这类静态排序无法利用**语义上下文**：同码词（如 "著名/注明"）中哪个是用户此刻想要的，往往只有上文能回答。用户被迫高频手动选重，打字流畅性被打断。

本文提出在 RIME 内集成本地 LLM 对同码候选做语义重排：

- **任务定位**：只排序、不生成。LLM 对每个候选计算 `P(候选 | 上文)` 的交叉熵评分，成本远低于逐字生成，且可整批并行。
- **编码无关**：LLM 的输入是纯中文（上文 + 候选词），与具体编码方案无关，任何四码定长方案开箱即用。
- **本地部署**：0.8B 量化模型 + CPU 推理，无网络依赖，无隐私外泄，延迟可控。

主要贡献：

1. **分层并行解码**（§3.2）：利用"所有候选共享同一段上下文"的结构，N 个候选的评分只需最多 3 次 `llama_decode`（上下文 1 次 + 候选 token 分层并行），与候选数无关。
2. **预解码**（§3.3）：commit 后上文即已确定，异步预解码并缓存；按键时只需候选 token 的 decode，感知延迟约减半。
3. **KV 代次机制**（§3.3）：解决预解码缓存与完整评分流程之间的状态一致性，杜绝编辑流中"旧 logits 被误用"的连锁错误。
4. **工程集成**（§3.5）：lua filter + lua processor + C++ DLL 三层结构，官方 rime.dll 上零修改运行，schema 一键部署、热开关。

## 2 相关工作

**传统候选排序**：输入法候选排序通常综合词频、用户词库、固顶词、简码与近期使用（MRU），本质是静态或局部统计，无法感知当前句子语义。同码词排序错误时用户只能手动选重。

**LLM 与输入法**：主流方向是云端大模型整句生成（如搜狗、微软 SwiftKey 的 AI 输入），延迟与隐私不可控，且改变的是"输入方式"而非"候选排序"。将小模型用于候选**重排**（rerank）的工作较少——排序任务比生成简单得多，小模型即可胜任，本地运行成本可接受。

**与同类项目的关系**：本仓库为**插件版**——独立 C++ DLL（`rime_llm.dll`）+ lua 组件，跑在官方小狼毫的 rime.dll 之上，安装即用；另一形态的**源码版**（rime-llm-ime）把 LLM 组件编译进 weasel/librime，并用 TSF 采集编辑器真实上文。两者不共享文件、同一项目，详见各仓库文档。

## 3 方法

### 3.1 任务设定与评分函数

给定上文 `ctx`（光标前的已上屏文字）与候选集 `C = {w₁ … wₙ}`（同码词），目标是求 `argmax P(wᵢ | ctx)`。

将候选词按 token 自回归分解，用交叉熵（CE）近似：

```
log P(w | ctx) ≈ Σⱼ log P(tokⱼ | ctx, tok₁…ⱼ₋₁) = -Σⱼ CEⱼ
```

CE 小者胜出。由于所有候选共享同一段 `ctx`，其首 token 概率可从**同一帧** logits 计算——这是并行化的起点（§3.2）。

### 3.2 分层并行解码（Layered Batched Decoding）

朴素实现：每个候选独立解码「上文 + 候选词」，N 个候选需要 N+1 次 `llama_decode`，实测 ~274 ms，不可用。

关键洞察：**所有候选共享同一段上下文**，上下文只需解码一次。

- **Step 1**：解码 `ctx` 一次，保存最后一帧 logits。所有候选第 1 个 token 的 CE 都从这一帧查表计算（归一化只做一次，见 [rime_llm.cpp](cpp/rime_llm.cpp) `logits_normalizer`）。
- **Step 2**：将 ctx 的 KV cache 复制到 M 个并行序列（`llama_memory_seq_cp`），每个序列放入一个候选的首 token，**一次 `llama_decode` 完成全部**首 token 评分。
- **Step 3**：三 token 候选在各自序列继续解码次 token（一次 decode）。

总 decode 次数 ≤ 3，与候选数无关。

两个实测边界（详见代码注释与 bench）：

- **SSM 跨序列干扰**：Qwen3.5 是 Attention + SSM（Mamba）混合架构，多序列 batch 中 Mamba 隐状态会跨序列耦合。分层算法把每序列增量限制为 1 个 token，干扰降至 ~0.5%，准确率 98.5%；超大 batch（250+ 序列）会掉到 74%。
- **`llama_get_logits_ith` 的索引语义**：`i` 是 batch 数组索引而非"第 i 个标记了 logits 的 token"，误用曾导致准确率仅 ~40%。见 [rime_llm.cpp](cpp/rime_llm.cpp) `score_batch` 注释。

### 3.3 预解码与 KV 代次

打字流程中有一个天然的时间差：**commit 时上文已确定，而候选要等编码打完才出现**。

- `prepare(ctx)`：commit 后异步执行 Step 1（上下文 decode + 保存 logits），不阻塞输入。
- `score(ctx, cands)`：若检测到 `ctx` 与预解码状态完全一致（token 序列相同且 seq0 的 KV 未被覆盖），直接跳过 Step 1，只做 KV copy + Step 2/3。

感知延迟从「上下文 + 候选」降到「仅候选」：S1 的 ~50 ms 从按键路径中消掉，按键部分降至 ~36 ms（总延迟 ~43 ms，含排队/打分开销）。

**KV 代次机制**：预解码状态保存 `(ctx, logits, g_prep_gen)`；seq0 的 KV 被任何 decode 覆盖时 `g_seq0_gen++`。`score` 的预解码命中条件 = token 完全匹配 **且** `g_seq0_gen == g_prep_gen`。这解决了编辑流（退格删词 → 重打同词）中候选窗抢在异步 prepare 完成前命中、在错误上下文上计算 CE 的问题。

**连锁失配修复**：完整评分流程 decode 后 seq0 代次已递增，若不同步写回预解码状态，后续同 ctx 的 score 会全部失配、连锁走完整流程（曾占 30% 的 score 请求）。因此完整流程成功后**自我刷新**预解码状态（代次、logits、ctx 一起写回），翻页/候选窗重建全部命中。详见 [rime_llm.cpp](cpp/rime_llm.cpp) `score_batch`。

### 3.4 长词评分外推

四字及以上候选只解码前 3 个 token，尾部用平均 CE 外推：

```
score = -ce_sum - (ce_sum/3) · (n_tokens-3) · λ,   λ = 0.6
```

截断会让长词被高估（尾部 CE 通常为正），λ=0.6 由 `eval_long_cand` 在真实语料上细扫 0.3–0.7 得出：真实尾部 CE/头部 CE 均值 0.58（4 字）/0.62（5 字+），0.5–0.7 为平台，首选一致率 ~94%；λ=0.6 方向平衡 up/down。零额外 decode 成本。

### 3.5 系统集成

三层结构，全部落在 RIME 的 schema 与 lua 生态内：

| 层 | 文件 | 职责 |
|------|------|------|
| C++ 插件 | `cpp/rime_llm.cpp` → `user/rime_llm.dll` | 模型加载、预解码、分层并行评分（llama.cpp C API，Lua 5.4 嵌入） |
| lua processor | `user/llm_processor.lua` | 上屏历史收集（commit_history）、编辑键判定、prepare 触发 |
| lua filter | `user/llm_filter.lua` | 调 `score` 重排候选、AI 标记、事件日志、结果缓存 |

要点：

- **触发区间**：编码长度达 `min_code_len`（默认 4）才触发；`max_code_len` 可选设上限，两值组成触发区间。
- **上文来源**：仅上屏历史（`commit_history`）。lua 侧无法感知鼠标/光标位置；应用切换经 TSF session 重置间接感知；浏览器网页切换不可感知（能力边界见 §5）。
- **编辑键重置**：退格/Delete/导航/回车视为编辑位置变化，上文基座重置（`commit_base`），并清空 filter 结果缓存——重打相同编码必须重新推理。
- **long_word_first**：long-word-first——候选算完 CE 后按词长降序排序、同词长按 CE 评分序（四码方案长词重码率高的优先展示）。
- **expected_length_weight**：适用于双拼等“两码一字”方案。输入 `L` 码时，候选字数为 `L/2` 或 `(L-1)/2`（整数化后即 `floor(L/2)`）的候选获得加权；加成是本次候选 LLM 分数跨度乘以该权重。加权分数相同时，所有匹配候选优先，再按原始 LLM 顺序排列。启用时优先于 `long_word_first`。
- **freq_weight / freq_k**：用户词频融合。`total = (1-w)·LLM评分 + w·count/(count+k)`——LLM 评分按候选窗内 min-max 归一，用户词频取饱和函数 `count/(count+k)`（词频数据由 lua 自动统计于 RIME 用户目录 `user_freq.tsv`）。解决“个人高频词在语料中罕见、纯 LLM 排序排不到第一”的问题（实证：LLM 排错事件 87% 的选中词用户词频≥2）。默认 `0.25/5`（真实候选窗回放：首选率 97.08%→98.20%）；`freq_weight: 0` 关闭。融合先于 expected_length_weight / long_word_first 应用。
- **热开关**：每次 filter 调用重读 `llm_rerank.enabled`，重新部署即生效，无需重启。
- **AI 标记**：LLM 首选候选以 ShadowCandidate 附加 "AI" 注释，肉眼可验证重排生效。

### 3.6 训练语料收集

llm_processor 在上屏瞬间记录「词 + 码」（手动选词码或满码顶屏码，单字 3 码截前 2 码——第 3 码是形码、由字本身决定，无额外信息；纯英文/标点条目跳过，否则会拿到前一个中文词的码）。

2026-08-02 起增加**真实候选窗快照**：llm_filter 每次调用时把 `(input, 前 N 候选)` 存入全局变量（含未评分的透传路径——候选窗是 RIME 实际显示的集合，即使不评分也构成训练样本）；上屏时用完整码匹配快照，训练样本变为 `词\t码\t候选1,候选2,...`，位置/候选/总数取自用户实际看到的候选窗。此前从字典反推同码候选（字典序 vs 词频序）导致训练分布与真实使用不一致。

## 4 实验

### 4.1 评估设置

- **样本**：wiki 语料 jieba 分词 + 拼读双拼词典（40 万词）同码采样，20000 样本（多字词）。
- **指标**：**首选率** = LLM 在同码词中将正确词排到第一位的概率。同码词只有一个时自动正确；正确词不在前 N 候选时自动错误。指标反映 LLM 在真实同码竞争中的排序能力。
- **协议**：分层并行解码（与生产一致）；CPU 后端；扫描 tok=1..20 × cand=2..9，总耗时 7.7 h。

### 4.2 首选率（20000 样本，拼读双拼 40 万词）

| tok\cand | cand=2 | cand=3 | cand=4 | cand=5 | cand=6 | cand=7 | cand=8 | cand=9 |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1 | 83.8 | 84.1 | 84.3 | 84.3 | 84.3 | 84.3 | 84.3 | 84.3 |
| 2 | 86.1 | 87.6 | 88.2 | 88.4 | 88.4 | 88.5 | 88.6 | 88.6 |
| 3 | 87.1 | 88.9 | 89.7 | 89.9 | 90.0 | 90.2 | 90.2 | 90.2 |
| 4 | 87.7 | 89.8 | 90.7 | 90.9 | 91.1 | 91.3 | 91.3 | 91.3 |
| 5 | 88.1 | 90.5 | 91.3 | 91.6 | 91.8 | 92.0 | 92.1 | 92.1 |
| 6 | 88.6 | 91.0 | 91.9 | 92.3 | 92.5 | 92.6 | 92.7 | 92.7 |
| 7 | 88.8 | 91.4 | 92.3 | 92.6 | 92.9 | 93.0 | 93.1 | 93.1 |
| 8 | 88.9 | 91.6 | 92.6 | 93.0 | 93.2 | 93.4 | 93.4 | 93.5 |
| 9 | 89.1 | 92.0 | 92.9 | 93.3 | 93.5 | 93.7 | 93.8 | 93.8 |
| **10** | **89.2** | **92.1** | **93.0** | **93.4** | **93.6** | **93.8** | **93.9** | **93.9** |
| 11 | 89.2 | 92.2 | 93.1 | 93.5 | 93.8 | 94.0 | 94.0 | 94.0 |
| 12 | 89.3 | 92.2 | 93.2 | 93.7 | 93.9 | 94.1 | 94.2 | 94.2 |
| 13 | 89.3 | 92.2 | 93.3 | 93.8 | 94.0 | 94.2 | 94.3 | 94.3 |
| 14 | 89.3 | 92.2 | 93.3 | 93.7 | 94.0 | 94.2 | 94.2 | 94.3 |
| 15 | 89.4 | 92.3 | 93.4 | 93.8 | 94.0 | 94.2 | 94.3 | 94.4 |
| 16 | 89.3 | 92.2 | 93.2 | 93.6 | 93.9 | 94.1 | 94.2 | 94.3 |
| 17 | 89.5 | 92.3 | 93.4 | 93.9 | 94.2 | 94.4 | 94.4 | 94.5 |
| 18 | 89.3 | 92.2 | 93.4 | 93.9 | 94.2 | 94.4 | 94.4 | 94.5 |
| 19 | 89.4 | 92.3 | 93.3 | 93.8 | 94.1 | 94.2 | 94.2 | 94.3 |
| 20 | 89.3 | 92.1 | 93.2 | 93.7 | 94.0 | 94.2 | 94.2 | 94.3 |

**关键结论：**

- 生产默认 **10 tok / 5 cand = 93.4%**。
- tok=1→5 跳升 ~7 pp，5→10 微升 ~2 pp，**10→20 饱和**——10 tok 已是最优上文窗口。
- cand 增至 9 达 93.9%，但每增 1 候选延迟 +~13 ms，5→9 的 0.5 pp 收益不划算。
- 天花板 ~94.3%（tok≈13–15），是 Qwen3.5-0.8B Q4_K_M 在此任务上的上限。

### 4.3 模型规模对比（20000 样本）

Qwen3.5-2B Q4_K_M（1.3 GB）vs 0.8B（508 MB），10 tok / 5 cand：

| | 0.8B | 2B | 差异 |
|------|:---:|:---:|:---:|
| 准确率 | 93.4% | 93.7% | +0.3 pp |
| CPU 延迟 | ~43 ms | ~130 ms | 3× |
| 模型大小 | 508 MB | 1.3 GB | 2.6× |

**结论：2B 几乎无优势**——+0.3 pp 不抵 3× 延迟和 2.6× 体积。排序任务简单，0.8B 即最优选择。

### 4.4 单字首选率（5535 样本，10 tok / 5 cand）

单字只取"单编码字"（无简码、前 2 码唯一、有 3 码形码），消除多音字编码歧义后评测，首选率从 89.8% 提升至 **96.8%**。

### 4.5 延迟与资源（CPU）

| 指标 | 值 |
|------|:---:|
| 延迟（10 tok / 5 cand） | **~43 ms** |
| 其中 ctx decode（S1） | 0 ms（预解码命中） |
| 候选 decode（S2+S3） | ~36 ms |
| 内存 | ~497 MB |
| 依赖 | 零（CPU 版） |

> 延迟为相对值，受 CPU 型号与线程数影响。两台电脑实测 7 线程时延迟性能饱和；默认 4 线程（=GGML 默认，适用旧设备）。可用 `bin/bench_threads.exe` 在本机实测后调整 `cpu_cores`（见用户说明）。

### 4.6 选重率对比

在真实打字场景（词典序 vs LLM 重排）下，LLM 重排的选重率可降至字典序的 **1/3**（`eval/eval_rerank.py` 逐词对比评测，输出 LLM 修正/改错明细）。

## 5 讨论与限制

- **模型上限**：~94.3% 是 0.8B Q4 模型的能力天花板。换更强的模型（或源码版的 TSF 真实上文）是继续提升的两条路径。
- **上文质量受限**：插件版上文仅来自上屏历史（commit_history）。lua 无法感知鼠标/光标位置，应用切换只能经 TSF session 重置间接感知，浏览器网页内切换完全不可感知——上一句的语义可能丢失。TSF 原生采集的完整方案见源码版。
- **SSM 干扰约束**：分层解码依赖"每序列增量 1 token"，超大 batch 会退化（§3.2）。
- **GPU 尝试已放弃**：RTX 4060 Laptop 实测最快 9.9 ms（10× CPU），但 CUDA graph 重编译开销、省电模式波动、特定输入卡死；CPU 在打字场景足够稳定。
- **首选率排查结论**（2026-08-10）：CE 正确性测试 6/6 通过、λ 外推平台 ~94.9%、真实打字首选率无下降——偶发"改错"是模型概率判断与用户意图不一致，非计算错误。

## 6 结论

本地 0.8B LLM 足以胜任四码定长输入法的同码候选重排：首选率 93.4%、感知延迟 ~43 ms、内存 ~500 MB、选重率降至 1/3。分层并行解码 + 预解码 + KV 代次机制使其达到可用延迟；编码无关的设计使其对任意四码定长方案开箱即用。继续提升的空间在模型规模与上文采集质量（源码版）。

---

# 二、用户说明

## 前置条件

- 小狼毫（Weasel）0.17.x 已安装，且 `rime.dll` 为官方原版（含 Lua 支持）
- 使用四码定长方案（拼读双拼、五笔、郑码、仓颉等）
- 下载模型 `Qwen3.5-0.8B-Q4_K_M.gguf`（约 500 MB），默认路径 `D:\gguf_models\`

## 一键部署（推荐）

使用 **GUI 安装器**（`installer\` 目录；插件版与源码版通用）。安装器**只做文件操作**——停止算法服务 → 复制/替换文件（被占用时自动改名腾位，极端情况延迟替换重启生效）。不修改方案配置、不碰注册表。

**前提**：已安装官方小狼毫；方案配置已含 LLM 组件行（拼读双拼方案自带——`processors` 最前 `lua_processor@*llm_processor`、`filters` 的 `uniquifier` 后 `lua_filter@*llm_filter`；其他方案参照"手动安装"第三步自行添加）。

1. `git clone` 本仓库到目标电脑（或下载仓库 zip 解压——插件版文件在 `user\`、源码版二进制在 `installer\source\`，均已入库）
2. **双击 `installer\install_llm_gui.bat`**（自动请求管理员权限）
3. 点击 **安装插件版**：停算法服务 → `rime_llm.dll` 等 → 小狼毫安装目录；`llm_filter.lua` / `llm_processor.lua` → `%APPDATA%\Rime\lua\` → 重启算法服务
4. **托盘小狼毫 → 右键 → 重新部署**。验证：首选候选 comment 出现 `AI` 标记；日志 `%APPDATA%\Rime\rime_llm_events.txt`

**切换版本**（插件版 ↔ 源码版）：重装官方小狼毫（恢复官方二进制）→ 把原始（不含 LLM 组件行）的方案配置重新复制到 `%APPDATA%\Rime\` → 打开安装器点另一个按钮。**切换没有自动流程**，这是刻意设计——避免任何状态残留。

**输入法图标消失时**：运行 `installer\repair_tsf.ps1`（右键"使用 PowerShell 运行"，自动提权；重注册 TSF 并挂回语言列表）。

命令行模式：`install_llm_gui.ps1 -CliAction install-plugin|install-source|status`。

## 手动安装

### 第一步：下载模型

打开 https://www.modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/files ，下载 `Qwen3.5-0.8B-Q4_K_M.gguf`（约 500 MB），放到 `D:\gguf_models\`。

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
  # long_word_first: false       # 长词优先（适用于四码等定长方案）
  # expected_length_weight: 0.20 # 适用于双拼等两码出一字的方案：当 `候选词字数=编码数÷2` 或 `候选词字数=(编码数-1)÷2` 时，此候选词获得排序加权。0=关闭；1=所有匹配候选词优先，内部按加权后评分排序
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
| `long_word_first` | false | `true` 时 long-word-first：候选算完 CE 后按词长降序、同词长按 CE 评分序排列 |
| `expected_length_weight` | 0 | 双拼等“两码一字”方案的预期字长匹配权重。输入 `L` 码时，`L/2` 或 `(L-1)/2` 字候选获得“本次有效 LLM 分数跨度 × 权重”的加成；失败哨兵分数不参与跨度计算，也不获得加成。加权分数相同时，匹配候选优先。`0` 关闭。大于 `0` 时优先于 `long_word_first`，推荐从 `0.20` 开始调试。 |
| `freq_weight` | 0.25 | 用户词频融合权重。`total = (1-w)·LLM评分(窗内min-max归一) + w·count/(count+k)`。词频由 lua 自动统计（RIME 用户目录 `user_freq.tsv`，仅中文词，每 20 词落盘）。真实候选窗回放实证（6000 抽样）：w=0.25 首选率 97.08%→98.20%。调大更个性化、调小更依语义；`0` 关闭。 |
| `freq_k` | 5 | 词频饱和常数：`count/(count+k)`。c=1→0.17、c=5→0.5、c=20→0.8。k 越大高频词越难饱和（更保守）。 |
| `min_tokens` | 1 | 上文 token 不够时不重排 |
| `max_tokens` | 10 | 截取的上文 token 数（10→17 仅 +1.1 pp 但 CPU 延迟翻倍，10 为性价比最优点） |
| `max_candidates` | 5 | 并行评分候选数（5→9 仅 +0.5 pp 但延迟翻倍，5 为最佳平衡） |
| `cpu_cores` | 4 | CPU 线程数（固定，无运行时动态调整）。**设备实测**：运行 `bin/bench_threads.exe` 查看延迟表后自行填入 |
| `model_path` | (内置默认) | 模型路径。换模型只需设置此项 |

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

数据流：lua（filter/processor）↔ C++ DLL（评分）通过 Lua C API 交互；日志走文件（`rime_llm_log.txt` / `rime_llm_events.txt`）；训练语料走 `llm_training.txt`（上屏时追加，`prep_training.py` 预处理）。

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
│   ├── sim_rerank.cpp         #   评测仿真器（stdin JSON → 排序结果）
│   ├── test_core.cpp          #   回归测试（CE 正确性/准确率/延迟基线）
│   ├── bench_sweep2.cpp       #   CPU 首选率扫参（tok×cand 网格，20000 样本）
│   ├── bench_single_char.cpp  #   单字首选率评测
│   ├── eval_long_cand.cpp     #   λ 外推系数细扫
│   ├── eval_s3_skip.cpp       #   跳过 Step 3 的效果评估
│   ├── bench_threads.cpp      #   线程数测定（build_bench_threads.bat）
│   └── lua/                   #   Lua 5.4 嵌入源码
├── eval\                      # 评估工具链（python）：评估/语料/测试
│   ├── eval_rerank.py         #   单文本：字典序 vs LLM 选重率对比
│   ├── eval_prefer.py         #   多方案首选率对比（同词跨方案合并候选，一次评分）
│   ├── batch_rerank.py        #   多模型批量评测（--prepare/--run/--compare）
│   ├── compare_dicts.py       #   多词库统一对比评测（各库独立候选）
│   ├── calibrate_css.py       #   CSS 校准（依赖 处理脚本/eval_css）
│   ├── prep_samples.py        #   wiki 语料 → eval_samples.tsv（同码采样）
│   ├── prep_training.py       #   打字语料 llm_training.txt → train_samples.tsv
│   └── run_tests.py           #   test_core 自动化测试驱动
├── bin\bench_threads.exe      # 预编译线程测定工具
└── deploy_llm_plugin.bat/.ps1 # 一键部署（提权 bat + PS 逻辑）
```

> 评估工具路径约定：**项目内资源**（词库 `pdsp_dict.yaml`、样本 `eval_samples.tsv`、`sim_rerank.exe`）相对脚本位置，cpp 程序数据文件相对 cwd（在项目根运行）；**本机/跨项目资源**（模型、语料、venv、处理脚本）用环境变量覆盖，默认值见下表。GPU 版（`rime_llm_cuda.cpp`/DLL）与语料（`train_samples.tsv` 等）仅本地留存，不进 GitHub。

## 核心算法要点

分层并行解码、预解码、KV 代次、长词外推的完整原理见**研究部分 §3**；实现层的坑（索引语义、代次连锁失配、`llama_memory_clear` 参数、`llama_tokenize` 负返回、lua 缓存误命中、编辑键重置根因、候选窗快照动机等）已写入代码注释，改代码前先读 `cpp/rime_llm.cpp` 的 `score_batch`/`prepare` 与两个 lua 文件顶部的注释。

## 评测工具用法

全部工具在 `eval/` 下，在项目根运行：

```powershell
# 单文本选重率对比（字典序 vs LLM）
python eval/eval_rerank.py --file 评测文本.txt     # --text "..." / --dict-only / --dict <词库>

# 多方案首选率对比（同词跨方案合并候选，一次评分）
python eval/eval_prefer.py --dict 拼读双拼.txt --dict 五笔.txt --n 20000

# 批量多模型评测（--prepare 生成测试数据 → --run 模型 → --compare 对比）
python eval/batch_rerank.py --prepare
python eval/batch_rerank.py --run "模型.gguf"
python eval/batch_rerank.py --compare

# 多词库统一对比（--segment 生成分段缓存 → --compare）
python eval/compare_dicts.py --segment
python eval/compare_dicts.py --compare --dict ... --name ... --dict ... --name ...

# CSS 校准（依赖 处理脚本/eval_css）
python eval/calibrate_css.py

# 语料准备（wiki → eval_samples.tsv；打字语料 → train_samples.tsv）
python eval/prep_samples.py
python eval/prep_training.py

# 打字语料（llm_training.txt）的质量分析/清洗归 BERT 分词项目：
#   D:/OneDrive/typing/bert_seg/analyze_corpus.py（质量分析）
#   D:/OneDrive/typing/bert_seg/clean_data.py（清洗 → 分词训练数据）

# C++ 回归测试（CE 正确性 + 准确率/延迟基线，在项目根运行）
cmake --build build_cpu --config Release --target test_core && ./build_cpu/test_core.exe
python eval/run_tests.py
```

**外部依赖与覆盖**：项目内资源（词库 `pdsp_dict.yaml`、`eval_samples.tsv`）相对脚本位置；模型/语料/分词 venv 等本机资源默认使用以下约定路径，可用环境变量覆盖：

| 环境变量 | 默认值 |
|------|------|
| `GGUF_MODEL` | `d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf` |
| `RIME_LLM_VENV_PY` | `D:/OneDrive/typing/bert_seg/.venv/Scripts/python.exe`（HanLP 分词） |
| `RIME_LLM_CORPUS` | `D:/OneDrive/typing/bert_seg/data/sentences_filtered.txt` |
| `RIME_LLM_DATA_DIR` | `D:/OneDrive/typing/bert_seg/data/batch_eval`（缓存/结果） |
| `RIME_LLM_SEG_CACHE` | `…/batch_eval/segments_10000.jsonl` |
| `RIME_LLM_TOOLCHAIN` | `D:/OneDrive/typing/处理脚本` |
| `RIME_LLM_WIKI` | `D:/分词注音工程/分读音词频统计/data/sentences_new.txt` |
| `RIME_LLM_SENTENCES` | `D:/分词注音工程/…/sentences_clean_1pct.txt` |

RIME 用户目录 = `%APPDATA%\Rime`。`sim_rerank.exe` 用 `cmake --build build_sim --config Release --target sim_rerank` 编译。

## 编译

需要 Visual Studio Build Tools 2022 + CMake + Ninja + llama.cpp 源码。

编译前修改 `CMakeLists.txt` 中的 `LLAMA_ROOT`（llama.cpp 路径）。**CPU 版**：

```powershell
cd cpp
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -S . -B build_cpu
ninja -C build_cpu rime_llm
```

post-build 自动复制 DLL 到 `user\`。部署前需先**退出小狼毫**（右键托盘 → 退出），复制 DLL 及其依赖，再重新启动、重新部署。

> GPU 版（`rime_llm_cuda.cpp`）源码与构建仅本地留存，不发布（§5 原因）。

## 调试接口

- **事件日志**：`rime_llm_events.txt`——每次真实评分一行，`时间|计数|编码|候选列表|上文|结果|延迟ms|上文来源`；C++ 日志 `rime_llm_log.txt` 限频记录（每 10 次 + 慢请求），含 S1/S2/S3 各段耗时与 `prep=` 命中标记——排查"预解码是否生效"看此字段。
- **`get_scores()`**：C++ 插件在 `score()` 后保存原始分数，`llm.get_scores()` 返回 `{[候选词]=分数}` 的 Lua 表，仅用于调试分析（lua filter 层不消费）。

```lua
local ranked = llm.score(ctx, cands)     -- 排序表（正常使用）
local scores = llm.get_scores()          -- 数值分数（调试用）
```

- **`test_core.exe`**：CE 正确性（分层 vs gold 对比）+ 准确率/延迟回归基线（`test_baseline.json`），改评分逻辑后必跑。

## 部署脚本原理

`deploy_llm_plugin.ps1`（`deploy_llm_plugin.bat` 提权调用）四步：① 定位安装目录（常见路径 → 注册表）；② 检测源码版 rime.dll 冲突（二进制含 `llm_filter` 特征即中止）；③ 复制 DLL/lua；④ schema 幂等修改（已存在时校验位置：processor 最前、filter 在 uniquifier 后固顶前，位置错则警告中止）。所有 schema 读写为 UTF-8 无 BOM。

---

# 许可证

本项目采用[署名许可协议](./LICENSE)：可自由使用（含商业用途），**无需作者同意**；用于商业用途时须注明作者来源（zhanghaozhecn，仓库：https://github.com/zhanghaozhecn/rime-llm-rerank）。
