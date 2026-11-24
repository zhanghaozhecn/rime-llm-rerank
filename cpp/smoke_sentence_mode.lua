-- smoke_sentence_mode.lua — 整句模式冒烟（2026-11-24 统一准入口径）
-- 准入 = 层1 词频在**等长词 + 子词**里统一取前 max_candidates（与字词模式
-- 一致，取代 2026-11-22 的"满覆盖优先占满窗"）；组句候选不占窗席、只显示
-- 1 条置顶。FM 判定（start/_end 恰为活动段）保留给 full 标志与组句。
-- 场景：
--   A  简拼短码 "nm"：等长词与子词全部进窗、全部真算 CE；full 标志仍按 FM
--   B  单候选 → 跳过评分（few_candidates）+ 引擎序透传
--   C  多段续打：活动段 = composition:back() 切片（code="shijie"）
--   D  sentence_mode 关闭：混合语义（层1 取窗）不变
--   E  span 不可用兜底：长度规则只影响 full 标志，不影响准入
--   F  two_code_sentence 旧键迁移 + 锁定 + 长度规则 full 标志
--   G  统一窗口：高频子词可排在低频等长词之前（等长 ≠ 概率高）
--   H  前缀软确认：窗口路径（首位前缀词 margin ≥ θ → 挂起）
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
local function mkenv(sent, input, seg, pfx)
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

-- 异步基建（2026-11-22）适配：整句模式 2026-11-23 起改为同步短预算
-- （150ms）——首轮即融合序；helper 仍跑二次同输入（命中缓存、0 LLM），
-- 断言落在稳定的融合路径上。
local function msleep(ms)
  local t = os.clock()
  while (os.clock() - t) * 1000 < ms do end
end
local function sent_run(cands, input, seg, wait_ms, pfx)
  OUT = {}; LIVE = {}
  filter(mktrans(cands), mkenv(true, input, seg, pfx))
  msleep(wait_ms or 250)
  OUT = {}; LIVE = {}
  filter(mktrans(cands), mkenv(true, input, seg, pfx))
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

-- ═══ 场景 A：简拼 "nm"——等长词与子词统一进窗（2026-11-24 新口径）═══
sent_run({
    mkc("你们", 0, 2), mkc("尼玛", 0, 2), mkc("你", 0, 1), mkc("那", 0, 1),
  }, "nm", { start = 0, _end = 2 })
assert(#OUT == 4, "A: yield count=" .. #OUT)
-- 准入 = 层1 统一（FM+子词），max_candidates=5 ≥ 4 → 全部进窗并真算 CE
local win1 = {}
for _, f in ipairs(crows()) do
  if f[12] == "1" then win1[#win1 + 1] = f end
end
assert(#win1 == 4, "A: 窗内应为全部 4 条（子词也进窗）: " .. #win1)
local fullmap = {}
for _, f in ipairs(win1) do
  assert(f[5] ~= "", "A: 窗内候选 ce 应非空: " .. f[3])
  fullmap[f[3]] = f[9]
end
-- full 标志仍是 FM 判定（等长=1，子词=0），但不再决定准入/顺序
assert(fullmap["你们"] == "1" and fullmap["你"] == "0",
    "A: full 标志应为 FM 判定: " .. tostring(fullmap["你"]))
local names = {}
for _, c in ipairs(OUT) do names[c.text] = true end
assert(names["你"] and names["那"] and names["你们"] and names["尼玛"],
    "A: 输出应含全部候选（统一概率序，不强制等长在前）")
print("[smoke] A 简拼短码 统一准入（子词进窗 + full 标志保留）OK")

-- ═══ 场景 B：窗 < 2（单候选）→ 跳过评分、引擎序透传 ═══
OUT = {}
LIVE = {}
filter(mktrans({ mkc("你", 0, 1) }),
       mkenv(true, "nm", { start = 0, _end = 2 }))
assert(#OUT == 1 and OUT[1].text == "你", "B: 单候选透传")
assert(saw_skip("few_candidates"), "B: 未发 S|few_candidates")
assert(#crows() == 0, "B: 不应有 C 行（跳过评分）")
print("[smoke] B 单候选跳过评分 + 引擎序透传 OK")

-- ═══ 场景 C：多段续打——活动段切片 shijie，统一准入 ═══
sent_run({
    mkc("世界", 5, 11), mkc("世纪", 5, 11),
    mkc("时", 5, 7), mkc("季", 9, 11), mkc("接", 10, 11),
  }, "nihaoshijie", { start = 5, _end = 11 })
assert(#OUT == 5, "C: yield count=" .. #OUT)
local winC = 0
for _, f in ipairs(crows()) do
  if f[12] == "1" then winC = winC + 1 end
end
assert(winC == 5, "C: 5 条全部进窗: " .. winC)
local lr = lrow()
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

-- ═══ 场景 E：span 不可用兜底——回退旧长度规则（只影响 full 标志）═══
sent_run({ mkc("一次"), mkc("一点点"), mkc("一起") },
         "iock", { start = 0, _end = 4 })
assert(#OUT == 3, "E: yield count=" .. #OUT)
win1 = {}
for _, f in ipairs(crows()) do
  if f[12] == "1" then win1[#win1 + 1] = f end
end
assert(#win1 == 3, "E: 统一准入应全部进窗: " .. #win1)
-- full 标志按长度规则兜底：一次/一起（2 字 = 4/2）FM=1；一点点（3 字）=0
local emap = {}
for _, f in ipairs(win1) do emap[f[3]] = f[9] end
assert(emap["一次"] == "1" and emap["一起"] == "1" and emap["一点点"] == "0",
    "E: 长度规则兜底 full 标志错: " .. tostring(emap["一点点"]))
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
-- 2026-11-23：整句模式已改同步短预算等待；本场景保留"超时挂账"回归，
-- 用 0 预算强制走 pending 分支（迁移是否触发整句模式仍由挂账证明）
_G.llm_sentence_wait_ms = 0
filter(mktrans({
    mkc("生产", 0, 2), mkc("生活", 0, 2), mkc("生", 0, 1), mkc("活", 0, 1),
  }), mkenv_tcs("ns", { start = 0, _end = 2 }))
_G.llm_sentence_wait_ms = nil
assert(#OUT == 4, "F1: yield count=" .. #OUT)
assert(saw_skip("async_pending"), "F1: 迁移配置未触发整句模式（无挂账）")
-- F2：长度规则兜底只影响 full 标志（2026-11-24 统一准入后不再影响准入）
OUT = {}
LIVE = {}
filter(mktrans({ mkc("一点点"), mkc("一下子") }),
       mkenv_tcs("iock", { start = 0, _end = 4 }))
assert(#OUT == 2, "F2: yield count=" .. #OUT)
local fwin = 0
for _, f in ipairs(crows()) do
  if f[12] == "1" then
    fwin = fwin + 1
    assert(f[9] == "0", "F2: 长度规则非满长 full 应=0")
  end
end
assert(fwin == 2, "F2: 统一准入应全部进窗: " .. fwin)
assert(not saw_skip("full_len_lt2"), "F2: 统一准入后不应再 skip")
print("[smoke] F 旧键迁移 + 锁定 + 长度规则 full 标志 OK")

-- ═══ 场景 G：统一窗口——高频子词可排在低频等长词前（2026-11-24 定案）═══
-- 层1 在等长词+子词里统一排序（不再"等长优先占窗"）：给「你」注入高频后，
-- 它应凭词频项排到融合序首位（等长 ≠ 概率高）。
local old_eff = _G.user_freq_eff
_G.user_freq_eff = function(t) return (t == "你") and 100 or 0 end
sent_run({
    mkc("你们", 0, 2), mkc("尼玛", 0, 2), mkc("你", 0, 1), mkc("那", 0, 1),
  }, "nm", { start = 0, _end = 2 })
_G.user_freq_eff = old_eff
assert(#OUT == 4, "G: yield count=" .. #OUT)
assert(OUT[1].text == "你", "G: 高频子词应排首位: " .. OUT[1].text)
-- 复核它确实进了窗（拿真 CE），而不是靠窗外层1 序
local gwin = false
for _, f in ipairs(crows()) do
  if f[3] == "你" and f[12] == "1" then gwin = true end
end
assert(gwin, "G: 高频子词应进评分窗")
print("[smoke] G 统一窗口 高频子词排在低频等长词前 OK")

-- ═══ 场景 H：前缀软确认（2026-11-24 合并单一路线）═══
-- 窗口路径 A 已退役：没有组句证据（本场景 ngram_group 未开、无 ngram 资产）
-- 时，即便窗口首位是"只覆盖前缀"的高频词也**不得**挂起——A 单独触发精度
-- 只有 56.8%，研究库 2×2 已判负收益。合并门的正/负判定由
-- smoke_ngram_group 场景 M 直测（lead 概率 ∧ 窗口第 1 ∧ span/文本）。
local old_eff2 = _G.user_freq_eff
_G.user_freq_eff = function(t) return (t == "我们") and 100 or 0 end
_G.llm_pending_confirm = nil
sent_run({
    mkc("我们德文", 0, 10), mkc("我们的文", 0, 10),
    mkc("我们", 0, 6), mkc("我们的", 0, 8),
  }, "womendewen", { start = 0, _end = 10 }, nil, true)
assert(_G.llm_pending_confirm == nil,
       "H: 无组句证据时窗口路径已退役，不应挂起")
_G.llm_pending_confirm = nil
sent_run({
    mkc("我们德文", 0, 10), mkc("我们的文", 0, 10),
    mkc("我们", 0, 6), mkc("我们的", 0, 8),
  }, "womendewen", { start = 0, _end = 10 }, nil, false)
_G.user_freq_eff = old_eff2
assert(_G.llm_pending_confirm == nil, "H: 关闭后不应挂起")
print("[smoke] H 前缀软确认（单一路线：无组句不确认）OK")

print("[smoke] SMOKE-SENTENCE-MODE OK")
