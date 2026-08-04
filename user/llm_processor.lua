-- llm_processor.lua — 上屏文字收集 + 预解码触发
-- 输出格式（一个场景一行）：
--   词1\t码1|词2\t码2|←|词3\t码3
--   | 分隔条目，\t 分隔词和码，← 退格，无码时码为空串

local prev_hist = {}     -- 上次 history 快照
local history = {}       -- 当前上屏词序列
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
    return k == "BackSpace" or k == "Delete"
        or k == "Control+BackSpace" or k == "Control+Delete"
        or NAV_KEYS[k]
        or k == "Return" or k == "KP_Enter"  -- 回车换行: 新段落, 上屏词序列断开
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
    local backend = (sc:get_string("llm_rerank/backend") or "off")
    if backend == "off" then
        llm_prep = nil  -- 释放已加载的 DLL 引用
    elseif not llm_prep then
        local modname = (backend == "gpu" or backend == "cuda") and "rime_llm_cuda" or "rime_llm"
        local ok, result = pcall(require, modname)
        if ok then
            -- 日志目录: RIME 用户目录 (与 filter 共用同一模块实例)
            local okd, ud = pcall(function() return rime_api.get_user_data_dir() end)
            if okd and ud and ud ~= "" then result.log_dir = ud end
            llm_prep = result
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
    --   return 2 跳过 commit_history 同步 (引擎 Pop 会重建 history, 覆盖重置;
    --   且退格后剩余词不应作为新词重新记录训练数据)
    if ctx.input == "" and is_edit_key(key:repr()) then
        local k = key:repr()
        if NAV_KEYS[k] or k == "Return" or k == "KP_Enter" then
            if #history > 0 then
                append_raw("\n")
            end
        elseif #history > 0 then
            append_raw(SPLIT .. BSP)
        end
        reset_history()
        -- 编辑后重打相同词 (ctx+input 相同) 必须重新推理: 清空 filter 结果缓存
        _G.llm_filter_cache = nil
        -- 上文已重置 → 立即异步预解码 (空上文)
        cur_ctx = (_G.llm_context_get() or ""):gsub('%s+', '')
        if llm_prep and llm_prep.prepare and cur_ctx ~= last_prep_ctx then
            last_prep_ctx = cur_ctx
            llm_prep.prepare(cur_ctx)
        end
        return 2
    end

    -- 同步 commit_history
    local all = ch:to_table()
    if all and #all > 0 then
        history = {}
        for i = 1, #all do
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
