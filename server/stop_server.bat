@echo off
chcp 65001 >nul
title 停止 LLM 服务

echo 正在停止 LLM 推理服务...

for /f "usebackq tokens=*" %%a in ("%TEMP%\rime_llm_pids.txt") do (
    taskkill /F /PID %%a 2>nul
)
del "%TEMP%\rime_llm_pids.txt" 2>nul

echo 服务已停止。
pause
