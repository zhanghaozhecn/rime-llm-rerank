-- smoke_tcs.lua — two_code_sentence 满长准入优先冒烟（2026-11-16 用户定案语义）
-- 场景 A: 满长候选 <2 个 → 整窗跳过评分（S|full_len_lt2）+ 纯层1序输出
-- 场景 B: 2 个满长 + 1 个非满长 → 仅满长的 2 个进窗算 CE（win=1），
--         非满长透传尾窗（win=0、ce 空），输出 = 满长组(融合序) + 层1序尾
-- 真 DLL + 真模型（0.5B）；live_write 打桩截获管道行（不连查看器）
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

-- 预热：显式加载模型（score 触发异步加载）+ 轮询就绪
llm.model_path = MODEL
llm.score("预热", { "x" })
local t0 = os.clock()
while not llm.is_ready() do
  if os.clock() - t0 > 90 then error("model load timeout") end
end
print(string.format("[smoke] model ready %.0fs", os.clock() - t0))

local function mkenv()
  return {
    engine = {
      schema = { config = {
        get_bool = function(_, k)
          if k == "llm_rerank/enabled" then return true end
          if k == "llm_rerank/debug_fusion" then return true end
          if k == "llm_rerank/two_code_sentence" then return true end
          return nil
        end,
        get_int = function(_, k)
          if k == "llm_rerank/max_candidates" then return 5 end
          return nil
        end,
        get_string = function(_, k)
          if k == "llm_rerank/model_path" then return MODEL end
          return nil
        end,
      } },
      context = { input = "iock" },   -- 4 码 → 满长 = 词长 2
    },
  }
end
local function mkc(t) return { text = t, comment = "", type = "table" } end
local function mktrans(texts)
  return { iter = function(self)
    local i = 0
    return function() i = i + 1
      local t = texts[i]
      if t then return mkc(t) end
      return nil
    end
  end }
end

local filter = dofile("../user/llm_filter.lua")
assert(type(filter) == "function", "filter not loaded")

local function crows()
  local rows = {}
  for _, l in ipairs(LIVE) do
    local f = {}
    for p in (l .. "|"):gmatch("([^|]*)|") do f[#f + 1] = p end
    if f[1] == "C" then rows[#rows + 1] = f end
  end
  return rows
end

-- ═══ 场景 A：全非满长（词长 3）→ 窗空，跳过评分 ═══
OUT = {}
LIVE = {}
filter(mktrans({ "一点点", "一下子" }), mkenv())
assert(#OUT == 2, "A: yield count=" .. #OUT)
assert(OUT[1].text == "一点点" and OUT[2].text == "一下子",
    "A: 层1序输出错: " .. OUT[1].text .. "," .. OUT[2].text)
local saw_lt2 = false
for _, l in ipairs(LIVE) do
  if l:sub(1, 2) == "S|" and l:find("full_len_lt2") then saw_lt2 = true end
end
assert(saw_lt2, "A: 未发 S|full_len_lt2")
assert(#crows() == 0, "A: 不应有 C 行（整窗跳过）")
print("[smoke] A 满长不足跳过 + 层1序输出 OK")

-- ═══ 场景 B：2 满长 + 1 非满长 → 仅满长进窗算 CE ═══
OUT = {}
LIVE = {}
filter(mktrans({ "一次", "一点点", "一起" }), mkenv())
assert(#OUT == 3, "B: yield count=" .. #OUT)
local first2 = OUT[1].text .. "," .. OUT[2].text
assert(first2 == "一次,一起" or first2 == "一起,一次",
    "B: 满长组未置顶: " .. first2)
assert(OUT[3].text == "一点点", "B: 非满长应居尾: " .. OUT[3].text)
-- C 行验证：win=1 恰 2 行、都是满长、ce 非空、full=1；win=0 恰 1 行（一点点）
local win1, win0 = {}, {}
for _, f in ipairs(crows()) do
  if f[12] == "1" then win1[#win1 + 1] = f
  elseif f[12] == "0" then win0[#win0 + 1] = f end
end
assert(#win1 == 2, "B: win=1 行数=" .. #win1)
assert(#win0 == 1 and win0[1][3] == "一点点", "B: win=0 行不对")
for _, f in ipairs(win1) do
  assert(f[3] == "一次" or f[3] == "一起", "B: 窗内词错: " .. f[3])
  assert(f[5] ~= "", "B: 窗内候选 ce 应非空: " .. f[3])
  assert(f[9] == "1", "B: 窗内候选 full 应=1")
end
assert(win0[1][5] == "", "B: 尾窗 ce 应空")
print("[smoke] B 满长准入优先 + CE 仅满长 OK")

print("[smoke] SMOKE-TCS OK")
