-- llm_processor.lua — 上屏文字收集 + 预解码触发
-- 输出格式（一个场景一行）：
--   词1\t码1|词2\t码2|←|词3\t码3
--   | 分隔条目，\t 分隔词和码，← 退格，无码时码为空串

local prev_hist = {}     -- 上次 history 快照
local history = {}       -- 当前上屏词序列
local commit_base = 0    -- 上文基座: 只认 commit_history 中 base 之后的新词
                         -- (编辑键后旧词永久忽略——librime 无法清 commit_history)
local SPLIT = "|"
local TAB = "\t"
local BSP = "←"
local prev_input = ""    -- 上一轮的输入码
local pending_code = ""  -- 手动选词上屏码（输入变空瞬间捕获）
local last_full = ""     -- 最后满码（4码），顶屏时回退用
local MAX_CODE = 4       -- 满码长度
local llm_prep = nil     -- 缓存的 llm 模块 (for prepare)
local last_prep_ctx = "" -- 上次 prepare 的 context，避免重复调用

local NAV_KEYS = { Left=true, Right=true, Up=true, Down=true,
                   Home=true, End=true, Page_Up=true, Page_Down=true }
-- 编辑位置变化键: 退格/删除 (删词) + 导航键 (光标移动/滚动) + 回车 (换行)
-- 这些键使会话上屏词序列不再代表光标前上文 → 上屏历史上文重置为空
local function is_edit_key(k)
    if k == "BackSpace" or k == "Delete"
        or k == "Control+BackSpace" or k == "Control+Delete"
        or NAV_KEYS[k]
        or k == "Return" or k == "KP_Enter" then  -- 回车换行: 新段落, 上屏词序列断开
        return true
    end
    -- 组合导航 (Control+Left / Shift+Home 等): 以导航键名结尾的 repr 均视为编辑位置变化
    for name in pairs(NAV_KEYS) do
        if #k > #name and k:sub(-#name) == name then return true end
    end
    return false
end

local function reset_history()
    history = {}
    prev_hist = {}
end

local function append_raw(text)
    local f = io.open(rime_api.get_user_data_dir() .. "\\llm_training.txt", "a")
    if f then
        f:write(text)
        f:close()
    end
end

-- === 用户词频计数 (llm_filter 排序融合用, 2026-08-19; 2026-08-21 改 Rime 时间衰减) ===
-- _G.user_word_freq: 词 → {c=累计次数, d=衰减计数 dee, t=最后提交 tick}
-- _G.user_freq_tick: 全局 tick (每词提交 +1, 同 rime userdb UpdateTickCount)
-- 衰减算法 = librime algo::formula_d (user_dictionary.cc 调频同源):
--   提交: dee = 1 + dee·exp((t_old - t_now)/200)   时间常数 τ=200 tick
--   查询: eff = dee·exp((t_word - t_now)/200)      (未提交期间持续衰减)
-- 每 20 个新词重写落盘 user_freq.tsv (崩溃最多丢 19 次计数)。仅计含中文的词
-- (判定为非 ASCII 即计, 与 Rime userdb "任何词条提交推 tick" 同源口径——
-- 全角标点也计, 有意为之; 2026-09-03 tick 含一字词定案同源原则)。
-- 格式: 首行 "#tick=N", 数据行 "词\t累计\tdee\ttick"; 兼容旧版 "词\t次数"
-- (迁移为 dee=次数, tick=当前 — 视为刚提交过)。
-- 落盘修剪 (2026-09-04): eff < 1e-3 的冷词条不再写 (对融合分影响
-- < 0.002 nats, 远低于任何实际分差) — 文件有界, 旧冷词条自然淘汰。
local FREQ_TAU = 200
local FREQ_FLUSH = 20
local freq_dirty = 0
local function freq_file()
    return rime_api.get_user_data_dir() .. "\\user_freq.tsv"
end
local function freq_load()
    _G.user_word_freq = _G.user_word_freq or {}
    local tick, maxt, legacy = nil, 0, {}
    local f = io.open(freq_file(), "r")
    if f then
        for line in f:lines() do
            local t = line:match("^#tick=(%d+)$")
            if t then
                tick = tonumber(t)
            else
                local w, c, d, tk = line:match("^(.-)\t(%d+)\t([%d%.]+)\t(%d+)$")
                if w and c and d and tk then
                    _G.user_word_freq[w] = { c = tonumber(c), d = tonumber(d), t = tonumber(tk) }
                    if tonumber(tk) > maxt then maxt = tonumber(tk) end
                else
                    local w2, n = line:match("^(.-)\t(%d+)$")
                    if w2 and n then legacy[#legacy + 1] = { w2, tonumber(n) } end
                end
            end
        end
        f:close()
    end
    _G.user_freq_tick = tick or maxt
    for _, e in ipairs(legacy) do
        _G.user_word_freq[e[1]] = { c = e[2], d = e[2], t = _G.user_freq_tick }
    end
end
local function freq_save()
    local f = io.open(freq_file(), "w")
    if f then
        f:write("#tick=" .. (_G.user_freq_tick or 0) .. "\n")
        local now = _G.user_freq_tick or 0
        for w, e in pairs(_G.user_word_freq) do
            local eff = e.d * math.exp((e.t - now) / FREQ_TAU)
            if eff >= 1e-3 then  -- 修剪: 衰减到噪声级的冷词条不落盘
                f:write(string.format("%s\t%d\t%.3f\t%d\n", w, e.c, e.d, e.t))
            end
        end
        f:close()
    end
end
local function freq_bump(word)
    if not _G.user_word_freq then freq_load() end
    _G.user_freq_tick = (_G.user_freq_tick or 0) + 1
    local e = _G.user_word_freq[word]
    if not e then
        e = { c = 0, d = 0, t = 0 }
        _G.user_word_freq[word] = e
    end
    e.d = 1 + e.d * math.exp((e.t - _G.user_freq_tick) / FREQ_TAU)
    e.c = e.c + 1
    e.t = _G.user_freq_tick
    freq_dirty = freq_dirty + 1
    if freq_dirty >= FREQ_FLUSH then
        freq_save()
        freq_dirty = 0
    end
end

-- 衰减有效计数 (llm_filter 融合用): rime formula_d 查询式
_G.user_freq_eff = function(w)
    local e = _G.user_word_freq and _G.user_word_freq[w]
    if not e or e.d <= 0 then return 0 end
    return e.d * math.exp((e.t - (_G.user_freq_tick or e.t)) / FREQ_TAU)
end

local function find_overlap(prev, curr)
    local np, nc = #prev, #curr
    for len = math.min(np, nc), 0, -1 do
        local match = true
        for j = 1, len do
            if prev[np - len + j] ~= curr[j] then
                match = false
                break
            end
        end
        if match then return len end
    end
    return 0
end

local function processor(key, env)
    if key:release() then return 2 end

    -- 上文检查 + 预解码 (每次按键): commit_history 变化 → 立即异步预解码
    local sc = env.engine.schema.config
    local enabled = sc:get_bool("llm_rerank/enabled") or false
    if not enabled then
        llm_prep = nil  -- 释放已加载的 DLL 引用
    else
        if not llm_prep then
            local ok, result = pcall(require, "rime_llm")
            if ok then
                -- 日志目录: RIME 用户目录 (与 filter 共用同一模块实例)
                local okd, ud = pcall(function() return rime_api.get_user_data_dir() end)
                if okd and ud and ud ~= "" then result.log_dir = ud end
                llm_prep = result
            end
        end
        -- model_path 每键轻量同步（仅变化时写，2026-08-31 修配置不生效的
        -- 根因）：路径只在"一次性 require 块"里读的话，首个触发 require 的
        -- 会话（部署期编译会话/配置未就绪的瞬间）会把默认路径永久固化到
        -- 模块级 llm_prep，之后的按键永不重读。prepare 是懒加载触发点，
        -- 同步必须发生在它之前——本键同步、本键 prepare，路径必然就位。
        local mp = sc:get_string("llm_rerank/model_path")
        if mp and mp ~= "" and llm_prep and llm_prep.model_path ~= mp then
            llm_prep.model_path = mp
            -- 模型将卸载重载, 旧模型的评分缓存作废 (2026-09-04; 源码版
            -- unload_model 清 s_cache 同理)——不清则同码重打期间继续用旧分
            _G.llm_filter_cache = nil
        end
    end
    -- ctx 归一化与 llm_filter 一致 (去空白): C++ prep 命中 = token 序列比较,
    -- 不一致会导致 prep 永远不命中 → 每次 score 完整解码 (~50ms)。
    -- 中文无空白两者相同; 含英文/空格 (如 "Hello world 你好") 时保证一致。
    local cur_ctx = (_G.llm_context_get() or ""):gsub('%s+', '')
    if llm_prep and llm_prep.prepare and cur_ctx ~= last_prep_ctx then
        last_prep_ctx = cur_ctx
        llm_prep.prepare(cur_ctx)
    end

    local ctx = env.engine.context
    local ch = ctx.commit_history
    if not ch then return 2 end

    -- 追踪满码（顶屏时回退用）
    if ctx.input ~= "" and #ctx.input >= MAX_CODE then
        last_full = ctx.input
    end

    -- 输入变空 → 捕获本次上屏码（手动选词、Tab、数字键）
    if prev_input ~= "" and ctx.input == "" then
        pending_code = prev_input
        last_full = ""  -- 已消费
    end
    prev_input = ctx.input

    -- 退格 / Delete / 导航键 (composition 为空时): 编辑位置变化
    --   rime 来源上文重置为空 (会话上屏词序列不再代表光标前上文), 立即重新预解码
    --   return 0 放行按键 (导航键/退格由后续 processor 正常处理, 光标移动),
    --   本分支已提前返回, 后续 commit_history 同步不会执行 (不覆盖重置;
    --   退格后剩余词不会作为新词重新记录训练数据)
    if ctx.input == "" and is_edit_key(key:repr()) then
        local k = key:repr()
        if NAV_KEYS[k] or k == "Return" or k == "KP_Enter" or
           k:match("(Left|Right|Up|Down|Home|End|Page_Up|Page_Down)$") then
            if #history > 0 then
                append_raw("\n")
            end
        elseif #history > 0 then
            append_raw(SPLIT .. BSP)
        end
        reset_history()
        -- 编辑键: 当前 commit_history 位置记为基座——旧词永久忽略
        -- (librime lua 无法清 commit_history, 旧词留在引擎里;
        -- 退格会被引擎清空 commit_history → 同步段检测缩短自动重置基座)
        commit_base = #ch:to_table()
        -- 编辑后重打相同词 (ctx+input 相同) 必须重新推理: 清空 filter 结果缓存
        _G.llm_filter_cache = nil
        if sc:get_bool("llm_rerank/debug_fusion") then
            pcall(function()
                local f = io.open(rime_api.get_user_data_dir()
                    .. "\\rime_llm_debug.txt", "a")
                if f then
                    f:write(string.format(
                        "%s|reset|编辑键(%s)→上文重置+缓存清空\n",
                        os.date("%H:%M:%S"), key:repr()))
                    f:close()
                end
            end)
        end
        -- 上文已重置 → 立即异步预解码 (空上文)
        cur_ctx = (_G.llm_context_get() or ""):gsub('%s+', '')
        if llm_prep and llm_prep.prepare and cur_ctx ~= last_prep_ctx then
            last_prep_ctx = cur_ctx
            llm_prep.prepare(cur_ctx)
        end
        return 0
    end

    -- 同步 commit_history
    local all = ch:to_table()
    -- 引擎清空 commit_history（退格等）→ 基座重置重新计数
    if all and #all < commit_base then
        commit_base = 0
    end
    if all and #all > commit_base then
        history = {}
        for i = commit_base + 1, #all do
            local entry = all[i]
            if entry and entry.text and #entry.text >= 1 then
                table.insert(history, entry.text)
            end
        end

        local overlap = find_overlap(prev_hist, history)
        local new_words = {}
        for i = overlap + 1, #history do
            table.insert(new_words, history[i])
        end

        if #new_words > 0 then
            if overlap == 0 then
                append_raw("\n")
            end

            local parts = {}
            for _, w in ipairs(new_words) do
                -- 含中文才分配码，跳过纯英文/数字/标点
                local has_chinese = w:match("[^\1-\127]")
                local code = ""
                if has_chinese then
                    -- 优先手动捕获的码，其次满码（顶屏回退），用完即清
                    code = pending_code
                    if code == "" then
                        code = last_full
                    end
                end
                pending_code = ""
                last_full = ""
                -- 词频计数: 仅含中文的词 (含英文/数字/标点不参与融合)
                if has_chinese then
                    if not _G.user_word_freq then freq_load() end  -- 诊断读数前先就位
                    local before = _G.user_freq_eff and _G.user_freq_eff(w) or 0
                    local t_before = _G.user_freq_tick or 0
                    freq_bump(w)
                    local dbg_flag = sc:get_bool("llm_rerank/debug_fusion")
                    if dbg_flag then
                        pcall(function()
                            local f = io.open(rime_api.get_user_data_dir()
                                .. "\\rime_llm_debug.txt", "a")
                            if f then
                                f:write(string.format(
                                    "%s|commit|词=%s|码=%s|eff %.3f→%.3f|tick %d→%d|flush脏%d/20\n",
                                    os.date("%H:%M:%S"), w, code, before,
                                    _G.user_freq_eff(w), t_before,
                                    _G.user_freq_tick or 0, freq_dirty))
                                f:close()
                            end
                        end)
                    end
                end
                -- 真实候选窗快照 (llm_filter 记录): 用截断前的完整码匹配
                -- (filter 记录的是完整 input; 训练样本带真实候选窗 词\t码\t候选1,候选2,...,
                -- LLM 重排目标 = 在窗内把正确词排第一; 无快照/不匹配回退旧格式 仅词+码)
                local window_cands = ""
                if code ~= "" and _G.llm_last_window
                        and _G.llm_last_window.input == code then
                    window_cands = TAB .. table.concat(_G.llm_last_window.cands, ",")
                    _G.llm_last_window = nil  -- 已消费
                end
                -- 单字 3 码只需前 2 码（第 3 码是形码，由字本身决定）
                if #w == 1 and #code >= 3 then
                    code = code:sub(1, 2)
                end
                table.insert(parts, w .. TAB .. code .. window_cands)
            end
            local sep = (overlap > 0 and SPLIT or "")
            append_raw(sep .. table.concat(parts, SPLIT))
        end

        if #new_words == 0 and #history < #prev_hist and #history < 3 then
            pending_code = ""
            last_full = ""
            append_raw("\n")
        end

        prev_hist = {}
        for _, v in ipairs(history) do table.insert(prev_hist, v) end
    end

    return 2
end

local function get_context()
    -- 上文 = 上屏历史 (commit_history)。返回 (文本, 来源)
    return table.concat(history, ""), "rime"
end

_G.llm_context_get = get_context
return processor
