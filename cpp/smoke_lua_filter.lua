-- smoke_lua_filter.lua — llm_filter.lua 端到端冒烟（伪 rime 环境 + 真 DLL）
-- 1) 语法/加载即验证；2) filter 全路径（层1 → 真 llm.score → 融合 → yield）
-- 3) debug_fusion=true → live 行广播（配合外部 -Raw 查看器收行）
package.cpath = [[build/Release/?.dll]]

-- rime-lua 全局兜底（徽章删除后 ShadowCandidate 已不再使用）
local OUT = {}
function yield(c) table.insert(OUT, c) end
ShadowCandidate = function(c, t, txt, cm, inherit) return c end

-- 伪上文：com 来源 + 真实感内容
_G.llm_context_get = function()
  return "测试上文：今天天气很好，我想去一次", "com"
end
-- user_freq_eff / user_unigram_term / user_freq_tick 不设（冷启动路径）

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
      return "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
    end
    return nil
  end,
}
local env = {
  engine = {
    schema = { config = cfgmock },
    context = { input = "iock" },
  },
}

local myc = { "一次", "一处", "依次" }
local function mkc(t) return { text = t, comment = "", type = "table" } end
local translation = {
  iter = function(self)
    local i = 0
    return function() i = i + 1; return myc[i] and mkc(myc[i]) or nil end
  end,
}

local filter = dofile("../user/llm_filter.lua")
print("[smoke] filter loaded:", type(filter))

-- 预热：显式加载模型（score 触发异步加载）+ 轮询就绪（模型加载 ~15s）
local m = require("rime_llm")
m.model_path = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
m.score("预热", { "x" })
local t0 = os.clock()
while not m.is_ready() do
  if os.clock() - t0 > 90 then error("model load timeout") end
end
print(string.format("[smoke] model ready %.0fs", os.clock() - t0))

-- 起管道 + 留 2s 给外部查看器连上（1s 重连周期），探针行本身丢弃
m.live_write("R|00:00:00|管道启动探针")
local tw = os.clock()
while os.clock() - tw < 2 do end

-- 第一次调用：真实评分路径（cache MISS）
local t1 = os.clock()
filter(translation, env)
print(string.format("[smoke] first call %.0fms", (os.clock() - t1) * 1000))
for i, c in ipairs(OUT) do io.write("[yield] ", tostring(c.text), "\n") end
assert(#OUT == 3, "yield count")
assert(OUT[1].text and type(OUT[1].text) == "string", "cand text")

-- 第二次调用：同 ctx+input → 缓存 HIT 路径（live L 行 cache=HIT）
OUT = {}
filter(translation, env)
print("[smoke] second call (cache HIT path)")
for i, c in ipairs(OUT) do io.write("[yield2] ", tostring(c.text), "\n") end

-- 编码不匹配 → S|pattern 路径
env.engine.context.input = "io"
OUT = {}
filter(translation, env)
print("[smoke] pattern-mismatch path, yields:", #OUT)

-- 尾窗路径：6 个候选 > max_candidates=5 → 第 6 名 win=0 透传
env.engine.context.input = "iock"
myc = { "一次", "一处", "依次", "一二次", "英超处", "衣傲处" }
OUT = {}
filter(translation, env)
print("[smoke] 6-cand tail path, yields:", #OUT)

-- 等管道送达后退出（查看器侧异步收行）
local tw2 = os.clock()
while os.clock() - tw2 < 1 do end
print("[smoke] SMOKE-LUA OK")
