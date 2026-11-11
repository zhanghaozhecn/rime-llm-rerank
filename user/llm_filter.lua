-- llm_filter.lua — LLM candidate rerank filter
-- 由 schema llm_rerank.enabled 控制：true | false
-- false 时不加载 DLL，不推理，候选原样透传

local llm = nil
local llm_loaded_for = nil  -- enabled value when llm was loaded

-- 融合系数 β 为内置常数（2026-11-05 用户定案：标定产物退出用户配置面——用户没有
-- 标定能力；与 FREQ_TAU=400 同待遇。调整 = 改代码随下次发版生效）：
local FREQ_BETA = 12 -- 对数词频融合系数（v3 2026-11-06 六维联合标定
                     -- w2×w3×β×τ×γ×λ 68,640 点: 用户域标定 → wiki 平台内
                     -- 就近点 (1.05/0.45/β12/τ400/γ1/λ0.5), 见研究库 §三十三）
                     -- fused = score + β·log(1+eff) + log(0.5·p1)
                     --   p1 = 用户累计 Unigram 平滑概率（llm_processor 维护,
                     --   _G.user_unigram_term 查询; 累计 Bigram 项已退役
                     --   2026-11-08, 见研究库 §三十七）
-- two_code_sentence 两码整句开关（2026-11-07 用户定案取代 elw）：
-- 两码一字整句方案下勾选后，词长==⌊码长/2⌋ 的候选作为一组直接优先
-- （组内融合分降序、同分稳定），其余候选按融合分降序在后——即原 elw
-- 的极限行为（elw·span 加成→∞），不再需要 span 间接量。默认 false。

local cfg = {
    -- 编码匹配模式（2026-09-30 取代 min_code_len/max_code_len）：
    -- 全串匹配输入编码串，语法同 Rime 自身 speller/auto_select_pattern。
    --   仅 4 码 = '.{4}'｜4 码以上 = '.{4,}'｜3-4 码 = '.{3,4}'｜
    --   指定首码的 4 码 = '[abcde]{4}'｜任意长度 = '.+'
    -- 引擎：DLL 的 std::regex（ECMAScript）；不可用时回退 Lua 模式
    -- （Lua 模式里 %d/%a 等转义与正则 \d/\w 不同，详见 README）。
    code_pattern     = '.{4}',
    -- min_code_len / max_code_len 已废弃（用户配置面移除，2026-09-30）：
    -- 等价写法 = code_pattern '.{4}'
    max_tokens       = 10,  -- 截取的上文 token 数（与 C++ 默认/源码版/README 统一，2026-09-02）
    max_candidates   = 5,
    cpu_cores        = nil,  -- nil = 不设置，走 C++ 默认（固定 4，bench_threads 实测后可配）
    debug_fusion     = false, -- true = 逐候选融合明细写 rime_llm_debug.txt (诊断用)
    two_code_sentence = false, -- 两码整句：词长==⌊码长/2⌋ 的候选一组优先
                               -- （2026-11-07 取代 expected_length_weight；
                               --  旧行读取端忽略，保存/重建节时剥除）
    -- freq_beta 不再从 schema 读取（2026-11-05 用户配置面移除，标定产物退出配置面）
    -- → 内置常数 FREQ_BETA；方案里残留旧行读取端忽略，保存/重建节时剥除
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

-- 编码模式匹配（2026-09-30）：全串匹配，语义同 Rime speller/auto_select_pattern。
-- 优先 DLL 的 std::regex（ECMAScript，与源码版 boost::regex 同套语法）；
-- 老版本 DLL 无 match_code 时回退 Lua 模式（用 find 的全串匹配 + 首尾锚定）。
-- 空模式 = 总是匹配（与源码版一致）。
local function match_code_pattern(code)
    local pat = cfg.code_pattern
    if not pat or pat == "" then return true end
    if llm and llm.match_code then
        local ok, r = pcall(llm.match_code, pat, code)
        if ok then return r and true or false end
        -- pcall 失败（模式非法）→ 落到下面的 Lua 模式回退
    end
    local ok, s, e = pcall(string.find, code, pat)
    if not ok or not s then return false end
    return s == 1 and e == #code   -- 全串匹配（Lua find 允许中段命中）
end

local function get_scores(cands)    if not llm or not llm.get_scores then return nil end
    local ok, scores = pcall(function() return llm.get_scores() end)
    if not ok or type(scores) ~= "table" then return nil end
    for _, text in ipairs(cands) do
        if not is_finite_number(scores[text]) then return nil end
    end
    return scores
end

-- ═══ 实时调试行广播（2026-11-10）═══
-- debug_fusion 开时把行协议（V/L/C/S/E/R，| 分隔）经 DLL 的命名管道
-- \\.\pipe\rime_llm_live 推给外部查看器（本仓库 debug\llm_debug_view.ps1）。
-- 协议两端（lua/C++/查看器）以 DLL 注释与查看器头部注释为准。
-- 旧 DLL 无 live_write 时静默跳过（向后兼容）；查看器未连接时 DLL 侧
-- 一次空遍历即返回。自由文本字段（input/ctx/word/reason）先过 live_esc。
local function live_esc(s)
    return (tostring(s or "")):gsub("|", "｜"):gsub("\n", " ")
end

local function live(line)
    if not (cfg.debug_fusion and llm and llm.live_write) then return end
    local ok = pcall(llm.live_write, line)
    if not ok then llm.live_write = nil end  -- 接口异常则本会话不再尝试
end

local function live_fmt3(v)
    if v == nil or v ~= v then return "" end
    return string.format("%.3f", v)
end

local function load_llm(env)
    local ok, cpp = pcall(require, "rime_llm")
    if ok and cpp then
        local sc = env.engine.schema.config
        local mp = sc:get_string("llm_rerank/model_path")
        -- 未配置时留给 C++ 默认（RIME 用户目录根，2026-08-31）
        if mp and mp ~= "" then cpp.model_path = mp end
        cpp.max_ctx    = cfg.max_tokens
        -- min_tokens 不设置：固定用 C++ 默认 1（用户配置面已移除，2026-09-30）
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
    -- 编码匹配模式（2026-09-30 取代 min/max_code_len）：get_string 未配置返回
    -- nil，配置了空串则视为"总是匹配"（与源码版一致）
    local pat = sc:get_string("llm_rerank/code_pattern")
    if pat ~= nil then cfg.code_pattern = pat end
    -- expected_length_weight 不再读取（2026-11-07 由 two_code_sentence 取代;
    -- 方案里残留旧行忽略, 保存时由安装器剥除）
    -- freq_beta 不再读取（2026-11-05 配置面移除; 方案里残留旧行忽略,
    -- 保存时由安装器剥除）
    local v = sc:get_int("llm_rerank/max_tokens")
    if v then cfg.max_tokens = v end
    v = sc:get_int("llm_rerank/max_candidates")
    if v then cfg.max_candidates = v end
    v = sc:get_int("llm_rerank/cpu_cores")
    if v then cfg.cpu_cores = v end
    -- min_tokens 不再从 schema 读取（2026-09-30 用户配置面移除；固定 C++ 默认 1）
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
    if #all < 2 then
        live("S|" .. os.date("%H:%M:%S") .. "|few_candidates|" ..
             live_esc(env.engine.context.input or "") .. "|-")
        for _, c in ipairs(all) do yield(c) end
        return
    end

    local input = env.engine.context.input or ""

    -- 候选窗快照: (input, 前 max_candidates 个候选) 供 llm_processor 上屏时
    -- 关联真实候选窗写入训练语料 (与 LLM 打分范围一致)。所有路径统一记录,
    -- 含 off/未加载/编码不匹配 code_pattern 的透传路径——候选窗是 RIME 实际显示的集合,
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

    -- 触发条件：编码串是否匹配 code_pattern（2026-09-30 取代 min/max_code_len 区间）
    -- 全串匹配（同 Rime auto_select_pattern 语义）。优先用 DLL 的 std::regex
    -- （与源码版 boost::regex 同一套 ECMAScript 语法）；DLL 不提供该函数时
    -- 回退 Lua 模式——两种写法对 .{4} / .{4,} / .{3,4} / [abcde]{4} 等价。
    if not match_code_pattern(input) then
        live("S|" .. os.date("%H:%M:%S") .. "|pattern|" .. live_esc(input)
             .. "|-")
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
    -- ═══ 层1: 全体候选 用户词频打分重排（v3 两层重排, 2026-11-07 定案）═══
    -- 全体候选 S1 = FREQ_BETA·log1p(eff) + 累计 Unigram 项, 稳定降序（同分保引擎序）,
    -- 取前 max_candidates 进 LLM 评分（层2 三项融合重排）, 其余按层1 序透传。
    -- 目标在层1 前 k 外 → 必然不在首位（评测 sweep_2layer 同语义, 全窗参评）。
    -- 文件序无关性: 引擎调频与否仅影响冷词同分打破（目标卷入 ≤0.05pp 窗,
    -- 实测见研究库 §三十三·附 6）。
    local layer1 = {}
    local s1_of = {}
    do
        local fe, bt = _G.user_freq_eff, _G.user_unigram_term
        for i, c in ipairs(all) do
            local n = fe and fe(c.text) or 0
            local s = FREQ_BETA * math.log(1 + n)
            if bt then s = s + bt(c.text) end
            layer1[i] = { c = c, s = s, idx = i }
            s1_of[c.text] = s
        end
        table.sort(layer1, function(a, b)
            if a.s ~= b.s then return a.s > b.s end
            return a.idx < b.idx   -- 稳定: 同分保引擎序
        end)
    end
    local cands = {}
    local l1win = {}
    for i = 1, math.min(cfg.max_candidates, #layer1) do
        cands[i] = layer1[i].c.text
        l1win[i] = layer1[i].c.text
    end
    -- 候选窗快照改为层1 前 k（LLM 实际评分范围; 训练语料窗口语义随生产）
    _G.llm_last_window = { input = input, cands = l1win }

    -- 缓存命中: 同 (ctx, input) 的评分结果直接复用 (翻页/候选窗重建不重复推理)。
    -- 编辑操作 (退格/导航/回车) 后 llm_processor 清空 _G.llm_filter_cache,
    -- 重打相同词重新推理 (同 ctx+input 的旧结果不适用于编辑后的新候选窗)
    local cache = _G.llm_filter_cache
    local ok, result, scores
    local dbg_cache = "MISS"
    local ev_ms = 0   -- 本轮推理耗时（缓存 HIT = 0；实时调试 L 行用）
    if cache and cache.ctx == context and cache.input == input and cache.result then
        ok, result, scores = true, cache.result, cache.scores
        dbg_cache = "HIT"
    else
        local t0 = os.clock()
        ok, result = pcall(function() return llm.score(context, cands) end)
        local elapsed_ms = (os.clock() - t0) * 1000
        ev_ms = elapsed_ms
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
        local epath = log_dir .. "\\rime_llm_events.txt"
        local ef = io.open(epath, "a")
        -- 日志轮转 (2026-09-04): >5MB 改名 .old (单文件轮转), 防无限增长
        if ef then
            local esz = ef:seek("end")
            if esz and esz > 5 * 1024 * 1024 then
                ef:close()
                os.remove(epath .. ".old")
                os.rename(epath, epath .. ".old")
                ef = io.open(epath, "a")
            end
        end
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
    -- CE/eff/词频加成/满长标记/最终 key 与名次, 写 rime_llm_debug.txt
    local live_ready = "n/a"   -- 模型就绪态（实时调试 L 行用；两个 dbg 块共享）
    local dbg = cfg.debug_fusion and {} or nil
    if dbg then
        local ctx_tail = #context > 16 and ("…" .. context:sub(-15)) or context
        local ready = "n/a"
        local okr, r = pcall(function() return llm.is_ready() end)
        if okr then ready = r and "1" or "0" end
        live_ready = ready
        table.insert(dbg, string.format(
            "%s|score|input=%s|cache=%s|ctx=[%s]|src=%s|tick=%s|ready=%s|n=%d",
            os.date("%H:%M:%S"), input, dbg_cache, ctx_tail, ctx_src,
            tostring(_G.user_freq_tick), ready, #cands))
        if not ok then
            table.insert(dbg, "  ERROR: score pcall failed")
            live("S|" .. os.date("%H:%M:%S") .. "|score_failed|" ..
                 live_esc(input) .. "|" .. live_esc(ctx_src))
        elseif type(result) ~= "table" then
            table.insert(dbg, string.format(
                "  score=nil (ready=%s, ctx空=%s — ready=0 模型未载/加载中; ctx空=min_tokens 跳过)",
                ready, context == "" and "是" or "否"))
            -- 实时调试（2026-11-10）：失败原因细分为 not_ready/ctx_empty/
            -- ctx_short——"为什么没触发"是调试窗口的主要用途之一
            local why = ready == "0" and "not_ready"
                    or (context == "" and "ctx_empty" or "ctx_short")
            live("S|" .. os.date("%H:%M:%S") .. "|" .. why .. "|" ..
                 live_esc(input) .. "|" .. live_esc(ctx_src))
        elseif not scores then
            table.insert(dbg, "  融合跳过: scores=nil (get_scores 校验失败 — 候选缺分/含异常值)")
            live("S|" .. os.date("%H:%M:%S") .. "|scores_nil|" ..
                 live_esc(input) .. "|" .. live_esc(ctx_src))
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
        -- 统一结合公式 (2026-09-03 冷启动标定; 2026-11-02 连续文章语料重标定;
        -- 2026-11-05 β 退出配置面 → FREQ_BETA 内置常数;
        -- 2026-11-06 v3: 六维联合标定 + 用户 bigram 项上线;
        -- **2026-11-08: 累计 Bigram 项退役**（cohort 生产量级评测实证真实用户龄
        -- fired ~2%、剔除零损失, 见研究库 §三十七——保留历史结论, 公式去掉 p2）):
        --   fused(w) = score(w) + FREQ_BETA·log(1+eff(w))
        --              + log(0.5·p1)     ← 用户累计 Unigram 项
        -- score = 原始 LLM 分 (−CE, 对数概率域); eff = librime algo::formula_d
        -- 指数衰减计数 (**τ=400** tick 内置常数, tick=每词提交+1, 引擎调频同源;
        -- llm_processor 维护, _G.user_freq_eff 查询)。对数域加法:
        --   ① 词频无上限: 强个人高频词可翻盘 CE 分差 (FREQ_BETA=12, v3 六维
        --      联合标定用户域标定→wiki 平台就近);
        --   ② 用户累计 Unigram 项: p1 = (uni+1)/(n_seen+2万) (原始计数不衰减),
        --      项值 log(0.5·p1)——与原标定语义的未 fired 形态逐字一致;
        --      冷启动全等值自动无害退化; llm_processor 维护 _G.user_unigram_term;
        --   ③ expected_length_weight (elw) 已退役 (2026-11-07): 整句偏好改由
        --      two_code_sentence 开关直接实现 (见下方满长组优先块)。
        --   ④ 冷启动 eff≡0 且 uni 无计数时自动退化为 score 序, 成熟期三项叠加。
        -- 失败哨兵分 (≤-1e9) 排尾部不参与; 同分稳定保序 (融合序)。
        local fused_scores = nil
        if #ordered > 1 and scores then
            local freq_eff = _G.user_freq_eff
            fused_scores = {}
            local arr = {}
            for i, c in ipairs(ordered) do
                local s = scores[c.text]
                if is_valid_llm_score(s) then
                    local n = freq_eff and freq_eff(c.text) or 0
                    local u1_term = _G.user_unigram_term
                            and _G.user_unigram_term(c.text) or 0
                    local t = s + FREQ_BETA * math.log(1 + n) + u1_term
                    fused_scores[c.text] = t
                    arr[i] = { c = c, t = t, idx = i }
                    if dbg then
                        dbg[c.text] = { ce = s, eff = n,
                                        fb = FREQ_BETA * math.log(1 + n),
                                        u1 = u1_term,
                                        fused = t, cerank = i }
                    end
                else
                    -- 无 CE 分（评分失败）→ 后两项和（层1 分）参与窗内排序
                    -- （2026-11-07 两层重排语义; 层1 已保证其在本窗内）
                    local s1 = s1_of[c.text]
                    fused_scores[c.text] = s1 or -math.huge
                    arr[i] = { c = c, t = s1 or -math.huge, idx = i }
                    if dbg then
                        dbg[c.text] = { ce = s, eff = 0, fb = 0,
                                        fused = s1 or -1 / 0, cerank = i,
                                        invalid = true }
                    end
                end
            end
            table.sort(arr, function(a, b)
                if a.t ~= b.t then return a.t > b.t end
                return a.idx < b.idx  -- 同分保持 LLM 评分序
            end)
            for i = 1, #arr do ordered[i] = arr[i].c end
        end
        -- 两码整句 (two_code_sentence, 2026-11-07 用户定案取代 elw):
        -- 词长==⌊码长/2⌋ 的候选一组直接优先 (组内融合分降序, 同分稳定),
        -- 其余按融合分降序——即原 elw 的极限行为 (elw·span 加成→∞),
        -- 不再需要 span 间接量。
        if cfg.two_code_sentence and #ordered > 1 and fused_scores then
            local expected_len = math.floor(#input / 2)
            if expected_len >= 1 then
                local arr = {}
                for i, c in ipairs(ordered) do
                    local len = utf8.len(c.text or "") or 0
                    arr[i] = { c = c, s = fused_scores[c.text] or -math.huge,
                               m = (len == expected_len), idx = i }
                    if dbg and dbg[c.text] then
                        dbg[c.text].full = arr[i].m
                    end
                end
                table.sort(arr, function(a, b)
                    if a.m ~= b.m then return a.m end
                    if a.s ~= b.s then return a.s > b.s end
                    return a.idx < b.idx  -- 同分保持融合序
                end)
                for i = 1, #arr do ordered[i] = arr[i].c end
            end
        end

        -- 诊断输出: 逐候选明细 + 名次变化汇总
        if dbg then
            local final_rank = {}
            for i, c in ipairs(ordered) do final_rank[c.text] = i end
            local all_rank = {}
            for i, c in ipairs(all) do all_rank[c.text] = i end

            -- 实时调试（2026-11-10）：L 头行（完整上文，不截断）+ 逐候选
            -- C 行（含层1 透传尾窗，上限 20 行；win=1 层2窗内/0 尾窗透传，
            -- ce 空串=无 CE 分，fin=最终输出位置）。与 debug.txt 人类格式
            -- 互补，供查看器（debug\llm_debug_view.ps1）渲染。
            live(string.format("L|%s|%s|%s|%s|%s|%s|%.0f|%s|%d",
                os.date("%H:%M:%S"), live_esc(input), dbg_cache,
                live_esc(ctx_src), live_esc(context),
                tostring(_G.user_freq_tick), ev_ms, live_ready, #cands))
            local winset = {}
            for _, w in ipairs(l1win) do winset[w] = true end
            local emitted = 0
            local function live_c(c, fin)
                if emitted >= 20 then return end
                emitted = emitted + 1
                local d = dbg[c.text]
                live(table.concat({
                    "C", tostring(all_rank[c.text] or 0), live_esc(c.text),
                    live_fmt3(s1_of[c.text]),
                    (d and d.ce and d.ce > -1e9) and live_fmt3(d.ce) or "",
                    d and live_fmt3(d.fb) or "",
                    d and live_fmt3(d.u1) or "",
                    d and live_fmt3(d.fused) or "",
                    (d and d.full) and "1" or "0",
                    tostring(d and d.cerank or 0),
                    tostring(fin), winset[c.text] and "1" or "0"
                }, "|"))
            end
            for i, c in ipairs(ordered) do live_c(c, i) end
            local tail_pos = #ordered
            for _, e in ipairs(layer1) do
                if not seen[e.c.text] then
                    tail_pos = tail_pos + 1
                    live_c(e.c, tail_pos)
                end
            end
            for i = 1, math.min(#ordered, 8) do
                local c = ordered[i]
                local d = dbg[c.text]
                if d then
                    local ce_str = (d.ce and d.ce > -1e9)
                        and string.format("%8.3f", d.ce) or "   -sent"
                    table.insert(dbg, string.format(
                        "  #%d %-6s CE=%s eff=%6.3f 频+%6.3f u1+%6.3f 满=%d key=%8.3f  原次序%d→%d",
                        i, c.text, ce_str, d.eff or 0, d.fb or 0,
                        d.u1 or 0, d.full and 1 or 0, d.fused or 0,
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
            local okw = pcall(function()
                local f = io.open(rime_api.get_user_data_dir()
                                  .. "\\rime_llm_debug.txt", "a")
                if f then
                    f:write(table.concat(dbg, "\n") .. "\n\n")
                    f:close()
                end
            end)
        end
        -- 来源徽章已删（2026-11-10 用户定案：实时调试窗口上线——上文来源/
        -- 内容与逐候选分数都在调试窗口看，候选窗保持干净、不再动 comment）
        for _, c in ipairs(ordered) do yield(c) end
        for _, e in ipairs(layer1) do
            if not seen[e.c.text] then yield(e.c) end
        end
    else
        -- 评分失败/缺分: 层1 已重排全体候选 → 按层1 序展示
        for _, e in ipairs(layer1) do yield(e.c) end
    end
end
