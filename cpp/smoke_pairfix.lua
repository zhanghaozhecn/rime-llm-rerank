-- smoke_pairfix.lua — 词码对扣分修正专项冒烟（2026-11-21 负分口径 + 子目录）
-- 口径（2026-11-21 解耦定案）: 词<TAB>码<TAB>-分数 只承载负分（CE 偏差
-- 降噪，评分窗内生效、受 fade）；正分行/非法行读取端跳过（固定候选归
-- 拼读双拼 pin_candidates.tsv + pin_filter.lua）。记录文件在用户文件夹
-- llm_rerank 子目录（迁移逻辑冒烟 = smoke_pair_key A 段）。
package.cpath = [[build/Release/?.dll]]

local SMK = os.getenv("TEMP") .. "\\pairfix_smoke"
os.execute('mkdir "' .. SMK .. '" 2>nul')
require("rime_llm").ensure_dir(SMK .. "\\llm_rerank")
os.remove(SMK .. "\\llm_rerank\\rime_llm_debug.txt")
os.remove(SMK .. "\\llm_rerank\\rime_llm_corpus.tsv")
local TBL = SMK .. "\\llm_rerank\\llm_pairfix.tsv"
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
local UNI = { ["与\tvkh"] = 0 }
_G.user_uni_count = function(w, c) return UNI[w .. "\t" .. (c or "")] or 0 end
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
            return "d:/gguf_models/Qwen3-0.6B-Base-Q4_K_M.gguf"
        end
        if k == "llm_rerank/code_pattern" then return ".+" end
        return nil
    end,
    get_list = function(_, k)
        if k == "engine/filters" then
            return { size = 2, get_value_at = function(_, i)
                return { get_string = function()
                    return (i == 0) and "simplifier" or "llm_filter"
                end }
            end }
        end
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
m.model_path = "d:/gguf_models/Qwen3-0.6B-Base-Q4_K_M.gguf"
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
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local s = f:read("*a"); f:close(); return s
end
local function read_record()
    return read_file(SMK .. "\\llm_rerank\\rime_llm_debug.txt") .. "\n"
        .. read_file(SMK .. "\\llm_rerank\\rime_llm_corpus.tsv")
end
local function tsv_split(line)
    local out, pos = {}, 1
    while true do
        local p = line:find("\t", pos, true)
        if not p then out[#out + 1] = line:sub(pos); break end
        out[#out + 1] = line:sub(pos, p - 1)
        pos = p + 1
    end
    return out
end
local function cand_line(_, word)
    local block = read_record()
    local wins = {}
    for line in block:gmatch("[^\r\n]+") do
        if line:sub(1, 2) == "W\t" then
            local f = tsv_split(line)
            if f[2] and f[9] then wins[#wins + 1] = { id = f[2], final = f[9] } end
        end
    end
    for i = #wins, 1, -1 do
        local w = wins[i]
        local rank = 1
        for cand in w.final:gmatch("[^,]+") do
            if cand == word then
                local prefix = w.id .. "|D|" .. rank .. "|"
                for line in block:gmatch("[^\r\n]+") do
                    if line:sub(1, #prefix) == prefix then return line end
                end
            end
            rank = rank + 1
        end
    end
    return nil
end
local function nums(line)
    return tonumber(line:match("ce=(%-?[%d%.]+)")),
           tonumber(line:match("fb=(%-?[%d%.]+)")),
           tonumber(line:match("u1=(%-?[%d%.]+)")),
           tonumber(line:match("key=(%-?[%d%.]+)")),
           tonumber(line:match("sdelta=(%-?[%d%.]+)"))
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
local l0 = cand_line(read_record(), "与")
assert(l0, "debug 与 line missing")
local ce0, fb0, u10, key0, sd0 = nums(l0)
assert(not sd0 or sd0 == 0, "无表文件不应有修正标注: " .. l0)
assert(ce0 and key0, "数字解析失败: " .. l0)
assert(math.abs(key0 - (ce0 + fb0 + u10)) < 0.02,
    "休眠 key 应=三项和: " .. l0)
print(string.format("[smoke] 无表休眠: key=%.3f = ce %.3f + fb %.3f + u1 %.3f OK",
    key0, ce0, fb0, u10))
local pos1 = #read_record() + 1

-- ── ② 负分: 与@vkh -5, key = 三项和 - 5, 行尾 修正-5 ──
write_tbl({ "与\tvkh\t-5" })
run()
assert(#OUT == 5, "yield count 2")
local l1 = cand_line(read_record():sub(pos1), "与")
assert(l1, "debug 与 line missing (2)")
local ce, fb, u1, key, sd1 = nums(l1)
assert(sd1 == -5, "修正-5 标注缺失: " .. l1)
assert(ce and fb and u1 and key, "数字解析失败: " .. l1)
assert(math.abs(key - (ce + fb + u1 - 5)) < 0.02,
    "key 应= ce+fb+u1-5: " .. l1)
print(string.format("[smoke] 负分: key=%.3f = ce %.3f + fb %.3f + u1 %.3f - 5 OK",
    key, ce, fb, u1))
local pos2 = #read_record() + 1

-- ── ③ 正分行/非法行读取端跳过（2026-11-21 解耦）──
UNI["与\tvkh"] = 0
write_tbl({ "与\tvkh\t+200", "予\tvkh\t+100", "玉\tvkh\tabc" })
run()
assert(#OUT == 5, "yield count 3")
local b3 = read_record():sub(pos2)
local l2 = cand_line(b3, "与")
assert(l2, "debug 与 line missing (3)")
local ce2, fb2, u12, key2, sd2 = nums(l2)
assert(not sd2 or sd2 == 0, "正分行应被跳过、无修正标注: " .. l2)
assert(ce2 and key2, "数字解析失败 (3): " .. l2)
assert(math.abs(key2 - (ce2 + fb2 + u12)) < 0.02,
    "正分行跳过后 key 应=三项和: " .. l2)
local l2b = cand_line(b3, "予")
if l2b then
    local _, _, _, _, sdb = nums(l2b)
    assert(not sdb or sdb == 0, "予 正分行应被跳过: " .. l2b)
end
local l2c = cand_line(b3, "玉")
if l2c then
    local _, _, _, _, sdc = nums(l2c)
    assert(not sdc or sdc == 0, "非法第三列行应被跳过: " .. l2c)
end
print("[smoke] 正分行 + 非法行读取端跳过 OK")
local pos3 = #read_record() + 1

-- ── ④ fade 对负分仍生效: 与@vkh uni=3 + -5 → 无修正、三项和 ──
UNI["与\tvkh"] = 3
write_tbl({ "与\tvkh\t-5" })
run()
local l3 = cand_line(read_record():sub(pos3), "与")
assert(l3, "debug 与 line missing (4)")
local ce3, fb3, u13, key3, sd3 = nums(l3)
assert(not sd3 or sd3 == 0, "负分 fade 后不应有修正标注: " .. l3)
assert(math.abs(key3 - (ce3 + fb3 + u13)) < 0.02,
    "负分 fade 后 key 应=三项和: " .. l3)
print("[smoke] 负分 fade 让位 OK")

print("[smoke] SMOKE-PAIRFIX OK")
