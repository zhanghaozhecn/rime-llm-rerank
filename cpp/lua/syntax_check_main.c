/* syntax_check_main.c — lua 语法检查器（loadfile 只编译不执行）
 * 用法: lua54syntax.exe <file.lua> → 退出码 0=OK / 2=语法错误
 * 本地维护工具，不入 git（lua 源目录，gitignore）。
 */
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"

int main(int argc, char **argv) {
  if (argc < 2) { printf("usage: lua54syntax <file.lua>\n"); return 1; }
  lua_State *L = luaL_newstate();
  if (!L) { printf("state alloc failed\n"); return 1; }
  int rc = luaL_loadfile(L, argv[1]);
  if (rc != LUA_OK) {
    printf("SYNTAX ERROR: %s\n", lua_tostring(L, -1));
    lua_close(L);
    return 2;
  }
  printf("syntax OK\n");
  lua_close(L);
  return 0;
}
