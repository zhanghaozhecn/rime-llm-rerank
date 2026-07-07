-- llm_rerank.lua — LLM candidate rerank filter (CPU)
-- 编码先验: 用读音概率修正 LLM 分数，解决多音字误排

local llm = nil
local inited = false
local code_prior = nil  -- 编码先验表 {[code] = {[word] = log_prior}}

local cfg = {
    min_code_len   = 3,    -- 3=单字全码, 4=词
    min_tokens     = 1,
    max_tokens     = 6,
    max_candidates = 3,
    cpu_cores      = nil,  -- nil = auto-detect in C++
    prior_alpha    = 0.5,  -- 先验强度: 0=关闭, 1=满强度
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
        v = tonumber(ns:get_value("prior_alpha"))
        if v then cfg.prior_alpha = v end
    end

    local ok, cpp = pcall(require, "rime_llm")
    if ok and cpp then
        cpp.model_path = os.getenv("RIME_LLM_MODEL") or "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
        cpp.max_ctx    = cfg.max_tokens
        cpp.min_tokens = cfg.min_tokens
        if cfg.cpu_cores then cpp.n_threads = cfg.cpu_cores end
        llm = cpp
    end

    -- 加载编码先验表
    local ok2, cp = pcall(require, "code_prior")
    if ok2 and cp then
        code_prior = cp
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
    local ok, ranked, scores = pcall(function() return llm.score(context, cands) end)
    local elapsed_ms = (os.clock() - t0) * 1000

    -- Event log: 时间|计数|编码|候选列表|上文|LLM结果|延迟ms
    local ef = io.open(TEMP .. "\\rime_llm_events.txt", "a")
    if ef then
        local cand_str = table.concat(cands, ","):gsub("|", "/")
        local ctx_safe = context:gsub("|", "/"):gsub("\n", " ")
        local res_info = "nil"
        if ok and type(ranked) == "table" then
            res_info = table.concat(ranked, ","):gsub("|", "/")
        end
        lat_count = lat_count + 1
        if elapsed_ms > lat_max then lat_max = elapsed_ms end
        ef:write(string.format("%s|%d|%s|%s|%s|%s|%.0fms\n",
            os.date("%H:%M:%S"), lat_count, input,
            cand_str, ctx_safe, res_info, elapsed_ms))
        ef:close()
    end

    if ok and ranked and scores then
        -- 对每个候选计算调整后的分数: adjusted = llm_score + alpha * log_prior
        local prior_map = nil
        if code_prior and cfg.prior_alpha > 0 then
            prior_map = code_prior[input]
        end

        local scored = {}
        local seen = {}
        for _, c in ipairs(all) do
            local s = scores[c.text]
            if s then
                if prior_map then
                    local lp = prior_map[c.text]
                    if lp then
                        s = s + cfg.prior_alpha * lp  -- lp ≤ 0, 惩罚低频读音
                    end
                end
                if not seen[c.text] then
                    seen[c.text] = true
                    table.insert(scored, {cand = c, score = s})
                end
            end
        end

        -- 按调整后分数降序
        table.sort(scored, function(a, b) return a.score > b.score end)

        for i, item in ipairs(scored) do
            if i == 1 then
                yield(ShadowCandidate(item.cand, item.cand.type, item.cand.text, item.cand.comment .. " AI", true))
            else
                yield(item.cand)
            end
        end

        -- 未评分的候选追加到末尾
        for _, c in ipairs(all) do
            if not seen[c.text] then yield(c) end
        end
    else
        for _, c in ipairs(all) do yield(c) end
    end
end
