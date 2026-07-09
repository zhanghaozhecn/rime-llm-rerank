-- llm_rerank.lua — LLM candidate rerank filter (CPU)

local llm = nil
local inited = false

local cfg = {
    min_code_len   = 4,
    min_tokens     = 1,
    max_tokens     = 6,
    max_candidates = 3,
    cpu_cores      = nil,  -- nil = auto-detect in C++
}

local lat_max   = 0
local lat_count = 0
local mem_logged = false

local function do_init(env)
    if inited then return end
    inited = true

    local sc = env.engine.schema.config
    local ns = sc:get_map("llm_rerank")
    if ns then
        local v = tonumber(ns:get_value("min_code_len"))
        if v then cfg.min_code_len = v end
        v = tonumber(ns:get_value("max_tokens"))
        if v then cfg.max_tokens = v end
        v = tonumber(ns:get_value("max_candidates"))
        if v then cfg.max_candidates = v end
        v = tonumber(ns:get_value("cpu_cores"))
        if v then cfg.cpu_cores = v end
        v = tonumber(ns:get_value("min_tokens"))
        if v then cfg.min_tokens = v end
    end

    local ok, cpp = pcall(require, "rime_llm")
    if ok and cpp then
        cpp.model_path = os.getenv("RIME_LLM_MODEL") or "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
        cpp.max_ctx    = cfg.max_tokens
        cpp.min_tokens = cfg.min_tokens
        if cfg.cpu_cores then cpp.n_threads = cfg.cpu_cores end
        llm = cpp
    end
end

-- === Filter ===
return function(translation, env)
    do_init(env)

    local all = {}
    for cand in translation:iter() do table.insert(all, cand) end
    if #all < 2 then for _, c in ipairs(all) do yield(c) end; return end

    local TEMP = os.getenv("TEMP") or "C:\\Windows\\Temp"
    if io.open(TEMP .. "\\rime_llm_off", "r") then
        for _, c in ipairs(all) do yield(c) end; return
    end

    if not llm then
        for _, c in ipairs(all) do yield(c) end; return
    end

    local input = env.engine.context.input or ""
    if #input < cfg.min_code_len then
        for _, c in ipairs(all) do yield(c) end; return
    end

    local context = ((_G.llm_context_get and _G.llm_context_get()) or ""):gsub('%s+', '')
    local cands = {}
    for i, c in ipairs(all) do
        if i > cfg.max_candidates then break end
        table.insert(cands, c.text)
    end

    local t0 = os.clock()
    local ok, result = pcall(function() return llm.score(context, cands) end)
    local elapsed_ms = (os.clock() - t0) * 1000

    -- Event log: 时间|计数|编码|候选列表|上文|LLM结果|延迟ms
    local ef = io.open(TEMP .. "\\rime_llm_events.txt", "a")
    if ef then
        local cand_str = table.concat(cands, ","):gsub("|", "/")
        local ctx_safe = context:gsub("|", "/"):gsub("\n", " ")
        local res_info = "nil"
        if ok and type(result) == "table" then
            res_info = table.concat(result, ","):gsub("|", "/")
        elseif ok and result then
            res_info = tostring(result)
        end
        lat_count = lat_count + 1
        if elapsed_ms > lat_max then lat_max = elapsed_ms end
        ef:write(string.format("%s|%d|%s|%s|%s|%s|%.0fms\n",
            os.date("%H:%M:%S"), lat_count, input,
            cand_str, ctx_safe, res_info, elapsed_ms))
        ef:close()
    end

    -- 首次成功重排时记录内存占用
    if ok and result and not mem_logged and llm.get_memory then
        mem_logged = true
        local mb = llm.get_memory()
        if mb and mb > 0 then
            local memf = io.open(TEMP .. "\\rime_llm_events.txt", "a")
            if memf then memf:write(string.format("# model memory: %d MB\n", mb)); memf:close() end
        end
    end

    if ok and result then
        -- result = LLM 按分数降序排列的候选表 {best, second, ...}
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
        for i, c in ipairs(ordered) do
            if i == 1 then
                yield(ShadowCandidate(c, c.type, c.text, c.comment .. " AI", true))
            else
                yield(c)
            end
        end
        for _, c in ipairs(all) do
            if not seen[c.text] then yield(c) end
        end
    else
        for _, c in ipairs(all) do yield(c) end
    end
end
