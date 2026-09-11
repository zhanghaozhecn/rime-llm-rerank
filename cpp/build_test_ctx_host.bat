@echo off
rem build_test_ctx_host.bat - build the standalone lua-host smoke test for rime_llm.dll
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d %~dp0
cl /O2 /utf-8 /I lua /DLUA_USE_WINDOWS test_ctx_host.c lua\lapi.c lua\lcode.c lua\lctype.c lua\ldebug.c lua\ldo.c lua\ldump.c lua\lfunc.c lua\lgc.c lua\llex.c lua\lmem.c lua\lobject.c lua\lopcodes.c lua\lparser.c lua\lstate.c lua\lstring.c lua\ltable.c lua\ltm.c lua\lundump.c lua\lvm.c lua\lzio.c lua\lauxlib.c lua\lbaselib.c lua\lcorolib.c lua\ldblib.c lua\liolib.c lua\lmathlib.c lua\loadlib.c lua\loslib.c lua\lstrlib.c lua\ltablib.c lua\lutf8lib.c lua\linit.c /Fe:test_ctx_host.exe
if errorlevel 1 (echo BUILD FAILED & exit /b 1)
echo BUILD OK
