@echo off
set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "RIME_DLL=C:\Program Files\Rime\weasel-0.17.4"
call "%VCVARS%" >nul 2>&1
cd /d "%~dp0"

echo === Rebuilding rime_llm.dll ===
rmdir /s /q build 2>nul
mkdir build
cd build
cmake .. -G "Visual Studio 17 2022" -A x64 >nul 2>&1
cmake --build . --config Release >nul 2>&1
cd ..

if not exist build\Release\rime_llm.dll (
    echo BUILD FAILED
    pause
    exit /b 1
)
echo BUILD OK
echo.
copy /Y build\Release\rime_llm.dll "%RIME_DLL%" >nul
if %ERRORLEVEL% neq 0 (echo Deploy FAILED - run as Administrator & pause & exit /b 1)
copy /Y build\Release\rime_llm.dll "..\user\rime_llm.dll" >nul
echo DLL deployed to RIME + cpp\user\
echo Right-click Weasel -^> Redeploy.
pause
