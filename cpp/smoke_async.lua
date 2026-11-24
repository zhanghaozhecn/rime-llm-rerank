-- smoke_async.lua — 异步基建（2026-11-22）冒烟
-- 真 DLL + 真模型（Qwen3-0.6B base）。场景：
--   A  submit+wait 基础链路（immediate 跳去抖）：快照字段齐全、fp 一致
--   B  poll 收割（非 immediate 去抖 40ms）：去抖窗口内 nil，稳定后拿到；
--      消费即清空（重复 poll = nil）
--   C  覆盖中断：submit fp1 → submit fp2 → 只收割 fp2（fp1 被 Step 边界
--      中断 / 结果槽覆盖，永不出现）
--   D  cancel：代次递增 + 清槽，丢弃任务无结果
--   E  filter 字词路径：首次 submit+wait 融合序；二次同输入缓存命中同序
--      且显著更快
--   F0 filter 整句路径（2026-11-23 修）：默认 150ms 预算内完成 → 首轮即
--      LLM 融合序 + L 行，不挂账
--   F  filter 整句超时回退：_G.llm_sentence_wait_ms=0 → 层1 序 +
--      S|async_pending + 无 L 行；换输入触发收割回填（W ok flags=async）；
--      原输入再 query 缓存命中融合序 + L 行
--   G  commit 收割（2026-11-22 测试精简补）：_G.llm_async_cancel（=
--      commit 通知链路）先收割落账（挂账 W ok flags=async）再取消——
--      上屏即落账，不依赖下一次 query
-- 语料/debug 写入拦截为内存收集（dofile 之后替换 _G 函数——llm_write_w
-- 运行时查全局）。
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

local filter = dofile("../user/llm_filter.lua")
assert(type(filter) == "function", "filter not loaded")
local CORPUS = {}
_G.llm_corpus_write = function(line) CORPUS[#CORPUS + 1] = line end
_G.llm_debug_write = function(line, force) end  -- 拦截（污染真实 debug.txt）

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
local function msleep(ms)
  local t = os.clock()
  while (os.clock() - t) * 1000 < ms do end
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
local CTX = "测试上文：今天天气很好，我想去一次"

-- ═══ 场景 A：submit+wait 基础链路 ═══
do
  local cands = { "世界", "世间", "是解" }
  local fp = llm.async_submit(CTX, cands, true)
  assert(fp and #fp > 0, "A: submit 无指纹")
  local r = llm.async_wait(fp, 400)
  assert(type(r) == "table" and r.fp == fp, "A: wait 无结果")
  local n = 0
  for _, t in ipairs(r.cands) do
    assert(r.scores[t] ~= nil, "A: " .. t .. " 无分")
    n = n + 1
  end
  assert(n == 3, "A: cands 数 " .. n)
  assert(type(r.ce3) == "table" and r.ce3[cands[1]], "A: ce3 缺")
  assert(type(r.segs) == "table", "A: segs 缺")
  assert(type(r.ev_ms) == "number" and r.ev_ms > 0, "A: ev_ms 异常")
  assert(type(r.ctx_used) == "string", "A: ctx_used 缺")
  assert(llm.async_poll() == nil, "A: wait 消费后结果槽应清空")
  print(string.format("[smoke] A submit+wait ok (ev=%.0fms prep=%s)",
        r.ev_ms, tostring(r.prep)))
end

-- ═══ 场景 B：poll 收割（去抖窗口）═══
do
  local cands = { "世界", "世间", "是解" }
  local fp = llm.async_submit(CTX, cands, false)
  assert(llm.async_poll() == nil, "B: 去抖窗口内不应拿到结果")
  msleep(200)
  local r = llm.async_poll()
  assert(type(r) == "table" and r.fp == fp, "B: poll 未拿到结果")
  assert(r.scores[cands[1]] ~= nil, "B: scores 缺")
  assert(llm.async_poll() == nil, "B: 结果应被消费清空")
  print("[smoke] B poll 收割 ok")
end

-- ═══ 场景 C：覆盖中断 ═══
do
  local fp1 = llm.async_submit(CTX, { "世界", "世间" }, false)
  msleep(60)   -- 越过去抖窗口，fp1 评分开跑
  local fp2 = llm.async_submit(CTX, { "世界", "世间", "是解" }, false)
  msleep(250)
  local r = llm.async_poll()
  assert(type(r) == "table" and r.fp == fp2,
      "C: 应只收割 fp2（fp1 被覆盖中断），实际 " .. tostring(r and r.fp))
  assert(llm.async_poll() == nil, "C: fp1 不应出现")
  print("[smoke] C 覆盖中断 ok")
end

-- ═══ 场景 D：cancel ═══
do
  llm.async_submit(CTX, { "世界", "世间" }, false)
  llm.async_cancel()
  msleep(120)
  assert(llm.async_poll() == nil, "D: cancel 后不应有新结果")
  print("[smoke] D cancel ok")
end

-- ═══ 场景 E：filter 字词路径（wait + 缓存命中）═══
do
  local fmk = function()
    return mktrans({
      mkc("世界"), mkc("世间"), mkc("是解"), mkc("收藏"),
    }), mkenv(false, "shijie")
  end
  OUT = {}; LIVE = {}
  local t = os.clock()
  local tr, ev = fmk()
  filter(tr, ev)
  local dt1 = (os.clock() - t) * 1000
  assert(#OUT == 4, "E: yield 数 " .. #OUT)
  local order1 = {}
  for i, c in ipairs(OUT) do order1[i] = c.text end
  assert(lrow() and lrow()[3] == "shijie", "E: 首轮应有 L 行（wait 融合）")
  -- 二次同输入：缓存命中，0 LLM
  OUT = {}; LIVE = {}
  t = os.clock()
  tr, ev = fmk()
  filter(tr, ev)
  local dt2 = (os.clock() - t) * 1000
  local order2 = {}
  for i, c in ipairs(OUT) do order2[i] = c.text end
  assert(table.concat(order1, ",") == table.concat(order2, ","),
      "E: 缓存命中序不一致")
  assert(dt2 < dt1 * 0.5, string.format(
      "E: 缓存命中应显著更快 dt1=%.0f dt2=%.0f", dt1, dt2))
  print(string.format(
      "[smoke] E 字词 wait %.0fms → 缓存 %.0fms 同序", dt1, dt2))
end

-- ═══ 场景 F0：整句模式同步预算（2026-11-23 修）——当前键即融合序 ═══
-- 默认预算 150ms；真模型小窗评分应远快于此 → 不再挂账、首轮就有 L 行，
-- 子词复用分同时就位（前缀确认的判定前提）。
do
  OUT = {}; LIVE = {}; CORPUS = {}
  _G.llm_sentence_wait_ms = nil         -- 用默认预算
  local tr, ev = mktrans({
      mkc("我们", 0, 2), mkc("你们", 0, 2), mkc("我", 0, 1), mkc("们", 0, 1),
    }), mkenv(true, "wm", { start = 0, _end = 2 })
  filter(tr, ev)
  assert(#OUT == 4, "F0: yield 数 " .. #OUT)
  assert(not saw_skip("async_pending"), "F0: 预算内不应挂账")
  assert(lrow() and lrow()[3] == "wm", "F0: 首轮应有 L 行（同步融合）")
  print("[smoke] F0 整句同步预算首轮融合 ok")
end

-- ═══ 场景 F：整句超时回退（挂账 / 收割回填 / 缓存命中）═══
do
  -- 预算置 0 强制走超时挂账分支（旧的"投递即走"语义，保留回归覆盖）
  _G.llm_sentence_wait_ms = 0
  local fmk = function(inp, seg)
    return mktrans({
      mkc("你们", 0, 2), mkc("尼玛", 0, 2), mkc("你", 0, 1), mkc("那", 0, 1),
    }), mkenv(true, inp, seg)
  end
  OUT = {}; LIVE = {}
  local tr, ev = fmk("nm", { start = 0, _end = 2 })
  filter(tr, ev)
  assert(#OUT == 4, "F: yield 数 " .. #OUT)
  assert(OUT[3].text == "你" and OUT[4].text == "那",
      "F: 未评分轮 PM 应按引擎序保持")
  assert(saw_skip("async_pending"), "F: S|async_pending 缺")
  assert(lrow() == nil, "F: 未评分不应有 L 行")
  -- 换输入触发收割：nm 任务完成 → 挂账回填（W ok 行尾 flags=async）
  msleep(220)
  OUT = {}; LIVE = {}
  tr, ev = fmk("nmsj", { start = 0, _end = 4 })
  filter(tr, ev)
  local found_async_w = false
  for _, line in ipairs(CORPUS) do
    if line:match("^W\t") and line:find("\tasync$") then
      found_async_w = true
    end
  end
  assert(found_async_w, "F: 挂账回填 W ok(flags=async) 行缺")
  -- 原输入再 query：收割回填后缓存命中 → 融合序 + L 行（不再挂账）
  OUT = {}; LIVE = {}
  tr, ev = fmk("nm", { start = 0, _end = 2 })
  filter(tr, ev)
  assert(not saw_skip("async_pending"), "F: 缓存命中不应再挂账")
  assert(lrow() and lrow()[3] == "nm", "F: 缓存命中应有 L 行（融合）")
  print("[smoke] F 整句超时挂账/收割回填/缓存命中 ok")
  _G.llm_sentence_wait_ms = nil     -- 恢复默认预算
end

-- ═══ 场景 G：commit 收割（llm_async_cancel = commit 通知链路）═══
do
  _G.llm_sentence_wait_ms = 0       -- 预算 0 强制挂账，测 commit 收割链
  OUT = {}; LIVE = {}; CORPUS = {}   -- 清空：F 已写过 async 行，计数需只看本轮
  -- 候选文本换新词：指纹 = 上文+候选，同候选会命中 F 的缓存（缓存命中
  -- 不再挂账是正确生产语义，场景隔离靠换候选）
  local tr, ev = mktrans({
      mkc("再见", 0, 2), mkc("再会", 0, 2), mkc("再", 0, 1), mkc("见", 0, 1),
    }), mkenv(true, "ns", { start = 0, _end = 2 })
  filter(tr, ev)
  assert(saw_skip("async_pending"), "G: 挂账缺")
  msleep(220)                       -- 评分完成（结果在槽）
  _G.llm_async_cancel()             -- commit 通知链路：先收割再取消
  local n_async = 0
  for _, line in ipairs(CORPUS) do
    if line:match("^W\t") and line:find("\tasync$") then n_async = n_async + 1 end
  end
  assert(n_async >= 1, "G: commit 收割未落账（W ok flags=async 缺）")
  assert(llm.async_poll() == nil, "G: 结果槽应已被收割消费")
  print("[smoke] G commit 收割落账 ok")
  _G.llm_sentence_wait_ms = nil     -- 恢复默认预算
end

print("[smoke_async] ALL PASS")
