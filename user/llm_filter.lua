-- llm_filter.lua — LLM candidate rerank filter
-- 由 schema llm_rerank.enabled 控制：true | false
-- false 时不加载 DLL，不推理，候选原样透传

local llm = nil
local llm_loaded_for = nil  -- enabled value when llm was loaded

local cfg = {
    min_code_len     = 4,
    max_code_len     = 0,   -- 0 = 不限制（编码长度上限，超出不推理）
    min_tokens       = 1,
    max_tokens       = 10,  -- 截取的上文 token 数（与 C++ 默认/源码版/README 统一，2026-09-02）
    max_candidates   = 5,
    cpu_cores        = nil,  -- nil = 不设置，走 C++ 默认（固定 4，bench_threads 实测后可配）
    expected_length_weight = 0,  -- > 0 = 两码一字方案的编码长度匹配加权
    freq_weight = 0.25,  -- 用户词频融合权重 (0=关闭); total=(1-w)·LLM + w·词频
    freq_k = 5,          -- 词频饱和常数: s_f = eff/(eff+k); eff = rime 时间衰减计数
}

local lat_max   = 0
local lat_count = 0

-- 结果缓存: 同一 (ctx, input) 的评分结果复用 (翻页/候选窗重建不重复推理)。
-- 存 _G 以便 llm_processor 在编辑操作 (退格/导航/回车) 时清空——
-- 编辑后重打相同词 (ctx+input 相同) 必须重新推理, 缓存会误命中导致无推理记录。
-- 翻页/候选窗重建 (无编辑) 缓存保留命中。
_G.llm_filter_cache = _G.llm_filter_cache or nil

local function is_finite_number(v)
    return type(v) == "number" and v == v
        and v > -math.huge and v < math.huge
end

local function is_valid_llm_score(v)
    return is_finite_number(v) and v > -1e9
end

local function get_config_number(sc, key)
    local ok, v = pcall(function() return sc:get_double(key) end)
    if ok and is_finite_number(v) then return v end
    ok, v = pcall(function() return sc:get_string(key) end)
    if ok then
        v = tonumber(v)
        if is_finite_number(v) then return v end
    end
    return nil
end

local function get_scores(cands)
    if not llm or not llm.get_scores then return nil end
    local ok, scores = pcall(function() return llm.get_scores() end)
    if not ok or type(scores) ~= "table" then return nil end
    for _, text in ipairs(cands) do
        if not is_finite_number(scores[text]) then return nil end
    end
    return scores
end

local function load_llm(env)
    local ok, cpp = pcall(require, "rime_llm")
    if ok and cpp then
        local sc = env.engine.schema.config
        local mp = sc:get_string("llm_rerank/model_path")
        -- 未配置时留给 C++ 默认（RIME 用户目录根，2026-08-31）
        if mp and mp ~= "" then cpp.model_path = mp end
        cpp.max_ctx    = cfg.max_tokens
        cpp.min_tokens = cfg.min_tokens
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
    local v = sc:get_int("llm_rerank/min_code_len")
    if v then cfg.min_code_len = v end
    v = sc:get_int("llm_rerank/max_code_len")
    if v then cfg.max_code_len = v end
    v = get_config_number(sc, "llm_rerank/expected_length_weight")
    if v ~= nil then cfg.expected_length_weight = math.max(0, v) end
    v = get_config_number(sc, "llm_rerank/freq_weight")
    if v ~= nil then cfg.freq_weight = math.max(0, v) end
    v = get_config_number(sc, "llm_rerank/freq_k")
    if v ~= nil and v >= 1 then cfg.freq_k = v end
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
    -- 每次调用都从 schema 读取 enabled，确保重新部署后立即生效
    local sc = env.engine.schema.config
    local enabled = sc:get_bool("llm_rerank/enabled") or false

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

    -- enabled false → 原样透传，不推理
    if not enabled then
        for _, c in ipairs(all) do yield(c) end; return
    end

    -- Lazy load DLL on first use (enabled 变化时重载, 重新部署立即生效)
    if not llm_loaded_for then
        load_llm(env)
    end

    if not llm then
        for _, c in ipairs(all) do yield(c) end; return
    end

    if #input < cfg.min_code_len then
        for _, c in ipairs(all) do yield(c) end; return
    end
    if cfg.max_code_len > 0 and #input > cfg.max_code_len then
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
    local ok, result, scores
    if cache and cache.ctx == context and cache.input == input and cache.result then
        ok, result, scores = true, cache.result, cache.scores
    else
        local t0 = os.clock()
        ok, result = pcall(function() return llm.score(context, cands) end)
        local elapsed_ms = (os.clock() - t0) * 1000
        if ok and type(result) == "table" then
            scores = get_scores(cands)
            _G.llm_filter_cache = {
                ctx = context, input = input, result = result, scores = scores
            }
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
        -- 用户词频融合 (freq_weight, 2026-08-19; 2026-08-21 词频改 Rime 时间衰减):
        -- total = (1-w)·LLM_minmax + w·eff/(eff+k)。eff = librime algo::formula_d
        -- 指数衰减计数 (τ=200 tick, tick=每词提交+1, 与引擎调频同源; 由
        -- llm_processor 维护, _G.user_freq_eff 查询) — 近期常打的词权重高,
        -- 久未使用的自动消退。实证 (17258 真实候选窗, 6000 抽样, 事前计数
        -- 口径): 纯 LLM 97.08%, 衰减融合约 +0.4pp; 融合的意义在个性化高频
        -- 词 (纯 LLM 排错事件 87% 选中词词频>=2)。同分稳定保序。
        -- 应用于其他排序策略之前: expected_length 以同分
        -- idx 的方式保留其影响。
        if cfg.freq_weight > 0 and #ordered > 1 and scores then
            local freq_eff = _G.user_freq_eff
            if freq_eff then
                local lo, hi
                for _, c in ipairs(ordered) do
                    local s = scores[c.text]
                    if is_valid_llm_score(s) then
                        if not lo or s < lo then lo = s end
                        if not hi or s > hi then hi = s end
                    end
                end
                local span = (lo and hi) and (hi - lo) or 0
                if span > 0 then
                    local w, k = cfg.freq_weight, cfg.freq_k
                    local arr = {}
                    for i, c in ipairs(ordered) do
                        local s = scores[c.text]
                        -- 失败哨兵/缺分 → s_l=0 (排尾部, 词频仍可救)
                        local sl = is_valid_llm_score(s) and ((s - lo) / span) or 0
                        local n = freq_eff(c.text)
                        arr[i] = { c = c, t = (1 - w) * sl + w * (n / (n + k)), idx = i }
                    end
                    table.sort(arr, function(a, b)
                        if a.t ~= b.t then return a.t > b.t end
                        return a.idx < b.idx  -- 同分保持 LLM 评分序
                    end)
                    for i = 1, #arr do ordered[i] = arr[i].c end
                end
            end
        end
        -- 两码一字方案: L 码对应 L/2 或 (L-1)/2 字。整数化后等价于 floor(L/2)。
        -- 奖励使用本次 LLM 分数跨度，保留分数差明显时的语义排序。
        if cfg.expected_length_weight > 0 and #ordered > 1 and scores then
            local arr = {}
            local min_score, max_score
            for i, c in ipairs(ordered) do
                local score = scores[c.text]
                if not is_finite_number(score) then
                    arr = nil
                    break
                end
                local valid = is_valid_llm_score(score)
                if valid then
                    if not min_score or score < min_score then min_score = score end
                    if not max_score or score > max_score then max_score = score end
                end
                arr[i] = { c = c, score = score, valid = valid, idx = i }
            end
            local expected_len = math.floor(#input / 2)
            local span = (min_score and max_score) and (max_score - min_score) or 0
            if arr and expected_len >= 1 and span > 0 then
                for _, item in ipairs(arr) do
                    local len = utf8.len(item.c.text or "") or 0
                    item.matches_expected_length = item.valid and len == expected_len
                    if item.matches_expected_length then
                        item.score = item.score + cfg.expected_length_weight * span
                    end
                end
                table.sort(arr, function(a, b)
                    if a.score ~= b.score then return a.score > b.score end
                    if a.matches_expected_length ~= b.matches_expected_length then
                        return a.matches_expected_length
                    end
                    return a.idx < b.idx  -- 分数相同保持 LLM 评分序
                end)
                for i = 1, #arr do ordered[i] = arr[i].c end
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
