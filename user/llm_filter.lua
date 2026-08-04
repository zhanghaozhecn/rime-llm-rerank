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

-- 结果缓存: 同一 (ctx, input) 的评分结果复用 (翻页/候选窗重建不重复推理)。
-- 存 _G 以便 llm_processor 在编辑操作 (退格/导航/回车) 时清空——
-- 编辑后重打相同词 (ctx+input 相同) 必须重新推理, 缓存会误命中导致无推理记录。
-- 翻页/候选窗重建 (无编辑) 缓存保留命中。
_G.llm_filter_cache = _G.llm_filter_cache or nil

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
        -- 日志目录: RIME 用户目录 (未设置时 C++ 回退 %TEMP%)
        local okd, ud = pcall(function() return rime_api.get_user_data_dir() end)
        if okd and ud and ud ~= "" then cpp.log_dir = ud end
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

    local input = env.engine.context.input or ""

    -- 候选窗快照: (input, 前 max_candidates 个候选) 供 llm_processor 上屏时
    -- 关联真实候选窗写入训练语料 (与 LLM 打分范围一致)。所有路径统一记录,
    -- 含 off/未加载/min_code_len 未达的透传路径——候选窗是 RIME 实际显示的集合,
    -- 即使不评分也构成训练样本 (LLM 要学的是在真实窗内把正确词排第一)。
    local win = {}
    for i, c in ipairs(all) do
        if i > cfg.max_candidates then break end
        win[#win + 1] = c.text
    end
    _G.llm_last_window = { input = input, cands = win }

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

    if #input < cfg.min_code_len then
        for _, c in ipairs(all) do yield(c) end; return
    end

    local ctx_text, ctx_src = "", "rime"
    if _G.llm_context_get then
        ctx_text, ctx_src = _G.llm_context_get()
    end
    -- 去空白: 上文中允许字母存在 (英文/数字是合法上文)。
    -- 不需过滤尾部 ASCII: Rime 编码显示在候选窗, 不写入编辑器,
    -- 外挂读到的光标前文本不会包含编码字母 (微软拼音式 inline composition 才会)
    local context = (ctx_text or ""):gsub('%s+', '')
    local cands = {}
    for i, c in ipairs(all) do
        if i > cfg.max_candidates then break end
        table.insert(cands, c.text)
    end

    -- 缓存命中: 同 (ctx, input) 的评分结果直接复用 (翻页/候选窗重建不重复推理)。
    -- 编辑操作 (退格/导航/回车) 后 llm_processor 清空 _G.llm_filter_cache,
    -- 重打相同词重新推理 (同 ctx+input 的旧结果不适用于编辑后的新候选窗)
    local cache = _G.llm_filter_cache
    local ok, result
    if cache and cache.ctx == context and cache.input == input and cache.result then
        ok, result = true, cache.result
    else
        local t0 = os.clock()
        ok, result = pcall(function() return llm.score(context, cands) end)
        local elapsed_ms = (os.clock() - t0) * 1000
        if ok and type(result) == "table" then
            _G.llm_filter_cache = { ctx = context, input = input, result = result }
        end

        -- Event log (仅真实推理时写; RIME 用户目录, 回退 %TEMP%)
        local okd, log_dir = pcall(function() return rime_api.get_user_data_dir() end)
        if not okd or not log_dir or log_dir == "" then
            log_dir = os.getenv("TEMP") or "C:\\Windows\\Temp"
        end
        local ef = io.open(log_dir .. "\\rime_llm_events.txt", "a")
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
            ef:write(string.format("%s|%d|%s|%s|%s|%s|%.0fms|%s\n",
                os.date("%H:%M:%S"), lat_count, input,
                cand_str, ctx_safe, res_info, elapsed_ms, ctx_src))
            ef:close()
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
