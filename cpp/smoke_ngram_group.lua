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
  -- 2026-11-24 定案：topk 20（lead 概率质量；显示仍只置顶 1 条）
  assert(params and params.topk == 20, "params.topk")
  return GEN
end
-- 2026-11-28 修：增量组句（2026-11-27 落地）后 filter 默认走
-- ngram_sentences_cached——不补桩时真 C++ 增量入口被调（无资产 → 空），
-- 注入静默消失（A/N 场景失败的根因）。缓存入口同签名，共用同一桩。
llm.ngram_sentences_cached = llm.ngram_sentences

-- Candidate 构造（rime-lua 生产环境有全局 Candidate；冒烟桩同签名）
function Candidate(t, s, e, txt, cm)
  local c = { text = txt, comment = cm or "", type = t, start = s, _end = e }
  return c
end

-- mock env：sentence_mode / ngram_group / 输出字形门 + 活动段
--   opts.ngram    false = 关闭 ngram_group
--   opts.simp     false = filters 里没有 simplifier（纯繁体方案）
--   opts.noopt    true  = 有 simplifier 但无 option_name（朙月恒转换）
--   opts.opt_off  "<名>" = 显式开关方案里该开关当前关闭
local function simp_filters(opts)
  local names = opts.simp == false
      and { [0] = "uniquifier", [1] = "llm_filter" }
      or { [0] = "simplifier", [1] = "llm_filter" }
  return { size = 2,
    get_value_at = function(_, i)
      return { get_string = function() return names[i] end }
    end }
end
local function mkenv(input, seg, opts)
  opts = opts or {}
  return {
    engine = {
      schema = { schema_id = "luna_pinyin_simp", config = {
        get_bool = function(_, k)
          if k == "llm_rerank/enabled" then return true end
          if k == "llm_rerank/debug_fusion" then return true end
          if k == "llm_rerank/sentence_mode" then return true end
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
          -- 组句候选 preedit（2026-11-28）：分隔符与引擎同源
          if k == "speller/delimiter" then return " '" end
          if k == "simplifier/option_name" then
            if opts.simp == false or opts.noopt then return nil end
            return "zh_simp"
          end
          return nil
        end,
        get_list = function(_, k)
          if k == "engine/filters" then return simp_filters(opts) end
          return nil
        end,
      } },
      context = {
        input = input,
        composition = seg and { back = function() return seg end } or nil,
        get_option = function(_, name) return name ~= opts.opt_off end,
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
-- 统一准入（2026-11-24）后窗口按融合序混排，首条可能是子词；"未注入"的
-- 判据改为"输出里没有组句文本"。
local function has_gen(tx)
  for _, t in ipairs(tx) do
    for _, it in ipairs(GEN or {}) do
      if t == it.text then return true end
    end
  end
  return false
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
-- 2026-11-24 用户定案：5 句仍然参与内部计算，但**界面上只显示 1 条**
--（排在最前的整句首选），其余位置是引擎候选。
-- 2026-11-24 修：只**注入/抑制**显示的那 1 条；与组句 top-20 同名（但非首位）
-- 的引擎候选必须照常出现在候选列表里（真机报障：象/向/想 整字消失）。
local gset, n_inj, first_inj = {}, 0, false
for i = 1, 5 do gset[GEN[i].text] = true end
for i, c in ipairs(OUT) do
  if c.type == "ngram_group" then
    n_inj = n_inj + 1
    if i == 1 then first_inj = true end
  end
end
check("A 组句只注入/显示 1 条（置顶）", n_inj == 1 and first_inj,
      "n_inj=" .. n_inj .. " first=" .. tostring(tx[1]))
local kept_engine = false
for _, t in ipairs(tx) do
  if t == "的天气" then kept_engine = true end   -- = GEN[4]，引擎也有
end
check("A 同名引擎候选不被组句吞掉", kept_engine, "的天气 in out")
check("A 句候选排在首位", gset[tx[1] or ""] == true, tx[1])
local pc = _G.llm_pending_confirm
-- 合并门（2026-11-24）后确认还要求"该 lead 是窗口融合序第 1"，融合序由真实
-- 模型 CE 决定 → 集成场景只做一致性检查（挂起时必须是证据词），正/负判定
-- 由下方直测场景 M 覆盖。
check("A 单字前缀确认（若挂起必须是「的」）",
      pc == nil or (pc.text == "的" and pc.input == "detianqi"),
      pc and (tostring(pc.text) .. "/" .. tostring(pc.input)) or "nil")

-- ── B：ngram_group 关闭 → 不注入、不挂起 ───────────────────────────
-- 哨兵组句文本避开引擎候选「的天气」，防止把引擎候选误判成注入
GEN = gen5("的", 2, { "的天气很好", "的天气真热", "的天启", "的天气啊", "的天气吧" })
_G.llm_pending_confirm = nil
run(engine_cands(), "detianqi", { start = 0, _end = 8 }, { ngram = false })
tx = texts()
check("B 关闭时不注入", not has_gen(tx), table.concat(tx, ","))
check("B 关闭时不挂起", _G.llm_pending_confirm == nil)

-- ── C：多字前导词「今天」一致 → 挂起「今天」 ──────────────────────
-- 2026-11-23 晚修后需留足剩余码：用 15 码长串（今天止于 7，剩余 8 ≥4）
GEN = gen5("今天", 7, { "今天天气好", "今天天气热", "今天晚上", "今天上午", "今天下午" })
_G.llm_pending_confirm = nil
run({
  mkc("今天天气", 0, 15), mkc("金田天气", 0, 15),
  mkc("今天", 0, 7), mkc("金田", 0, 7),
}, "jintiandetianqi", { start = 0, _end = 15 })
pc = _G.llm_pending_confirm
check("C 多字前缀确认（若挂起必须是「今天」）",
      pc == nil or pc.text == "今天", pc and tostring(pc.text) or "nil")

-- ── D：filters 无 simplifier（纯繁体方案）→ gate 关闭 ──────────────
GEN = gen5("的", 2, { "的天气很好", "的天气真热", "的天启", "的天气啊", "的天气吧" })
_G.llm_pending_confirm = nil
run(engine_cands(), "detianqi", { start = 0, _end = 8 }, { simp = false })
tx = texts()
check("D 无 simplifier 不注入", not has_gen(tx), table.concat(tx, ","))

-- ── G：有 simplifier、无 option_name（朙月恒转换）→ 注入 + 单字确认 ──
-- 2026-11-23 真机报障场景：luna_pinyin 的 simplifier 缺节 = opencc 默认
-- t2s 恒转换（候选恒简体）；旧判据只认 option_name 非空，把它判成繁体
-- 方案 → 组句静默关闭、单字前缀确认永不触发。新判据必须放行。
GEN = gen5("的", 2, { "的天气很好", "的天气真热", "的天启", "的天气", "的天气啊" })
_G.llm_pending_confirm = nil
run(engine_cands(), "detianqi", { start = 0, _end = 8 }, { noopt = true })
tx = texts()
local injected = false
for i = 1, 5 do
  for _, it in ipairs(GEN) do
    if tx[i] == it.text then injected = true end
  end
end
check("G 无 option_name 仍注入", injected, table.concat(tx, ","))
pc = _G.llm_pending_confirm
check("G 无 option_name 单字确认（若挂起必须是「的」）",
      pc == nil or pc.text == "的", pc and tostring(pc.text) or "nil")

-- ── H：显式开关方案、开关当前关闭 → 注入点 gate 拦住 ───────────────
GEN = gen5("的", 2, { "的天气很好", "的天气真热", "的天启", "的天气啊", "的天气吧" })
_G.llm_pending_confirm = nil
run(engine_cands(), "detianqi", { start = 0, _end = 8 }, { opt_off = "zh_simp" })
tx = texts()
check("H 开关关闭不注入", not has_gen(tx), table.concat(tx, ","))

-- ── I：短码/组句不可用 → 不确认（2026-11-24 口径：守卫改音节单位）──
-- 旧「整段 ≥6 码 ∧ 剩余 ≥4 码」是拍的，已退役（简拼/双拼/混拼下码数无意义）。
-- 现在：① 码切在音节中间时组句返回空 → 合并门没有组句证据，不确认；
-- ② 剩余音节不足由 M5/M5b 覆盖（多字 lead 余 1 拒、单字 lead 余 1 放行）。
local function short_cands()
  return { mkc("进天", 0, 4), mkc("金田", 0, 4),
           mkc("进", 0, 3), mkc("金", 0, 3) }
end
GEN = nil            -- 模拟 jint（音节中间）→ 生成器返回空
_G.llm_pending_confirm = nil
run(short_cands(), "jint", { start = 0, _end = 4 })
check("I 组句空（码断在音节中）不确认", _G.llm_pending_confirm == nil,
      _G.llm_pending_confirm and tostring(_G.llm_pending_confirm.text))
_G.llm_pending_confirm = nil
run(short_cands(), "jinti", { start = 0, _end = 5 })
check("I 组句空（jinti）不确认", _G.llm_pending_confirm == nil)
-- 长前导词贴段末：detianq 里「的天气」止于 6、句长 4 音节 → 只剩 1 音节，
-- 且 lead 是 3 音节（>1）→ 不确认
GEN = gen5("的天气", 6, { "的天气啊", "的天气好", "的天气真", "的天气很", "的天气吧" })
_G.llm_pending_confirm = nil
run(engine_cands(), "detianq", { start = 0, _end = 7 })
check("I 多字 lead 余 1 音节不确认", _G.llm_pending_confirm == nil)

-- ── J：同码同长同音字占位 → 文本不符必须不确认（2026-11-24 真机报障）──
-- 「今天的天气很好」把「的」确认成「得」：句级证据 lead=的，但子词块里
-- [0,2) 只有「得」时，旧逻辑按码位区间 + 字符数命中 → 挂起「得」。
-- 修复后要求文本一致：证据词不在子词块 → 放弃（宁可不确认，不可错确认）。
local function wrong_cands()
  return { mkc("得天气", 0, 8), mkc("得天器", 0, 8),
           mkc("得", 0, 2), mkc("得天", 0, 6) }
end
GEN = gen5("的", 2, { "的天气很好", "的天气真热", "的天启", "的天气", "的天气啊" })
_G.llm_pending_confirm = nil
run(wrong_cands(), "detianqi", { start = 0, _end = 8 })
check("J 子词无证据词时不确认", _G.llm_pending_confirm == nil,
      _G.llm_pending_confirm and tostring(_G.llm_pending_confirm.text))

-- ── K：同区间存在 的/得 → 必须选证据词「的」（不论融合序先后）────────
local function mixed_cands()
  return { mkc("得天气", 0, 8), mkc("的天气", 0, 8),
           mkc("得", 0, 2), mkc("的", 0, 2), mkc("得天", 0, 6) }
end
GEN = gen5("的", 2, { "的天气很好", "的天气真热", "的天启", "的天气", "的天气啊" })
_G.llm_pending_confirm = nil
run(mixed_cands(), "detianqi", { start = 0, _end = 8 })
pc = _G.llm_pending_confirm
check("K 同区间同音字（若挂起必须是证据词「的」）",
      pc == nil or pc.text == "的", pc and tostring(pc.text) or "nil")

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

-- ── M：合并前缀门直测（2026-11-24：lead 概率 ∧ 窗口第 1 ∧ span/文本 ∧ 音节守卫）──
-- 集成场景的窗口融合序由真实模型 CE 决定（非确定），正/负判定在这里直测
-- 纯计算函数 `_G.llm_prefix_gate`（filter 同一份实现）。
-- gsum 项 = { lead, lead_end, score, 整句文本 }：整句字符数 = 音节数（中文
-- 一字一音节），守卫按「剩余音节」判——不再看码数。
local gate = _G.llm_prefix_gate
check("M 合并门已导出", type(gate) == "function")
local function gsum(items)
  local t = {}
  for i, x in ipairs(items) do
    t[i] = { text = x[4] or x[1], lead = x[1], lead_end = x[2], score = x[3] }
  end
  return t
end
-- M1 单字 lead、P=1.0、窗口第 1、剩 2 音节（的天气：3−1）
local l, p = gate(gsum({ { "的", 2, -1, "的天气" }, { "的", 2, -2, "的天气" } }),
                  mkc("的", 0, 2), 0, 8)
check("M1 P=1 ∧ 窗1 单字确认", l == "的" and p and p > 0.99, tostring(l))
-- M2 两个 lead（P≈0.62）→ 低于 0.95 不确认
l = gate(gsum({ { "的", 2, -1, "的天气" }, { "得", 2, -1.5, "得天气" } }),
         mkc("的", 0, 2), 0, 8)
check("M2 概率不足不确认", l == nil, tostring(l))
-- M2b 阈值 hook 放宽 → 同一窗通过（冒烟/调参入口）
_G.llm_prefix_confirm_p = 0.5
l = gate(gsum({ { "的", 2, -1, "的天气" }, { "得", 2, -1.5, "得天气" } }),
         mkc("的", 0, 2), 0, 8)
_G.llm_prefix_confirm_p = nil
check("M2b 阈值 hook 生效", l == "的", tostring(l))
-- M3 窗口第 1 是同 span 同音字（文本不一致）→ 不确认
l = gate(gsum({ { "的", 2, -1, "的天气" } }), mkc("得", 0, 2), 0, 8)
check("M3 文本不一致不确认", l == nil, tostring(l))
-- M4 窗口第 1 同文本但 span 不对齐 → 不确认
l = gate(gsum({ { "的", 2, -1, "的天气" } }), mkc("的", 0, 1), 0, 8)
check("M4 span 不对齐不确认", l == nil, tostring(l))
-- M5 多字 lead、确认后只剩 1 音节 → 不确认（边界歧义档，实测 90.5%）
l = gate(gsum({ { "我们", 6, -1, "我们德" } }), mkc("我们", 0, 6), 0, 9)
check("M5 多字 lead 余 1 音节不确认", l == nil, tostring(l))
-- M5b 单字 lead、只剩 1 音节 → **不确认**（2026-11-24 真机定案：`xiazai`
-- 在 xia 就确认「下」会把 2 字词拆成 单字+单字；该例外仅 +112 触发，去掉后
-- 精度 95.48% / 召回 40.23% / K=5 1935）
l = gate(gsum({ { "的", 2, -1, "的天" } }), mkc("的", 0, 2), 0, 6)
check("M5b 单字 lead 余 1 音节不确认", l == nil, tostring(l))
-- M6 简拼/双拼形态：码只 3 个但音节正常（的天气 3 音节，余 2）→ 确认
--（旧「≥6 码」守卫会误拒；音节守卫按 3 音节放行）
l = gate(gsum({ { "的", 1, -1, "的天气" } }), mkc("的", 0, 1), 0, 3)
check("M6 短码正常音节确认", l == "的", tostring(l))
-- M7 多字 lead、窗第 1、剩 2 音节（今天天气：4−2）→ 确认
l = gate(gsum({ { "今天", 7, -1, "今天天气" }, { "今天", 7, -2, "今天天气" } }),
         mkc("今天", 0, 7), 0, 15)
check("M7 多字确认", l == "今天", tostring(l))
-- M8 窗口第 1 是短子词（不是证据词本身）→ 不确认
l = gate(gsum({ { "的天气", 6, -1, "的天气" } }), mkc("的", 0, 2), 0, 8)
check("M8 窗1 非证据词不确认", l == nil, tostring(l))
-- M9–M13 绝对置信度门（2026-11-25）：ce1 / 空上文 d / 1 字上文 / 关闭钩子
local function ce1map(t, c1) return { [t] = { c1, nil, nil } } end
local g1 = gsum({ { "的", 2, -1, "的天气" } })
l = gate(g1, mkc("的", 0, 2), 0, 8, nil, ce1map("的", 5), 4)
check("M9 ce1≤11 确认（4 字上文）", l == "的", tostring(l))
l = gate(g1, mkc("的", 0, 2), 0, 8, nil, ce1map("的", 12), 4)
check("M9b ce1>11 不确认", l == nil, tostring(l))
l = gate(g1, mkc("的", 0, 2), 0, 8, nil, ce1map("的", 5), 1)
check("M10 有效上文 1 字不确认", l == nil, tostring(l))
-- 短上文下限（2026-11-25 实测，12,000 句）：<4 字一律不确认——
-- 空上文（无 CE，只靠 ngram 一条腿）d 再大也不确认
local gd1 = gsum({ { "的", 2, -1, "的天气" }, { "得", 2, -11.5, "得天气" } })
l = gate(gd1, mkc("的", 0, 2), 0, 8, nil, nil, 0)
check("M11 空上文不确认", l == nil, tostring(l))
l = gate(g1, mkc("的", 0, 2), 0, 8, nil, ce1map("的", 5), 2)
check("M11b 2 字上文不确认", l == nil, tostring(l))
l = gate(g1, mkc("的", 0, 2), 0, 8, nil, ce1map("的", 5), 3)
check("M11c 3 字上文不确认", l == nil, tostring(l))
_G.llm_prefix_ce1 = 0
l = gate(g1, mkc("的", 0, 2), 0, 8, nil, ce1map("的", 99), 1)
_G.llm_prefix_ce1 = nil
check("M12 关闭钩子回到旧行为", l == "的", tostring(l))

-- ── N：无上文（CE 不可算）→ 融合按剩余项 + 组句 lead 照常确认 ──────
-- 2026-11-24 用户定案：无上文时 fused = β·log1p(eff) + log(uni+1) + 词码对；
-- 组句 lead 仍与窗口融合序第 1 比较、照常挂起。窗口序无 CE → 层1 序 =
-- 引擎序（全零计数时）→ 首候选「的」必与 lead 一致，判定是确定性的。
local saved_ctx_get = _G.llm_context_get
_G.llm_context_get = function() return "", "com" end
GEN = gen5("的", 2, { "的天气很好", "的天气真热", "的天启", "的天气", "的天气啊" })
_G.llm_pending_confirm = nil
run({ mkc("的", 0, 2), mkc("得", 0, 2), mkc("的天气", 0, 8), mkc("得", 0, 2) },
    "detianqi", { start = 0, _end = 8 })
pc = _G.llm_pending_confirm
check("N 无上文不再自动确认（<4 字下限）", pc == nil,
      pc and tostring(pc.text) or "nil")
local saw_freq, saw_ctx_empty, ctx_used_empty = false, false, false
for _, ln in ipairs(LIVE) do
  if ln:find("|freq_only|", 1, true) then saw_freq = true end
  if ln:find("|ctx_empty|", 1, true) then saw_ctx_empty = true end
  if ln:sub(1, 2) == "L|" then
    local f = {}
    for s in (ln .. "|"):gmatch("([^|]*)|") do f[#f + 1] = s end
    ctx_used_empty = (f[12] == "")   -- 第 12 字段 = ctx_used
  end
end
check("N 无上文走 freq_only（不 skip ctx_empty）", saw_freq and not saw_ctx_empty)
check("N 无上文不做 CE（ctx_used 空）", ctx_used_empty)

-- ── N2：确认过一次 phrase（组合区有已确认前缀）→ 有临时上文 → 完整 CE ──
-- prefix_text 非空时 freq_only 必须关闭：本轮按 prefix 作 ctx 真跑 CE
-- （L 行 ctx_used = 前缀文本；不是 freq_only）。
_G.llm_confirmed_prefix = function() return "的" end
GEN = gen5("的", 2, { "的天气很好", "的天气真热", "的天启", "的天气", "的天气啊" })
_G.llm_pending_confirm = nil
run({ mkc("的", 0, 2), mkc("得", 0, 2), mkc("的天气", 0, 8), mkc("得", 0, 2) },
    "detianqi", { start = 0, _end = 8 })
_G.llm_confirmed_prefix = nil
local saw_freq2, ctx_used_prefix = false, false
for _, ln in ipairs(LIVE) do
  if ln:find("|freq_only|", 1, true) then saw_freq2 = true end
  if ln:sub(1, 2) == "L|" then
    local f = {}
    for s in (ln .. "|"):gmatch("([^|]*)|") do f[#f + 1] = s end
    ctx_used_prefix = (f[12] == "的")
  end
end
check("N2 有临时上文不降级 freq_only", not saw_freq2)
check("N2 CE 上文含已确认前缀", ctx_used_prefix)

-- ── N3：无上文 + 组句不可用（gen 空）→ 保持旧行为（skip ctx_empty）──
GEN = nil
_G.llm_pending_confirm = nil
run({ mkc("的", 0, 2), mkc("得", 0, 2), mkc("的天气", 0, 8) },
    "detianqi", { start = 0, _end = 8 })
saw_ctx_empty = false
for _, ln in ipairs(LIVE) do
  if ln:find("|ctx_empty|", 1, true) then saw_ctx_empty = true end
end
check("N3 无组句仍 skip ctx_empty",
      _G.llm_pending_confirm == nil and saw_ctx_empty)

-- ── N4：无上文 + N-gram 开关关 → 保持旧行为（skip ctx_empty）────────
-- 2026-11-24 单开关：前缀自动确认并入 ngram_group（旧键 prefix_confirm
-- 读取端忽略），关组句即关确认，freq_only 不再生效。
GEN = gen5("的", 2, { "的天气很好", "的天气真热", "的天启", "的天气", "的天气啊" })
_G.llm_pending_confirm = nil
run({ mkc("的", 0, 2), mkc("得", 0, 2), mkc("的天气", 0, 8) },
    "detianqi", { start = 0, _end = 8 }, { ngram = false })
saw_ctx_empty = false
for _, ln in ipairs(LIVE) do
  if ln:find("|ctx_empty|", 1, true) then saw_ctx_empty = true end
end
check("N4 组句关时不走 freq_only",
      _G.llm_pending_confirm == nil and saw_ctx_empty)

-- ── P：组句候选 preedit（音节分隔，2026-11-28）──────────────────────
-- P1 无同 span 引擎 preedit → 自建（词边界 + 词内 DP；冒烟无 syll 表 →
--    仅词边界，分隔符取 speller/delimiter 首字符）；
-- P2 有同 span 引擎候选 preedit → 原样复用（含 preedit_format，与引擎显示
--    一致）。
GEN = gen5("的", 2, { "的天气很好", "的天气真热", "的天启", "的天气", "的天气啊" })
for _, it in ipairs(GEN) do
  it.words = { { w = "的", e = 2 }, { w = "天气", e = 8 } }
end
_G.llm_pending_confirm = nil
run(engine_cands(), "detianqi", { start = 0, _end = 8 })
check("P1 组句候选自建 preedit（词边界加分隔）",
      OUT[1] and OUT[1].preedit == "de tianqi",
      OUT[1] and tostring(OUT[1].preedit))
local ec = engine_cands()
for _, c in ipairs(ec) do
  if c.start == 0 and c._end == 8 then c.preedit = "de tian qi" end
end
run(ec, "detianqi", { start = 0, _end = 8 })
check("P2 同 span 引擎 preedit 优先复用",
      OUT[1] and OUT[1].preedit == "de tian qi",
      OUT[1] and tostring(OUT[1].preedit))

_G.llm_context_get = saved_ctx_get

print(string.format("[smoke] ngram_group: %d pass, %d fail", OK, FAIL))
if FAIL > 0 then os.exit(1) end
