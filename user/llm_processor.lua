-- llm_processor.lua — 上屏文字收集 + 预解码触发
-- 输出格式（一个场景一行）：
--   词1\t码1|词2\t码2|←|词3\t码3
--   | 分隔条目，\t 分隔词和码，← 退格，无码时码为空串

local prev_hist = {}     -- 上次 history 快照
local history = {}       -- 当前上屏词序列
local commit_base = 0    -- 上文基座: 只认 commit_history 中 base 之后的新词
                         -- (编辑键后旧词永久忽略——librime 无法清 commit_history)
local com_ctx_enabled = true  -- COM/UIA 光标上文旁路总开关（2026-09-29 定案：
                              -- 不做配置项、无关闭态；排障直接改此值）
local prev_input = ""    -- 上一轮的输入码
local pending_code = ""  -- 手动选词上屏码（输入变空瞬间捕获）
local last_full = ""     -- 最后满码（4码），顶屏时回退用
local MAX_CODE = 4       -- 满码长度
local llm_prep = nil     -- 缓存的 llm 模块 (for prepare)
local last_prep_ctx = "" -- 上次 prepare 的 context，避免重复调用

local NAV_KEYS = { Left=true, Right=true, Up=true, Down=true,
                   Home=true, End=true, Page_Up=true, Page_Down=true }

-- 导航/换行类键（含组合导航 Control+Left / Shift+Home 等：以导航键名结尾的
-- repr 均算）。与删除类键分开：编辑键重置两者共用，训练数据标记只区分这两类
--（导航/回车 → 换行 "\n"；删除 → 退格 "←"）。
local function is_nav_ish_key(k)
    if NAV_KEYS[k] or k == "Return" or k == "KP_Enter" then return true end
    for name in pairs(NAV_KEYS) do
        if #k > #name and k:sub(-#name) == name then return true end
    end
    return false
end

-- 编辑位置变化键: 退格/删除 (删词) + 导航键 (光标移动/滚动) + 回车 (换行)
-- + Ctrl+z/y/v/x (撤销/重做/粘贴/剪切——改变光标前文本, 2026-09-12 信号层
-- 统一补入; 字符类含大写形态: Shift 按下时 keysym 为大写)
-- 这些键使会话上屏词序列不再代表光标前上文 → 上屏历史上文重置为空
local function is_edit_key(k)
    if k == "BackSpace" or k == "Delete"
       or k == "Control+BackSpace" or k == "Control+Delete"
       or k:match("^Control%+[zyvxZYVX]$")
       or is_nav_ish_key(k) then
        return true
    end
    return false
end

local function reset_history()
    history = {}
    prev_hist = {}
end

-- ═══ 实时调试行广播（2026-11-10）═══
-- debug_fusion 开时把 E（commit 落账）/R（编辑键 reset）行经 DLL 命名管道
-- \\.\pipe\rime_llm_live 推给查看器（debug\llm_debug_view.ps1）。行协议
-- 与 llm_filter.lua 侧一致；调用点各自已判 debug_fusion，这里只判模块。
-- 旧 DLL 无 live_write 时静默跳过。
local function live_esc(s)
    return (tostring(s or "")):gsub("|", "｜"):gsub("\n", " ")
end

local function live(line)
    if not (llm_prep and llm_prep.live_write) then return end
    local ok = pcall(llm_prep.live_write, line)
    if not ok then llm_prep.live_write = nil end
end

-- 异步预解码触发（归一化 + 去重，按键路径与编辑键重置路径共用）。
-- ctx 归一化与 llm_filter 一致 (去空白): C++ prep 命中 = token 序列比较,
-- 不一致会导致 prep 永远不命中 → 每次 score 完整解码 (~50ms)。
-- 中文无空白两者相同; 含英文/空格 (如 "Hello world 你好") 时保证一致。
local function trigger_prepare()
    local cur_ctx = (_G.llm_context_get() or ""):gsub('%s+', '')
    if llm_prep and llm_prep.prepare and cur_ctx ~= last_prep_ctx then
        -- 2026-11-18：只有 DLL 真正受理（返回 true）才记账。此前先记账后调用，
        -- 一旦 prepare 因"模型加载中 / 推理持锁被跳过"被丢弃就再也不会重试，
        -- 满码评分只能走完整 S1（真机 4 连 prep=0 的成因之一）。
        local okp, acc = pcall(llm_prep.prepare, cur_ctx)
        if okp and acc then last_prep_ctx = cur_ctx end
    end
end

-- === 用户词频账本（2026-11-17 用户定案：衰减账 + 累计账合并为单文件单账本）===
-- 两本账原本键相同（词\t码）、计数时机相同（OnCommit）、落盘节奏相同
-- （每 20 词全量重写）——合并为一个 map、一次重写、单一格式，消除双文件
-- 跨文件漂移与"同形异义格式"误读（2026-11-16 累计账读取事故即为后者）。
-- **2026-11-13 词码对记账（用户原则性定案）**: 键 = (词, 码)——多音词属于
-- 不同的词, 不同编码的相同字词是不同词条（形码方案 userdb 同语义）;
-- wiki 59,681 窗重分析: 分键全面更优（−0.34~−0.73pp 随龄扩大）。
-- _G.user_stats: "词\t码" → {d=衰减计数 dee, t=最后提交 tick, c=累计次数}
-- _G.user_freq_tick: 全局 tick (每词提交 +1, 同 rime userdb UpdateTickCount)
-- 衰减算法 = librime algo::formula_d (user_dictionary.cc 调频同源):
--   提交: dee = 1 + dee·exp((t_old - t_now)/τ)    查询: eff = dee·exp(...)
-- τ=400 (2026-11-06 v3 六维联合标定; 词频记忆半衰 ~277 次上屏)
-- 累计计数 c 不衰减（log(c+1) 融合项）；只计含中文的词条。
-- 文件: 用户目录 user_ledger.tsv（两版共用）
--   首行 "#tick=N"；数据行 "s\t词\t码\tdee\ttick\tcum"（码可空）。
--   行首 s = 行类型（旧账本 u/b 行天然不匹配，防同形异义误读）。
--   修剪: eff < 1e-3 且 cum=0 才丢——含中文词条终身保留（旧累计账语义），
--   全角标点等非中文行随衰减淘汰。
-- 旧两账本一次性迁移（只读，旧文件保留不删；落盘写新名）:
--   user_eff.tsv（回退 user_freq.tsv）5 字段 → dee/tick, cum=commits(含中文时)
--   user_unigram.tsv（回退 user_bigram.tsv）u 行 → cum=max(cum, 次数)
--   eff 的 commits 列对含中文词条 = 真实累计次数（同一提交两处计数），
--   取 max 可补回 2026-11-16 读取事故丢失的累计次数。
-- n_seen 不再记录（2026-11-17 用户定案：不参与打分，无消费方）。
local FREQ_TAU = 400
local FREQ_FLUSH = 20
local stats_dirty = 0
local function freq_key(word, code)
    return word .. "\t" .. (code or "")
end
local function ledger_file()
    return rime_api.get_user_data_dir() .. "\\user_ledger.tsv"
end
local function has_non_ascii(w)
    return w:match("[^\1-\127]") ~= nil
end
local function has_cjk(w)
    for _, cp in utf8.codes(w) do
        if cp >= 0x4E00 and cp <= 0x9FFF then return true end
    end
    return false
end
local function open_fallback(names)
    for _, n in ipairs(names) do
        local f = io.open(rime_api.get_user_data_dir() .. "\\" .. n, "r")
        if f then return f end
    end
    return nil
end
-- 旧衰减账（user_eff.tsv / user_freq.tsv）: 词\t码\tcommits\tdee\ttick。
-- commits 对含中文词条 = 真实累计提交次数，迁移时直接作为 cum——可补回
-- 2026-11-16 累计账读取事故丢失的次数。旧词级行（4/2 字段）不再迁移。
local function stats_load_legacy_eff()
    local f = open_fallback({ "user_eff.tsv", "user_freq.tsv" })
    if not f then return nil end
    local tick, maxt = nil, 0
    for line in f:lines() do
        local t = line:match("^#tick=(%d+)$")
        if t then
            tick = tonumber(t)
        else
            local w, c, cn, d, tk =
                line:match("^(.-)\t(%l*)\t(%d+)\t([%d%.]+)\t(%d+)$")
            if w and cn and d and tk then
                _G.user_stats[w .. "\t" .. c] =
                    { d = tonumber(d), t = tonumber(tk),
                      c = has_cjk(w) and tonumber(cn) or 0 }
                if tonumber(tk) > maxt then maxt = tonumber(tk) end
            end
        end
    end
    f:close()
    return tick or maxt
end
-- 旧累计账（user_unigram.tsv / user_bigram.tsv）: u\t词\t码\t次数。
-- 旧行照原值接管（保持迁移前评分口径）；3 字段旧词级行与旧 b 行忽略。
local function stats_load_legacy_uni()
    local f = open_fallback({ "user_unigram.tsv", "user_bigram.tsv" })
    if not f then return end
    for line in f:lines() do
        local kind, a, cnt = line:match("^(%a)\t(.-)\t(%d+)$")
        if kind == "u" and a:find("\t", 1, true) then
            local n = tonumber(cnt)
            local e = _G.user_stats[a]
            if e then
                if n > (e.c or 0) then e.c = n end
            else
                _G.user_stats[a] = { d = 0, t = 0, c = n }
            end
        end
    end
    f:close()
end
local function stats_load()
    _G.user_stats = _G.user_stats or {}
    local tick = nil
    local f = io.open(ledger_file(), "r")
    if f then
        local maxt = 0
        for line in f:lines() do
            local t = line:match("^#tick=(%d+)$")
            if t then
                tick = tonumber(t)
            else
                -- s\t词\t码\tdee\ttick\tcum（码可空；只认 s 行）
                local w, c, d, tk, cu =
                    line:match("^s\t([^\t]+)\t([^\t]*)\t([%d%.]+)\t(%d+)\t(%d+)$")
                if w and d and tk and cu then
                    _G.user_stats[w .. "\t" .. c] =
                        { d = tonumber(d), t = tonumber(tk),
                          c = tonumber(cu) }
                    if tonumber(tk) > maxt then maxt = tonumber(tk) end
                end
            end
        end
        f:close()
        tick = tick or maxt
    else
        -- 首次升级：旧两账本一次性合并（只读，旧文件保留）
        tick = stats_load_legacy_eff()
        stats_load_legacy_uni()
    end
    _G.user_freq_tick = tick or _G.user_freq_tick or 0
end
local function stats_save()
    local f = io.open(ledger_file(), "w")
    if f then
        f:write("#tick=" .. (_G.user_freq_tick or 0) .. "\n")
        local now = _G.user_freq_tick or 0
        for k, e in pairs(_G.user_stats) do
            -- 修剪: 衰减到噪声级且无累计提交的冷词条不落盘；含中文词条
            -- cum>0 终身保留（旧累计账语义），文件有界于中文词表规模。
            local eff = e.d * math.exp((e.t - now) / FREQ_TAU)
            if eff >= 1e-3 or (e.c or 0) > 0 then
                f:write(string.format("s\t%s\t%.3f\t%d\t%d\n",
                    k, e.d, e.t, e.c or 0))
            end
        end
        f:close()
    end
end
local function stats_bump(word, code)
    if not has_non_ascii(word) then return end
    if not _G.user_stats then stats_load() end
    _G.user_freq_tick = (_G.user_freq_tick or 0) + 1
    local k = freq_key(word, code)
    local e = _G.user_stats[k]
    if not e then
        e = { d = 0, t = 0, c = 0 }
        _G.user_stats[k] = e
    end
    e.d = 1 + e.d * math.exp((e.t - _G.user_freq_tick) / FREQ_TAU)
    e.t = _G.user_freq_tick
    if has_cjk(word) then e.c = (e.c or 0) + 1 end
    stats_dirty = stats_dirty + 1
    if stats_dirty >= FREQ_FLUSH then
        stats_save()
        stats_dirty = 0
    end
end

-- 衰减有效计数 (llm_filter 融合用): rime formula_d 查询式 (词码对)
_G.user_freq_eff = function(w, code)
    if not _G.user_stats then stats_load() end
    local e = _G.user_stats[freq_key(w, code)]
    if not e or e.d <= 0 then return 0 end
    return e.d * math.exp((e.t - (_G.user_freq_tick or e.t)) / FREQ_TAU)
end

-- === 用户累计 Unigram 计数 (v3 2026-11-06; 累计 Bigram 退役 2026-11-08) ===
-- 融合项 = log(uni+1)（2026-11-11 简化：原 log p1 的分母与 δ 缩放均为窗内
-- 常数 = 排序不变量，位级等价去除）。口径 = 只计含中文字符的词（纯标点
-- 不计——与标定的词典词流同源）；原始计数不衰减（标定语义）。
-- 累计计数与衰减计数同存 user_ledger.tsv 的 cum 列（2026-11-17 合并）；
-- n_seen 连记录一并取消（不参与打分，无消费方）。
_G.user_unigram_term = function(x, code)
    if not _G.user_stats then stats_load() end
    local e = _G.user_stats[freq_key(x, code)]
    return math.log(((e and e.c or 0) + 1))
end

-- 累计 unigram 原始计数（llm_filter 调试行"累计频"列 / pairfix fade 门用）
_G.user_uni_count = function(x, code)
    if not _G.user_stats then stats_load() end
    local e = _G.user_stats[freq_key(x, code)]
    return e and e.c or 0
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

    -- 上文检查 + 预解码 (每次按键): commit_history 变化 → 立即异步预解码
    local sc = env.engine.schema.config
    local enabled = sc:get_bool("llm_rerank/enabled") or false
    if not enabled then
        llm_prep = nil  -- 释放已加载的 DLL 引用
    else
        if not llm_prep then
            local ok, result = pcall(require, "rime_llm")
            if ok then
                -- 日志目录: RIME 用户目录 (与 filter 共用同一模块实例)
                local okd, ud = pcall(function() return rime_api.get_user_data_dir() end)
                if okd and ud and ud ~= "" then result.log_dir = ud end
                llm_prep = result
            end
        end
        -- model_path 每键轻量同步（仅变化时写，2026-08-31 修配置不生效的
        -- 根因）：路径只在"一次性 require 块"里读的话，首个触发 require 的
        -- 会话（部署期编译会话/配置未就绪的瞬间）会把默认路径永久固化到
        -- 模块级 llm_prep，之后的按键永不重读。prepare 是懒加载触发点，
        -- 同步必须发生在它之前——本键同步、本键 prepare，路径必然就位。
        local mp = sc:get_string("llm_rerank/model_path")
        if mp and mp ~= "" and llm_prep and llm_prep.model_path ~= mp then
            llm_prep.model_path = mp
            -- 模型将卸载重载（评分结果缓存已于 2026-11-11 删除，无需清）
        end
    end
    -- 鼠标点击检测（2026-09-11 深夜用户定案：任何点击=光标可能移动→
    -- 清历史上文兜底，不做例外排除——候选窗/工具栏点击也清，上下文
    -- 宁可变短不可错；2026-09-12 起同时失效 COM/UIA 快照+重读——真文
    -- 快照也是旧时刻的，点击移光标后同样冒充）
    if llm_prep and llm_prep.click_happened and llm_prep.click_happened() then
        local ch0 = env.engine.context.commit_history
        if ch0 then commit_base = #ch0:to_table() end
        reset_history()
        -- 点击候选窗选词场景：commit kick 刚刷新的正确快照会被废，但
        -- kick 50ms 后读回同样正确的文本（点击已处理完、含新上屏词），自愈
        if llm_prep.edit_reset_context then
            pcall(llm_prep.edit_reset_context)
        end
    end

    -- 上文检查 + 预解码 (每次按键): commit_history 变化 → 立即异步预解码
    trigger_prepare()

    local ctx = env.engine.context
    local ch = ctx.commit_history
    if not ch then return 2 end

    -- 跨应用切换检测（2026-09-11，DLL fg_changed 内部比前台 pid）：插件版
    -- lua 无焦点事件，切换后旧窗口的 history 残留会冒充新窗口上文（真机
    -- 踩坑：切新文档首词标 AI·历史而非无徽章）。切到新进程 → 重置历史 +
    -- commit_history 旧词记为基座（只认切换后的新词，与编辑键同款语义）。
    -- 比 pid 不比 HWND：同应用内对话框/多文档窗口不误清。
    if llm_prep and llm_prep.fg_changed and llm_prep.fg_changed() then
        local all0 = ch:to_table()
        commit_base = #all0
        reset_history()
    end

    -- [拆分提交]（2026-11-20）: 词 composition + 标点键 → 词先单独提交、
    -- 标点独立成段提交。punctuator 原路径把标点 PushInput 进同一
    -- composition 一并 Commit，提交码变 "muak,"：词频键脏（干净键永不
    -- 积累）、C 行 ref 断链（同码才回挂）、回撤整提交粒度（删标点连词
    -- 一起回撤）。屏幕文本不变：confirm 提交的正是当前高亮（重排后首选），
    -- 标点键放行后 punctuator 在空 composition 上独立成段、独立提交。
    -- 门: 纯字母码 composition（punct 段 input 含标点不命中 %l+$，天然防
    -- 重入）× 标点类键（可打印非字母数字；数字=选择键、空格 0x20、回车/
    -- 退格 <0x21 都不在区间）。confirm 后走既有"输入变空捕获码"路径，
    -- bump/C 行零改动；候选/段绑定缺失时 pcall 兜底回原行为。
    do
        local kc = key:keycode()
        if ctx.input ~= "" and ctx.input:match("^%l+$")
                and kc >= 0x21 and kc <= 0x7e
                and not (kc >= 0x30 and kc <= 0x39)
                and not (kc >= 0x41 and kc <= 0x5a)
                and not (kc >= 0x61 and kc <= 0x7a) then
            local okc, cand = pcall(function()
                return ctx.composition:back():get_selected_candidate()
            end)
            if okc and cand and cand.type ~= "raw" then
                ctx:confirm_current_selection()
                if sc:get_bool("llm_rerank/debug_fusion") then
                    live("R|" .. os.date("%H:%M:%S")
                        .. "|标点拆分: 词已独立提交，标点随后独立提交")
                end
            end
        end
    end

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

    -- 退格 / Delete / 导航键 (composition 为空时): 编辑位置变化
    --   rime 来源上文重置为空 (会话上屏词序列不再代表光标前上文), 立即重新预解码
    --   return 0 放行按键 (导航键/退格由后续 processor 正常处理, 光标移动),
    --   本分支已提前返回, 后续 commit_history 同步不会执行 (不覆盖重置;
    --   退格后剩余词不会作为新词重新记录训练数据)
    if ctx.input == "" and is_edit_key(key:repr()) then
        local k = key:repr()
        -- 常开语料 M：reset 事件与 kind（与源码版 reason 映射同集）
        local kind = "navigation"
        if k == "BackSpace" or k == "Control+BackSpace" then
            kind = "backspace"
        elseif k == "Delete" or k == "Control+Delete" then
            kind = "delete"
        elseif k:match("^Control%+[zyvxZYVX]$") then
            kind = "undo-clipboard"
        elseif k == "Return" or k == "KP_Enter" then
            kind = "enter"
        end
        local dbg_flag = sc:get_bool("llm_rerank/debug_fusion")
        _G.llm_debug_enabled = dbg_flag or false
        if _G.llm_write_m then _G.llm_write_m(kind) end
        reset_history()
        -- 编辑键: 当前 commit_history 位置记为基座——旧词永久忽略
        -- (librime lua 无法清 commit_history, 旧词留在引擎里;
        --  退格会被引擎清空 commit_history → 同步段检测缩短自动重置基座)
        commit_base = #ch:to_table()
        -- 评分结果缓存已于 2026-11-11 删除（同 ctx+input 复用命中率过低）；
        -- 每次触发都是真实推理，编辑键无需再清缓存
        -- 2026-09-12 信号层统一: COM/UIA 快照失效 + kick 延迟重读(~50ms)——
        -- 退格/导航/撤销/粘贴后旧快照不再 2.5s 新鲜窗内冒充真文; 打首词
        -- (人手 >300ms) 时新快照已就绪, 首词即有正确 AI·UIA/COM 上文
        if llm_prep and llm_prep.edit_reset_context then
            pcall(llm_prep.edit_reset_context)
        end
        if dbg_flag then
            live("R|" .. os.date("%H:%M:%S") .. "|编辑键("
                 .. live_esc(key:repr()) .. ")→上文重置+缓存清空")
        end
        -- 上文已重置 → 立即异步预解码 (空上文)
        trigger_prepare()
        return 0
    end

    -- 同步 commit_history
    local all = ch:to_table()
    -- 引擎清空 commit_history（退格等）→ 基座重置重新计数
    if all and #all < commit_base then
        commit_base = 0
    end
    if all and #all > commit_base then
        history = {}
        for i = commit_base + 1, #all do
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
            if overlap == 0 and _G.llm_write_m then
                _G.llm_write_m("scene")
            end

            local dbg_flag = sc:get_bool("llm_rerank/debug_fusion")
            _G.llm_debug_enabled = dbg_flag or false
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
                -- 词频计数: 仅含中文的词 (含英文/数字/标点不参与融合)
                -- 2026-11-13 词码对记账: bump 键 = (词, 完整提交码)
                -- 2026-11-17 单账本: dee 与累计计数同一次 bump/落盘
                if has_chinese then
                    if not _G.user_stats then stats_load() end
                    local before = _G.user_freq_eff and _G.user_freq_eff(w, code) or 0
                    local t_before = _G.user_freq_tick or 0
                    stats_bump(w, code)
                    local after = _G.user_freq_eff and _G.user_freq_eff(w, code) or 0
                    local tick_after = _G.user_freq_tick or 0
                    local cid = _G.llm_write_c
                                and _G.llm_write_c(w, code, tick_after, true)
                                or nil
                    if dbg_flag then
                        live(string.format("E|%s|%s|%.3f|%.3f|%d|%d",
                            os.date("%H:%M:%S"), live_esc(w), before,
                            after, t_before, tick_after))
                        if cid and _G.llm_debug_e then
                            _G.llm_debug_e(cid, before, after, stats_dirty)
                        end
                    end
                else
                    if _G.llm_write_c then
                        _G.llm_write_c(w, code, _G.user_freq_tick or 0, false)
                    end
                end
            end

            -- 上屏后立即刷新 COM/UIA 快照（2026-09-10）：新词此刻已入
            -- 文档/控件，读链 6-13ms 在后台线程完成，下一键即有新鲜上文
            -- 2026-11-18：带 1 = 快照刷新完成后由 DLL 用**同一份文本**预解码。
            -- kick→快照更新有 ~50ms 延迟，按键路径此刻读到的仍是旧文本，
            -- 用它 prepare 会与满码 score 的 ctx 不同源（真机 4 连 miss 根因）。
            if llm_prep and llm_prep.kick_context then
                pcall(llm_prep.kick_context, 1)
            end
        end

        if #new_words == 0 and #history < #prev_hist and #history < 3 then
            pending_code = ""
            last_full = ""
            if _G.llm_write_m then _G.llm_write_m("scene") end
        end

        prev_hist = {}
        for _, v in ipairs(history) do table.insert(prev_hist, v) end
    end

    -- 2026-11-18：history 已在上面同步完毕，此刻再触发一次预解码。
    -- 键首那次 trigger_prepare 早于 history 追加（拿不到刚上屏的词），
    -- 这条补的是"历史兜底路径"的 ctx；ctx 未变时被去重挡住，零额外开销。
    trigger_prepare()

    return 2
end

local function get_context()
    -- 三层上文（2026-09-10 全功能）：COM（Word/WPS 文字文档模型）→
    -- UIA TextPattern（通用现代应用）→ 上屏历史（兜底）。前两层由 DLL
    -- llm_context() 完成（前台门控 + 快照新鲜度 + 来源进程校验都在 C++，
    -- 按键路径零阻塞）；失败回落历史。旁路无常关配置（2026-09-29 定案删
    -- com_context 配置项；排障改文件头 com_ctx_enabled 重部署）
    if com_ctx_enabled and llm_prep and llm_prep.llm_context then
        local ok, t, src = pcall(llm_prep.llm_context)
        if ok and type(t) == "string" and #t > 0 then
            return t, src
        end
    end
    return table.concat(history, ""), "rime"
end

_G.llm_context_get = get_context
return processor
