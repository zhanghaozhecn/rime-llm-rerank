-- smoke_prefix_gate_model.lua — 前缀确认门（模型）行为冒烟（2026-11-25）
--
-- 验证插件侧接线的三条：
--   A  模型可用时：前缀确认 = (model score ≥ τ) ∧ 非 ta 族 ∧ p≥0.5
--      （逐例与 _G.llm_prefix_score 的分数对照）
--   B  τ 边界：_G.llm_prefix_tau=0 → 全确认；=1 → 全不确认
--   C  ta 族黑名单：lead=他们 一律不确认；_G.llm_prefix_tablock=0 时放行
--   D  P 门替换：p<0.5 不确认（训练域下界），p 在 0.5~0.95 也可确认
--
-- 跑法（cwd = 插件 cpp\；需 RIME_LLM_PREFIX_MODEL_PATH 指向模型）：
--   lua_host.exe smoke_prefix_gate_model.lua
package.cpath = [[build/Release/?.dll]]

local llm = require("rime_llm")
llm.live_write = function() end
_G.llm_context_get = function() return "", "" end

local CASES = os.getenv("PG_CASES")
        or "../llm-rerank-research/eval/lgb/pg_cases.lua"
dofile("../user/llm_filter.lua")
local m = _G.llm_prefix_model_reload and _G.llm_prefix_model_reload()
if not m then error("模型未加载（RIME_LLM_PREFIX_MODEL_PATH?）") end
local TAU = m.tau
print(string.format("[smoke] model: %d 树 τ=%.6f", #m.trees, TAU))

local npass, nfail = 0, 0
local function chk(name, cond, extra)
  if cond then
    npass = npass + 1
  else
    nfail = nfail + 1
    print(string.format("[FAIL] %s %s", name, extra or ""))
  end
end

local function to_win(c)
  local ordered = {}
  for _, o in ipairs(c.ordered) do
    ordered[#ordered + 1] = { text = o.t, start = 0, _end = o.e }
  end
  local gen = {}
  for _, g in ipairs(c.gen) do
    gen[#gen + 1] = { score = g.s, lead = g.lead, lead_end = g.le,
                      text = g.text }
  end
  return gen, ordered
end

local function class_first_text(ord, lead)
  local single = (utf8.len(lead) == 1)
  for _, o in ipairs(ord) do
    local n = utf8.len(o.text) or #o.text
    if (n == 1) == single then return o.text end
  end
end
local function put_class_first(ord, text)
  local single = (utf8.len(text) == 1)
  local idx
  for i, o in ipairs(ord) do
    local n = utf8.len(o.text) or #o.text
    if (n == 1) == single then idx = i; break end
  end
  if not idx then return end
  local j
  for i, o in ipairs(ord) do if o.text == text then j = i; break end end
  if j and j ~= idx then ord[idx], ord[j] = ord[j], ord[idx] end
end

-- A：逐例与分数对照（2026-11-26 起结构证据 = 同字数档首选）
local cases = dofile(CASES)
local n_a = 0
for _, c in ipairs(cases) do
  local gen, ordered = to_win(c)
  local win = { ordered = ordered, code = c.code, seg_start = 0,
                gshow = c.gshow }
  local sc = _G.llm_prefix_score(gen, c.lead, c.p, c.le, c.ce3,
                                 #c.code, c.ctx_chars, win)
  if sc then
    local b1 = { text = c.lead, start = 0, _end = c.le }
    local got = _G.llm_prefix_gate(gen, b1, 0, #c.code, nil, c.ce3,
                                   c.ctx_chars, win)
    local want = (sc >= TAU) and (class_first_text(ordered, c.lead) == c.lead)
    chk("A/" .. c.wid, (got ~= nil) == want,
        string.format("score=%.4f τ=%.4f got=%s", sc, TAU,
                      tostring(got)))
    n_a = n_a + 1
  end
end
print(string.format("[smoke] A 逐例对照 %d 例", n_a))

-- B：τ 边界（取一个 lead 本身是同档首选的例）
local c1
for _, c in ipairs(cases) do
  local _, ord = to_win(c)
  if class_first_text(ord, c.lead) == c.lead then c1 = c; break end
end
c1 = c1 or cases[1]
local gen1, ord1 = to_win(c1)
local win1 = { ordered = ord1, code = c1.code, seg_start = 0,
               gshow = c1.gshow }
local b1 = { text = c1.lead, start = 0, _end = c1.le }
_G.llm_prefix_tau = 0
chk("B/tau=0", _G.llm_prefix_gate(gen1, b1, 0, #c1.code, nil, c1.ce3,
                                  c1.ctx_chars, win1) ~= nil)
_G.llm_prefix_tau = 1
chk("B/tau=1", _G.llm_prefix_gate(gen1, b1, 0, #c1.code, nil, c1.ce3,
                                  c1.ctx_chars, win1) == nil)
_G.llm_prefix_tau = nil

-- C：ta 族（把 case1 的 lead 改成「他们」，其余特征沿用）
local gen2, ord2 = to_win(c1)
for _, g in ipairs(gen2) do
  if g.lead == c1.lead then g.lead = "他们" end
end
for _, o in ipairs(ord2) do
  if o.text == c1.lead then o.text = "他们" end
end
put_class_first(ord2, "他们")
local ce2 = {}
for k, v in pairs(c1.ce3) do ce2[k] = v end
ce2["他们"] = c1.ce3[c1.lead]
local win2 = { ordered = ord2, code = c1.code, seg_start = 0,
               gshow = c1.gshow }
local b2 = { text = "他们", start = 0, _end = c1.le }
local g2 = gen2
g2[1].lead = "他们"
_G.llm_prefix_tau = 0                      -- 分数不是瓶颈，单验黑名单
chk("C/ta blocked", _G.llm_prefix_gate(g2, b2, 0, #c1.code, nil, ce2,
                                       c1.ctx_chars, win2) == nil)
_G.llm_prefix_tablock = 0
chk("C/ta unblocked", _G.llm_prefix_gate(g2, b2, 0, #c1.code, nil, ce2,
                                         c1.ctx_chars, win2) ~= nil)
_G.llm_prefix_tablock = nil
_G.llm_prefix_tau = nil

-- D：P 门替换（p 由 gen 分数 softmax 决定）
-- 构造两窗：p≈0.6（低于旧 0.95）与 p≈0.3（低于训练域下界）
local function synth(p_target)
  -- 两条句（1:1），质量比 = exp(-la) → p = 1/(1+exp(-la))
  local la = math.log(p_target / (1 - p_target))
  local g = {
    { score = -2.0, lead = "测试", lead_end = 6, text = "测试一下" },
    { score = -2.0 - la, lead = "测是", lead_end = 6, text = "测是一个" },
  }
  return g, "测试"
end
local gd, ld = synth(0.6)
local ordd = { { text = ld, start = 0, _end = 6 },
               { text = "测是", start = 0, _end = 6 } }
local ced = { [ld] = { 3.0 }, ["测试"] = { 3.0 },
               ["测是"] = { 9.0 }, ["测试一下"] = { 2.0 } }
local wind = { ordered = ordd, code = "ceshiyixia", seg_start = 0,
               gshow = "NONE" }
local bd = { text = ld, start = 0, _end = 6 }
_G.llm_prefix_tau = 0
chk("D/p=0.6 pass", _G.llm_prefix_gate(gd, bd, 0, 11, nil, ced, 9,
                                       wind) ~= nil)
local gd2, ld2 = synth(0.3)
local ord2b = { { text = ld2, start = 0, _end = 6 },
                { text = "测是", start = 0, _end = 6 } }
local win2b = { ordered = ord2b, code = "ceshiyixia", seg_start = 0,
                gshow = "NONE" }
chk("D/p=0.3 blocked", _G.llm_prefix_gate(gd2, bd, 0, 11, nil, ced, 9,
                                          win2b) == nil)
_G.llm_prefix_tau = nil

print(string.format("[smoke] prefix gate model: %d pass, %d fail",
                    npass, nfail))
if nfail > 0 then os.exit(1) end
