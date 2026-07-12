-- llm_context.lua — 上屏文字收集 + 打字序列采集
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

    -- 退格
    if ctx.input == "" and key:repr() == "BackSpace" then
        if #history > 0 then
            append_raw(SPLIT .. BSP)
        end
        return 2
    end

    -- Delete
    if ctx.input == "" and key:repr() == "Delete" then
        if #history > 0 then
            append_raw(SPLIT .. BSP)
        end
        return 2
    end

    -- 导航键 → 换行
    if ctx.input == "" and NAV_KEYS[key:repr()] then
        if #history > 0 then
            append_raw("\n")
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
                -- 单字 3 码只需前 2 码（第 3 码是形码，由字本身决定）
                if #w == 1 and #code >= 3 then
                    code = code:sub(1, 2)
                end
                table.insert(parts, w .. TAB .. code)
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

        -- Context 已更新，立即预解码。与 filter 使用同一个 DLL
        if not llm_prep then
            -- 读取 backend 配置，和 filter 一致
            local sc = env.engine.schema.config
            local backend = (sc:get_string("llm_rerank/backend") or "cpu")
            local modname = (backend == "gpu" or backend == "cuda") and "rime_llm_cuda" or "rime_llm"
            local ok, result = pcall(require, modname)
            if ok then llm_prep = result end
        end
        local cur_ctx = _G.llm_context_get()
        if llm_prep and llm_prep.prepare and cur_ctx ~= last_prep_ctx then
            last_prep_ctx = cur_ctx
            llm_prep.prepare(cur_ctx)
        end
    end

    return 2
end

local function get_context()
    return table.concat(history, "")
end

_G.llm_context_get = get_context
return processor
