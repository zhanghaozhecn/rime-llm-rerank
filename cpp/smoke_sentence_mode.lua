-- smoke_sentence_mode.lua — 整句模式（sentence_mode，2026-11-22 定案）冒烟
-- 满覆盖（FM）判定 = 候选 start/_end 恰为活动段 [start,_end)，取代
-- two_code_sentence 的词长==⌊码长/2⌋。场景：
--   A  简拼短码 "nm"：FM 进窗算 CE，PM 尾窗按引擎序（不再被层1 重排）
--   B  FM < 2 → 整窗跳过评分（S|full_len_lt2）+ 引擎序透传
--   C  多段续打：活动段 = composition:back() 切片（code="shijie"），
--      pattern/词频键/调试行随切片
--   D  sentence_mode 关闭：混合语义不变（PM 可进窗，窗外层1 序）
--   E  span 不可用兜底：回退旧长度规则 词长==⌊码长/2⌋（两码方案保真）
-- 真 DLL + 真模型（Qwen3-0.6B base）；live_write 打桩截获管道行。
-- C 行 1 基下标：C=1 eng=2 word=3 s1=4 ce=5 … full=9 cerank=10 fin=11 win=12
package.cpath = [[build/Release/?.dll]]

local OUT = {}
function yield(c) table.insert(OUT, c) end
ShadowCandidate = function(c, t, txt, cm, inherit) return c end
_G.llm_context_get = function()
  return "测试上文：今天天气很好，我想去一次", "com"
end

local llm = require("rime_llm")
local LIVE = {}
llm.live_write = function(line) LIVE[#LIVE + 1] = line end

local MODEL = "d:/gguf_models/Qwen3-0.6B-Base-Q4_K_M.gguf"

-- 预热：显式加载模型 + 轮询就绪
llm.model_path = MODEL
llm.score("预热", { "x" })
local t0 = os.clock()
while not llm.is_ready() do
  if os.clock() - t0 > 90 then error("model load timeout") end
end
print(string.format("[smoke] model ready %.0fs", os.clock() - t0))

-- mock env：sentence_mode 开关 + code_pattern + composition 活动段
local function mkenv(sent, input, seg)
  return {
    engine = {
      schema = { config = {
        get_bool = function(_, k)
          if k == "llm_rerank/enabled" then return true end
          if k == "llm_rerank/debug_fusion" then return true end
          if k == "llm_rerank/sentence_mode" then return sent end
          return nil
        end,
        get_int = function(_, k)
          if k == "llm_rerank/max_candidates" then return 5 end
          return nil
        end,
        get_string = function(_, k)
          if k == "llm_rerank/code_pattern" then return ".{2,}" end
          if k == "llm_rerank/model_path" then return MODEL end
          return nil
        end,
      } },
      context = {
        input = input,
        composition = seg and
            { back = function() return seg end } or nil,
      },
    },
  }
end
local function mkc(t, s, e)
  local c = { text = t, comment = "", type = "table" }
  if s then c.start = s; c._end = e end
  return c
end
local function mktrans(cands)
  return { iter = function(self)
    local i = 0
    return function() i = i + 1
      return cands[i]
    end
  end }
end

local filter = dofile("../user/llm_filter.lua")
assert(type(filter) == "function", "filter not loaded")

local function lrows()
  local rows = {}
  for _, l in ipairs(LIVE) do
    local f = {}
    for p in (l .. "|"):gmatch("([^|]*)|") do f[#f + 1] = p end
    rows[#rows + 1] = f
  end
  return rows
end
local function crows()
  local rows = {}
  for _, f in ipairs(lrows()) do
    if f[1] == "C" then rows[#rows + 1] = f end
  end
  return rows
end
local function lrow()
  for _, f in ipairs(lrows()) do
    if f[1] == "L" then return f end
  end
  return nil
end
local function saw_skip(reason)
  for _, f in ipairs(lrows()) do
    if f[1] == "S" and f[3] == reason then return true end
  end
  return false
end

-- ═══ 场景 A：简拼 "nm"——FM(你们/尼玛) 进窗，PM(你/那) 尾窗引擎序 ═══
OUT = {}
LIVE = {}
filter(mktrans({
    mkc("你们", 0, 2), mkc("尼玛", 0, 2), mkc("你", 0, 1), mkc("那", 0, 1),
  }), mkenv(true, "nm", { start = 0, _end = 2 }))
assert(#OUT == 4, "A: yield count=" .. #OUT)
local top2 = OUT[1].text .. "," .. OUT[2].text
assert(top2 == "你们,尼玛" or top2 == "尼玛,你们",
    "A: FM 未置顶: " .. top2)
assert(OUT[3].text == "你" and OUT[4].text == "那",
    "A: PM 应按引擎序在尾: " .. OUT[3].text .. "," .. OUT[4].text)
local lr = lrow()
assert(lr and lr[3] == "nm", "A: L 行输入码应为切片 nm")
local win1 = {}
for _, f in ipairs(crows()) do
  if f[12] == "1" then win1[#win1 + 1] = f end
end
assert(#win1 == 2, "A: win=1 行数=" .. #win1)
for _, f in ipairs(win1) do
  assert(f[3] == "你们" or f[3] == "尼玛", "A: 窗内应全 FM: " .. f[3])
  assert(f[5] ~= "", "A: 窗内候选 ce 应非空: " .. f[3])
  assert(f[9] == "1", "A: 窗内候选 full 应=1: " .. f[3])
end
print("[smoke] A 简拼短码 FM 进窗 + PM 引擎序尾 OK")

-- ═══ 场景 B：FM < 2（全 PM）→ 整窗跳过 + 引擎序透传 ═══
OUT = {}
LIVE = {}
filter(mktrans({ mkc("你", 0, 1), mkc("那", 0, 1) }),
       mkenv(true, "nm", { start = 0, _end = 2 }))
assert(#OUT == 2, "B: yield count=" .. #OUT)
assert(OUT[1].text == "你" and OUT[2].text == "那",
    "B: 引擎序透传: " .. OUT[1].text .. "," .. OUT[2].text)
assert(saw_skip("full_len_lt2"), "B: 未发 S|full_len_lt2")
assert(#crows() == 0, "B: 不应有 C 行（整窗跳过）")
print("[smoke] B 满覆盖不足跳过 + 引擎序透传 OK")

-- ═══ 场景 C：多段续打——活动段切片 shijie，PM 尾窗引擎序 ═══
OUT = {}
LIVE = {}
filter(mktrans({
    mkc("世界", 5, 11), mkc("世纪", 5, 11),
    mkc("时", 5, 7), mkc("季", 9, 11), mkc("接", 10, 11),
  }), mkenv(true, "nihaoshijie", { start = 5, _end = 11 }))
assert(#OUT == 5, "C: yield count=" .. #OUT)
local topc = OUT[1].text .. "," .. OUT[2].text
assert(topc == "世界,世纪" or topc == "世纪,世界",
    "C: FM 未置顶: " .. topc)
assert(OUT[3].text == "时" and OUT[4].text == "季" and OUT[5].text == "接",
    "C: PM 应按引擎序在尾: " ..
    OUT[3].text .. "," .. OUT[4].text .. "," .. OUT[5].text)
lr = lrow()
assert(lr and lr[3] == "shijie", "C: L 行输入码应为切片 shijie")
print("[smoke] C 多段组合活动段切片 OK")

-- ═══ 场景 D：sentence_mode 关闭——混合语义不变（PM 可进窗）═══
OUT = {}
LIVE = {}
filter(mktrans({
    mkc("你们", 0, 2), mkc("尼玛", 0, 2), mkc("你", 0, 1), mkc("那", 0, 1),
  }), mkenv(false, "nm", { start = 0, _end = 2 }))
assert(#OUT == 4, "D: yield count=" .. #OUT)
local pm_in_win = 0
for _, f in ipairs(crows()) do
  if f[12] == "1" and (f[3] == "你" or f[3] == "那") then
    pm_in_win = pm_in_win + 1
  end
end
assert(pm_in_win >= 1, "D: 关闭态 PM 应可进窗（层1 前 k）")
print("[smoke] D 关闭态混合语义（PM 可进窗）OK")

-- ═══ 场景 E：span 不可用兜底——回退旧长度规则（两码方案保真）═══
OUT = {}
LIVE = {}
filter(mktrans({ mkc("一次"), mkc("一点点"), mkc("一起") }),
       mkenv(true, "iock", { start = 0, _end = 4 }))
assert(#OUT == 3, "E: yield count=" .. #OUT)
local f2 = OUT[1].text .. "," .. OUT[2].text
assert(f2 == "一次,一起" or f2 == "一起,一次",
    "E: 满长组未置顶: " .. f2)
assert(OUT[3].text == "一点点", "E: 非满长应居尾: " .. OUT[3].text)
win1 = {}
for _, f in ipairs(crows()) do
  if f[12] == "1" then win1[#win1 + 1] = f end
end
assert(#win1 == 2, "E: win=1 行数=" .. #win1)
for _, f in ipairs(win1) do
  assert(f[9] == "1", "E: 窗内候选 full 应=1")
end
print("[smoke] E span 不可用回退旧长度规则 OK")

print("[smoke] SMOKE-SENTENCE-MODE OK")
