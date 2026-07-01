@echo off
set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "PLUGIN_DIR=D:\llama.cpp-mirror\rime_plugin"
call "%VCVARS%" >nul 2>&1
cd /d "%PLUGIN_DIR%"

echo === Compiling bench_batch ===
if exist bench_batch.obj del bench_batch.obj
cl /O2 /arch:AVX2 /utf-8 /MD bench_batch.cpp ^
   /I..\include /I..\ggml\include /I. /EHsc ^
   /link ..\build\src\Release\llama.lib ^
         ..\build\ggml\src\Release\ggml.lib ^
         ..\build\ggml\src\Release\ggml-base.lib ^
         ..\build\ggml\src\Release\ggml-cpu.lib ^
         advapi32.lib ^
         /OUT:bench_batch.exe
if %ERRORLEVEL% neq 0 (echo BUILD FAILED & pause & exit /b 1)

echo.
echo === Running bench_batch ===
bench_batch.exe 2>nul
echo.
pause
