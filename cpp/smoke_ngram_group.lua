-- smoke_ngram_group.lua — N-gram 组句候选注入 + 句级前缀判定（2026-11-23）
--
-- 组句器本体（C++ gram/词表/beam）由 ngram_parity.lua + 研究链留档对拍覆盖；
-- 本冒烟只测 lua 侧接线：生成候选前置注入、去重、满覆盖/层1/评分复用、
-- 以及"前导词一致 → 前缀确认"的新判定（§11.10）。
-- llm.ngram_load / llm.ngram_sentences 打桩（不加载真实 390MB 资产）。
--
-- 场景：
--   A  5 条组句候选（前导词全为「的」）→ 输出前 5 条 = 注入序；前缀确认
--      挂起 {text="的"}（单字路径 = 新判定才可能）
--   B  ngram_group 关闭 → 不注入、不挂起
--   C  多字前导词「今天」一致 → 挂起 {text="今天"}
--   D  方案无 simplifier（纯繁体输出）→ 运行期 gate 关闭，不注入
--   F  组句文本与引擎候选重复 → 输出无重复条目
package.cpath = [[build/Release/?.dll]]

local OUT = {}
function yield(c) table.insert(OUT, c) end
ShadowCandidate = function(c, t, txt, cm, inherit) return c end
_G.llm_context_get = function()
  return "今天的", "com"
end

local llm = require("rime_llm")
local LIVE = {}
llm.live_write = function(line) LIVE[#LIVE + 1] = line end

local MODEL = "d:/gguf_models/Qwen3-0.6B-Base-Q4_K_M.gguf"
llm.model_path = MODEL
llm.score("预热", { "x" })
local t0 = os.clock()
while not llm.is_ready() do
  if os.clock() - t0 > 90 then error("model load timeout") end
end
print(string.format("[smoke] model ready %.0fs", os.clock() - t0))

-- ── 打桩：组句器 ──────────────────────────────────────────────────────
local GEN = nil          -- 当前场景的生成结果
llm.ngram_load = function() return true end
llm.ngram_sentences = function(code, ctx, params)
  assert(params and params.topk == 5, "params.topk")
  return GEN
end

-- Candidate 构造（rime-lua 生产环境有全局 Candidate；冒烟桩同签名）
function Candidate(t, s, e, txt, cm)
  local c = { text = txt, comment = cm or "", type = t, start = s, _end = e }
  return c
end

-- mock env：sentence_mode / ngram_group / simplifier 三开关 + 活动段
local function mkenv(input, seg, opts)
  opts = opts or {}
  return {
    engine = {
      schema = { schema_id = "luna_pinyin_simp", config = {
        get_bool = function(_, k)
          if k == "llm_rerank/enabled" then return true end
          if k == "llm_rerank/debug_fusion" then return true end
          if k == "llm_rerank/sentence_mode" then return true end
          if k == "llm_rerank/prefix_confirm" then return true end
          if k == "llm_rerank/ngram_group" then return opts.ngram ~= false end
          return nil
        end,
        get_int = function(_, k)
          if k == "llm_rerank/max_candidates" then return 5 end
          return nil
        end,
        get_string = function(_, k)
          if k == "llm_rerank/code_pattern" then return ".{2,}" end
          if k == "llm_rerank/model_path" then return MODEL end
          if k == "simplifier/option_name" then
            return opts.simp == false and nil or "zh_simp"
          end
          return nil
        end,
      } },
      context = {
        input = input,
        composition = seg and { back = function() return seg end } or nil,
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

local function run(cands, input, seg, opts)
  OUT = {}; LIVE = {}
  local env = mkenv(input, seg, opts)
  filter(mktrans(cands), env)
  return env
end
local function texts()
  local t = {}
  for i, c in ipairs(OUT) do t[i] = c.text end
  return t
end

local OK = 0
local FAIL = 0
local function check(name, cond, detail)
  if cond then
    OK = OK + 1
    print("[PASS] " .. name)
  else
    FAIL = FAIL + 1
    print("[FAIL] " .. name .. (detail and ("  " .. tostring(detail)) or ""))
  end
end

-- 场景数据：input "detianqi"（8 码），活动段 [0,8)
-- 引擎候选：满覆盖 得天器 / 的天气；子词 的（0..2）、得天（0..6）
local function engine_cands()
  return {
    mkc("得天器", 0, 8), mkc("的天气", 0, 8),
    mkc("的", 0, 2), mkc("得天", 0, 6),
  }
end
local function gen5(lead, lead_end, texts)
  local items = {}
  for i, t in ipairs(texts) do
    items[i] = { text = t, lead = lead, lead_end = lead_end, score = -i }
  end
  return items
end

-- ── A：5 句前导词「的」一致 → 注入 + 单字前缀确认 ──────────────────
GEN = gen5("的", 2, { "的天气很好", "的天气真热", "的天启", "的天气", "的天气啊" })
_G.llm_pending_confirm = nil
run(engine_cands(), "detianqi", { start = 0, _end = 8 })
local tx = texts()
-- 前 5 条 = 组句候选（打分后融合序可重排，集合必须是这 5 条）
local gset, top5 = {}, {}
for i = 1, 5 do
  gset[GEN[i].text] = true
  top5[tx[i]] = true
end
local top5_ok = true
for t in pairs(gset) do
  if not top5[t] then top5_ok = false end
end
check("A 前 5 条都是组句候选", top5_ok, table.concat(tx, ","))
check("A 引擎候选排在组句候选之后", (function()
  for i = 6, #tx do
    if gset[tx[i]] then return false end
  end
  return true
end)())
local pc = _G.llm_pending_confirm
check("A 单字前缀确认挂起", pc and pc.text == "的" and pc.input == "detianqi",
      pc and (tostring(pc.text) .. "/" .. tostring(pc.input)) or "nil")

-- ── B：ngram_group 关闭 → 不注入、不挂起 ───────────────────────────
_G.llm_pending_confirm = nil
run(engine_cands(), "detianqi", { start = 0, _end = 8 }, { ngram = false })
tx = texts()
check("B 关闭时不注入", tx[1] == "得天器" or tx[1] == "的天气", tx[1])
check("B 关闭时不挂起", _G.llm_pending_confirm == nil)

-- ── C：多字前导词「今天」一致 → 挂起「今天」 ──────────────────────
GEN = gen5("今天", 6, { "今天天气好", "今天天气热", "今天晚上", "今天上午", "今天下午" })
_G.llm_pending_confirm = nil
run({
  mkc("今天天气", 0, 8), mkc("金田天气", 0, 8),
  mkc("今天", 0, 6), mkc("金田", 0, 6),
}, "jintianti", { start = 0, _end = 8 })
pc = _G.llm_pending_confirm
check("C 多字前缀确认挂起", pc and pc.text == "今天", pc and tostring(pc.text))

-- ── D：无 simplifier（繁体输出方案）→ gate 关闭 ───────────────────
GEN = gen5("的", 2, { "的天气很好", "的天气真热", "的天启", "的天气", "的天气啊" })
_G.llm_pending_confirm = nil
run(engine_cands(), "detianqi", { start = 0, _end = 8 }, { simp = false })
tx = texts()
check("D 无 simplifier 不注入", tx[1] == "得天器" or tx[1] == "的天气", tx[1])

-- ── F：组句文本与引擎候选重复 → 输出去重 ──────────────────────────
GEN = gen5("的天气", 6, { "的天气", "的天气很", "的天气真", "的天气好", "的天气啊" })
run(engine_cands(), "detianqi", { start = 0, _end = 8 })
tx = texts()
local seen, dup = {}, false
for _, t in ipairs(tx) do
  if seen[t] then dup = true end
  seen[t] = true
end
check("F 输出去重", not dup)

print(string.format("[smoke] ngram_group: %d pass, %d fail", OK, FAIL))
if FAIL > 0 then os.exit(1) end
