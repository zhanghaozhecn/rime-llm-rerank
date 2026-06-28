@echo off
for /f "usebackq tokens=*" %%a in ("%TEMP%\rime_llm_pids.txt") do (
    taskkill /F /PID %%a 2>nul
)
taskkill /F /IM python.exe 2>nul
taskkill /F /IM pythonw.exe 2>nul
del "%TEMP%\rime_llm_pids.txt" 2>nul
