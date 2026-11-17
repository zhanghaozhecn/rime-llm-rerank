-- smoke_pairfix.lua — 词码对分数修正专项冒烟（2026-11-17 有符号表）
-- 新口径: 词<TAB>码<TAB>[+|-]分数; +200/+100=加分, -5=扣分;
-- 正分不受 fade 限制，负分保留 fade；正分候选不在层1前k也优先占窗。
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
local function mkc(t) return { text = t, comment = "", type = "table" } end
local function make_translation(words)
    return {
        iter = function(self)
            local i = 0
            return function()
                i = i + 1
                return words[i] and mkc(words[i]) or nil
            end
        end,
    }
end
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

local function write_tbl(lines)
    local f = io.open(TBL, "w")
    f:write("# 词码对分数修正（smoke）\n")
    for _, line in ipairs(lines) do f:write(line .. "\n") end
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

local words5 = { "语", "与", "予", "玉", "育" }
local translation = make_translation(words5)

local function run()
    OUT = {}
    filter(translation, env)
    return OUT
end

-- ── ① 无表文件: 机制休眠, key = 三项和 ──
os.remove(TBL)
run()
assert(#OUT == 5, "yield count")
local l0 = cand_line(read_dbg(), "与")
assert(l0, "debug 与 line missing")
assert(not l0:find("修正", 1, true), "无表文件不应有修正标注: " .. l0)
local ce0, fb0, u10, key0 = nums(l0)
assert(ce0 and key0, "数字解析失败: " .. l0)
assert(math.abs(key0 - (ce0 + fb0 + u10)) < 0.02,
    "休眠 key 应=三项和: " .. l0)
print(string.format("[smoke] 无表休眠: key=%.3f = ce %.3f + fb %.3f + u1 %.3f OK",
    key0, ce0, fb0, u10))
local pos1 = #read_dbg() + 1

-- ── ② 负分: 与@vkh -5, key = 三项和 - 5, 行尾 修正-5 ──
write_tbl({ "与\tvkh\t-5", "查\tesm" })
run()
assert(#OUT == 5, "yield count 2")
local blk = read_dbg():sub(pos1)
local l1 = cand_line(blk, "与")
assert(l1, "debug 与 line missing (2)")
assert(l1:find("修正-5", 1, true), "修正-5 标注缺失: " .. l1)
local ce, fb, u1, key = nums(l1)
assert(ce and fb and u1 and key, "数字解析失败: " .. l1)
assert(math.abs(key - (ce + fb + u1 - 5)) < 0.02,
    "key 应= ce+fb+u1-5: " .. l1)
print(string.format("[smoke] 负分: key=%.3f = ce %.3f + fb %.3f + u1 %.3f - 5 OK",
    key, ce, fb, u1))
local pos2 = #read_dbg() + 1

-- ── ③ 正分 +200: 不受 fade 影响, key = 三项和 + 200, 与排第一 ──
_G.user_uni["与\tvkh"] = 3
write_tbl({ "与\tvkh\t+200" })
run()
assert(#OUT == 5, "yield count 3")
local l2 = cand_line(read_dbg():sub(pos2), "与")
assert(l2, "debug 与 line missing (3)")
assert(l2:find("修正+200", 1, true), "修正+200 标注缺失: " .. l2)
local ce2, fb2, u12, key2 = nums(l2)
assert(ce2 and key2, "数字解析失败 (3): " .. l2)
assert(math.abs(key2 - (ce2 + fb2 + u12 + 200)) < 0.02,
    "正分 key 应= ce+fb+u1+200: " .. l2)
assert(OUT[1].text == "与", "正分应排第一: " .. OUT[1].text)
print(string.format("[smoke] 正分 +200 (uni=3 仍生效): key=%.3f = "
    .. "ce %.3f + fb %.3f + u1 %.3f + 200 OK", key2, ce2, fb2, u12))
local pos3 = #read_dbg() + 1

-- ── ④ fade 对负分仍生效: 与@vkh uni=3 + -5 → 无修正、三项和 ──
write_tbl({ "与\tvkh\t-5" })
run()
local l3 = cand_line(read_dbg():sub(pos3), "与")
assert(l3, "debug 与 line missing (4)")
assert(not l3:find("修正", 1, true), "负分 fade 后不应有修正标注: " .. l3)
local ce3, fb3, u13, key3 = nums(l3)
assert(math.abs(key3 - (ce3 + fb3 + u13)) < 0.02,
    "负分 fade 后 key 应=三项和: " .. l3)
print("[smoke] 负分 fade 让位 OK")
local pos4 = #read_dbg() + 1

-- ── ⑤ +200 / +100: 首选第一、次选第二 ──
_G.user_uni["与\tvkh"] = 0
write_tbl({ "与\tvkh\t+200", "予\tvkh\t+100" })
run()
assert(#OUT == 5, "yield count 5")
assert(OUT[1].text == "与", "固定首选应排第一: " .. OUT[1].text)
assert(OUT[2].text == "予", "固定次选应排第二: " .. OUT[2].text)
local b5 = read_dbg():sub(pos4)
local a5 = cand_line(b5, "与")
local b5l = cand_line(b5, "予")
assert(a5 and b5l, "debug 行缺失 (+200/+100)")
assert(a5:find("修正+200", 1, true), "与 应标 修正+200: " .. a5)
assert(b5l:find("修正+100", 1, true), "予 应标 修正+100: " .. b5l)
print("[smoke] 固定首选 +200 / 次选 +100 OK")
local pos5 = #read_dbg() + 1

-- ── ⑥ 正分候选不在层1前5: 仍占窗并排第一 ──
-- 8 个候选; 前5个高词频, 玉 层1 第8; 表给 玉 +200。
_G.user_uni["玉\tvkh"] = 0
_G.user_freq_eff = function(w, c)
    if c ~= "vkh" then return 0 end
    if w == "与" or w == "予" or w == "语" or w == "育" or w == "雨" then
        return 0.717
    end
    return 0
end
local words8 = { "语", "与", "予", "育", "雨", "玉", "鱼", "遇" }
local translation8 = make_translation(words8)
write_tbl({ "玉\tvkh\t+200" })
OUT = {}
filter(translation8, env)
assert(#OUT == 8, "yield count 6")
local l6 = cand_line(read_dbg():sub(pos5), "玉")
assert(l6, "正分窗准入失败: 玉 无 debug 行")
assert(l6:find("修正+200", 1, true), "玉 应标 修正+200: " .. l6)
assert(OUT[1].text == "玉", "正分窗准入后应排第一: " .. OUT[1].text)
print("[smoke] 层1前5外正分占窗 OK")

print("[smoke] SMOKE-PAIRFIX OK")
