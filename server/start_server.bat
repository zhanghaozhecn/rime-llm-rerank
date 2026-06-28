@echo off
title LLM Server
cd /d "%~dp0"

if not exist "d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf" (
    echo Model not found: d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf
    echo Run setup.bat first.
    pause
    exit /b 1
)

where pythonw >nul 2>nul
if %errorlevel% equ 0 (
    start "" pythonw pipe_server.py
) else (
    start "" /MIN python pipe_server.py
)

echo LLM server started (background).
echo Stop: double-click stop_server.bat
timeout /t 2 >nul
