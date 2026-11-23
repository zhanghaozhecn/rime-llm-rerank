-- smoke_sentence_mode.lua — 整句模式（sentence_mode，2026-11-22 定案）冒烟
-- 满覆盖（FM）判定 = 候选 start/_end 恰为活动段 [start,_end)，取代
-- two_code_sentence 的词长==⌊码长/2⌋。场景：
--   A  简拼短码 "nm"：FM 进窗算 CE，PM 尾窗按引擎序（不再被层1 重排）
--   B  FM < 2 → 整窗跳过评分（S|full_len_lt2）+ 引擎序透传
--   C  多段续打：活动段 = composition:back() 切片（code="shijie"），
--      pattern/词频键/调试行随切片
--   D  sentence_mode 关闭：混合语义不变（PM 可进窗，窗外层1 序）
--   E  span 不可用兜底：回退旧长度规则 词长==⌊码长/2⌋（两码方案保真）
--   F  two_code_sentence 旧键迁移（原 smoke_tcs 合并，2026-11-22 测试
--      精简）：旧键直升整句模式 + code_pattern 锁定（.{4} 旧值被覆盖，
--      2 码即触发）+ 长度规则路径的 full_len_lt2 skip + 层1 序输出
--      （smoke_tcs 场景 B 与本文件 E 同代码路径同断言，不再单测）
--   G  子词复用排序（2026-11-23）：PM token 前缀命中 FM → 复用 CE 融合分
--      参与排序（"错" 的 token 是 FM "错事/错失" 首 token → 有分），无前缀
--      匹配的 PM（"混能"）保引擎序殿后
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

-- 异步基建（2026-11-22）适配：整句模式首轮异步挂账不评分（层1 序输出 +
-- S|async_pending），同输入二次 query 经收割回填后缓存命中走融合路径。
-- 本 helper 先跑挂账轮、等评分完成、再跑收割轮，使场景断言仍落在融合
-- 路径（FM 窗融合序 + L/C 行——语义与同步版等价）。
local function msleep(ms)
  local t = os.clock()
  while (os.clock() - t) * 1000 < ms do end
end
local function sent_run(cands, input, seg, wait_ms)
  OUT = {}; LIVE = {}
  filter(mktrans(cands), mkenv(true, input, seg))
  msleep(wait_ms or 250)
  OUT = {}; LIVE = {}
  filter(mktrans(cands), mkenv(true, input, seg))
end

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
sent_run({
    mkc("你们", 0, 2), mkc("尼玛", 0, 2), mkc("你", 0, 1), mkc("那", 0, 1),
  }, "nm", { start = 0, _end = 2 })
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
sent_run({
    mkc("世界", 5, 11), mkc("世纪", 5, 11),
    mkc("时", 5, 7), mkc("季", 9, 11), mkc("接", 10, 11),
  }, "nihaoshijie", { start = 5, _end = 11 })
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
sent_run({ mkc("一次"), mkc("一点点"), mkc("一起") },
         "iock", { start = 0, _end = 4 })
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

-- ═══ 场景 F：two_code_sentence 旧键迁移（原 smoke_tcs 合并）═══
-- 旧键读取兜底：sentence_mode 新键缺席时沿用旧键值；开启后 code_pattern
-- 锁定 '.{2,}'（方案节 '.{4}' 旧值被运行期覆盖——2 码即触发重排）。
-- F1 = 迁移配置下跑 2 码 nm：.{4} 旧值会让 pattern 不匹配（无 W 行），
--      W 行出现即证明锁定 + 迁移双生效；
-- F2 = 长度规则路径（候选无 span）的 skip：全非满长（3 字词）→
--      full_len_lt2 + 层1 序输出 + 无 C 行（原 smoke_tcs 场景 A）。
local function mkenv_tcs(input, seg)
  return {
    engine = {
      schema = { config = {
        get_bool = function(_, k)
          if k == "llm_rerank/enabled" then return true end
          if k == "llm_rerank/debug_fusion" then return true end
          if k == "llm_rerank/two_code_sentence" then return true end
          return nil   -- sentence_mode 新键缺席（旧方案形态）
        end,
        get_int = function(_, k)
          if k == "llm_rerank/max_candidates" then return 5 end
          return nil
        end,
        get_string = function(_, k)
          if k == "llm_rerank/code_pattern" then return ".{4}" end
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
-- F1：迁移 + 锁定（2 码触发即证锁定 '.{2,}' 生效）。候选文本换新词——
-- 指纹 = 上文+候选文本，同候选会命中前面场景的缓存（缓存命中不再挂账
-- 是正确生产语义，场景隔离靠换候选）
OUT = {}
LIVE = {}
filter(mktrans({
    mkc("生产", 0, 2), mkc("生活", 0, 2), mkc("生", 0, 1), mkc("活", 0, 1),
  }), mkenv_tcs("ns", { start = 0, _end = 2 }))
assert(#OUT == 4, "F1: yield count=" .. #OUT)
assert(saw_skip("async_pending"), "F1: 迁移配置未触发整句模式（无挂账）")
-- F2：长度规则 skip（原 smoke_tcs 场景 A 断言原样）
OUT = {}
LIVE = {}
filter(mktrans({ mkc("一点点"), mkc("一下子") }),
       mkenv_tcs("iock", { start = 0, _end = 4 }))
assert(#OUT == 2, "F2: yield count=" .. #OUT)
assert(OUT[1].text == "一点点" and OUT[2].text == "一下子",
    "F2: 层1序输出错: " .. OUT[1].text .. "," .. OUT[2].text)
assert(saw_skip("full_len_lt2"), "F2: 未发 S|full_len_lt2")
assert(#crows() == 0, "F2: 不应有 C 行（整窗跳过）")
print("[smoke] F 旧键迁移 + 锁定 + 长度规则 skip OK")

-- ═══ 场景 G：子词（PM）复用 FM 推理结果的零成本排序（2026-11-23）═══
-- 候选：FM = 错事 / 错失（Qwen3-0.6B 下"错事"= 2 token [错][事]），
-- PM 引擎序 = 混能 / 错。DLL 用 FM 已算 token 前缀匹配：PM "错" 的 token
-- 与 FM 首 token 相同 → 复用 ce1 得融合分；"混能" 前缀不匹配 → 无分。
-- 期望：PM 块 = 错（有分在前）+ 混能（无分引擎序殿后）——与引擎序相反。
-- 用新候选词隔离指纹（同候选会命中前面场景缓存）。
sent_run({
    mkc("错事", 0, 6), mkc("错失", 0, 6), mkc("混能", 0, 3), mkc("错", 0, 3),
  }, "cuoshi", { start = 0, _end = 6 })
assert(#OUT == 4, "G: yield count=" .. #OUT)
local gtop2 = OUT[1].text .. "," .. OUT[2].text
assert(gtop2 == "错事,错失" or gtop2 == "错失,错事",
    "G: FM 未置顶: " .. gtop2)
assert(OUT[3].text == "错", "G: 有复用分的子词应排 PM 块首: " ..
    OUT[3].text .. "," .. OUT[4].text)
assert(OUT[4].text == "混能", "G: 无复用分子词应引擎序殿后: " ..
    OUT[3].text .. "," .. OUT[4].text)
-- 复核复用分确实来自前缀匹配（而非巧合保序）：PM "错" 必须有分
local sawc = false
for _, f in ipairs(crows()) do
  if f[3] == "错" then sawc = true end
end
assert(sawc, "G: 缺 PM 行")
print("[smoke] G 子词复用排序 OK")

-- ═══ 场景 H：前缀软确认判定（2026-11-23 实验，_G.llm_prefix_confirm）═══
-- 候选：FM = 我们德文 / 我们的文（满覆盖），PM = 我们 / 我们的（首 token
-- 与 FM 相同 → 有复用分）。θ 设 0.01 保证触发；断言挂起项为多字词、
-- endp < 段末、input 与当前一致。关闭开关后同候选不再挂起。
_G.llm_prefix_confirm = true
_G.llm_prefix_confirm_theta = 0.01
_G.llm_pending_confirm = nil
sent_run({
    mkc("我们德文", 0, 10), mkc("我们的文", 0, 10),
    mkc("我们", 0, 6), mkc("我们的", 0, 8),
  }, "womendewen", { start = 0, _end = 10 })
local hpc = _G.llm_pending_confirm
assert(type(hpc) == "table", "H: 未挂起确认")
assert(type(hpc.text) == "string" and #hpc.text > 0, "H: text 空")
assert(hpc.endp and hpc.endp < 10, "H: endp 应 < 段末: " .. tostring(hpc.endp))
assert(hpc.input == "womendewen", "H: input 不符")
_G.llm_prefix_confirm = nil
_G.llm_prefix_confirm_theta = nil
_G.llm_pending_confirm = nil
sent_run({
    mkc("我们德文", 0, 10), mkc("我们的文", 0, 10),
    mkc("我们", 0, 6), mkc("我们的", 0, 8),
  }, "womendewen", { start = 0, _end = 10 })
assert(_G.llm_pending_confirm == nil, "H: 关闭后不应挂起")
print("[smoke] H 前缀软确认判定 OK")

print("[smoke] SMOKE-SENTENCE-MODE OK")
