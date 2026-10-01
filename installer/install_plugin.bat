@echo off
REM ============================================
REM  LLM rerank installer - PLUGIN edition
REM  Starts install_plugin.ps1 with admin rights
REM  (UAC prompt appears once).
REM  Interpreter: pwsh 7 when available (preferred),
REM  else built-in Windows PowerShell 5.1 - the
REM  script has a UTF-8 BOM so 5.1 parses its
REM  Chinese text correctly (without BOM 5.1 reads
REM  it as ANSI and dies at parse time: "flash exit").
REM ============================================

setlocal
set "PS="
for %%I in (pwsh.exe) do if not defined PS set "PS=%%~$PATH:I"
if not defined PS if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PS=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PS set "PS=powershell.exe"

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator privileges, please confirm the UAC prompt...
  "%PS%" -NoProfile -Command "Start-Process '%PS%' -Verb RunAs -ArgumentList '-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','%~dp0install_plugin.ps1'"
  exit /b
)

REM -STA: WinForms requires a single-threaded apartment (pwsh 7 defaults to MTA)
"%PS%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0install_plugin.ps1"
