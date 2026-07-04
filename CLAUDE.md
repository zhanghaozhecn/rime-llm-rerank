# LLM 候选重排

独立于任何 RIME 方案的 C++ 插件，为四码定长方案提供 LLM 智能候选排序。

## 项目结构

```
llm_rerank/
├── cpp/
│   ├── dev/                  # 源码 + 构建
│   │   ├── rime_llm.cpp      #   C++ 插件（CPU 推理，并行 batch 评分）
│   │   ├── CMakeLists.txt    #   CMake 配置（依赖 D:\llama.cpp-mirror\）
│   │   └── rebuild.bat       #   一键编译+部署
│   └── user/
│       └── rime_llm.dll      #   预编译 DLL
├── common/                   # Lua filter（发布用副本）
│   ├── llm_rerank.lua        #   候选重排 filter
│   └── llm_context.lua       #   上屏文字收集
├── test_typing_eval.py       # 模拟打字评估（GPU）
├── analyze_typing.py         # 真实打字分析（对比赛文）
├── verify_typing.py          # 直接 LLM 验证 + 上下文比对
├── schema-patch.yaml         # 配置示例
├── sync_llm.ps1              # 同步到 GitHub（本地工具）
└── README.md
```

Lua filter 主副本在 `d:\OneDrive\typing\拼读双拼\配置文件\lua\`，common/ 是发布时的副本。

## 关键路径

| 项目 | 路径 |
|------|------|
| C++ 源码 | `cpp/dev/rime_llm.cpp` |
| Lua filter | `d:\OneDrive\typing\拼读双拼\配置文件\lua\llm_rerank.lua` |
| Lua 上文 | `d:\OneDrive\typing\拼读双拼\配置文件\lua\llm_context.lua` |
| llama.cpp | `D:\llama.cpp-mirror\` |
| GGUF 模型 | `d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf` |
| DLL 部署 | `C:\Program Files\Rime\weasel-0.17.4\rime_llm.dll` |
| GitHub | `D:\rime-llm-rerank\` |

## 技术栈

- **模型**：Qwen3.5-0.8B (752M), Q4_K_M 量化, GGUF 格式
- **推理**：llama.cpp C API, 并行多 seq_id batch 评分
- **评分**：CE loss, 所有候选一次 llama_decode
- **延迟**：~120ms (4tok/4cand, CPU 自动线程)
- **准确率**：真实打字 95.3% (赛文测试), benchmark 95.7%

## GPU 尝试（已放弃）

RTX 4060 Laptop 测试：最快 9.9ms (10x CPU)，但存在 CUDA graph 重编译开销、笔记本 GPU 省电波动、特定输入卡死等不稳定问题。结论：CPU 在打字场景足够稳定。

## 发布

GitHub：`D:\rime-llm-rerank\`。手动同步，不使用 CI。
