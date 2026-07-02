-- llm_rerank.lua — LLM candidate rerank filter
-- Config in schema.yaml under "llm_rerank" namespace

local M = {}
local llm = nil
local backend = "none"

-- Defaults (overridden by schema config)
local cfg = {
    code_pattern   = "^[a-z]{4}$",  -- regex: which codes trigger LLM
    min_tokens     = 1,             -- min context tokens to start rerank
    max_tokens     = 4,             -- max context tokens for scoring
    max_candidates = 4,             -- candidates to score in parallel (2-9)
    cpu_cores      = 6,             -- physical CPU cores
}

local lat_max   = 0
local lat_count = 0

-- === Init: read schema config, load backend ===
function M.init(env)
    local sc = env.engine.schema.config
    local ns = sc:get_map("llm_rerank")
    if ns then
        cfg.code_pattern   = ns:get_value("code_pattern")   or cfg.code_pattern
        cfg.min_tokens     = tonumber(ns:get_value("min_tokens"))     or cfg.min_tokens
        cfg.max_tokens     = tonumber(ns:get_value("max_tokens"))     or cfg.max_tokens
        cfg.max_candidates = tonumber(ns:get_value("max_candidates")) or cfg.max_candidates
        cfg.cpu_cores      = tonumber(ns:get_value("cpu_cores"))      or cfg.cpu_cores
    end

    -- Try C++ plugin first
    local ok_cpp, cpp = pcall(function() return require("rime_llm") end)
    if ok_cpp and cpp then
        cpp.model_path = os.getenv("RIME_LLM_MODEL") or "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
        cpp.max_ctx    = cfg.max_tokens
        cpp.n_threads = cfg.cpu_cores
        llm = cpp
        backend = "cpp"
    else
        local ok_pipe, pipe = pcall(function() return require("rime_pipe") end)
        if ok_pipe and pipe then
            pipe.TIMEOUT = 0.2
            llm = pipe
            backend = "pipe"
        end
    end
end

-- === Filter ===
function M.func(translation, env)
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

    -- Check code pattern
    local input = env.engine.context.input or ""
    if not input:match(cfg.code_pattern) then
        for _, c in ipairs(all) do yield(c) end; return
    end

    -- Collect context and candidates
    local context = ((_G.llm_context_get and _G.llm_context_get()) or ""):gsub('%s+', '')
    local cands = {}
    for i, c in ipairs(all) do
        if i > cfg.max_candidates then break end
        table.insert(cands, c.text)
    end

    local t0 = os.clock()
    local ok, result = nil, nil

    if backend == "cpp" then
        ok, result = pcall(function() return llm.score(context, cands) end)
    else -- pipe
        local parts = {}
        for _, w in ipairs(cands) do
            table.insert(parts, '"' .. w:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"')
        end
        local esc = context:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
        local body = '{"context":"' .. esc .. '","candidates":[' .. table.concat(parts, ",") .. ']}'
        ok, result = pcall(function()
            local r, s = llm.request("http://127.0.0.1:9877/rerank", body)
            if type(s) == "number" and s >= 200 and s < 300 and type(r) == "string" then
                if r:find('"rerank":%s*false') then return nil end
                local fp = r:find('"first"')
                if fp then return r:sub(fp):match('"first":%s*"([^"]+)"') end
            end
        end)
    end

    local elapsed_ms = (os.clock() - t0) * 1000
    lat_count = lat_count + 1
    if elapsed_ms > lat_max then lat_max = elapsed_ms end
    local pf = io.open(TEMP .. "\\rime_latency.txt", "w")
    if pf then
        pf:write(string.format("count=%d  max=%.0fms  last=%.0fms  backend=%s",
            lat_count, lat_max, elapsed_ms, backend))
        pf:close()
    end

    if ok and result then
        local llm_cand = nil
        for _, c in ipairs(all) do if c.text == result then llm_cand = c; break end end
        if llm_cand then
            yield(ShadowCandidate(llm_cand, llm_cand.type, llm_cand.text,
                llm_cand.comment .. " ⚡", true))
        end
        for _, c in ipairs(all) do if c ~= llm_cand then yield(c) end end
    else
        for _, c in ipairs(all) do yield(c) end
    end
end

return M
