@echo off
chcp 65001 >nul
title 安装 LLM 推理服务
echo ============================================
echo   RIME LLM 推理服务 — 一键安装
echo ============================================
echo.
echo 将执行以下操作:
echo   1. 安装 Python 依赖 (llama-cpp-python, pywin32, numpy)
echo   2. 复制 rime_pipe.dll 到小狼毫安装目录
echo   3. 从魔搭下载模型文件 (约 500MB)
echo.
echo 预计耗时 5-15 分钟，请确保网络畅通。
echo.

REM ── 检查 Python ──
python --version >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到 Python！
    echo 请先安装 Python 3.10+ (python.org)，安装时务必勾选 Add to PATH
    pause & exit /b 1
)
echo [通过] Python 已安装 (%python --version 2>&1)

REM ── 安装依赖 ──
echo.
echo [1/3] 安装 Python 包...
pip install llama-cpp-python pywin32 numpy --quiet
if errorlevel 1 (
    echo [错误] 安装失败。重试或换源: pip install ... -i https://pypi.tuna.tsinghua.edu.cn/simple
    pause & exit /b 1
)
echo [通过] 依赖安装完成

REM ── 安装 DLL ──
echo.
echo [2/3] 安装管道通信组件...
set "RIME_DIR=C:\Program Files\Rime"
if exist "%RIME_DIR%\weasel-0.17.4" (
    copy /Y "%~dp0rime_pipe.dll" "%RIME_DIR%\weasel-0.17.4\rime_pipe.dll" >nul
    echo [通过] 已安装到 %RIME_DIR%\weasel-0.17.4
) else if exist "%RIME_DIR%\weasel-0.16.3" (
    copy /Y "%~dp0rime_pipe.dll" "%RIME_DIR%\weasel-0.16.3\rime_pipe.dll" >nul
    echo [通过] 已安装到 %RIME_DIR%\weasel-0.16.3
) else (
    echo [警告] 未能自动安装。请手动复制 rime_pipe.dll 到:
    echo   C:\Program Files\Rime\weasel-版本号\
)

REM ── 下载模型 ──
echo.
echo [3/3] 从魔搭下载模型 (约 500MB)...
if not exist "d:\gguf_models" mkdir "d:\gguf_models"
pip install modelscope --quiet 2>nul
python -c "from modelscope import snapshot_download; snapshot_download('Qwen/Qwen3.5-0.8B-GGUF', cache_dir='d:/gguf_models', allow_file_pattern='*Q4_K_M*')"

if exist "d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf" (
    echo [通过] 模型已下载到 d:\gguf_models\
) else (
    echo [错误] 模型下载失败。可能原因: 网络异常 / 磁盘空间不足。
    echo 请检查网络后重新运行本文件。
    pause & exit /b 1
)

echo.
echo ============================================
echo   安装完成！
echo.
echo   下一步: 将 lua\*.lua 复制到方案目录
echo          在 schema.yaml 中添加配置 (参考 schema-patch.yaml)
echo          双击 start_server.bat 启动服务
echo          右键小狼毫托盘 → 重新部署
echo ============================================
pause
