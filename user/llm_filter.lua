-- llm_filter.lua — LLM candidate rerank filter
-- 由 schema llm_rerank.enabled 控制：true | false
-- false 时不加载 DLL，不推理，候选原样透传

local llm = nil
local llm_loaded_for = nil  -- enabled value when llm was loaded

-- 融合系数 β 为内置常数（2026-11-05 用户定案：标定产物退出用户配置面——用户没有
-- 标定能力；与 FREQ_TAU=400 同待遇。调整 = 改代码随下次发版生效）：
local FREQ_BETA = 14 -- 对数词频融合系数（2026-11-14 默认模型改
                     -- Qwen2.5-0.5B 后重标定: 用户域 34k + wiki 池化
                     -- 180k 网格, kCeW (1.0,1.10,0.60)+β14 偶半选→奇半
                     -- 验四半区一致, 见研究库 calibrate_model_05b; 旧
                     -- v3 (1.05/0.45/β12) 为 0.8B 标定值）
                     -- fused = score + β·log(1+eff) + log(0.5·p1)
                     --   p1 = 用户累计 Unigram 平滑概率（llm_processor 维护,
                     --   _G.user_unigram_term 查询; 累计 Bigram 项已退役
                     --   2026-11-08, 见研究库 §三十七）
-- two_code_sentence 两码整句开关（2026-11-07 用户定案取代 elw）：
-- 两码一字整句方案下勾选后，词长==⌊码长/2⌋ 的候选作为一组直接优先
-- （组内融合分降序、同分稳定），其余候选按融合分降序在后——即原 elw
-- 的极限行为（elw·span 加成→∞），不再需要 span 间接量。默认 false。

-- 词码对分数修正（2026-11-17 用户定案：固顶与 pairfix 合并为一张有符号表）：
-- 表放用户目录 llm_pairfix.tsv，行 `词<TAB>码<TAB>[+|-]分数`：
--   +200 / 200 = 加分（固定首选，09876 上屏时写入）
--   +100 / 100 = 加分（固定次选，手动编辑）
--   -5         = 扣分（pairfix 预置降噪；无第三列 = 旧默认扣 5）
-- `#` 注释；无文件 = 机制休眠；每次窗口准入/融合轻量重读，编辑即时生效。
-- 正分不受 fade 限制（09876 上屏会累计 uni 计数，固定首选必须持久）；
-- 负分保留 fade（用户该词码对累计 >= PAIRFIX_FADE_UNI 次 -> 预置让位）。
-- 正分候选即使不在层1 前 k，也优先占用评分窗名额（见窗口准入段）。
-- 旧 2026-11-13 pairfix 推导（wiki 拆半/用户域回放）保留在文件头历史注释：
-- 与@vkh 等污染对按字频抬分；负分只破 CE 险胜的近平局。
local PAIRFIX_PENALTY_DEFAULT = 5.0
local PAIRFIX_FADE_UNI = 3

-- 读参考表 → { ["词\t码"] = 有符号分数 }; 无文件返回 nil（机制休眠）
local function pairfix_table()
    local ok, ud = pcall(function() return rime_api.get_user_data_dir() end)
    if not ok or type(ud) ~= "string" or ud == "" then return nil end
    local f = io.open(ud .. "\\llm_pairfix.tsv", "r")
    if not f then return nil end
    local tbl = {}
    for line in f:lines() do
        line = line:gsub("\r$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local w, c, sv = line:match("^(.-)\t(.-)\t(.+)$")
            local delta
            if sv then
                sv = sv:match("^([%+%-]?[%d%.]+)$")
                if not sv then
                    w, c = nil, nil   -- 第三列非法：跳过，不并进码键
                else
                    delta = tonumber(sv)
                end
            else
                w, c = line:match("^(.-)\t(.-)$")
                delta = -PAIRFIX_PENALTY_DEFAULT  -- 旧两列格式 = 默认扣 5
            end
            if w and w ~= "" and c and c ~= "" and delta then
                tbl[w .. "\t" .. c] = delta
            end
        end
    end
    f:close()
    return tbl
end

-- 命中返回有符号分数修正；正分（固定首选/次选）不受 fade 限制
local function pairfix_delta(tbl, text, input)
    if not tbl then return 0 end
    local key = text .. "\t" .. (input or "")
    local d = tbl[key]
    if not d or d == 0 then return 0 end
    if d > 0 then return d end
    local uni = _G.user_uni_count
                    and _G.user_uni_count(text, input) or 0
    if uni >= PAIRFIX_FADE_UNI then return 0 end
    return d
end

local cfg = {
    -- 编码匹配模式（2026-09-30 取代 min_code_len/max_code_len）：
    -- 全串匹配输入编码串，语法同 Rime 自身 speller/auto_select_pattern。
    --   仅 4 码 = '.{4}'｜4 码以上 = '.{4,}'｜3-4 码 = '.{3,4}'｜
    --   指定首码的 4 码 = '[abcde]{4}'｜任意长度 = '.+'
    -- 引擎：DLL 的 std::regex（ECMAScript）；不可用时回退 Lua 模式
    -- （Lua 模式里 %d/%a 等转义与正则 \d/\w 不同，详见 README）。
    code_pattern     = '.{4}',
    -- min_code_len / max_code_len 已废弃（用户配置面移除，2026-09-30）：
    -- 等价写法 = code_pattern '.{4}'
    max_tokens       = 20,  -- 截取的上文 token 数（2026-11-19 随生产模型切 Qwen3-0.6B base 定案，旧 10 为 0.5B 时代值）
    max_candidates   = 6,   -- 2026-11-19：0.6B k*=6（候选段 100ms / 最优 3.65%）
    cpu_cores        = nil,  -- nil = 不设置，走 C++ 默认（固定 4，bench_threads 实测后可配）
    debug_fusion     = false, -- true = 逐候选融合明细写 rime_llm_debug.txt (诊断用)
    two_code_sentence = false, -- 两码整句：词长==⌊码长/2⌋ 的候选一组优先
                               -- （2026-11-07 取代 expected_length_weight；
                               --  旧行读取端忽略，保存/重建节时剥除）
    -- freq_beta 不再从 schema 读取（2026-11-05 用户配置面移除，标定产物退出配置面）
    -- → 内置常数 FREQ_BETA；方案里残留旧行读取端忽略，保存/重建节时剥除
}

-- ============================================================
-- 记录文件（2026-11-17 用户定案：只保留两个文件）
--   常开语料 rime_llm_corpus.tsv（TSV，不轮转，独立可分析）
--   按需 debug rime_llm_debug.txt（| 分隔，10MB 单轮转）
-- 事件 ID 串联两文件；debug 只写语料没有的字段（CE/eff/耗时/错误），
-- 不重复词/码/上下文/候选序/配置。llm_processor.lua 复用这些 _G 函数。
-- ============================================================
_G.llm_ev_seq = _G.llm_ev_seq or 0
_G.llm_debug_enabled = _G.llm_debug_enabled or false

local function rec_user_dir()
    local ok, ud = pcall(function() return rime_api.get_user_data_dir() end)
    if ok and type(ud) == "string" and ud ~= "" then return ud end
    return os.getenv("TEMP") or "C:\\Windows\\Temp"
end

local function rec_esc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub("\t", "\\t")
         :gsub("\r", "\\r"):gsub("\n", "\\n")
    return s
end

local function rec_cand_esc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub(",", "\\,")
         :gsub("\t", "\\t"):gsub("\r", "\\r"):gsub("\n", "\\n")
    return s
end

local function rec_join(v, maxn)
    local out = {}
    for i = 1, math.min(#(v or {}), maxn) do
        out[i] = rec_cand_esc(v[i])
    end
    return table.concat(out, ",")
end

local function rec_ctx_tail(s, n)
    s = s or ""
    if #s <= n then return s end
    local cut = #s - n + 1
    while cut <= #s and (s:byte(cut) or 0) >= 0x80
            and (s:byte(cut) or 0) < 0xC0 do
        cut = cut + 1
    end
    return s:sub(cut)
end

local function rec_stamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

function _G.llm_new_event(kind, tick)
    _G.llm_ev_seq = (_G.llm_ev_seq or 0) + 1
    return os.date("%Y%m%dT%H%M%S") .. "-" .. tostring(tick or 0)
        .. "-" .. string.format("%04d", _G.llm_ev_seq)
end

local function rec_header_ok(path, magic, header)
    local f = io.open(path, "rb")
    if f then
        local first = f:read("*l")
        f:close()
        if not first then
            f = io.open(path, "ab")
            if not f then return false end
            f:write(header .. "\n"); f:close(); return true
        end
        return first:sub(1, #magic) == magic
    end
    f = io.open(path, "ab")
    if not f then return false end
    f:write(header .. "\n"); f:close(); return true
end

local function rec_append(path, line)
    local f = io.open(path, "ab")
    if not f then return end
    f:write(line, "\n")
    f:close()
end

function _G.llm_corpus_write(line)
    local ud = rec_user_dir()
    local path = ud .. "\\rime_llm_corpus.tsv"
    if _G.llm_corpus_header_path ~= path then
        _G.llm_corpus_header_path = path
        _G.llm_corpus_ok = rec_header_ok(path, "#RIME_CORPUS\tv2\t",
            "#RIME_CORPUS\tv2\t" .. rec_stamp() .. "\tplugin")
    end
    if not _G.llm_corpus_ok then return end
    rec_append(path, line)
end

function _G.llm_debug_write(line, force)
    if not force and not _G.llm_debug_enabled then return end
    local ud = rec_user_dir()
    local path = ud .. "\\rime_llm_debug.txt"
    if _G.llm_debug_header_path ~= path then
        _G.llm_debug_header_path = path
        _G.llm_debug_ok = rec_header_ok(path, "#RIME_DEBUG|v2|",
            "#RIME_DEBUG|v2|" .. rec_stamp() .. "|plugin")
    end
    if not _G.llm_debug_ok then return end
    local f = io.open(path, "rb")
    if f then
        local sz = f:seek("end")
        f:close()
        if sz and sz > 10 * 1024 * 1024 then
            os.remove(path .. ".old")
            os.rename(path, path .. ".old")
        end
    end
    rec_append(path, line)
end

local function rec_rank(v, word)
    for i, x in ipairs(v or {}) do
        if x == word then return i end
    end
    return -1
end

function _G.llm_write_w(id, src, code, ctx, engine, window, final, tick,
                        status, skip, prep, flags)
    local line = table.concat({
        "W", id, rec_stamp(), rec_esc(src), rec_esc(code),
        rec_esc(rec_ctx_tail(ctx, 120)), rec_join(engine, 10),
        rec_join(window, 20), rec_join(final, 20), tostring(tick or 0),
        status or "ok", rec_esc(skip or ""), prep and "1" or "0",
        rec_esc(flags or "")
    }, "\t")
    _G.llm_corpus_write(line)
    _G.llm_last_event_id = id
    _G.llm_last_window = { id = id, code = code, engine = engine or {},
                           window = window or {}, final = final or {},
                           tick = tick or 0 }
    return id
end

function _G.llm_write_c(word, code, tick, cjk)
    local ref, re, rw, rf = "", -1, -1, -1
    local wl = _G.llm_last_window
    if wl and code and code ~= "" and wl.code == code then
        ref = wl.id or ""
        re = rec_rank(wl.engine, word)
        rw = rec_rank(wl.window, word)
        rf = rec_rank(wl.final, word)
    end
    _G.llm_last_window = nil
    local id = _G.llm_new_event("C", tick)
    local line = table.concat({
        "C", id, rec_stamp(), ref, rec_esc(word), rec_esc(code or ""),
        tostring(re), tostring(rw), tostring(rf), tostring(tick or 0),
        cjk and "cjk=1" or ""
    }, "\t")
    _G.llm_corpus_write(line)
    _G.llm_last_event_id = id
    return id
end

function _G.llm_write_m(kind)
    local id = _G.llm_new_event("M", 0)
    local line = table.concat({
        "M", id, rec_stamp(), _G.llm_last_event_id or "", kind or "unknown",
        "", ""
    }, "\t")
    _G.llm_corpus_write(line)
    _G.llm_debug_write(id .. "|R|gen=" .. tostring(_G.llm_reset_gen or 0),
                       false)
    return id
end

local function rec_base(path)
    path = path or ""
    return (path:match("([^\\/]+)$") or path)
end

function _G.llm_write_h(schema, model)
    local id = _G.llm_new_event("H", _G.user_freq_tick or 0)
    local line = table.concat({
        "H", id, rec_stamp(), "plugin", rec_esc(schema or "unknown"),
        rec_esc(rec_base(model)), rec_esc(cfg.code_pattern or ""),
        tostring(cfg.max_candidates or 5), tostring(cfg.max_tokens or 10),
        cfg.two_code_sentence and "1" or "0", "14.00", "400"
    }, "\t")
    _G.llm_corpus_write(line)
end

local function rec_num(v)
    if type(v) ~= "number" or v ~= v or v <= -1e307 or v >= 1e307 then
        return "-inf"
    end
    return string.format("%.3f", v)
end

function _G.llm_debug_p(id, total, prep)
    _G.llm_debug_write(string.format("%s|P|total=%.1f|prep=%d", id,
                                     total or 0, prep and 1 or 0), false)
end

function _G.llm_debug_d(id, rank, ce, ce1, ce2, ce3, eff, fb, u1, full,
                        key, sdelta, cerank, finrank)
    _G.llm_debug_write(string.format(
        "%s|D|%d|ce=%s|ce1=%s|ce2=%s|ce3=%s|eff=%.3f|fb=%.3f|u1=%.3f"
        .. "|full=%d|key=%s|sdelta=%g|cerank=%d|finrank=%d",
        id, rank, rec_num(ce), rec_num(ce1), rec_num(ce2), rec_num(ce3),
        eff or 0, fb or 0, u1 or 0, full and 1 or 0, rec_num(key),
        sdelta or 0, cerank or 0, finrank or 0), false)
end

function _G.llm_debug_e(id, before, after, dirty)
    _G.llm_debug_write(string.format(
        "%s|E|eff_before=%.3f|eff_after=%.3f|dirty=%d", id, before or 0,
        after or 0, dirty or 0), false)
end

local lat_max   = 0
local lat_count = 0

local function is_finite_number(v)
    return type(v) == "number" and v == v
        and v > -math.huge and v < math.huge
end

local function is_valid_llm_score(v)
    return is_finite_number(v) and v > -1e9
end

-- 编码模式匹配（2026-09-30）：全串匹配，语义同 Rime speller/auto_select_pattern。
-- 优先 DLL 的 std::regex（ECMAScript，与源码版 boost::regex 同套语法）；
-- 老版本 DLL 无 match_code 时回退 Lua 模式（用 find 的全串匹配 + 首尾锚定）。
-- 空模式 = 总是匹配（与源码版一致）。
local function match_code_pattern(code)
    local pat = cfg.code_pattern
    if not pat or pat == "" then return true end
    if llm and llm.match_code then
        local ok, r = pcall(llm.match_code, pat, code)
        if ok then return r and true or false end
        -- pcall 失败（模式非法）→ 落到下面的 Lua 模式回退
    end
    local ok, s, e = pcall(string.find, code, pat)
    if not ok or not s then return false end
    return s == 1 and e == #code   -- 全串匹配（Lua find 允许中段命中）
end

local function get_scores(cands)    if not llm or not llm.get_scores then return nil end
    local ok, scores = pcall(function() return llm.get_scores() end)
    if not ok or type(scores) ~= "table" then return nil end
    for _, text in ipairs(cands) do
        if not is_finite_number(scores[text]) then return nil end
    end
    return scores
end

-- ═══ 实时调试行广播（2026-11-10）═══
-- debug_fusion 开时把行协议（V/L/C/S/E/R，| 分隔）经 DLL 的命名管道
-- \\.\pipe\rime_llm_live 推给外部查看器（本仓库 debug\llm_debug_view.ps1）。
-- 协议两端（lua/C++/查看器）以 DLL 注释与查看器头部注释为准。
-- 旧 DLL 无 live_write 时静默跳过（向后兼容）；查看器未连接时 DLL 侧
-- 一次空遍历即返回。自由文本字段（input/ctx/word/reason）先过 live_esc。
local function live_esc(s)
    return (tostring(s or "")):gsub("|", "｜"):gsub("\n", " ")
end

local function live(line)
    if not (cfg.debug_fusion and llm and llm.live_write) then return end
    local ok = pcall(llm.live_write, line)
    if not ok then llm.live_write = nil end  -- 接口异常则本会话不再尝试
end

local function live_fmt3(v)
    if v == nil or v ~= v then return "" end
    return string.format("%.3f", v)
end

local function load_llm(env)
    local ok, cpp = pcall(require, "rime_llm")
    if ok and cpp then
        local sc = env.engine.schema.config
        local mp = sc:get_string("llm_rerank/model_path")
        -- 未配置时留给 C++ 默认（RIME 用户目录根，2026-08-31）
        if mp and mp ~= "" then cpp.model_path = mp end
        cpp.max_ctx    = cfg.max_tokens
        -- min_tokens 不设置：固定用 C++ 默认 1（用户配置面已移除，2026-09-30）
        if cfg.cpu_cores then cpp.n_threads = cfg.cpu_cores end
        -- 日志目录: RIME 用户目录 (未设置时 C++ 回退 %TEMP%)
        local okd, ud = pcall(function() return rime_api.get_user_data_dir() end)
        if okd and ud and ud ~= "" then cpp.log_dir = ud end
        llm = cpp
        llm_loaded_for = true
    end
end

local function init_config(env)
    local sc = env.engine.schema.config
    -- 编码匹配模式（2026-09-30 取代 min/max_code_len）：get_string 未配置返回
    -- nil，配置了空串则视为"总是匹配"（与源码版一致）
    local pat = sc:get_string("llm_rerank/code_pattern")
    if pat ~= nil then cfg.code_pattern = pat end
    -- expected_length_weight 不再读取（2026-11-07 由 two_code_sentence 取代;
    -- 方案里残留旧行忽略, 保存时由安装器剥除）
    -- freq_beta 不再读取（2026-11-05 配置面移除; 方案里残留旧行忽略,
    -- 保存时由安装器剥除）
    local v = sc:get_int("llm_rerank/max_tokens")
    if v then cfg.max_tokens = v end
    v = sc:get_int("llm_rerank/max_candidates")
    if v then cfg.max_candidates = v end
    v = sc:get_int("llm_rerank/cpu_cores")
    if v then cfg.cpu_cores = v end
    -- min_tokens 不再从 schema 读取（2026-09-30 用户配置面移除；固定 C++ 默认 1）
    local dbg = sc:get_bool("llm_rerank/debug_fusion")
    if dbg ~= nil then cfg.debug_fusion = dbg end
    -- 两码整句开关（2026-11-16 补读——自 13ed97e 引入起从未读 schema，
    -- 插件版该开关一直停默认 false；源码版正常，故真机未暴露）
    local tcs = sc:get_bool("llm_rerank/two_code_sentence")
    if tcs ~= nil then cfg.two_code_sentence = tcs end
    _G.llm_debug_enabled = cfg.debug_fusion
    if not _G.llm_h_written then
        _G.llm_h_written = true
        local sid = (env.engine.schema and env.engine.schema.schema_id)
                    or "unknown"
        local mp = sc:get_string("llm_rerank/model_path") or ""
        _G.llm_write_h(sid, mp)
    end
end

local function texts_of(list, maxn)
    local out = {}
    for i = 1, math.min(#list, maxn) do out[i] = list[i].text end
    return out
end

-- === Filter ===
return function(translation, env)
    -- 每次调用都从 schema 读取 enabled，确保重新部署后立即生效
    local sc = env.engine.schema.config
    local enabled = sc:get_bool("llm_rerank/enabled") or false

    -- Init config once (non-DLL config doesn't invalidate on redeploy)
    if not cfg._inited then
        init_config(env)
        cfg._inited = true
    end

    local input = env.engine.context.input or ""
    local all = {}
    for cand in translation:iter() do table.insert(all, cand) end
    local ctx_text, ctx_src = "", "rime"
    if _G.llm_context_get then
        ctx_text, ctx_src = _G.llm_context_get()
    end
    -- 去空白: 上文中允许字母存在 (英文/数字是合法上文)。
    -- 不需过滤尾部 ASCII: Rime 编码显示在候选窗, 不写入编辑器,
    -- 外挂读到的光标前文本不会包含编码字母 (微软拼音式 inline composition 才会)
    local context = (ctx_text or ""):gsub('%s+', '')
    local tick = _G.user_freq_tick or 0
    -- DLL 需先加载：match_code 用 std::regex；Lua 回退不支持 .{4} 量词。
    if enabled and not llm_loaded_for then
        load_llm(env)
    end
    local pattern_ok = enabled and match_code_pattern(input) or false
    -- 常开语料 W：只在 enabled + pattern 匹配时尝试（部分输入码不落行）。
    local rec = enabled and pattern_ok
    local wid = rec and _G.llm_new_event("W", tick) or nil
    local engine_top = texts_of(all, 10)
    -- 清掉上一轮快照，避免未重排/失败路径的陈旧窗口被 C 误引用。
    _G.llm_last_window = nil

    if #all < 2 then
        live("S|" .. os.date("%H:%M:%S") .. "|few_candidates|" ..
             live_esc(input) .. "|-")
        if wid then
            _G.llm_write_w(wid, ctx_src, input, context, engine_top, {}, {},
                           tick, "skip", "few_candidates", false, "")
        end
        for _, c in ipairs(all) do yield(c) end
        return
    end

    -- enabled false → 原样透传，不推理（常开语料也不写 W）
    if not enabled then
        for _, c in ipairs(all) do yield(c) end; return
    end

    if not llm then
        if wid then
            _G.llm_write_w(wid, ctx_src, input, context, engine_top, {}, {},
                           tick, "skip", "model_loading", false, "")
        end
        live("S|" .. os.date("%H:%M:%S") .. "|model_loading|" ..
             live_esc(input) .. "|-")
        for _, c in ipairs(all) do yield(c) end; return
    end

    -- 触发条件：编码串是否匹配 code_pattern（2026-09-30 取代 min/max_code_len 区间）
    -- 全串匹配（同 Rime auto_select_pattern 语义）。优先用 DLL 的 std::regex
    -- （与源码版 boost::regex 同一套 ECMAScript 语法）；DLL 不提供该函数时
    -- 回退 Lua 模式——两种写法对 .{4} / .{4,} / .{3,4} / [abcde]{4} 等价。
    if not pattern_ok then
        live("S|" .. os.date("%H:%M:%S") .. "|pattern|" .. live_esc(input)
             .. "|-")
        for _, c in ipairs(all) do yield(c) end; return
    end

    -- 空上文：与源码版一致跳过评分（W skip 记录）
    if context == "" then
        if wid then
            _G.llm_write_w(wid, ctx_src, input, context, engine_top, {}, {},
                           tick, "skip", "ctx_empty", false, "")
        end
        live("S|" .. os.date("%H:%M:%S") .. "|ctx_empty|" ..
             live_esc(input) .. "|" .. live_esc(ctx_src))
        for _, c in ipairs(all) do yield(c) end; return
    end
    -- ═══ 层1: 全体候选 用户词频打分重排（v3 两层重排, 2026-11-07 定案）═══
    -- 全体候选 S1 = FREQ_BETA·log1p(eff) + 累计 Unigram 项, 稳定降序（同分保引擎序）,
    -- 取前 max_candidates 进 LLM 评分（层2 三项融合重排）, 其余按层1 序透传。
    -- 目标在层1 前 k 外 → 必然不在首位（评测 sweep_2layer 同语义, 全窗参评）。
    -- 文件序无关性: 引擎调频与否仅影响冷词同分打破（目标卷入 ≤0.05pp 窗,
    -- 实测见研究库 §三十三·附 6）。
    local layer1 = {}
    local s1_of = {}
    do
        -- 词码对记账（2026-11-13 用户定案）: eff/uni 查询键 = (候选, 当前
        -- 窗码)——多音词属不同词条, 每个码对只看自己的历史（wiki 59,681
        -- 窗: 分键全面更优 −0.34~−0.73pp 随龄扩大）
        local fe, bt = _G.user_freq_eff, _G.user_unigram_term
        for i, c in ipairs(all) do
            local n = fe and fe(c.text, input) or 0
            local s = FREQ_BETA * math.log(1 + n)
            if bt then s = s + bt(c.text, input) end
            layer1[i] = { c = c, s = s, idx = i }
            s1_of[c.text] = s
        end
        table.sort(layer1, function(a, b)
            if a.s ~= b.s then return a.s > b.s end
            return a.idx < b.idx   -- 稳定: 同分保引擎序
        end)
    end
    -- 词码对分数表：正分（固定首选 +200 / 固定次选 +100）在层1 排序后
    -- 优先占用评分窗名额；窗口大小仍不超过 max_candidates（不扩窗、不增
    -- decode 行数）。分数表在窗口准入前读一次，本窗融合复用同一份。
    local pftbl = pairfix_table()
    local cands = {}
    local l1win = {}
    local win_seen = {}
    local function add_win(e)
        if #cands >= cfg.max_candidates then return end
        local t = e.c.text
        if win_seen[t] then return end
        win_seen[t] = true
        cands[#cands + 1] = t
        l1win[#l1win + 1] = t
    end
    -- 正分候选优先占位：+200 先于 +100；同分按层1 分、再按引擎序。
    if pftbl then
        local pos = {}
        for _, e in ipairs(layer1) do
            local d = pairfix_delta(pftbl, e.c.text, input)
            if d > 0 then pos[#pos + 1] = { e = e, d = d } end
        end
        table.sort(pos, function(a, b)
            if a.d ~= b.d then return a.d > b.d end
            if a.e.s ~= b.e.s then return a.e.s > b.e.s end
            return a.e.idx < b.e.idx
        end)
        for _, p in ipairs(pos) do add_win(p.e) end
    end
    -- two_code_sentence 准入优先（2026-11-16 用户定案，取代 2026-11-07 的
    -- "词频前 k 全参评 + 最终排序满长组置顶"）：正分固定词先占位后，剩余
    -- 名额里词长==⌊码长/2⌋ 的候选优先；不足就空着——不匹配词长的候选
    -- 不进窗、不算 CE。固定词不受满长限制（固定首选优先于整句规则）。
    local tcs_elen = cfg.two_code_sentence and math.floor(#input / 2) or 0
    if tcs_elen >= 1 then
        for _, e in ipairs(layer1) do
            if (utf8.len(e.c.text or "") or 0) == tcs_elen then
                add_win(e)
            end
        end
    else
        for _, e in ipairs(layer1) do
            add_win(e)
        end
    end
    local w_written = false
    -- 评分结果缓存已删除（2026-11-11 用户定案）：同 (上文+编码) 的复用在
    -- 生产里命中率极低（每个新词的上文都变），却要维护一整套失效逻辑（编辑键清
    -- 缓存/候选集变化重放），删掉以简化。每次触发都是真实推理。
    -- 满长准入后窗不足 2 个（不足即空着的极端形态）：无重排意义、整窗跳过
    -- 评分（与源码版一致显式发 S 事件，避免静默零输出）——ok 保持 nil，
    -- 下游走层1 序展示。
    if tcs_elen >= 1 and #cands < 2 then
        live("S|" .. os.date("%H:%M:%S") .. "|full_len_lt2|" ..
             live_esc(input) .. "|" .. live_esc(ctx_src))
        if wid then
            _G.llm_write_w(wid, ctx_src, input, context, engine_top, l1win,
                           {}, tick, "skip", "full_len_lt2", false, "")
            w_written = true
        end
        cands = {}
    end
    local ok, result, scores
    local ev_ms = 0   -- 本轮推理耗时（实时调试 L 行用）
    if #cands >= 2 then
        do
        local t0 = os.clock()
        ok, result = pcall(function() return llm.score(context, cands) end)
        local elapsed_ms = (os.clock() - t0) * 1000
        ev_ms = elapsed_ms
        if ok and type(result) == "table" then
            scores = get_scores(cands)
        end

        lat_count = lat_count + 1
        if elapsed_ms > lat_max then lat_max = elapsed_ms end
        end   -- if #cands >= 2（满长准入窗 <2 跳过评分）
    end

    -- 失败原因（用于 W skip）；ok/result 成功时为空
    local skip_reason = nil
    if #cands >= 2 then
        if not ok then
            skip_reason = "score_failed"
        elseif type(result) ~= "table" then
            local okr, ready = pcall(function() return llm.is_ready() end)
            skip_reason = (okr and ready) and "ctx_short" or "not_ready"
        elseif not scores then
            skip_reason = "scores_nil"
        end
    end

    local live_ready = "n/a"
    local dbg = cfg.debug_fusion and {} or nil
    local prep_flag = "0"
    if dbg then
        local okr, r = pcall(function() return llm.is_ready() end)
        if okr then live_ready = r and "1" or "0" end
        local okp, ph = pcall(function() return llm.prep_hit end)
        prep_flag = (okp and ph) and "1" or "0"
        if skip_reason then
            live("S|" .. os.date("%H:%M:%S") .. "|" .. skip_reason .. "|" ..
                 live_esc(input) .. "|" .. live_esc(ctx_src))
        end
    end

    if ok and result then
        local seen = {}
        local ordered = {}
        for i = 1, #result do
            for _, c in ipairs(all) do
                if c.text == result[i] and not seen[c.text] then
                    seen[c.text] = true
                    table.insert(ordered, c)
                    break
                end
            end
        end
        -- 统一结合公式 (2026-09-03 冷启动标定; 2026-11-02 连续文章语料重标定;
        -- 2026-11-05 β 退出配置面 → FREQ_BETA 内置常数;
        -- 2026-11-06 v3: 六维联合标定 + 用户 bigram 项上线;
        -- **2026-11-08: 累计 Bigram 项退役**（cohort 生产量级评测实证真实用户龄
        -- fired ~2%、剔除零损失, 见研究库 §三十七——保留历史结论, 公式去掉 p2）):
        --   fused(w) = score(w) + FREQ_BETA·log(1+eff(w))
        --              + log(0.5·p1)     ← 用户累计 Unigram 项
        -- score = 原始 LLM 分 (−CE, 对数概率域); eff = librime algo::formula_d
        -- 指数衰减计数 (**τ=400** tick 内置常数, tick=每词提交+1, 引擎调频同源;
        -- llm_processor 维护, _G.user_freq_eff 查询)。对数域加法:
        --   ① 词频无上限: 强个人高频词可翻盘 CE 分差 (FREQ_BETA=12, v3 六维
        --      联合标定用户域标定→wiki 平台就近);
        --   ② 用户累计 Unigram 项: p1 = (uni+1)/(n_seen+2万) (原始计数不衰减),
        --      项值 log(0.5·p1)——与原标定语义的未 fired 形态逐字一致;
        --      冷启动全等值自动无害退化; llm_processor 维护 _G.user_unigram_term;
        --   ③ expected_length_weight (elw) 已退役 (2026-11-07): 整句偏好改由
        --      two_code_sentence 开关直接实现 (见下方满长组优先块)。
        --   ④ 冷启动 eff≡0 且 uni 无计数时自动退化为 score 序, 成熟期三项叠加。
        --   ⑤ 词码对分数修正（2026-11-17 有符号表）: 正分 = 固定首选/次选
        --      （+200/+100，不受 fade）；负分 = pairfix 降噪（原 −λ，保留
        --      fade）。无 CE 分支同样生效；debug 行尾 修正%+g，C 行尾追加
        --      sdelta（有符号；旧 pf 字段仍为负分幅度，兼容旧查看器）。
        -- 失败哨兵分 (≤-1e9) 排尾部不参与; 同分稳定保序 (融合序)。
        local fused_scores = nil
        if #ordered > 1 and scores then
            local freq_eff = _G.user_freq_eff
            -- CE 三分量（2026-11-11 协议 v2）：get_ce3 = text → {c1,c2,c3}
            -- 原始分量（未乘权重）；旧 DLL 无此函数时静默缺省
            local ce3map = nil
            if llm.get_ce3 then
                local okc, m = pcall(llm.get_ce3)
                if okc and type(m) == "table" then ce3map = m end
            end
            -- 无 CE 分候选的融合（2026-11-13 用户定案，取代 2026-11-07
            -- "回退后两项和"）: CE 取窗内已算 CE 的**最低分**（score =
            -- −CE 负值域，最低分 = 最差证据 → 该候选排到窗底但保留与
            -- 层1 的正常耦合）。旧语义（融合=层1 分）会让无法表示的字
            -- （如 tokenizer 打不出的 生僻字「𬤊」）以 S1=0 压过全部
            -- 负分候选跳首选——aki 实况窗两例实证。全窗无有效 CE 时
            -- min_valid 为 nil、加 0 = 自然回退层1 序。
            local min_valid = nil
            for _, c in ipairs(ordered) do
                local s = scores[c.text]
                if is_valid_llm_score(s)
                        and (not min_valid or s < min_valid) then
                    min_valid = s
                end
            end
            fused_scores = {}
            -- 本窗已在窗口准入前读过同一份表（正分占位用），这里复用。
            local arr = {}
            for i, c in ipairs(ordered) do
                local s = scores[c.text]
                if is_valid_llm_score(s) then
                    local n = freq_eff and freq_eff(c.text, input) or 0
                    local u1_term = _G.user_unigram_term
                            and _G.user_unigram_term(c.text, input) or 0
                    local delta = pairfix_delta(pftbl, c.text, input)
                    local t = s + FREQ_BETA * math.log(1 + n) + u1_term
                            + delta
                    fused_scores[c.text] = t
                    arr[i] = { c = c, t = t, idx = i }
                    if dbg then
                        dbg[c.text] = { ce = s, eff = n,
                                        fb = FREQ_BETA * math.log(1 + n),
                                        u1 = u1_term,
                                        pf = delta < 0 and -delta or nil,
                                        sdelta = delta ~= 0 and delta or nil,
                                        uni = _G.user_uni_count
                                              and _G.user_uni_count(c.text,
                                                                    input) or 0,
                                        ce3 = ce3map and ce3map[c.text] or nil,
                                        fused = t, cerank = i }
                    end
                else
                    -- 无 CE 分（评分失败/无法表示）→ 层1 分 + 窗内最低
                    -- LLM 分（压制到窗底, 保留层1 耦合; 见上注）
                    local s1 = s1_of[c.text]
                    local delta = pairfix_delta(pftbl, c.text, input)
                    local t = (s1 or -math.huge)
                            + (min_valid and min_valid or 0) + delta
                    fused_scores[c.text] = t
                    arr[i] = { c = c, t = t, idx = i }
                    if dbg then
                        dbg[c.text] = { ce = s, eff = 0, fb = 0,
                                        pf = delta < 0 and -delta or nil,
                                        sdelta = delta ~= 0 and delta or nil,
                                        uni = _G.user_uni_count
                                              and _G.user_uni_count(c.text,
                                                                    input) or 0,
                                        ce3 = ce3map and ce3map[c.text] or nil,
                                        fused = t, cerank = i,
                                        invalid = true }
                    end
                end
            end
            table.sort(arr, function(a, b)
                if a.t ~= b.t then return a.t > b.t end
                return a.idx < b.idx  -- 同分保持 LLM 评分序
            end)
            for i = 1, #arr do ordered[i] = arr[i].c end
        end
        -- 两码整句 (two_code_sentence, 2026-11-07 用户定案取代 elw):
        -- 词长==⌊码长/2⌋ 的候选一组直接优先 (组内融合分降序, 同分稳定),
        -- 其余按融合分降序——即原 elw 的极限行为 (elw·span 加成→∞),
        -- 不再需要 span 间接量。
        if cfg.two_code_sentence and #ordered > 1 and fused_scores then
            local expected_len = math.floor(#input / 2)
            if expected_len >= 1 then
                local arr = {}
                for i, c in ipairs(ordered) do
                    local len = utf8.len(c.text or "") or 0
                    arr[i] = { c = c, s = fused_scores[c.text] or -math.huge,
                               m = (len == expected_len), idx = i }
                    if dbg and dbg[c.text] then
                        dbg[c.text].full = arr[i].m
                    end
                end
                table.sort(arr, function(a, b)
                    if a.m ~= b.m then return a.m end
                    if a.s ~= b.s then return a.s > b.s end
                    return a.idx < b.idx  -- 同分保持融合序
                end)
                for i = 1, #arr do ordered[i] = arr[i].c end
            end
        end

        -- 诊断输出: 逐候选明细 + 名次变化汇总
        if dbg then
            local final_rank = {}
            for i, c in ipairs(ordered) do final_rank[c.text] = i end
            local all_rank = {}
            for i, c in ipairs(all) do all_rank[c.text] = i end

            -- 实时调试（2026-11-10；2026-11-11 协议 v2：频两项改发原始值
            -- eff/uni——"显示未乘系数的数字"，尾接 CE 三分量 ce1/ce2/ce3
            -- （未乘 kCeW 权重，查看器点击 CE 单元格展开）；L 尾加 prep=预解码命中）：
            -- L 头行（完整上文，不截断）+ 逐候选 C 行（含层1 透传尾窗，上限
            -- 20 行；win=1 层2窗内/0 尾窗透传，ce 空串=无 CE 分，fin=最终
            -- 输出位置）。与 debug.txt 人类格式互补，供查看器渲染。
            local prep = prep_flag
            -- 协议 v4（2026-11-12）：L 尾追加 ctx_used = 推理实际使用的
            -- 上文尾部文本（去空白上文中末 ≤max_ctx token 的原文段，
            -- get_ctx_used 容错旧 DLL；查看器据此灰显未用前缀）
            local okcu, cu = pcall(function() return llm.get_ctx_used() end)
            local ctxused = (okcu and type(cu) == "string") and live_esc(cu) or ""
            -- L 第 3 字段原为评分缓存 HIT/MISS——缓存已删（2026-11-11），
            -- 保留位置发 "-"（旧查看器显示"评缓 -"，字段数不变免错位）
            -- 尾两字段: prep=预解码命中, ctx_used=推理用尾部。
            -- n_seen 字段已删（2026-11-17 用户定案：不参与打分, 连记录
            -- 一并取消）——查看器按字段数兼容旧行（>12 取第 13 字段，
            -- 否则第 12 字段）。
            live(string.format("L|%s|%s|%s|%s|%s|%s|%.0f|%s|%d|%s|%s",
                os.date("%H:%M:%S"), live_esc(input), "-",
                live_esc(ctx_src), live_esc(context),
                tostring(_G.user_freq_tick), ev_ms, live_ready, #cands, prep,
                ctxused))
            local winset = {}
            for _, w in ipairs(l1win) do winset[w] = true end
            local emitted = 0
            local function live_c(c, fin)
                if emitted >= 20 then return end
                emitted = emitted + 1
                local d = dbg[c.text]
                local d3 = d and d.ce3
                live(table.concat({
                    "C", tostring(all_rank[c.text] or 0), live_esc(c.text),
                    live_fmt3(s1_of[c.text]),
                    (d and d.ce and d.ce > -1e9) and live_fmt3(d.ce) or "",
                    d and live_fmt3(d.eff) or "",
                    tostring(d and d.uni or 0),
                    d and live_fmt3(d.fused) or "",
                    (d and d.full) and "1" or "0",
                    tostring(d and d.cerank or 0),
                    tostring(fin), winset[c.text] and "1" or "0",
                    d3 and live_fmt3(d3[1]) or "",
                    d3 and live_fmt3(d3[2]) or "",
                    d3 and live_fmt3(d3[3]) or "",
                    d and live_fmt3(d.fb) or "",   -- 词频得分 β·log1p(eff)
                    d and live_fmt3(d.u1) or "",   -- 累计得分 log(p1)
                    -- v5: 旧 pf = 负分幅度（仅扣分，0=未命中），保留给旧查看器
                    d and live_fmt3(d.pf or 0) or "0",
                    -- v6 (2026-11-17): 有符号词码对修正分（+200/+100/−5/0）
                    d and live_fmt3(d.sdelta or 0) or "0"
                }, "|"))
            end
            for i, c in ipairs(ordered) do live_c(c, i) end
            local tail_pos = #ordered
            for _, e in ipairs(layer1) do
                if not seen[e.c.text] then
                    tail_pos = tail_pos + 1
                    live_c(e.c, tail_pos)
                end
            end
            -- debug P/D：只写语料没有的字段；词/候选序在语料 W，
            -- 靠 wid 关联；不写 debug 文件的人类可读块。
            _G.llm_debug_p(wid, ev_ms, prep_flag == "1")
            for i, c in ipairs(ordered) do
                local d = dbg[c.text]
                if d then
                    local d3 = d.ce3 or {}
                    _G.llm_debug_d(wid, i, d.ce, d3[1], d3[2], d3[3],
                                   d.eff, d.fb, d.u1, d.full, d.fused,
                                   d.sdelta, d.cerank, i)
                end
            end
        end
        -- 常开语料 W ok（最终序 + 引擎前 10 + 层1 窗）
        if wid and not w_written then
            _G.llm_write_w(wid, ctx_src, input, context, engine_top, l1win,
                           texts_of(ordered, 20), tick, "ok", "",
                           prep_flag == "1", "")
            w_written = true
        end
        -- 来源徽章已删（2026-11-10 用户定案：实时调试窗口上线——上文来源/
        -- 内容与逐候选分数都在调试窗口看，候选窗保持干净、不再动 comment）
        for _, c in ipairs(ordered) do yield(c) end
        for _, e in ipairs(layer1) do
            if not seen[e.c.text] then yield(e.c) end
        end
    else
        -- 评分失败/缺分: 层1 已重排全体候选 → 按层1 序展示
        if wid and not w_written then
            _G.llm_write_w(wid, ctx_src, input, context, engine_top, l1win,
                           {}, tick, "skip", skip_reason or "score_failed",
                           prep_flag == "1", "")
            w_written = true
        end
        for _, e in ipairs(layer1) do yield(e.c) end
    end
end
