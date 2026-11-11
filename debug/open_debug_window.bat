@echo off
REM ============================================
REM  LLM live debug window - PLUGIn edition
REM  Starts llm_debug_view.ps1 (WinForms viewer
REM  reading named pipe rime_llm_live).
REM  Interpreter: pwsh 7 when available
REM  (preferred), else built-in PowerShell 5.1 -
REM  the script has a UTF-8 BOM so 5.1 parses
REM  its Chinese text correctly.
REM ============================================

setlocal
set "PS="
for %%I in (pwsh.exe) do if not defined PS set "PS=%%~$PATH:I"
if not defined PS if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PS=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PS set "PS=powershell.exe"

REM -STA: WinForms requires a single-threaded apartment (pwsh 7 defaults to MTA)
"%PS%" -noProfile -STA -ExecutionPolicy Bypass -File "%~dp0llm_debug_view.ps1" %*
