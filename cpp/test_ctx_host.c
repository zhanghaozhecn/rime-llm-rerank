/* test_ctx_host.c — rime_llm.dll lua 桥冒烟 + S2 基准（独立 mini host）
 * 冒烟：require / llm_context+kick_context 注册 / COM/UIA 快照可取 / lua 语法。
 * S2 基准（2026-09-11 卡顿排查）A/B：不触发 llm_context（ctxlink 线程未启）
 * vs 触发+kick（线程活跃）各测 score ×5 —— 定位后台线程对推理耗时的影响。
 * score 直调无 lua filter 缓存，C++ 侧同 ctx 连续调用走 prep 命中形态（S2 主导）。
 * 编译：build_test_ctx_host.bat（cl + cpp/lua 内嵌源码）
 * 路径：库与 lua 一律用**相对路径**，运行前把 cwd 切到 exe 所在目录（cpp\）——
 *       无需任何绝对路径，仓库整体搬目录/换盘符后照样跑。
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* 把工作目录切到 exe 所在目录（cpp\）——与 build_test_ctx_host.bat 的 cd /d %~dp0 同口径 */
static void chdir_to_exe_dir(void) {
    char path[MAX_PATH];
    DWORD n = GetModuleFileNameA(NULL, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    char * slash = strrchr(path, '\\');
    if (slash) { *slash = '\0'; SetCurrentDirectoryA(path); }
}

static int fail(const char * what) {
    fprintf(stderr, "[FAIL] %s\n", what);
    return 1;
}

static int run(lua_State * L, const char * code) {
    if (luaL_dostring(L, code))
        return fail(lua_tostring(L, -1));
    return 0;
}

/* 轮询 is_ready（宿主侧 sleep） */
static int wait_ready(lua_State * L, int max_ms) {
    for (int i = 0; i < max_ms / 250; i++) {
        lua_getglobal(L, "package");
        lua_getfield(L, -1, "loaded");
        lua_getfield(L, -1, "rime_llm");
        lua_getfield(L, -1, "is_ready");
        if (lua_isfunction(L, -1)) {
            lua_call(L, 0, 1);
            int ready = lua_toboolean(L, -1);
            lua_pop(L, 4);
            if (ready) return 1;
        } else {
            lua_pop(L, 4);
        }
        Sleep(250);
    }
    return 0;
}

int main(void) {
    chdir_to_exe_dir();   /* cwd = cpp\（相对路径基准） */
    lua_State * L = luaL_newstate();
    if (!L) return fail("luaL_newstate");
    luaL_openlibs(L);

    if (run(L,
        "package.cpath = [[build/Release/?.dll]]\n"
        "local m = require('rime_llm')\n"
        "print('[host] funcs:', type(m.llm_context), type(m.kick_context))\n"))
        return 1;

    /* 模型加载：设路径（本机实际位置）+ score 首调懒触发 + 宿主轮询 */
    if (run(L,
        "package.loaded.rime_llm.model_path = "
        "'d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf'\n"
        "package.loaded.rime_llm.score('预热', {'x'})\n"))
        return 1;
    if (!wait_ready(L, 60000)) return fail("model load timeout");

    if (run(L,
        "local m = package.loaded.rime_llm\n"
        "local ctx = '已进行测试在文档中三种徽章'\n"
        "local cands = {'第一','地一','地衣','第壹','帝一'}\n"
        "m.score(ctx, cands)  -- 首跑建立 prep\n"
        "bench = function(tag)\n"
        "  local best, worst, sum = 1e9, 0, 0\n"
        "  for i = 1, 10 do\n"
        "    local t = os.clock()\n"
        "    m.score(ctx, cands)\n"
        "    local ms = (os.clock() - t) * 1000\n"
        "    if ms < best then best = ms end\n"
        "    if ms > worst then worst = ms end\n"
        "    sum = sum + ms\n"
        "  end\n"
        "  print(string.format('[bench %s] best=%.0f avg=%.0f worst=%.0f ms',\n"
        "                      tag, best, sum / 10, worst))\n"
        "end\n"
        "bench('A-no-ctxlink')\n"))
        return 1;

    /* 触发 ctxlink 线程 + 持续活跃 */
    if (run(L,
        "local m = package.loaded.rime_llm\n"
        "m.llm_context()\n"
        "m.kick_context()\n"))
        return 1;
    Sleep(4000);
    if (run(L,
        "local m = package.loaded.rime_llm\n"
        "m.kick_context()\n"
        "local t, s = m.llm_context()\n"
        "print('[host] ctx: ' .. (t and ('src=' .. s .. ' [' .. t .. ']') or 'nil'))\n"
        "m.kick_context()\n"))
        return 1;
    Sleep(100);
    if (run(L, "bench('B-ctxlink-active')\n"))
        return 1;

    if (run(L,
        "for _, f in ipairs({'llm_filter.lua', 'llm_processor.lua'}) do\n"
        "  local chunk, err = loadfile('../user/' .. f)\n"
        "  print('[host] syntax', f, chunk and 'OK' or err)\n"
        "end\n"
        /* 探测 rime-lua 暴露的全局匹配函数（编码模式匹配用哪个引擎的实测依据） */
        "for _, n in ipairs({'regex_match','regex_search','regex_replace','utf8'}) do\n"
        "  print('[host] global', n, type(_G[n]))\n"
        "end\n"
        /* match_code 语义探针（2026-09-30 编码模式匹配） */
        "local mc = package.loaded.rime_llm.match_code\n"
        "print('[host] match_code type:', type(mc))\n"
        "local function t(pat, code)\n"
        "  local ok, r = pcall(mc, pat, code)\n"
        "  print(string.format('[host]   %-14s vs %-7s -> %s', pat, code, ok and tostring(r) or ('ERR ' .. tostring(r))))\n"
        "end\n"
        "if type(mc) == 'function' then\n"
        "  t('.{4}', 'abcd')      -- 期望 true\n"
        "  t('.{4}', 'abcde')     -- 期望 false（4 码以外不匹配）\n"
        "  t('.{4,}', 'abcd')     -- 期望 true\n"
        "  t('.{4,}', 'abcde')    -- 期望 true\n"
        "  t('.{3,4}', 'abc')     -- 期望 true\n"
        "  t('.{3,4}', 'abcde')   -- 期望 false\n"
        "  t('[abcde]{4}', 'abcd')-- 期望 true\n"
        "  t('[abcde]{4}', 'abcf')-- 期望 false\n"
        "  t('.+', 'a')           -- 期望 true\n"
        "  t('', 'a')             -- 期望 true（空=总是匹配）\n"
        "  t('(', 'a')            -- 非法模式 -> 回退默认 .{4}\n"
        "end\n"))
        return 1;

    printf("[host] SMOKE OK\n");
    lua_close(L);
    return 0;
}
