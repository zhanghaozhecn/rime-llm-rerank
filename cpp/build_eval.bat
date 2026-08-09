@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d %~dp0
cl /O2 /std:c++17 /EHsc /DNDEBUG /MT eval_long_cand.cpp /I D:\llama.cpp-mirror\include /I D:\llama.cpp-mirror\ggml\include D:\llama.cpp-mirror\build-mt\src\Release\llama.lib D:\llama.cpp-mirror\build-mt\ggml\src\Release\ggml.lib D:\llama.cpp-mirror\build-mt\ggml\src\Release\ggml-base.lib D:\llama.cpp-mirror\build-mt\ggml\src\Release\ggml-cpu.lib /Fe:eval_long_cand.exe /link /LTCG advapi32.lib
