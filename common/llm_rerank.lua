-- llm_rerank.lua — LLM candidate rerank filter (CPU)

local llm = nil
local inited = false

local cfg = {
    min_code_len   = 4,
    min_tokens     = 1,
    max_tokens     = 4,
    max_candidates = 4,
    cpu_cores      = nil,  -- nil = auto-detect in C++
}

local lat_max   = 0
local lat_count = 0

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

    -- Event log: time|code|ctx_chars|n_cands|LLM_pick|ok|ms|cand1,cand2,...
    local ef = io.open(TEMP .. "\\rime_llm_events.txt", "a")
    if ef then
        local cand_str = table.concat(cands, ","):gsub("|", "/")
        local ctx_safe = context:gsub("|", "/"):gsub("\n", " ")
        ef:write(string.format("%s|%s|%d|%s|%s|%d|%s|%s|%s\n",
            os.date("%H:%M:%S"), input, #context, tostring(#cands),
            ok and result or "nil", ok and (result ~= nil) and 1 or 0,
            tostring(math.floor(elapsed_ms)), ctx_safe, cand_str))
        ef:close()
    end

    lat_count = lat_count + 1
    if elapsed_ms > lat_max then lat_max = elapsed_ms end
    local pf = io.open(TEMP .. "\\rime_latency.txt", "w")
    if pf then
        pf:write(string.format("count=%d  max=%.0fms  last=%.0fms",
            lat_count, lat_max, elapsed_ms))
        pf:close()
    end

    if ok and result then
        local llm_cand = nil
        for _, c in ipairs(all) do if c.text == result then llm_cand = c; break end end
        if llm_cand then
            yield(ShadowCandidate(llm_cand, llm_cand.type, llm_cand.text,
                llm_cand.comment .. " AI", true))
        end
        for _, c in ipairs(all) do if c ~= llm_cand then yield(c) end end
    else
        for _, c in ipairs(all) do yield(c) end
    end
end
