# C++ Plugin Build Guide

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Visual Studio Build Tools | 2022 | C++ desktop dev + CMake tools |
| CMake | 3.16+ | Already included in VS |
| llama.cpp | latest | Need to compile static libs |
| Lua 5.4 headers | included | Already in this directory |

## Step 1: Clone and build llama.cpp

```powershell
git clone https://gitcode.com/ggerganov/llama.cpp.git D:\llama.cpp-mirror
cd D:\llama.cpp-mirror
mkdir build && cd build
cmake .. -G "Visual Studio 17 2022" -A x64 -DGGML_AVX2=ON -DGGML_CUDA=OFF -DGGML_VULKAN=OFF
cmake --build . --config Release --target llama --parallel 8
```

## Step 2: Build rime_llm.dll

Double-click `rebuild.bat` in this directory, or run:

```powershell
mkdir build && cd build
cmake .. -G "Visual Studio 17 2022" -A x64
cmake --build . --config Release
```

The DLL will be at `build\Release\rime_llm.dll`.

## Step 3: Deploy

```powershell
# Admin required
Copy-Item -Force build\Release\rime_llm.dll "C:\Program Files\Rime\weasel-0.17.4\"
Copy-Item -Force build\Release\rime_llm.dll "..\user\"   # for sync
```

## Benchmarks

```powershell
build_bench.bat     # compile and run latency benchmark
```
