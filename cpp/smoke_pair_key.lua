-- smoke_pair_key.lua — 词码对记账 + 无CE取窗内最低 专项冒烟（2026-11-13）
-- A. processor 存储/查询: 新格式分键读取、旧词级行忽略、带码查询
-- B. filter 端到端: 分键 mock 词频注入 → 层1 词码对排序生效（真 DLL）
package.cpath = [[build/Release/?.dll]]

local SMK = os.getenv("TEMP") .. "\\pairkey_smoke"
os.execute('mkdir "' .. SMK .. '" 2>nul')

-- ═══ A. processor 单元（单账本 user_ledger.tsv, 2026-11-17 合并）═══
-- 账本在用户文件夹 llm_rerank 子目录（2026-11-21 起）；本段顺带冒烟
-- 根目录旧账本的一次性迁移（dofile processor 时 resolve 迁移）。
rime_api = { get_user_data_dir = function() return SMK end }
for _, n in ipairs({ "user_ledger.tsv", "user_eff.tsv", "user_unigram.tsv",
                     "user_freq.tsv", "user_bigram.tsv" }) do
    os.remove(SMK .. "\\" .. n)
    os.remove(SMK .. "\\llm_rerank\\" .. n)
end
-- 新格式: "#tick=N" + "词\t码\tdee\ttick\tcum"（兼容旧 s 行）——
-- 故意写根目录旧位置，dofile processor 应迁移到子目录
local pf = io.open(SMK .. "\\user_ledger.tsv", "w")
pf:write("#tick=10\n")
pf:write("s\t键\tjki\t2.000\t10\t3\n")   -- 衰减计数 2.0 / 累计 3
pf:write("s\t键\t\t1.000\t9\t2\n")       -- 空码（捕获失败提交）
pf:write("s\t旧\tzzz\t5.000\t10\t0\n")   -- 无累计计数
pf:write("u\t忽略\tx\t7\n")              -- 旧行类型: 忽略
pf:close()

local proc = dofile("..\\user\\llm_processor.lua")
print("[smoke] processor loaded:", type(proc))
assert(_G.user_unigram_term and _G.user_freq_eff and _G.user_uni_count,
       "导出面")

local function approx(a, b, tag)
    assert(math.abs(a - b) < 1e-9, tag .. " 期望 " .. b .. " 实得 " .. a)
    print("[smoke] " .. tag .. " = " .. string.format("%.6f", a) .. " OK")
end
approx(_G.user_unigram_term("键", "jki"), math.log(4), "uni(键,jki)=ln4")
approx(_G.user_unigram_term("键", "jk"), math.log(1), "uni(键,jk)=ln1 无史")
approx(_G.user_unigram_term("键", ""), math.log(3), "uni(键,'')=ln3 空码对")
approx(_G.user_uni_count("键", "jki"), 3, "uni_count(键,jki)=3")
approx(_G.user_unigram_term("忽略", "x"), math.log(1), "旧行类型忽略")
approx(_G.user_freq_eff("键", "jki"), 2.0, "eff(键,jki)=2.0 同账本")
approx(_G.user_freq_eff("键", "jk"), 0, "eff(键,jk) 异码无史")

-- 子目录迁移断言（2026-11-22 四件全分语义修订：有状态资产 = **复制**快照，
-- 旧文件保留——多个方案各自复制一份，不能 move 走让后来者无源可复制）
local mig = io.open(SMK .. "\\llm_rerank\\user_ledger.tsv", "r")
assert(mig, "账本未复制到 llm_rerank 子目录")
mig:close()
local oldl = io.open(SMK .. "\\user_ledger.tsv", "r")
assert(oldl, "根目录旧账本应保留（复制迁移，不再 move）")
oldl:close()
print("[smoke] 账本复制迁移 llm_rerank/ 子目录 OK（旧文件保留）")

-- 旧两账本一次性迁移: cum = max(eff.commits, uni), 只对含中文词条
os.remove(SMK .. "\\llm_rerank\\user_ledger.tsv")
os.remove(SMK .. "\\user_ledger.tsv")   -- 复制迁移后旧文件保留：这里显式清掉，
                                        -- 才能走到 eff/unigram 旧账迁移分支
pf = io.open(SMK .. "\\user_eff.tsv", "w")
pf:write("#tick=100\n")
pf:write("键\tjki\t5\t2.000\t100\n")   -- commits=5 > uni=2
pf:write("键\t\t3\t1.000\t90\n")
pf:write("——\t\t4\t2.000\t100\n")      -- 全角标点: cum=0
pf:close()
pf = io.open(SMK .. "\\user_unigram.tsv", "w")
pf:write("#n=42\n")                    -- n_seen 不再记录/读取
pf:write("u\t键\tjki\t2\n")
pf:write("u\t键\t\t4\n")               -- uni=4 > commits=3
pf:write("u\t级\tjls\t9\n")            -- 仅累计账有: dee=0
pf:close()
_G.user_stats = nil
proc = dofile("..\\user\\llm_processor.lua")
approx(_G.user_unigram_term("键", "jki"), math.log(6), "迁移 max=5 → ln6")
approx(_G.user_unigram_term("键", ""), math.log(5), "迁移 max=4 → ln5")
approx(_G.user_unigram_term("级", "jls"), math.log(10), "仅累计账 → ln10")
approx(_G.user_unigram_term("——", ""), math.log(1), "标点 cum=0")
approx(_G.user_freq_eff("键", "jki"), 2.0, "迁移 eff=2.0")
approx(_G.user_freq_eff("级", "jls"), 0, "仅累计账 dee=0")

-- 旧名回退: 新两账本缺失时读 user_freq.tsv / user_bigram.tsv
os.remove(SMK .. "\\user_eff.tsv")
os.remove(SMK .. "\\user_unigram.tsv")
pf = io.open(SMK .. "\\user_freq.tsv", "w")
pf:write("#tick=7\n")
pf:write("回\thei\t2\t1.000\t7\n")
pf:close()
pf = io.open(SMK .. "\\user_bigram.tsv", "w")
pf:write("u\t回\thei\t5\n")
pf:close()
_G.user_stats = nil
proc = dofile("..\\user\\llm_processor.lua")
approx(_G.user_unigram_term("回", "hei"), math.log(6),
       "uni(回,hei)=ln6 旧名回退 max=5")
approx(_G.user_freq_eff("回", "hei"), 1.0, "eff(回,hei)=1.0 旧名回退")

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
_G.user_uni_count = function(w, c)
    return (w == "一处" and c == "iock") and 5 or 0
end
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
            return "d:/gguf_models/Qwen3-0.6B-Base-Q4_K_M.gguf"
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
m.model_path = "d:/gguf_models/Qwen3-0.6B-Base-Q4_K_M.gguf"
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
-- 「一处」@iock 强词码对史（14·ln4+ln6 ≈ 21.2）应压过引擎序首「一次」
assert(OUT[1].text == "一处",
    "词码对层1 未生效: OUT[1]=" .. tostring(OUT[1].text))
print("[smoke] 层1 词码对排序生效: 一处 升首 OK")

print("[smoke] SMOKE-PAIRKEY OK")
