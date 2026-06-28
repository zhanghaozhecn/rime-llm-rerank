@echo off
chcp 65001 >nul
title 启动 LLM 服务
cd /d "%~dp0"

echo ============================================
echo   启动 LLM 推理服务
echo ============================================
echo.

if not exist "d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf" (
    echo [错误] 模型文件未找到: d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf
    echo.
    echo 请先运行 setup.bat 安装模型。
    pause
    exit /b 1
)

echo 模型: Qwen3.5-0.8B-Q4_K_M.gguf (500MB)
echo 配置: 4 进程并行，每进程 2 线程
echo.

echo 正在后台启动...
where pythonw >nul 2>nul
if %errorlevel% equ 0 (
    start "" pythonw pipe_server.py
) else (
    start "" /MIN python pipe_server.py
)

echo 服务已在后台启动。
echo.
echo 验证: 右键小狼毫托盘 → 重新部署 → 打字看是否有 ⚡ 标记
echo 停止: 双击 stop_server.bat
echo.
echo 此窗口即将关闭...
timeout /t 3 >nul
