-- smoke_prefix_model.lua — 前缀确认门模型：插件侧 vs 研究侧对拍（2026-11-25）
--
-- 输入 = 研究库 eval/lgb/pg_cases.lua（gen / ce3 / ordered / p / le / ctx 原始
-- 输入，由 eval/lgb/gen_pg_cases.py 生成）；输出每例的 41 维特征与分数，
-- 由 Python 侧与研究值比对（期望 maxdiff < 1e-9）。
--
-- 跑法（cwd = 插件 cpp\）：lua_host.exe <本文件>
-- 环境：PG_CASES / PG_OUT / RIME_LLM_PREFIX_MODEL_PATH（模型文件路径）
package.cpath = [[build/Release/?.dll]]

local llm = require("rime_llm")
llm.live_write = function() end          -- 管道打桩（本冒烟不关心调试流）
_G.llm_context_get = function() return "", "" end

local CASES = os.getenv("PG_CASES")
        or "../llm-rerank-research/eval/lgb/pg_cases.lua"
local OUT = os.getenv("PG_OUT")
        or "../llm-rerank-research/eval/lgb/pg_lua.tsv"

dofile("../user/llm_filter.lua")          -- 注册 _G.llm_prefix_score 等

local m = _G.llm_prefix_model_reload and _G.llm_prefix_model_reload()
if not m then error("模型未加载（RIME_LLM_PREFIX_MODEL_PATH?）") end
print(string.format("[smoke] model loaded: %d 树, τ=%.6f",
                    #m.trees, m.tau))

local cases = dofile(CASES)
local nf = #m.feats          -- 特征数跟模型文件走（41 → 53 = 41+ss12）
local fo = assert(io.open(OUT, "w"))
local head = { "wid", "score" }
for i = 1, nf do head[#head + 1] = "f" .. i end
fo:write(table.concat(head, "\t") .. "\n")

local n_ok = 0
for _, c in ipairs(cases) do
  local gen = {}
  for _, g in ipairs(c.gen) do
    gen[#gen + 1] = { score = g.s, lead = g.lead, lead_end = g.le,
                      text = g.text }
  end
  local ordered = {}
  for _, o in ipairs(c.ordered) do
    ordered[#ordered + 1] = { text = o.t, start = 0, _end = o.e }
  end
  local win = { ordered = ordered, code = c.code, seg_start = 0,
                gshow = c.gshow }
  local sc, x = _G.llm_prefix_score(gen, c.lead, c.p, c.le, c.ce3,
                                    #c.code, c.ctx_chars, win)
  if not sc then
    print("[FAIL] " .. c.wid .. " 无分数")
  else
    n_ok = n_ok + 1
    local out = { c.wid, string.format("%.12f", sc) }
    for i = 1, nf do out[#out + 1] = string.format("%.12g", x[i]) end
    fo:write(table.concat(out, "\t") .. "\n")
  end
end
fo:close()
print(string.format("[smoke] prefix model: %d/%d 例有分数 → %s",
                    n_ok, #cases, OUT))
