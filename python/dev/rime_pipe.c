/*
 * rime_pipe.c — Windows 命名管道客户端 for RIME Lua
 * 延迟 ~1-2ms（vs HTTP 80-192ms），无网络栈开销
 */
#include <windows.h>
#include <lua.h>
#include <lauxlib.h>

static double g_timeout = 0.2;  /* 秒 */

/*
 * Lua: result, status = rime_pipe.request(url, body)
 * url 忽略（管道固定路径），body 是 JSON 请求体
 * 成功返回 (response_json, 200)，失败返回 (nil, "error message")
 */
static int request(lua_State *L) {
    luaL_checkstring(L, 1);  /* url — 忽略 */
    size_t body_len = 0;
    const char *body = luaL_optlstring(L, 2, NULL, &body_len);
    if (!body || body_len == 0) {
        lua_pushnil(L); lua_pushstring(L, "empty body"); return 2;
    }

    /* 连接到命名管道 */
    DWORD tmo = (DWORD)(g_timeout * 1000);
    if (WaitNamedPipeA("\\\\.\\pipe\\rime_llm", tmo) == 0) {
        lua_pushnil(L); lua_pushstring(L, "pipe not available"); return 2;
    }

    HANDLE hPipe = CreateFileA(
        "\\\\.\\pipe\\rime_llm",
        GENERIC_READ | GENERIC_WRITE,
        0, NULL, OPEN_EXISTING, 0, NULL);
    if (hPipe == INVALID_HANDLE_VALUE) {
        lua_pushnil(L); lua_pushstring(L, "connect failed"); return 2;
    }

    /* 设置为消息模式 */
    DWORD mode = PIPE_READMODE_MESSAGE;
    SetNamedPipeHandleState(hPipe, &mode, NULL, NULL);

    /* 超时 */
    COMMTIMEOUTS ct = {0};
    ct.ReadTotalTimeoutConstant = tmo;
    ct.WriteTotalTimeoutConstant = tmo;
    SetCommTimeouts(hPipe, &ct);

    /* 写请求 */
    DWORD written = 0;
    if (!WriteFile(hPipe, body, (DWORD)body_len, &written, NULL) || written != body_len) {
        CloseHandle(hPipe);
        lua_pushnil(L); lua_pushstring(L, "write failed"); return 2;
    }

    /* 读响应 */
    char buf[65536] = {0};
    DWORD nread = 0;
    if (!ReadFile(hPipe, buf, sizeof(buf) - 1, &nread, NULL) || nread == 0) {
        CloseHandle(hPipe);
        lua_pushnil(L); lua_pushstring(L, "read failed"); return 2;
    }
    CloseHandle(hPipe);

    lua_pushlstring(L, buf, nread);
    lua_pushinteger(L, 200);
    return 2;
}

/* Lua: rime_pipe.TIMEOUT = 0.2 */
static int set_timeout(lua_State *L) {
    g_timeout = luaL_checknumber(L, 3);
    return 0;
}

__declspec(dllexport) int luaopen_rime_pipe(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, request);
    lua_setfield(L, -2, "request");
    lua_pushnumber(L, g_timeout);
    lua_setfield(L, -2, "TIMEOUT");
    /* __newindex 拦截 TIMEOUT 赋值 */
    lua_newtable(L);
    lua_pushcfunction(L, set_timeout);
    lua_setfield(L, -2, "__newindex");
    lua_setmetatable(L, -2);
    return 1;
}
