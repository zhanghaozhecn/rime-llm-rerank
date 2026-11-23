-- smoke_prefix_confirm.lua — 前缀软确认（2026-11-23 实验）逻辑冒烟
-- 只验证 processor 侧执行逻辑（挂起 → menu 查找 → ctx:select → 清理）。
-- 引擎侧的 select → Segment::Close 截段 → Forward + Compose 重译剩余，
-- 已由 rime_cand_probe 的 C API 探针在真引擎上验证（设计文档 §11.8）。
-- 用法：cd cpp && lua_host.exe smoke_prefix_confirm.lua
package.cpath = [[build/Release/?.dll]]

local proc = dofile("../user/llm_processor.lua")
assert(type(proc) == "function", "processor not loaded")
assert(type(_G.llm_run_pending_confirm) == "function",
       "llm_run_pending_confirm not exported")

local function mkenv(input, cands, rec)
  local menu = {
    prepare = function(_, _n) return #cands end,
    get_candidate_at = function(_, i) return cands[i + 1] end,
  }
  local ctx = {
    input = input,
    composition = { back = function() return { menu = menu } end },
    select = function(_, i) rec.i = i end,
  }
  return { engine = { context = ctx } }
end

-- A 正常执行：前缀未变 + 候选存在 → 选中并清挂起
do
  local rec = {}
  local env = mkenv("womendewen",
      { { text = "我们", start = 0, _end = 6 },
        { text = "我", start = 0, _end = 2 } }, rec)
  _G.llm_pending_confirm = { input = "womendewen", text = "我们", endp = 6 }
  _G.llm_run_pending_confirm(env)
  assert(rec.i == 0, "A: 应选 idx 0，实际 " .. tostring(rec.i))
  assert(_G.llm_pending_confirm == nil, "A: 挂起应清除")
  print("[smoke] A 挂起执行 + 清理 ok")
end

-- B 输入前缀被改（当前 input 不以挂起 input 为前缀）→ 丢弃，不 select
do
  local rec = {}
  local env = mkenv("womendex", { { text = "我们", start = 0, _end = 6 } }, rec)
  _G.llm_pending_confirm = { input = "womendewen", text = "我们", endp = 6 }
  _G.llm_run_pending_confirm(env)
  assert(rec.i == nil, "B: 前缀不符不应 select")
  assert(_G.llm_pending_confirm == nil, "B: 挂起应清除")
  print("[smoke] B 前缀被改丢弃 ok")
end

-- E 用户继续打码（当前 input 以挂起 input 为前缀）→ 照常执行
do
  local rec = {}
  local env = mkenv("womendewenx",
      { { text = "我们", start = 0, _end = 6 } }, rec)
  _G.llm_pending_confirm = { input = "womendewen", text = "我们", endp = 6 }
  _G.llm_run_pending_confirm(env)
  assert(rec.i == 0, "E: 前缀延伸应执行，实际 " .. tostring(rec.i))
  print("[smoke] E 前缀延伸照常执行 ok")
end

-- C 候选不在 menu → 不崩、清挂起
do
  local rec = {}
  local env = mkenv("womendewen", { { text = "我", start = 0, _end = 2 } }, rec)
  _G.llm_pending_confirm = { input = "womendewen", text = "我们", endp = 6 }
  _G.llm_run_pending_confirm(env)
  assert(rec.i == nil, "C: 候选缺失不应 select")
  assert(_G.llm_pending_confirm == nil, "C: 挂起应清除")
  print("[smoke] C 候选缺失安全退出 ok")
end

-- D 无 composition（输入刚开始）→ 安全退出
do
  local ctx = { input = "womendewen", composition = nil,
                select = function() error("must not select") end }
  _G.llm_pending_confirm = { input = "womendewen", text = "我们", endp = 6 }
  _G.llm_run_pending_confirm({ engine = { context = ctx } })
  assert(_G.llm_pending_confirm == nil, "D: 挂起应清除")
  print("[smoke] D 无 composition 安全退出 ok")
end

print("SMOKE-PREFIX-CONFIRM OK")

-- ═══ 段 2：ctx + prefix 接口（2026-11-23，真 DLL + 真模型）═══
-- ① 短上文：score(ctx, cands, P) 与 score(ctx..P, cands) 的 ctx token 序列
--    相同（ctx 未截断 + P 完整）→ 分数应逐值一致。
-- ② 增量路径：先 prepare(ctx) 再 score(ctx, cands, P)——ensure_ctx_kv 走
--    "前缀延伸"分支（只 decode P 的 token），分数应与全量一致。
local llm = require("rime_llm")
llm.model_path = "d:/gguf_models/Qwen3-0.6B-Base-Q4_K_M.gguf"
llm.score("预热", { "x" })
local t0 = os.clock()
while not llm.is_ready() do
  if os.clock() - t0 > 90 then error("model load timeout") end
end
local function msleep(ms)
  local t = os.clock()
  while (os.clock() - t) * 1000 < ms do end
end

local cands = { "很好", "很坏" }
-- ① 等价性
llm.score("今天天气", cands, "不错")
local s1 = llm.get_scores()
llm.score("今天天气不错", cands)
local s2 = llm.get_scores()
local d1 = math.abs((s1["很好"] or 0) - (s2["很好"] or 0))
local d2 = math.abs((s1["很坏"] or 0) - (s2["很坏"] or 0))
assert(d1 < 1e-6 and d2 < 1e-6,
       string.format("I: prefix 等价不一致 d1=%.6f d2=%.6f", d1, d2))
print("[smoke] I prefix 等价（ctx..P == ctx,P）ok")

-- ② 增量路径一致性
llm.prepare("今天天气")
msleep(200)
llm.score("今天天气", cands, "不错")
local s3 = llm.get_scores()
local d3 = math.abs((s3["很好"] or 0) - (s1["很好"] or 0))
local d4 = math.abs((s3["很坏"] or 0) - (s1["很坏"] or 0))
assert(d3 < 1e-6 and d4 < 1e-6,
       string.format("J: 增量路径不一致 d3=%.6f d4=%.6f", d3, d4))
print("[smoke] J 增量路径（prepare(ctx) → ctx+P）ok")

print("SMOKE-PREFIX-CONFIRM-FULL OK")
