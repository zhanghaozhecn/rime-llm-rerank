/* lua_host.c — 通用 lua 脚本宿主（冒烟用）：luaL_newstate + openlibs +
 * dofile(argv[1])。cwd 切到 exe 所在目录（与 test_ctx_host 同款，相对路径
 * 基准 = cpp\）。脚本内自行设 package.cpath / 伪 rime 环境。 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static void chdir_to_exe_dir(void) {
    char path[MAX_PATH];
    DWORD n = GetModuleFileNameA(NULL, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    char * slash = strrchr(path, '\\');
    if (slash) { *slash = '\0'; SetCurrentDirectoryA(path); }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: lua_host <script.lua>\n"); return 2; }
    chdir_to_exe_dir();
    lua_State * L = luaL_newstate();
    if (!L) { fprintf(stderr, "[FAIL] luaL_newstate\n"); return 1; }
    luaL_openlibs(L);
    if (luaL_dofile(L, argv[1])) {
        fprintf(stderr, "[FAIL] %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }
    lua_close(L);
    return 0;
}
