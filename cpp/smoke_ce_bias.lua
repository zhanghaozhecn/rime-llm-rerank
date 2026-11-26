-- smoke_ce_bias.lua — CE 偏置专项冒烟（2026-11-26 负分口径 + 子目录）
-- 口径（2026-11-26 用户定案）: 词<TAB>码<TAB>负分——**只承载负分**，正分行
-- 读取端跳过；fade（(词,码) 累计 >= 3 让位）；非法第三列跳过。字-音节键
-- 同表（只打折不加分），见第⑤段。
-- 记录文件在用户文件夹 llm_rerank 子目录（迁移逻辑冒烟 = smoke_pair_key A 段）。
package.cpath = [[build/Release/?.dll]]

local SMK = os.getenv("TEMP") .. "\\ce_bias_smoke"
os.execute('mkdir "' .. SMK .. '" 2>nul')
require("rime_llm").ensure_dir(SMK .. "\\llm_rerank")
os.remove(SMK .. "\\llm_rerank\\rime_llm_debug.txt")
os.remove(SMK .. "\\llm_rerank\\rime_llm_corpus.tsv")
local TBL = SMK .. "\\llm_rerank\\ce_bias.tsv"
local TBL_SYLL = SMK .. "\\llm_rerank\\syll_chars.tsv"
-- 字-音节行与 (词,码) 行同表（2026-11-26 用户定案）：统一路径 + 分区标记
os.remove(TBL)
os.remove(TBL_SYLL)
os.remove(SMK .. "\\llm_rerank\\llm_pairfix.tsv")   -- 旧名兜底文件也清掉

rime_api = { get_user_data_dir = function() return SMK end }
function yield(c) end
ShadowCandidate = function(c) return c end
_G.llm_context_get = function()
    return "测试上文：今天天气很好，我想出去走走", "com"
end
_G.user_freq_eff = function(w, c)
    -- 生@shen 给足词频（β·log1p(1e6)≈193 ≫ CE 差）：整读分层测试要靠它
    -- 把前缀简拼字顶到融合序第 1，再看分层能否翻回来。
    if w == "生" and c == "shen" then return 1e6 end
    return (w == "与" and c == "vkh") and 0.717 or 0
end
_G.user_unigram_term = function(w, c) return 0 end
local UNI = { ["与\tvkh"] = 0 }
_G.user_uni_count = function(w, c) return UNI[w .. "\t" .. (c or "")] or 0 end
_G.user_freq_tick = 9

local CFG = {}   -- 可变开关（sentence_mode 等整句路径开关用）
local cfgmock = {
    get_bool = function(_, k)
        if k == "llm_rerank/enabled" then return true end
        if k == "llm_rerank/debug_fusion" then return true end
        if k == "llm_rerank/sentence_mode" then return CFG.sent end
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
local function mkc(t)
    -- start/_end = 码区间（3 码窗）；字-音节偏置用 span 查表
    return { text = t, comment = "", type = "table", start = 0, _end = 3 }
end
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
    f:write("# CE 偏置（smoke）\n")
    for _, line in ipairs(lines) do f:write(line .. "\n") end
    f:close()
end
-- 字-音节行（同表第二种键）：写前先清空表，避免沿袭上一段
local function write_share(lines)
    local f = io.open(TBL, "w")
    f:write("# CE 偏置（smoke）：词键 + 字-音节键同表\n")
    for _, line in ipairs(lines) do f:write(line .. "\n") end
    f:close()
end
-- 音节 → 整读字串（2026-11-26 用户定案①）
local function write_syll(lines)
    local f = io.open(TBL_SYLL, "w")
    f:write("# 音节 → 整读字串（smoke）\n")
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

local words5 = { "语文", "与", "予以", "玉", "育" }
local translation = make_translation(words5)

local function run()
    OUT = {}
    filter(translation, env)
    return OUT
end

-- 4 码 span 候选（双拼「2 码音 + 2 码形」）与换输入码的运行器
local function mkc4(t)
    return { text = t, comment = "", type = "table", start = 0, _end = 4 }
end
local function make_translation4(words)
    return {
        iter = function(self)
            local i = 0
            return function()
                i = i + 1
                return words[i] and mkc4(words[i]) or nil
            end
        end,
    }
end
local function run_x(trans, input)
    OUT = {}
    env.engine.context.input = input
    filter(trans, env)
    env.engine.context.input = "vkh"
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

-- ── ② 负分: 语文@vkh -5（词键只作用于多字）, key = 三项和 - 5 ──
write_tbl({ "语文\tvkh\t-5" })
run()
assert(#OUT == 5, "yield count 2")
local l1 = cand_line(read_record():sub(pos1), "语文")
assert(l1, "debug 与 line missing (2)")
local ce, fb, u1, key, sd1 = nums(l1)
assert(sd1 == -5, "修正-5 标注缺失: " .. l1)
assert(ce and fb and u1 and key, "数字解析失败: " .. l1)
assert(math.abs(key - (ce + fb + u1 - 5)) < 0.02,
    "key 应= ce+fb+u1-5: " .. l1)
print(string.format("[smoke] 负分: key=%.3f = ce %.3f + fb %.3f + u1 %.3f - 5 OK",
    key, ce, fb, u1))
local pos2 = #read_record() + 1

-- ── ③ 正分行不生效（2026-11-26 用户定案：字词两种键都不支持正分）；
--      非法第三列仍跳过 ──
UNI["语文	vkh"] = 0
write_tbl({ "语文	vkh	+5", "予以	vkh	+3", "玉	vkh	abc" })
run()
assert(#OUT == 5, "yield count 3")
local b3 = read_record():sub(pos2)
local l2 = cand_line(b3, "语文")
assert(l2, "debug 与 line missing (3)")
local ce2, fb2, u12, key2, sd2 = nums(l2)
assert(not sd2 or sd2 == 0, "正分行应不生效: " .. l2)
assert(ce2 and key2, "数字解析失败 (3): " .. l2)
assert(math.abs(key2 - (ce2 + fb2 + u12)) < 0.02,
    "正分行跳过后 key 应=三项和: " .. l2)
local l2b = cand_line(b3, "予以")
if l2b then
    local _, _, _, _, sdb = nums(l2b)
    assert(not sdb or sdb == 0, "予 正分行应不生效: " .. l2b)
end
local l2c = cand_line(b3, "玉")
if l2c then
    local _, _, _, _, sdc = nums(l2c)
    assert(not sdc or sdc == 0, "非法第三列行应被跳过: " .. l2c)
end
print("[smoke] 正分行不生效 + 非法行跳过 OK")
local pos3 = #read_record() + 1

-- ── ④ fade 对负分仍生效: 语文@vkh uni=3 + -5 → 无修正、三项和 ──
UNI["语文\tvkh"] = 3
write_tbl({ "语文\tvkh\t-5" })
run()
local l3 = cand_line(read_record():sub(pos3), "语文")
assert(l3, "debug 与 line missing (4)")
local ce3, fb3, u13, key3, sd3 = nums(l3)
assert(not sd3 or sd3 == 0, "负分 fade 后不应有修正标注: " .. l3)
assert(math.abs(key3 - (ce3 + fb3 + u13)) < 0.02,
    "负分 fade 后 key 应=三项和: " .. l3)
print("[smoke] 负分 fade 让位 OK")

-- ── ⑤ 字-音节偏置：ce_bias.tsv（T1 = log P(读音|字)）──
-- 与@vkh 的读音表给 -2.0；模拟 3 码 span 走「取前 2 码」回退（表键 vk）。
write_share({ "与\tvk\t-2.0" })
_G.llm_ce_share_reload = true
run()
local l4 = cand_line(read_record():sub(pos3), "与")
assert(l4, "debug 与 line missing (5)")
local ce4, fb4, u14, key4, sd4 = nums(l4)
assert(sd4 == -2, "字-音节偏置 -2 未生效: " .. l4)
assert(math.abs(key4 - (ce4 + fb4 + u14 - 2)) < 0.02,
    "key 应= ce+fb+u1-2: " .. l4)
-- 关闸后应回到三项和
_G.llm_ce_share = false
pos = #read_record() + 1
run()
local l5 = cand_line(read_record():sub(pos), "与")
assert(l5, "debug 与 line missing (6)")
local ce5, fb5, u15, key5, sd5 = nums(l5)
assert(not sd5 or sd5 == 0, "关闸后不应有字-音节偏置: " .. l5)
assert(math.abs(key5 - (ce5 + fb5 + u15)) < 0.02, "关闸 key 应=三项和: " .. l5)
_G.llm_ce_share = nil
-- 正价值不生效：本偏置只打折不加分（声调合并时占比可 >1）。
-- 清掉 ④ 留下的 UNI=3（否则 fade 让位会被误判成「正价值没生效」）
UNI["与\tvkh"] = 0
write_share({ "与\tvk\t+1.5" })
_G.llm_ce_share_reload = true
pos = #read_record() + 1
run()
local l6 = cand_line(read_record():sub(pos), "与")
assert(l6, "debug 与 line missing (7)")
local _, _, _, _, sd6 = nums(l6)
assert(not sd6 or sd6 == 0, "正价值不应生效: " .. l6)
print("[smoke] 字-音节偏置（T1）+ 关闸 + 只打折 OK")

-- ⑥ 词键不下沉到单字候选（"与"@vkh 写词键 → 单字候选不生效；
--    字-音节键才是单字的通道）
UNI["与\tvkh"] = 0
write_tbl({ "与\tvkh\t-5" })
pos = #read_record() + 1
run()
local l7 = cand_line(read_record():sub(pos), "与")
assert(l7, "debug 与 line missing (8)")
local _, _, _, key7, sd7 = nums(l7)
assert(not sd7 or sd7 == 0, "词键不应作用于单字候选: " .. l7)
print("[smoke] 词键不下沉单字 OK")

-- ⑦ 整读分层（2026-11-26 用户定案①）+ 前缀简拼不叠偏置（定案②）
--    同窗「神（整读）/ 生（shen 是 sheng 的前缀）」：词频把 生 顶到融合序
--    第 1（β·log1p(1e6)≈193 ≫ CE 差）；分层后**显示序**必须 神 在前。
--    生 作为前缀简拼不叠偏置（表里写了 生\tshen -5 也不生效）。
CFG.sent = true                       -- 整句模式才有「先长后短 + 单字分层」
_G.llm_sentence_wait_ms = 3000        -- 冒烟放宽等待（生产默认 150ms）
write_syll({ "shen\t神深身" })
write_share({ "生\tshen\t-5" })
_G.llm_ce_share_reload = true
_G.llm_syll_reload = true
run_x(make_translation4({ "神", "生" }), "shen")
assert(#OUT == 2, "yield count 7: " .. #OUT)
assert(OUT[1].text == "神", "整读应排在前缀简拼之前: " .. OUT[1].text)
assert(OUT[2].text == "生", "前缀简拼应在后: " .. OUT[2].text)
assert(_G.llm_tier_map and _G.llm_tier_map["生"] == 1,
    "生 应判为前缀简拼层")
assert(not (_G.llm_tier_map and _G.llm_tier_map["神"]), "神 应判为整读层")
local l7 = cand_line(read_record(), "生")
assert(l7, "debug 生 line missing (7)")
local _, _, _, _, sd7 = nums(l7)
assert(not sd7 or sd7 == 0, "前缀简拼不应叠偏置: " .. tostring(l7))
-- A/B：关掉分层 → 融合序说话（生 的 β·log1p(1e6) 压倒 CE）→ 生 在前。
-- 这一步证明上面的顺序翻转确实是分层起的作用（不是巧合的 CE）。
_G.llm_exact_tier = false
_G.llm_syll_reload = true
run_x(make_translation4({ "神", "生" }), "shen")
assert(OUT[1].text == "生", "关分层后应回到融合序: " .. OUT[1].text)
_G.llm_exact_tier = nil
print("[smoke] 整读分层 + 前缀不叠偏置 OK")
_G.llm_sentence_wait_ms = nil

-- ⑧ 双拼「2 码音 + 2 码形」偏置键（定案①第二用途）：4 码单字也要吃到
--    2 码音的偏置行（旧规则硬编码 #span==3，4 码静默失效）。
CFG.sent = false
write_syll({ "vk\t与玉育" })
write_tbl({ "与\tvk\t-2" })
_G.llm_ce_share_reload = true
_G.llm_syll_reload = true
run_x(make_translation4({ "与", "玉" }), "vkhx")
local l8 = cand_line(read_record(), "与")
assert(l8, "debug 与 line missing (8)")
local _, _, _, _, sd8 = nums(l8)
assert(sd8 == -2, "4 码应剥到 2 码音偏置: " .. tostring(l8))
-- A/B 关（_G.llm_exact_tier=false）→ 退回旧规则：4 码不剥 → 不叠
_G.llm_exact_tier = false
_G.llm_syll_reload = true
run_x(make_translation4({ "与", "玉" }), "vkhx")
local l8b = cand_line(read_record(), "与")
assert(l8b, "debug 与 line missing (8b)")
local _, _, _, _, sd8b = nums(l8b)
assert(not sd8b or sd8b == 0, "关新语义后 4 码不应叠偏置: " .. tostring(l8b))
_G.llm_exact_tier = nil
print("[smoke] 双拼 4 码剥离 + A/B 回退 OK")

-- ⑨ 自动前缀确认：音节不完整的单字不参与 1 字档首选（2026-11-26 定案②）
--    直测 _G.llm_prefix_gate（与 filter 同一份实现）：
--    1 字档融合序 = [生(前缀), 神(整读)]，lead = 神 → 必须确认 神；
--    去掉 tier（旧行为）→ pick = 生 ≠ lead → 不确认。
do
    local gen = { { text = "神马呢", lead = "神", lead_end = 4, score = 1.0 } }
    local function cc(t)
        return { text = t, comment = "", type = "table", start = 0, _end = 4 }
    end
    local sheng, shen = cc("生"), cc("神")
    local ordered = { sheng, shen }          -- 融合序：生 在前
    local b1 = ordered[1]
    -- code 要长于 lead（gate 要求 lead 是严格前缀）：shenma / lead=神(0..4)
    local win_new = { ordered = ordered, code = "shenma", seg_start = 0,
                      tier = { ["生"] = 1 }, gshow = nil }
    local win_old = { ordered = ordered, code = "shenma", seg_start = 0,
                      gshow = nil }
    local got = _G.llm_prefix_gate(gen, b1, 0, 6, nil, nil, nil, win_new)
    assert(got == "神", "1 字档应跳过前缀简拼字并确认 神: " .. tostring(got))
    local got_old = _G.llm_prefix_gate(gen, b1, 0, 6, nil, nil, nil, win_old)
    assert(got_old == nil, "无 tier 时旧行为：pick=生≠lead 不确认")
    print("[smoke] 1 字档跳过不完整音节字 OK")
end

-- ⑩ 同 span 取首选（2026-11-26 定案③）：同字数档会被「同长度、不同切分」的
--    候选占位（明察 span 0..7 vs lead 明朝 0..8），旧规则判失败；按 span 取
--    → 明朝 是它自己那一格的首选 → 确认。A/B 回旧口径 → 不确认。
do
    local gen = { { text = "明朝政治热", lead = "明朝", lead_end = 8,
                    score = 1.0 } }
    local function cc(t, e)
        return { text = t, comment = "", type = "table", start = 0, _end = e }
    end
    local ordered = { cc("明察", 7), cc("明朝", 8) }   -- 融合序：明察 在前
    local code = "mingchaozhengzhire"
    local win = { ordered = ordered, code = code, seg_start = 0, gshow = nil }
    assert(_G.llm_prefix_gate(gen, ordered[1], 0, #code, nil, nil, nil, win)
        == "明朝", "同 span 取首选应确认 明朝")
    _G.llm_gate_span = false
    assert(_G.llm_prefix_gate(gen, ordered[1], 0, #code, nil, nil, nil, win)
        == nil, "回同字数档时 明察 占位 → 不确认")
    _G.llm_gate_span = nil
    print("[smoke] 同 span 取首选 OK")
end

print("[smoke] SMOKE-CE-BIAS OK")