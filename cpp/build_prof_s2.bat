@echo off
REM build_prof_s2.bat - build prof_s2.exe (thread-count latency probe)
REM usage: build_prof_s2.bat  (output: prof_s2.exe here)
REM prereq: llama.cpp MT static build (LLAMA_ROOT, default D:/llama.cpp-mirror)
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d %~dp0
if "%LLAMA_ROOT%"=="" set LLAMA_ROOT=D:/llama.cpp-mirror
cl /O2 /std:c++17 /EHsc /DNDEBUG /MT /utf-8 prof_s2.cpp /I %LLAMA_ROOT%\include /I %LLAMA_ROOT%\ggml\include %LLAMA_ROOT%\build-mt\src\Release\llama.lib %LLAMA_ROOT%\build-mt\ggml\src\Release\ggml.lib %LLAMA_ROOT%\build-mt\ggml\src\Release\ggml-base.lib %LLAMA_ROOT%\build-mt\ggml\src\Release\ggml-cpu.lib /Fe:prof_s2.exe /link /LTCG advapi32.lib
exit /b %errorlevel%
