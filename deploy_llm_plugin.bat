@echo off
REM ============================================
REM  rime-llm-rerank plugin one-click deploy
REM  Run on the target machine (double-click)
REM  Auto-elevates to admin, then runs deploy_llm_plugin.ps1
REM  Copies plugin DLLs to Rime install dir, lua to Rime user dir,
REM  patches schema (idempotent), then you redeploy from tray.
REM  Optional args: -Gpu  -ModelPath <path>  -InstallDir <path>
REM                 -SchemaName pdsp.schema.yaml  -Force
REM ============================================

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator privileges, please confirm the UAC prompt...
  powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy_llm_plugin.ps1" %*
pause
