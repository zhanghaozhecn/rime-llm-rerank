@echo off
title RIME LLM Rerank - Setup
echo ============================================
echo   RIME LLM Rerank - One-Click Setup
echo ============================================
echo.
echo This will:
echo   1. Install Python packages: llama-cpp-python, pywin32, numpy
echo   2. Copy rime_pipe.dll to RIME program directory
echo   3. Download model from ModelScope (~500MB)
echo.
echo NOTE: Right-click this file -^> "Run as Administrator" for DLL install.
echo Estimated time: 5-15 min. Requires internet.
echo.

python --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Python not found.
    echo Install Python 3.10+ from python.org
    echo Check "Add Python to PATH" during install.
    pause
    exit /b 1
)
echo [OK] Python found

echo.
echo [1/3] Python packages...
pip show llama-cpp-python >nul 2>&1
if errorlevel 1 (
    echo   Installing llama-cpp-python pywin32 numpy...
    pip install llama-cpp-python pywin32 numpy --quiet
    if errorlevel 1 (
        echo [ERROR] Install failed. Try:
        echo   pip install llama-cpp-python pywin32 numpy -i https://pypi.tuna.tsinghua.edu.cn/simple
        pause
        exit /b 1
    )
) else (
    echo   [SKIP] Already installed
)

echo.
echo [2/3] Pipe DLL...
set "RIME_DIR=C:\Program Files\Rime"
set "DLL_DST="
if exist "%RIME_DIR%\weasel-0.17.4" set "DLL_DST=%RIME_DIR%\weasel-0.17.4\rime_pipe.dll"
if exist "%RIME_DIR%\weasel-0.16.3" set "DLL_DST=%RIME_DIR%\weasel-0.16.3\rime_pipe.dll"
if "%DLL_DST%"=="" (
    echo   [WARN] RIME not found. Manually copy rime_pipe.dll to RIME program dir.
) else if exist "%DLL_DST%" (
    echo   [SKIP] Already installed
) else (
    copy /Y "%~dp0rime_pipe.dll" "%DLL_DST%" >nul 2>&1
    if errorlevel 1 (
        echo   [WARN] Permission denied. Right-click -^> Run as Administrator.
    ) else (
        echo   [OK] Installed
    )
)

echo.
echo [3/3] Model file...
if exist "d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf" (
    echo   [SKIP] Already downloaded
) else (
    if not exist "d:\gguf_models" mkdir "d:\gguf_models"
    echo   Downloading from ModelScope (~500MB)...
    pip install modelscope --quiet 2>nul
    python -c "from modelscope import snapshot_download; snapshot_download('unsloth/Qwen3.5-0.8B-GGUF', cache_dir='d:/gguf_models', allow_file_pattern='*Q4_K_M*')"
    if exist "d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf" (
        echo   [OK] Download complete
    ) else (
        echo   [ERROR] Download failed. Check internet and retry.
        pause
        exit /b 1
    )
)

echo.
echo ============================================
echo   Setup complete!
echo.
echo   Next steps:
echo   1. Copy lua\*.lua to your schema lua/ folder
echo   2. Add config from schema-patch.yaml to schema.yaml
echo   3. Double-click start_server.bat
echo   4. Right-click Weasel tray -^> Redeploy
echo ============================================
pause
