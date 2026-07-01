@echo off
title LLM Server
cd /d "%~dp0"

if not exist "d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf" (
    echo Model not found: d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf
    echo Run setup.bat first.
    pause
    exit /b 1
)

REM Find Python 3.12 (required for llama-cpp-python)
set PYCMD=
for /f "tokens=*" %%v in ('python -c "import sys; print(sys.version_info.minor)" 2^>nul') do if "%%v"=="12" set PYCMD=python
if defined PYCMD (
    where pythonw >nul 2>nul
    if not errorlevel 1 (start "" pythonw pipe_server.py) else (start "" /MIN python pipe_server.py)
    goto :started
)

REM Default python is not 3.12, try py launcher
py -3.12 -c "print('ok')" >nul 2>nul
if not errorlevel 1 (
    start "" /MIN py -3.12 pipe_server.py
    goto :started
)

echo Python 3.12 is required. Current python is not 3.12.
echo Download from https://www.python.org/downloads/
pause
exit /b 1

:started
echo LLM server started (background).
echo Stop: double-click stop_server.bat
timeout /t 2 >nul
