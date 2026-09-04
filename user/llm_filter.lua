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
    debug_fusion     = false, -- true = 逐候选融合明细写 rime_llm_debug.txt (诊断用)
    expected_length_weight = 0.2,  -- 预期词长加成 (冷启动标定 2026-09-03; 0=关闭)
    freq_beta = 1.5,  -- 对数词频融合系数 (0=关闭); fused = score + β·log(1+eff)
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
    v = get_config_number(sc, "llm_rerank/freq_beta")
    if v ~= nil then cfg.freq_beta = math.max(0, v) end
    v = sc:get_int("llm_rerank/max_tokens")
    if v then cfg.max_tokens = v end
    v = sc:get_int("llm_rerank/max_candidates")
    if v then cfg.max_candidates = v end
    v = sc:get_int("llm_rerank/cpu_cores")
    if v then cfg.cpu_cores = v end
    v = sc:get_int("llm_rerank/min_tokens")
    if v then cfg.min_tokens = v end
    local dbg = sc:get_bool("llm_rerank/debug_fusion")
    if dbg ~= nil then cfg.debug_fusion = dbg end
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
    local dbg_cache = "MISS"
    if cache and cache.ctx == context and cache.input == input and cache.result then
        ok, result, scores = true, cache.result, cache.scores
        dbg_cache = "HIT"
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

    -- 融合诊断 (llm_rerank/debug_fusion: true): 每次评分逐候选记录
    -- CE/eff/词频加成/词长加成/最终 key 与名次, 写 rime_llm_debug.txt
    local dbg = cfg.debug_fusion and {} or nil
    local dbg_span = nil
    if dbg then
        local ctx_tail = #context > 16 and ("…" .. context:sub(-15)) or context
        local ready = "n/a"
        local okr, r = pcall(function() return llm.is_ready() end)
        if okr then ready = r and "1" or "0" end
        table.insert(dbg, string.format(
            "%s|score|input=%s|cache=%s|ctx=[%s]|src=%s|tick=%s|ready=%s|n=%d",
            os.date("%H:%M:%S"), input, dbg_cache, ctx_tail, ctx_src,
            tostring(_G.user_freq_tick), ready, #cands))
        if not ok then
            table.insert(dbg, "  ERROR: score pcall failed")
        elseif type(result) ~= "table" then
            table.insert(dbg, string.format(
                "  score=nil (ready=%s, ctx空=%s — ready=0 模型未载/加载中; ctx空=min_tokens 跳过)",
                ready, context == "" and "是" or "否"))
        elseif not scores then
            table.insert(dbg, "  融合跳过: scores=nil (get_scores 校验失败 — 候选缺分/含异常值)")
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
        -- 统一结合公式 (2026-09-03, 冷启动标定):
        --   fused(w) = score(w) + β·log(1+eff(w)) + elw·span·[词长==⌊码长/2⌋]
        -- score = 原始 LLM 分 (−CE, 对数概率域); eff = librime algo::formula_d
        -- 指数衰减计数 (τ=200 tick, tick=每词提交+1, 引擎调频同源; llm_processor
        -- 维护, _G.user_freq_eff 查询)。对数域三项加法:
        --   ① 词频无上限: 强个人高频词可翻盘 CE 分差 (β=1.5, 本机真实窗回放
        --      事前口径 β∈[1,2] 平台);
        --   ② 预期词长加成作用于融合分 (elw=0.2, 冷启动标定: dict 窗+零词频
        --      argmax [0.15,0.2], ≥0.4 转负)——修复旧实现按原始分重排导致
        --      ELW 架空词频融合的组成缺陷 (2026-09-03 实测 +0.00pp);
        --   ③ 冷启动 eff≡0 自动退化为 score + elw·span·匹配, 成熟期三项叠加。
        -- span 取窗内有效原始分跨度; 失败哨兵分 (≤-1e9) 排尾部不参与;
        -- 任一候选无有效融合分则整体跳过 elw 段。同分稳定保序 (融合序)。
        local fused_scores = nil
        if #ordered > 1 and scores then
            local freq_eff = _G.user_freq_eff
            fused_scores = {}
            local arr = {}
            for i, c in ipairs(ordered) do
                local s = scores[c.text]
                if is_valid_llm_score(s) then
                    local n = freq_eff and freq_eff(c.text) or 0
                    local t = s + cfg.freq_beta * math.log(1 + n)
                    fused_scores[c.text] = t
                    arr[i] = { c = c, t = t, idx = i }
                    if dbg then
                        dbg[c.text] = { ce = s, eff = n,
                                        fb = cfg.freq_beta * math.log(1 + n),
                                        fused = t, cerank = i }
                    end
                else
                    fused_scores[c.text] = -math.huge
                    arr[i] = { c = c, t = -math.huge, idx = i }  -- 无效分保序排尾
                    if dbg then
                        dbg[c.text] = { ce = s, eff = 0, fb = 0,
                                        fused = -1 / 0, cerank = i, invalid = true }
                    end
                end
            end
            table.sort(arr, function(a, b)
                if a.t ~= b.t then return a.t > b.t end
                return a.idx < b.idx  -- 同分保持 LLM 评分序
            end)
            for i = 1, #arr do ordered[i] = arr[i].c end
        end
        -- 预期词长加权 (expected_length_weight): 两码一字方案 L 码对应 floor(L/2) 字
        if cfg.expected_length_weight > 0 and #ordered > 1 and fused_scores then
            local expected_len = math.floor(#input / 2)
            local min_score, max_score
            for _, c in ipairs(ordered) do
                local s = scores[c.text]
                if is_valid_llm_score(s) then
                    if not min_score or s < min_score then min_score = s end
                    if not max_score or s > max_score then max_score = s end
                end
            end
            local span = (min_score and max_score) and (max_score - min_score) or 0
            if expected_len >= 1 and span > 0 then
                local arr, ok2 = {}, true
                for i, c in ipairs(ordered) do
                    local f = fused_scores[c.text]
                    if not f or f == -math.huge then
                        ok2 = false
                        break
                    end
                    local len = utf8.len(c.text or "") or 0
                    arr[i] = { c = c, s = f,
                               m = (len == expected_len), idx = i }
                end
                if ok2 then
                    for _, item in ipairs(arr) do
                        if item.m then
                            item.s = item.s + cfg.expected_length_weight * span
                            if dbg and dbg[item.c.text] then
                                dbg[item.c.text].eb =
                                    cfg.expected_length_weight * span
                            end
                        end
                    end
                    table.sort(arr, function(a, b)
                        if a.s ~= b.s then return a.s > b.s end
                        if a.m ~= b.m then return a.m end
                        return a.idx < b.idx  -- 分数相同保持融合序
                    end)
                    for i = 1, #arr do ordered[i] = arr[i].c end
                end
                if dbg then dbg_span = span end
            end
        end

        -- 诊断输出: 逐候选明细 + 名次变化汇总
        if dbg then
            local final_rank = {}
            for i, c in ipairs(ordered) do final_rank[c.text] = i end
            local all_rank = {}
            for i, c in ipairs(all) do all_rank[c.text] = i end
            for i = 1, math.min(#ordered, 8) do
                local c = ordered[i]
                local d = dbg[c.text]
                if d then
                    table.insert(dbg, string.format(
                        "  #%d %-6s CE=%8.3f eff=%6.3f 频+%6.3f 长+%5.2f key=%8.3f  原次序%d→%d",
                        i, c.text, d.ce or 0, d.eff or 0, d.fb or 0,
                        d.eb or 0, (d.fused or 0) + (d.eb or 0),
                        d.cerank or 0, final_rank[c.text] or 0))
                end
            end
            local moved = {}
            for i, c in ipairs(ordered) do
                local d = dbg[c.text]
                if d and d.cerank and final_rank[c.text] and
                        d.cerank ~= final_rank[c.text] then
                    table.insert(moved, string.format("%s %d→%d",
                        c.text, d.cerank, final_rank[c.text]))
                end
            end
            table.insert(dbg, #moved > 0
                and ("  名次变化: " .. table.concat(moved, ", "))
                or  "  名次变化: 无 (CE 序即融合序)")
            if dbg_span then
                table.insert(dbg, string.format("  词长span=%.3f", dbg_span))
            end
            local okw = pcall(function()
                local f = io.open(rime_api.get_user_data_dir()
                                  .. "\\rime_llm_debug.txt", "a")
                if f then
                    f:write(table.concat(dbg, "\n") .. "\n\n")
                    f:close()
                end
            end)
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
