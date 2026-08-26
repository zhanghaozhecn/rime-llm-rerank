@echo off
REM ============================================
REM  LLM rerank installer - PLUGIN edition
REM  Starts install_plugin.ps1 with admin rights
REM  (UAC prompt appears once). Uses only the
REM  built-in Windows PowerShell 5.1.
REM ============================================

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator privileges, please confirm the UAC prompt...
  powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0install_plugin.ps1'"
  exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_plugin.ps1"
