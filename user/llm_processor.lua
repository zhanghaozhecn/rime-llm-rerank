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
local function trigger_prepare(env)
    local cur_ctx = (_G.llm_context_get() or ""):gsub('%s+', '')
    -- 组合区已确认前缀（2026-11-23）：与 filter 的 ctx 口径一致，prep 才能
    -- 命中；prefix 变化也视为 ctx 变化（去重键含 prefix）
    local cur_pf = ""
    if _G.llm_confirmed_prefix and env then
        local okc, pf = pcall(_G.llm_confirmed_prefix, env)
        if okc and type(pf) == "string" then cur_pf = pf end
    end
    local key = cur_pf ~= "" and (cur_ctx .. "\x1c" .. cur_pf) or cur_ctx
    if llm_prep and llm_prep.prepare and key ~= last_prep_ctx then
        -- 2026-11-18：只有 DLL 真正受理（返回 true）才记账。此前先记账后调用，
        -- 一旦 prepare 因"模型加载中 / 推理持锁被跳过"被丢弃就再也不会重试，
        -- 满码评分只能走完整 S1（真机 4 连 prep=0 的成因之一）。
        local okp, acc = pcall(llm_prep.prepare, cur_ctx, cur_pf)
        if okp and acc then last_prep_ctx = key end
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
--   首行 "#tick=N"；随后 # 注释行（列含义，落盘自带）；数据行
--   "词\t码\tdee\ttick\tcum"（2026-11-20 去掉行类型列 s——每行省 2 字节，
--   词必非 ASCII 不会与注释/旧格式混淆；码可空）。
--   读取端兼容旧 6 列 s 行（s\t词\t码\tdee\ttick\tcum，2026-11-20 前）。
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
-- [词级聚合回退]（2026-11-27）: 层1/融合查询键 = (词, 当前段码)——整句
-- 模式下当前段码是**整段码**，与账本存储键 (词, 词自己的段码) 不同构
-- （实测整句 (词,整段码) 命中 0.2–1.4%，词级键 7–12%，40× 缺口）。
-- 精确键 miss 时回退词级聚合 = Σ各码形条目（eff 按各自 tick 衰减后求和、
-- cum 求和）——跨码形/跨段长的词频重新生效；字词模式段=单词，精确键本
-- 就命中，回退不触发（pdsp 14.7%≈词单键 14.8%）。多音词消歧：精确键
-- 优先，聚合只在 miss 时兜底。
-- 索引 word_agg: word → { [码] = {d=,t=,c=} }（与 _G.user_stats 同生共
-- 死，载入重建、bump/refund 增量同步、切方案随 _G.user_stats 一起清）。
-- A/B：_G.llm_freq_agg == false 或 RIME_LLM_FREQ_AGG=0 → 纯精确键。
local word_agg = nil
local function freq_agg_enabled()
    if _G.llm_freq_agg == false then return false end
    if os.getenv("RIME_LLM_FREQ_AGG") == "0" then return false end
    return true
end
local function word_agg_rebuild()
    word_agg = {}
    if not _G.user_stats then return end
    for k, e in pairs(_G.user_stats) do
        local w, c = k:match("^(.-)\t(.*)$")
        if w then
            word_agg[w] = word_agg[w] or {}
            word_agg[w][c] = { d = e.d or 0, t = e.t or 0, c = e.c or 0 }
        end
    end
end
local function word_agg_sync(word, code, e)
    if not word_agg then return end
    word_agg[word] = word_agg[word] or {}
    word_agg[word][code or ""] =
        { d = e and e.d or 0, t = e and e.t or 0, c = e and (e.c or 0) or 0 }
end
-- 词级聚合查询：返回 (Σeff, Σcum)。now = 全局 tick（与精确键衰减同基准）。
local function word_agg_query(w, now)
    local arr = word_agg and word_agg[w]
    if not arr then return 0, 0 end
    local sd, sc = 0, 0
    for _, e in pairs(arr) do
        if (e.d or 0) > 0 then
            sd = sd + e.d * math.exp(((e.t or 0) - now) / FREQ_TAU)
        end
        sc = sc + (e.c or 0)
    end
    return sd, sc
end
-- 账本路径（2026-11-22 用户定案：四件全分）：账本按方案分目录
-- <用户文件夹>\llm_rerank\<方案 ID>\user_ledger.tsv。账本属"有状态资产"：
-- 该方案首次读写时从旧位置（llm_rerank 根 / 用户文件夹根）**复制**一份
-- （旧文件保留不删）——每个方案各得一份快照，此后独立演进；键 = 词+码，
-- 码与方案绑定、天然不相交，历史条目跨方案共存无害。目录由
-- rime_llm.dll ensure_dir 建立（rime-lua 无 mkdir，单层 → 父/子两次）。
local function llm_dir_ensure(dir)
    local ok, cpp = pcall(require, "rime_llm")
    if not ok or not cpp or not cpp.ensure_dir then return false end
    local ok2, made = pcall(cpp.ensure_dir, dir)
    return ok2 and made == true
end

local function schema_safe(sid)
    if type(sid) ~= "string" or sid == "" then return "" end
    sid = sid:gsub("[^%w_%.%-]", "_")
    if #sid > 64 then sid = sid:sub(1, 64) end
    return sid
end

local function rerank_root()
    local ok, ud = pcall(function() return rime_api.get_user_data_dir() end)
    if not ok or type(ud) ~= "string" or ud == "" then return nil, ud end
    return ud .. "\\llm_rerank", ud
end

-- 方案目录；方案不可得 → llm_rerank 根（部署期/冒烟桩）
local function rerank_dir()
    local root = rerank_root()
    if not root then return nil end
    local sid = schema_safe(_G.llm_schema_id)
    return sid ~= "" and (root .. "\\" .. sid) or root
end

local function dir_ensure2(dir)
    local root = rerank_root()
    if root then llm_dir_ensure(root) end
    return llm_dir_ensure(dir)
end

local function file_copy(src, dst)
    local fi = io.open(src, "rb")
    if not fi then return false end
    local fo = io.open(dst, "wb")
    if not fo then fi:close() return false end
    while true do
        local chunk = fi:read(65536)
        if not chunk then break end
        fo:write(chunk)
    end
    fi:close()
    fo:close()
    return true
end

-- sid 省略 = 当前方案；方案不可得 → llm_rerank 根（部署期/冒烟桩）；
-- 用户目录不可得 → %TEMP%（旧行为）
local function ledger_file(sid)
    local root, ud = rerank_root()
    if not root then
        local tmp = os.getenv("TEMP") or "C:\\Windows\\Temp"
        return tmp .. "\\user_ledger.tsv"
    end
    sid = schema_safe(sid or _G.llm_schema_id)
    local dir = sid ~= "" and (root .. "\\" .. sid) or root
    local new = dir .. "\\user_ledger.tsv"
    local f = io.open(new, "rb")
    if f then f:close() return new end
    -- 旧位置 1 = llm_rerank 根（方案层还不存在时）；旧位置 2 = 用户文件夹根
    local legacy = {}
    if dir ~= root then legacy[#legacy + 1] = root .. "\\user_ledger.tsv" end
    legacy[#legacy + 1] = ud .. "\\user_ledger.tsv"
    for _, old in ipairs(legacy) do
        local g = io.open(old, "rb")
        if g then
            g:close()
            if dir_ensure2(dir) and file_copy(old, new) then return new end
            return old          -- 复制失败：暂用旧位置，下次再试
        end
    end
    if dir_ensure2(dir) then return new end
    return ud .. "\\user_ledger.tsv"
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
local stats_schema = nil   -- 内存账本所属方案（切方案时落盘旧账本再重载）
local function stats_load(sid)
    sid = schema_safe(sid or _G.llm_schema_id)
    _G.user_stats = _G.user_stats or {}
    stats_schema = sid
    local tick = nil
    local f = io.open(ledger_file(sid), "r")
    if f then
        local maxt = 0
        for line in f:lines() do
            local t = line:match("^#tick=(%d+)$")
            if t then
                tick = tonumber(t)
            else
                -- 新: 词\t码\tdee\ttick\tcum；旧(2026-11-20 前):
                -- s\t词\t码\tdee\ttick\tcum（码可空；读取端兼容旧 s 行）
                local w, c, d, tk, cu =
                    line:match("^([^\t#]+)\t([^\t]*)\t([%d%.]+)\t(%d+)\t(%d+)$")
                if not w then
                    w, c, d, tk, cu =
                        line:match("^s\t([^\t]+)\t([^\t]*)\t([%d%.]+)\t(%d+)\t(%d+)$")
                end
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
    word_agg_rebuild()          -- 词级聚合索引随账本重建（两级回退查询用）
end
local function stats_save(sid)
    local f = io.open(ledger_file(sid or stats_schema), "w")
    if f then
        f:write("#tick=" .. (_G.user_freq_tick or 0) .. "\n")
        -- 列含义注释（2026-11-20 起每帧自带；读取端跳过一切 # 行）
        f:write("#词\t码\t衰减计数dee\t最近提交tick\t累计次数cum\n")
        f:write("#码可空（2026-11-21 起简码/顶屏提交也记录完整输入码，空码仅剩"
            .. "无 composition 的边缘提交）；dee 每词提交 = 1 + dee·exp(-Δ/400)；"
            .. "tick 每词提交 +1；cum 仅中文词递增\n")
        local now = _G.user_freq_tick or 0
        for k, e in pairs(_G.user_stats) do
            -- 修剪: 衰减到噪声级且无累计提交的冷词条不落盘；含中文词条
            -- cum>0 终身保留（旧累计账语义），文件有界于中文词表规模。
            local eff = e.d * math.exp((e.t - now) / FREQ_TAU)
            if eff >= 1e-3 or (e.c or 0) > 0 then
                f:write(string.format("%s\t%.3f\t%d\t%d\n",
                    k, e.d, e.t, e.c or 0))
            end
        end
        f:close()
    end
end
-- 账本方案同步（2026-11-22 分目录）：每键由 processor 入口调用。
-- 切方案 → 旧方案内存账本先落盘（写到**旧方案**目录），清空后载入新方案
-- 账本（首次 = 从旧位置复制快照）。同方案 = 字符串比较即返回，零开销。
local function stats_ensure_schema()
    local sid = schema_safe(_G.llm_schema_id)
    if _G.user_stats and stats_schema == sid then return end
    if _G.user_stats then stats_save(stats_schema) end
    _G.user_stats = nil
    word_agg = nil              -- 聚合索引随账本清空，载入后重建
    stats_load(sid)
end

-- tick 省略 = 自动 +1（单词条提交）；显式传入 = 提交级 tick（2026-11-26
-- 整句词频归因：一次 commit 事件只推一个 tick，N 个词共享同值——tick 是
-- 衰减年龄基准，若每词 +1 会让一次 N 词长句把全局时间轴推快 N 倍，全体
-- 历史词条等效加速衰老）
local function stats_bump(word, code, tick)
    if not has_non_ascii(word) then return end
    -- 纯标点提交不入账（2026-11-20 用户定案：带标点行从账本删除）——
    -- 标点永不进重排窗口，dee 纯浪费且常用标点（，。）持续 bump 永不达
    -- 修剪线；连 tick 也不推（更同源 rime userdb "词条提交才推 tick"）。
    -- 退款弹栈照常（无账目 → 不退）。含中文词条不受影响。
    if not has_cjk(word) then return end
    stats_ensure_schema()
    if tick == nil then
        _G.user_freq_tick = (_G.user_freq_tick or 0) + 1
        tick = _G.user_freq_tick
    end
    local k = freq_key(word, code)
    local e = _G.user_stats[k]
    if not e then
        e = { d = 0, t = 0, c = 0 }
        _G.user_stats[k] = e
    end
    -- [回撤退款]（2026-11-20）bump 前快照进浅撤销栈（cap 4，回撤环总在
    -- 近处）——formula_d 递推确定性，恢复前像即精确退款；栈只在内存，
    -- 跨重启为空则不退（回退现行为）。
    e.hist = e.hist or {}
    e.hist[#e.hist + 1] = { tick = tick, d = e.d, t = e.t, c = e.c or 0 }
    if #e.hist > 4 then table.remove(e.hist, 1) end
    e.d = 1 + e.d * math.exp((e.t - tick) / FREQ_TAU)
    e.t = tick
    if has_cjk(word) then e.c = (e.c or 0) + 1 end
    word_agg_sync(word, code, e)    -- 聚合索引增量同步（两级回退）
    stats_dirty = stats_dirty + 1
    if stats_dirty >= FREQ_FLUSH then
        stats_save()
        stats_dirty = 0
    end
end

-- [回撤退款]（2026-11-20）: 提交被回撤（M backspace/delete/undo）→ 撤销
-- 该次 bump。按条目撤销栈顶 tick 匹配提交 tick → 恢复 bump 前像（d/t/c
-- 精确还原）；栈空/tick 不配 → 不退（现行为）。退款立即落盘（悬在内存
-- 被杀进程吞掉就白退）；退款后 cum=0 的错词由既有修剪规则自然淘汰。
_G.stats_refund = function(word, code, tick)
    if not has_non_ascii(word) then return false end
    stats_ensure_schema()
    local e = _G.user_stats[freq_key(word, code)]
    local h = e and e.hist and e.hist[#e.hist]
    if not h or h.tick ~= tick then return false end
    table.remove(e.hist)
    e.d, e.t, e.c = h.d, h.t, (h.c or 0)
    word_agg_sync(word, code, e)    -- 聚合索引随退款还原
    stats_save()
    stats_dirty = 0
    return true
end

-- [回撤退款] 提交栈（cap 8）: 与语料 strict 弹栈口径对齐——backspace/
-- delete/undo 每条 M 弹 1 条提交并退款；navigation/enter/scene 边界清栈。
-- words 非空 = 词级归因的组记录（2026-11-26）：一次提交 N 个词条目，
-- 一条 M 整组退款（弹栈粒度仍是「一次提交」）；word/code 为组内首词，
-- 仅作退款失败时的显示兜底。
local function commit_stack_push(word, code, tick, cid, words)
    _G.llm_commit_stack = _G.llm_commit_stack or {}
    _G.llm_commit_stack[#_G.llm_commit_stack + 1] =
        { word = word, code = code, tick = tick, cid = cid, words = words }
    if #_G.llm_commit_stack > 8 then
        table.remove(_G.llm_commit_stack, 1)
    end
end
local function commit_stack_clear()
    _G.llm_commit_stack = {}
end

-- ═══ 整句词频归因（2026-11-26）═══
-- 整句模式一次 commit 上屏的是整个句子，把整句记成词条 = 键永不复现（实测
-- luna_pinyin 账本 8.4% 条目 ≥6 字、多段提交键错配为「整句文本⊕尾段码」）。
-- 改为：commit 时按「组合区已确认段」逐词归因——普通段/确认词 = 单词条，
-- 组句段 = 组句词路径（llm_filter 登记的 _G.llm_gen_paths）按段码切片。
-- A/B：_G.llm_sentence_attr=false 或 RIME_LLM_SENTENCE_ATTR=0 关闭（回退
-- 旧行为：整句键入账）。
local function attr_enabled()
    if _G.llm_sentence_attr == false then return false end
    local e = os.getenv("RIME_LLM_SENTENCE_ATTR")
    return not (e and e == "0")
end

local function attr_seg_has_cjk(s)
    for _, cp in utf8.codes(s) do
        if cp >= 0x4E00 and cp <= 0x9FFF then return true end
    end
    return false
end

-- 校验 + 归因。strip = commit_notifier 快照（各已确认段 {text, code}）。
-- 全过才返回 {words={{w=,code=}…}, full_code=, path=}，否则 nil（消费端
-- 回退旧行为——宁可不归因不错记）。校验：
--   ① Σ段文本 == 提交文本（字节级）；
--   ② 含中文段的段码为纯小写字母（标点/英文段跳过不记账）；
--   ③ full_code 与通知器捕获码一致或其后缀（捕获码非空且纯字母时）；
--   ④ 组句段词路径覆盖校验（偏移严格递增、末端 == 段码长）。
local function build_attribution(w, strip, live_code)
    if type(strip) ~= "table" or #strip == 0 then return nil end
    local parts, full_code = {}, ""
    for _, seg in ipairs(strip) do
        parts[#parts + 1] = seg.text
        if attr_seg_has_cjk(seg.text) then
            if type(seg.code) ~= "string"
                    or seg.code:match("^[a-z]+$") == nil then
                return nil
            end
            full_code = full_code .. seg.code
        end
    end
    if table.concat(parts) ~= w then return nil end
    if full_code == "" then return nil end
    if type(live_code) == "string" and live_code ~= ""
            and live_code:match("^[a-z]+$")
            and full_code ~= live_code
            and full_code:sub(-#live_code) ~= live_code then
        return nil
    end
    local words = {}
    for _, seg in ipairs(strip) do
        if attr_seg_has_cjk(seg.text) then
            local path = nil
            local ring = _G.llm_gen_paths
            if ring then
                for i = #ring, 1, -1 do
                    if ring[i].text == seg.text and ring[i].code == seg.code
                            and type(ring[i].words) == "table"
                            and #ring[i].words > 0 then
                        path = ring[i].words
                        break
                    end
                end
            end
            if path then
                local prev, okp, sliced = 0, true, {}
                for _, wd in ipairs(path) do
                    if type(wd.e) ~= "number" or type(wd.w) ~= "string"
                            or wd.e <= prev or wd.e > #seg.code then
                        okp = false
                        break
                    end
                    sliced[#sliced + 1] = { w = wd.w,
                                            code = seg.code:sub(prev + 1, wd.e) }
                    prev = wd.e
                end
                if okp and prev == #seg.code then
                    for _, p in ipairs(sliced) do
                        if attr_seg_has_cjk(p.w) then
                            words[#words + 1] = p
                        end
                    end
                else
                    words[#words + 1] = { w = seg.text, code = seg.code }
                end
            else
                words[#words + 1] = { w = seg.text, code = seg.code }
            end
        end
    end
    if #words == 0 then return nil end
    local pf = {}
    for _, p in ipairs(words) do pf[#pf + 1] = p.w .. ":" .. p.code end
    return { words = words, full_code = full_code,
             path = table.concat(pf, "/") }
end

-- 衰减有效计数 (llm_filter 融合用): rime formula_d 查询式 (词码对)
-- miss 时词级聚合回退（2026-11-27，见 word_agg 注释；A/B llm_freq_agg）
_G.user_freq_eff = function(w, code)
    stats_ensure_schema()
    local e = _G.user_stats[freq_key(w, code)]
    if not e or e.d <= 0 then
        if not freq_agg_enabled() then return 0 end
        local sd = word_agg_query(w, (_G.user_freq_tick or 0))
        return sd
    end
    return e.d * math.exp((e.t - (_G.user_freq_tick or e.t)) / FREQ_TAU)
end

-- === 用户累计 Unigram 计数 (v3 2026-11-06; 累计 Bigram 退役 2026-11-08) ===
-- 融合项 = log(uni+1)（2026-11-11 简化：原 log p1 的分母与 δ 缩放均为窗内
-- 常数 = 排序不变量，位级等价去除）。口径 = 只计含中文字符的词（纯标点
-- 不计——与标定的词典词流同源）；原始计数不衰减（标定语义）。
-- 累计计数与衰减计数同存 user_ledger.tsv 的 cum 列（2026-11-17 合并）；
-- n_seen 连记录一并取消（不参与打分，无消费方）。
_G.user_unigram_term = function(x, code)
    stats_ensure_schema()
    local e = _G.user_stats[freq_key(x, code)]
    if not e then
        if not freq_agg_enabled() then return 0 end
        local _, sc = word_agg_query(x, (_G.user_freq_tick or 0))
        return math.log(sc + 1)
    end
    return math.log(((e and e.c or 0) + 1))
end

-- 累计 unigram 原始计数（llm_filter 调试行"累计频"列 / CE 偏置 fade 门用）
-- miss 时词级聚合回退（Σ 各码形 cum；fade 门语义 = 跨码形累计）
_G.user_uni_count = function(x, code)
    stats_ensure_schema()
    local e = _G.user_stats[freq_key(x, code)]
    if not e then
        if not freq_agg_enabled() then return 0 end
        local _, sc = word_agg_query(x, (_G.user_freq_tick or 0))
        return sc
    end
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

-- 组合区已确认段文本（2026-11-23，§11.8 协同）：前缀软确认后，这些词是
-- 确定的 token，LLM 的 ctx 必须包含它们（CE(整句) = CE(P|C) + CE(R|C+P)）。
-- 取 composition 里 status ≥ kSelected 的段的选中候选文本按顺序拼接。
-- Composition 的 lua 绑定没有 to_table，走 toSegmentation():to_table()（深拷贝段列表）。
local function confirmed_prefix_text(env)
    local ctx = env and env.engine and env.engine.context
    local comp = ctx and ctx.composition
    if not comp then return "" end
    local ok, segs = pcall(function()
        return comp:toSegmentation():to_table()
    end)
    if not ok or type(segs) ~= "table" then return "" end
    local parts = {}
    for _, seg in ipairs(segs) do
        local st = seg.status
        if st == "kSelected" or st == "kConfirmed" then
            local ok2, cand = pcall(function()
                return seg:get_selected_candidate()
            end)
            if ok2 and cand and cand.text and cand.text ~= "" then
                parts[#parts + 1] = cand.text
            end
        end
    end
    return table.concat(parts)
end
_G.llm_confirmed_prefix = confirmed_prefix_text

-- 前缀软确认执行（2026-11-23 实验，配合 llm_filter.lua 的 PREFIX_CONFIRM）：
-- 上一轮 filter 挂起的 {input, text, endp}，在本键进入 input 之前执行
-- ctx:select(idx) → Segment::Close 截段（partial tag）→ Forward + Compose
-- 只重译剩余码（组合区内预确认，不上屏）。只认输入前缀未变；执行/丢弃后
-- 清挂起（一次性）。menu 下标 = filter 后的候选序（ctx:select 作用同一 menu）。
local function run_pending_confirm(env)
    local pc = _G.llm_pending_confirm
    if not pc then return end
    _G.llm_pending_confirm = nil
    local ctx = env.engine.context
    local inp = ctx.input or ""
    if inp == "" or inp:sub(1, #pc.input) ~= pc.input then return end
    local comp = ctx.composition
    local seg = comp and comp:back()
    local menu = seg and seg.menu
    if not menu then return end
    local okn, n = pcall(function() return menu:prepare(16) end)
    if not okn or type(n) ~= "number" or n <= 0 then return end
    for i = 0, n - 1 do
        local c = menu:get_candidate_at(i)
        if c and c.text == pc.text then
            pcall(function() ctx:select(i) end)
            break
        end
    end
end
_G.llm_run_pending_confirm = run_pending_confirm   -- 冒烟/排障入口

local function processor(key, env)
    if key:release() then return 2 end
    run_pending_confirm(env)   -- 新键进入前执行上一轮挂起的软确认

    -- 当前方案 ID（2026-11-22 按方案分文件夹）：每键刷新，账本/日志按方案
    -- 选子目录；切方案时 stats_ensure_schema 落盘旧账本并载入新账本
    do
        local sid = env.engine.schema and env.engine.schema.schema_id
        if sid and sid ~= "" then _G.llm_schema_id = sid end
        stats_ensure_schema()
    end

    -- [简码/顶屏码补录]（2026-11-21）: commit_notifier 在 composition 清空
    -- (Clear) 前触发, c.input 即本次提交的完整输入码（简码 1-2 码也完整）
    -- ——旧滞后捕获（输入变空瞬间）对顶屏提交拿不到码：提交与清空发生在
    -- 同一个键内、speller 先于本 processor。每次提交（含标点/ASCII）压
    -- 一条进队列, 与 commit_history 新条目 1:1 对齐消费（见下方词循环）。
    if not env._commit_hook then
        env._commit_hook = true
        _G.llm_commit_inputs = _G.llm_commit_inputs or {}
        _G.llm_attr_strips = _G.llm_attr_strips or {}
        pcall(function()
            env.engine.context.commit_notifier:connect(function(c)
                table.insert(_G.llm_commit_inputs, c.input or "")
                if #_G.llm_commit_inputs > 16 then
                    table.remove(_G.llm_commit_inputs, 1)
                end
                -- [整句词频归因]（2026-11-26）：commit 在 composition 清空
                -- (Clear) 前触发——此刻逐已确认段取（选中文本, 段码切片）
                -- 快照，与 commit_inputs 1:1 进队。读不到（librime-lua 过旧/
                -- 时序异常）压 false 占位，消费端回退旧行为——宁可不错记。
                local strip = false
                pcall(function()
                    local comp = c.composition
                    if not comp or type(comp.toSegmentation) ~= "function"
                            then return end
                    local ok2, segs = pcall(function()
                        return comp:toSegmentation():to_table()
                    end)
                    if not ok2 or type(segs) ~= "table" then return end
                    local input = c.input or ""
                    local list = {}
                    for _, seg in ipairs(segs) do
                        local st = seg.status
                        if st == "kSelected" or st == "kConfirmed" then
                            local ok3, cand = pcall(function()
                                return seg:get_selected_candidate()
                            end)
                            if ok3 and cand and cand.text
                                    and cand.text ~= "" then
                                local scode = ""
                                if type(seg.start) == "number"
                                        and type(seg._end) == "number"
                                        and seg._end > seg.start
                                        and seg._end <= #input then
                                    scode = input:sub(seg.start + 1, seg._end)
                                end
                                list[#list + 1] = { text = cand.text,
                                                    code = scode }
                            end
                        end
                    end
                    if #list > 0 then strip = list end
                end)
                table.insert(_G.llm_attr_strips, strip)
                if #_G.llm_attr_strips > 16 then
                    table.remove(_G.llm_attr_strips, 1)
                end
                -- 异步基建（2026-11-22）：提交后上文变化，中断在跑的评分
                -- （DLL 代次递增 + 清任务槽，score_batch Step 边界生效）；
                -- lua 侧挂账条目随代次废弃。评分结果槽保留——已完成的成果
                -- 仍可被后续 query 收割回填。
                if _G.llm_async_cancel then pcall(_G.llm_async_cancel) end
            end)
        end)
    end

    -- 上文检查 + 预解码 (每次按键): commit_history 变化 → 立即异步预解码
    local sc = env.engine.schema.config
    local enabled = sc:get_bool("llm_rerank/enabled") or false
    if not enabled then
        llm_prep = nil  -- 释放已加载的 DLL 引用
    else
        if not llm_prep then
            local ok, result = pcall(require, "rime_llm")
            if ok then
                -- 日志目录: RIME 用户目录 llm_rerank\<方案> 子目录（2026-11-22
                -- 按方案分文件夹；与 filter 共用同一模块实例；dll 设置端建目录）
                local sdir = rerank_dir()
                if sdir then
                    dir_ensure2(sdir)
                    result.log_dir = sdir
                    _G.llm_log_dir = sdir
                end
                llm_prep = result
            end
        end
        -- 方案切换：DLL 日志目录跟随当前方案（g_log_dir 进程级，只在首次
        -- require 时设 → 切方案后 X 行会继续写旧目录）
        if llm_prep then
            local sdir = rerank_dir()
            if sdir and _G.llm_log_dir ~= sdir then
                dir_ensure2(sdir)
                llm_prep.log_dir = sdir
                _G.llm_log_dir = sdir
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
    trigger_prepare(env)

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
        -- [回撤退款]（2026-11-20）: backspace/delete/undo 弹最近提交并撤销
        -- 其账本 bump（快照栈精确恢复 d/t/c，退款立即落盘）；navigation/
        -- enter 是边界不回撤——清提交栈，与语料 strict 弹栈口径一致。
        if kind == "backspace" or kind == "delete"
                or kind == "undo-clipboard" then
            _G.llm_commit_stack = _G.llm_commit_stack or {}
            if #_G.llm_commit_stack > 0 then
                local last = table.remove(_G.llm_commit_stack)
                -- 词级归因组记录（2026-11-26）：一次提交 N 个词条目整组退款
                local okr = false
                if last.words and #last.words > 0 then
                    for _, aw in ipairs(last.words) do
                        if _G.stats_refund
                                and _G.stats_refund(aw.w, aw.code, last.tick) then
                            okr = true
                        end
                    end
                else
                    okr = _G.stats_refund
                        and _G.stats_refund(last.word, last.code, last.tick)
                end
                if dbg_flag then
                    local n = (last.words and #last.words) or 1
                    live("R|" .. os.date("%H:%M:%S") .. "|回撤退款(" .. kind
                        .. "): " .. (okr and "已退 " or "不退 ")
                        .. tostring(last.word) .. "[" .. tostring(last.code)
                        .. "] x" .. tostring(n))
                end
                if okr and _G.llm_debug_refund then
                    _G.llm_debug_refund(last.cid, last.tick)
                end
            end
        else
            commit_stack_clear()
        end
        reset_history()
        -- 编辑键: 当前 commit_history 位置记为基座——旧词永久忽略
        -- (librime lua 无法清 commit_history, 旧词留在引擎里;
        --  退格会被引擎清空 commit_history → 同步段检测缩短自动重置基座)
        -- 被跳过的历史条目对应的通知器队列条目一并丢弃（1:1 对齐防串码）
        local all_e = ch:to_table()
        if all_e and #all_e > commit_base and _G.llm_commit_inputs
                and #_G.llm_commit_inputs > 0 then
            local skip = math.min(#all_e - commit_base,
                                  #_G.llm_commit_inputs)
            for _ = 1, skip do
                table.remove(_G.llm_commit_inputs, 1)
                -- 归因条带与 commit_inputs 1:1 对齐，同步丢弃（2026-11-26）
                if _G.llm_attr_strips and #_G.llm_attr_strips > 0 then
                    table.remove(_G.llm_attr_strips, 1)
                end
            end
        end
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
        trigger_prepare(env)
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
                commit_stack_clear()
            end

            local dbg_flag = sc:get_bool("llm_rerank/debug_fusion")
            _G.llm_debug_enabled = dbg_flag or false
            for _, w in ipairs(new_words) do
                -- 含中文才分配码，跳过纯英文/数字/标点
                local has_chinese = w:match("[^\1-\127]")
                -- 1:1 取本提交的捕获输入码（通知器每提交压一条, 含标点/ASCII）
                local live_code = ""
                if _G.llm_commit_inputs and #_G.llm_commit_inputs > 0 then
                    live_code = table.remove(_G.llm_commit_inputs, 1)
                end
                -- 1:1 取本提交的归因条带（已确认段 {text, code} 列表或 false）
                local strip = nil
                if _G.llm_attr_strips and #_G.llm_attr_strips > 0 then
                    strip = table.remove(_G.llm_attr_strips, 1)
                end
                local code = ""
                if has_chinese then
                    -- 优先手动捕获的码，其次满码（顶屏回退），用完即清；
                    -- 都没有（简码/顶屏提交）→ 通知器捕获（唯一完整来源）
                    code = pending_code
                    if code == "" then
                        code = last_full
                    end
                    if code == "" and live_code ~= "" then
                        code = live_code
                    end
                end
                pending_code = ""
                last_full = ""
                -- 词频计数: 仅含中文的词 (含英文/数字/标点不参与融合)
                -- 2026-11-13 词码对记账: bump 键 = (词, 完整提交码)
                -- 2026-11-17 单账本: dee 与累计计数同一次 bump/落盘
                -- [整句词频归因]（2026-11-26）：校验通过 → 词级条目入账
                -- （组句段按组句词路径切词、普通段/确认词单词条），N 词
                -- 共享提交级 tick；整句键**不再**入账。C 行仍为整句原样 +
                -- v8 path 尾字段。校验失败 → 回退旧行为（整句键入账）。
                local attr = nil
                if has_chinese and attr_enabled() then
                    attr = build_attribution(w, strip, live_code)
                end
                if attr then
                    stats_ensure_schema()
                    _G.user_freq_tick = (_G.user_freq_tick or 0) + 1
                    local tick_after = _G.user_freq_tick
                    local cid = _G.llm_write_c
                                and _G.llm_write_c(w, attr.full_code,
                                                   tick_after, true, attr.path)
                                or nil
                    local grp = {}
                    for _, aw in ipairs(attr.words) do
                        local before = _G.user_freq_eff
                            and _G.user_freq_eff(aw.w, aw.code) or 0
                        stats_bump(aw.w, aw.code, tick_after)
                        local after = _G.user_freq_eff
                            and _G.user_freq_eff(aw.w, aw.code) or 0
                        grp[#grp + 1] = aw
                        if dbg_flag then
                            live(string.format("E|%s|%s|%.3f|%.3f|%d|%d",
                                os.date("%H:%M:%S"), live_esc(aw.w),
                                before, after, tick_after - 1, tick_after))
                            if cid and _G.llm_debug_e then
                                _G.llm_debug_e(cid, before, after,
                                               stats_dirty)
                            end
                        end
                    end
                    commit_stack_push(w, attr.full_code, tick_after, cid, grp)
                elseif has_chinese then
                    stats_ensure_schema()
                    local before = _G.user_freq_eff and _G.user_freq_eff(w, code) or 0
                    local t_before = _G.user_freq_tick or 0
                    stats_bump(w, code)
                    local after = _G.user_freq_eff and _G.user_freq_eff(w, code) or 0
                    local tick_after = _G.user_freq_tick or 0
                    local cid = _G.llm_write_c
                                and _G.llm_write_c(w, code, tick_after, true)
                                or nil
                    commit_stack_push(w, code, tick_after, cid)
                    if dbg_flag then
                        live(string.format("E|%s|%s|%.3f|%.3f|%d|%d",
                            os.date("%H:%M:%S"), live_esc(w), before,
                            after, t_before, tick_after))
                        if cid and _G.llm_debug_e then
                            _G.llm_debug_e(cid, before, after, stats_dirty)
                        end
                    end
                else
                    local tick0 = _G.user_freq_tick or 0
                    local cid0 = _G.llm_write_c
                                 and _G.llm_write_c(w, code, tick0, false)
                                 or nil
                    commit_stack_push(w, code, tick0, cid0)
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
            commit_stack_clear()
        end

        prev_hist = {}
        for _, v in ipairs(history) do table.insert(prev_hist, v) end
    end

    -- 2026-11-18：history 已在上面同步完毕，此刻再触发一次预解码。
    -- 键首那次 trigger_prepare 早于 history 追加（拿不到刚上屏的词），
    -- 这条补的是"历史兜底路径"的 ctx；ctx 未变时被去重挡住，零额外开销。
    trigger_prepare(env)

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
