@echo off
set "RIME_DLL=C:\Program Files\Rime\weasel-0.17.4"
set "RIME_LUA=%APPDATA%\Rime\lua"
copy /Y build\Release\rime_llm.dll "%RIME_DLL%"
if %ERRORLEVEL% equ 0 (echo DLL deployed. Redeploy Weasel to test.) else (echo FAILED - run as Administrator)
pause
