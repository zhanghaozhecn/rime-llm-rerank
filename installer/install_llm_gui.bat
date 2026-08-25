@echo off
REM ============================================
REM  LLM rerank installer launcher (GUI)
REM  Starts install_llm_gui.ps1 with admin rights
REM  (UAC prompt appears once). Prefers PowerShell
REM  7 (pwsh) when available, falls back to the
REM  built-in Windows PowerShell 5.1.
REM ============================================

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator privileges, please confirm the UAC prompt...
  where pwsh.exe >nul 2>&1
  if %errorlevel% equ 0 (
    powershell -NoProfile -Command "Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0install_llm_gui.ps1'"
  ) else (
    powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0install_llm_gui.ps1'"
  )
  exit /b
)

where pwsh.exe >nul 2>&1
if %errorlevel% equ 0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_llm_gui.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_llm_gui.ps1"
)
