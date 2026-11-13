-- smoke_pairfix.lua — 多音词码对预置降分修正 专项冒烟（2026-11-13）
-- 机制部署、表作参考：用户目录 llm_pairfix.tsv 存在 → 命中对融合分 −λ
-- 且 debug.txt 行尾 修正-λ 标注; fade（用户自身 uni ≥3）→ 让位;
-- 无表文件 → 机制休眠（无标注、key=三项和）。
package.cpath = [[build/Release/?.dll]]

local SMK = os.getenv("TEMP") .. "\\pairfix_smoke"
os.execute('mkdir "' .. SMK .. '" 2>nul')
os.remove(SMK .. "\\rime_llm_debug.txt")
local TBL = SMK .. "\\llm_pairfix.tsv"
os.remove(TBL)

rime_api = { get_user_data_dir = function() return SMK end }
function yield(c) end
ShadowCandidate = function(c) return c end
_G.llm_context_get = function()
    return "测试上文：今天天气很好，我想出去走走", "com"
end
-- 层1 注入: 与@vkh 强词码对史（其余 0）→ 与 进 LLM 窗
_G.user_freq_eff = function(w, c)
    return (w == "与" and c == "vkh") and 0.717 or 0
end
_G.user_unigram_term = function(w, c) return 0 end
_G.user_uni = { ["与\tvkh"] = 0 }
_G.user_freq_tick = 9

local cfgmock = {
    get_bool = function(_, k)
        if k == "llm_rerank/enabled" then return true end
        if k == "llm_rerank/debug_fusion" then return true end
        return nil
    end,
    get_int = function(_, k)
        if k == "llm_rerank/max_candidates" then return 5 end
        return nil
    end,
    get_string = function(_, k)
        if k == "llm_rerank/model_path" then
            return "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
        end
        if k == "llm_rerank/code_pattern" then return ".+" end
        return nil
    end,
}
local myc = { "语", "与", "予", "玉", "育" }
local function mkc(t) return { text = t, comment = "", type = "table" } end
local translation = {
    iter = function(self)
        local i = 0
        return function() i = i + 1; return myc[i] and mkc(myc[i]) or nil end
    end,
}
local env = { engine = { schema = { config = cfgmock },
                         context = { input = "vkh" } } }

local filter = dofile("..\\user\\llm_filter.lua")
print("[smoke] filter loaded:", type(filter))

local m = require("rime_llm")
m.model_path = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
m.score("预热", { "x" })
local t0 = os.clock()
while not m.is_ready() do
    if os.clock() - t0 > 90 then error("model load timeout") end
end
print(string.format("[smoke] model ready %.0fs", os.clock() - t0))

local function write_tbl()
    local f = io.open(TBL, "w")
    f:write("# 多音词码对预置降分修正参考表（拼读双拼; wiki 推导样例）\n")
    f:write("与\tvkh\t5\n")
    f:write("查\tesm\n")            -- λ 缺省 = 5.0
    f:close()
end
local function read_dbg()
    local f = io.open(SMK .. "\\rime_llm_debug.txt", "r")
    if not f then return "" end
    local s = f:read("*a"); f:close(); return s
end
local function cand_line(block, word)
    for line in block:gmatch("[^\r\n]+") do
        if line:sub(1, 3) == "  #" and line:find(word, 1, true) then
            return line
        end
    end
    return nil
end
local function nums(line)
    return tonumber(line:match("CE=%s*([-%d%.]+)")),
           tonumber(line:match("频%+%s*([-%d%.]+)")),
           tonumber(line:match("u1%+%s*([-%d%.]+)")),
           tonumber(line:match("key=%s*([-%d%.]+)"))
end
local OUT = {}
yield = function(c) table.insert(OUT, c) end

-- ── ① 无表文件: 机制休眠, key = 三项和 ──
filter(translation, env)
assert(#OUT == 5, "yield count")
local l0 = cand_line(read_dbg(), "与")
assert(l0, "debug 与 line missing")
assert(not l0:find("修正-λ", 1, true), "无表文件不应有修正标注: " .. l0)
local ce0, fb0, u10, key0 = nums(l0)
assert(ce0 and key0, "数字解析失败: " .. l0)
assert(math.abs(key0 - (ce0 + fb0 + u10)) < 0.02,
    "休眠 key 应=三项和: " .. l0)
print(string.format("[smoke] 无表休眠: key=%.3f = ce %.3f + fb %.3f + u1 %.3f OK",
    key0, ce0, fb0, u10))
local pos1 = #read_dbg() + 1

-- ── ② 表文件生效: 与@vkh 融合分 −5, 行尾 修正-λ5 ──
write_tbl()
OUT = {}
filter(translation, env)
assert(#OUT == 5, "yield count 2")
local blk = read_dbg():sub(pos1)
local l1 = cand_line(blk, "与")
assert(l1, "debug 与 line missing (2)")
assert(l1:find("修正-λ5", 1, true), "修正-λ5 标注缺失: " .. l1)
local ce, fb, u1, key = nums(l1)
assert(ce and fb and u1 and key, "数字解析失败: " .. l1)
assert(math.abs(key - (ce + fb + u1 - 5)) < 0.02,
    "key 应= ce+fb+u1-5: " .. l1)
print(string.format("[smoke] 预置生效: key=%.3f = ce %.3f + fb %.3f + u1 %.3f - 5 OK",
    key, ce, fb, u1))
local pos2 = #read_dbg() + 1

-- ── ③ fade 让位: 用户自身 uni=3 → 无修正、key=三项和（λ 缺省行同验）──
_G.user_uni["与\tvkh"] = 3
OUT = {}
filter(translation, env)
assert(#OUT == 5, "yield count 3")
local l2 = cand_line(read_dbg():sub(pos2), "与")
assert(l2, "debug 与 line missing (3)")
assert(not l2:find("修正-λ", 1, true), "fade 后不应有修正标注: " .. l2)
local ce2, fb2, u12, key2 = nums(l2)
assert(ce2 and key2, "数字解析失败 (3): " .. l2)
assert(math.abs(key2 - (ce2 + fb2 + u12)) < 0.02,
    "fade 后 key 应= ce+fb+u1: " .. l2)
print(string.format("[smoke] fade 让位: key=%.3f = ce %.3f + fb %.3f + u1 %.3f OK",
    key2, ce2, fb2, u12))

print("[smoke] SMOKE-PAIRFIX OK")
