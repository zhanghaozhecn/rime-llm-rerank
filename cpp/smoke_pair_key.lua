-- smoke_pair_key.lua — 词码对记账 + 无CE取窗内最低 专项冒烟（2026-11-13）
-- A. processor 存储/查询: 新格式分键读取、旧词级行忽略、带码查询
-- B. filter 端到端: 分键 mock 词频注入 → 层1 词码对排序生效（真 DLL）
package.cpath = [[build/Release/?.dll]]

local SMK = os.getenv("TEMP") .. "\\pairkey_smoke"
os.execute('mkdir "' .. SMK .. '" 2>nul')

-- ═══ A. processor 单元 ═══
rime_api = { get_user_data_dir = function() return SMK end }
-- 2026-11-14 文件名语义化: user_eff.tsv (衰减账) / user_unigram.tsv (累计账),
-- 旧名 user_freq.tsv / user_bigram.tsv 回退读。本块先写新名测正路径,
-- 回退用例在 uni 断言后。
local pf = io.open(SMK .. "\\user_unigram.tsv", "w")
pf:write("#n=42\n")
pf:write("u\t键\tjki\t3\n")     -- 新格式: 词码对
pf:write("u\t键\t\t2\n")        -- 新格式: 空码（捕获失败提交）
pf:write("u\t级\t7\n")          -- 旧词级: 忽略
pf:write("b\t前\t词\t9\n")      -- 旧 b 行: 忽略
pf:close()

local proc = dofile("..\\user\\llm_processor.lua")
print("[smoke] processor loaded:", type(proc))
assert(_G.user_unigram_term and _G.user_freq_eff, "导出面")

local function approx(a, b, tag)
    assert(math.abs(a - b) < 1e-9, tag .. " 期望 " .. b .. " 实得 " .. a)
    print("[smoke] " .. tag .. " = " .. string.format("%.6f", a) .. " OK")
end
approx(_G.user_unigram_term("键", "jki"), math.log(4), "uni(键,jki)=ln4")
approx(_G.user_unigram_term("键", "jk"), math.log(1), "uni(键,jk)=ln1 无史")
approx(_G.user_unigram_term("级", "jls"), math.log(1), "uni(级,*) 旧行忽略")
approx(_G.user_unigram_term("键", ""), math.log(3), "uni(键,'')=ln3 空码对")

-- 旧名回退: 新名缺失时读 user_bigram.tsv (行格式相同, 无损接管)
os.remove(SMK .. "\\user_unigram.tsv")
pf = io.open(SMK .. "\\user_bigram.tsv", "w")
pf:write("#n=7\n")
pf:write("u\t回\thei\t5\n")
pf:close()
_G.user_uni = nil
proc = dofile("..\\user\\llm_processor.lua")
approx(_G.user_unigram_term("回", "hei"), math.log(6),
       "uni(回,hei)=ln6 旧名回退")

-- freq 侧: 手工置分键账本 → 带码查询
_G.user_word_freq = { ["键\tjki"] = { c = 2, d = 2.0, t = 0 } }
_G.user_freq_tick = 0
assert(_G.user_freq_eff("键", "jki") > 1.9, "eff(键,jki) 带码查询")
assert(_G.user_freq_eff("键", "jk") == 0, "eff(键,jk) 异码无史")
print("[smoke] eff(键,jki)=" .. _G.user_freq_eff("键", "jki") .. " OK; 异码=0 OK")

-- ═══ B. filter 端到端（真 DLL, 分键注入）═══
function yield(c) end
ShadowCandidate = function(c) return c end
_G.llm_context_get = function()
    return "测试上文：今天天气很好，我想去一次", "com"
end
-- 分键注入: 「一处」@iock 有强词码对史, 其余 0
_G.user_freq_eff = function(w, c)
    return (w == "一处" and c == "iock") and 3.0 or 0
end
_G.user_unigram_term = function(w, c)
    return (w == "一处" and c == "iock") and math.log(6) or 0
end
_G.user_uni = { ["一处\tiock"] = 5 }
_G.user_freq_tick = 9

local cfgmock = {
    get_bool = function(_, k)
        if k == "llm_rerank/enabled" then return true end
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
local env = { engine = { schema = { config = cfgmock },
                         context = { input = "iock" } } }
local myc = { "一次", "一处", "依次" }
local function mkc(t) return { text = t, comment = "", type = "table" } end
local translation = {
    iter = function(self)
        local i = 0
        return function() i = i + 1; return myc[i] and mkc(myc[i]) or nil end
    end,
}

local filter = dofile("..\\user\\llm_filter.lua")
print("[smoke] filter loaded:", type(filter))

local m = require("rime_llm")
m.model_path = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
m.score("预热", { "x" })
local t0 = os.clock()
while not m.is_ready() do
    if os.clock() - t0 > 90 then error("model load timeout") end
end
print(string.format("[smoke] model ready %.0fs", os.clock() - t0))

local OUT = {}
yield = function(c) table.insert(OUT, c) end
filter(translation, env)
for i, c in ipairs(OUT) do io.write("[yield] ", tostring(c.text), "\n") end
assert(#OUT == 3, "yield count")
-- 「一处」@iock 强词码对史（12·ln4+ln6 ≈ 18.2）应压过引擎序首「一次」
assert(OUT[1].text == "一处",
    "词码对层1 未生效: OUT[1]=" .. tostring(OUT[1].text))
print("[smoke] 层1 词码对排序生效: 一处 升首 OK")

print("[smoke] SMOKE-PAIRKEY OK")
