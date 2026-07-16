-- llm_filter.lua — LLM candidate rerank filter
-- 由 schema llm_rerank.backend 控制：cpu | gpu | off
-- off 时不加载 DLL，不推理，候选原样透传

local llm = nil
local llm_loaded_for = nil  -- backend value when llm was loaded

local cfg = {
    min_code_len   = 4,
    min_tokens     = 1,
    max_tokens     = 6,
    max_candidates = 5,
    cpu_cores      = nil,  -- nil = auto-detect in C++
}

local lat_max   = 0
local lat_count = 0

local function load_llm(env, backend)
    local modname = (backend == "gpu" or backend == "cuda") and "rime_llm_cuda" or "rime_llm"
    local ok, cpp = pcall(require, modname)
    if ok and cpp then
        local sc = env.engine.schema.config
        local mp = sc:get_string("llm_rerank/model_path")
        cpp.model_path = (mp and mp ~= "") and mp or "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
        cpp.max_ctx    = cfg.max_tokens
        cpp.min_tokens = cfg.min_tokens
        if cfg.cpu_cores then cpp.n_threads = cfg.cpu_cores end
        llm = cpp
        llm_loaded_for = backend
    end
end

local function init_config(env)
    local sc = env.engine.schema.config
    local v = sc:get_int("llm_rerank/min_code_len")
    if v then cfg.min_code_len = v end
    v = sc:get_int("llm_rerank/max_tokens")
    if v then cfg.max_tokens = v end
    v = sc:get_int("llm_rerank/max_candidates")
    if v then cfg.max_candidates = v end
    v = sc:get_int("llm_rerank/cpu_cores")
    if v then cfg.cpu_cores = v end
    v = sc:get_int("llm_rerank/min_tokens")
    if v then cfg.min_tokens = v end
end

-- === Filter ===
return function(translation, env)
    -- 每次调用都从 schema 读取 backend，确保重新部署后立即生效
    local sc = env.engine.schema.config
    local backend = (sc:get_string("llm_rerank/backend") or "off")

    -- Init config once (non-DLL config doesn't invalidate on redeploy)
    if not cfg._inited then
        init_config(env)
        cfg._inited = true
    end

    local all = {}
    for cand in translation:iter() do table.insert(all, cand) end
    if #all < 2 then for _, c in ipairs(all) do yield(c) end; return end

    -- backend off → 原样透传，不推理
    if backend == "off" then
        for _, c in ipairs(all) do yield(c) end; return
    end

    -- Lazy load DLL on first use for this backend
    if llm_loaded_for ~= backend then
        llm = nil; llm_loaded_for = nil
        load_llm(env, backend)
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

    -- Event log
    local TEMP = os.getenv("TEMP") or "C:\\Windows\\Temp"
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
