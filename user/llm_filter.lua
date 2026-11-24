-- llm_filter.lua — LLM candidate rerank filter
-- 由 schema llm_rerank.enabled 控制：true | false
-- false 时不加载 DLL，不推理，候选原样透传
--
-- 异步基建（2026-11-22，两版同构）：评分移出按键路径——DLL 持久评分线程
-- （覆盖式任务槽 + 代次中断），字词模式 submit+wait（等价既有同步评分）。
-- **2026-11-23 修**：整句模式也改为 submit + 短预算 wait（150ms）——此前
-- "投递即走"使当前键只能显示层 1 序、LLM 结果仅在同指纹重查时可见（真机
-- 连续整句打字实测从未上屏）；超时仍回退挂账 pending。快照缓存指纹 =
-- 上文\x1f候选\x1e子词清单拼接串。

local llm = nil
local llm_loaded_for = nil  -- enabled value when llm was loaded

-- 融合系数 β 为内置常数（2026-11-05 用户定案：标定产物退出用户配置面——用户没有
-- 标定能力；与 FREQ_TAU=400 同待遇。调整 = 改代码随下次发版生效）：
-- 前缀软确认（2026-11-24 定案：合并单一路线，取代窗口 A + 句级 B 两路）：
-- 唯一 pending 生产者 = 组句（ngram）给文本 + 窗口融合序投票：
--   ① 组句侧：top-20 组句按前导词(lead) 分组做 softmax，P(lead) ≥ 0.95
--      （研究库 §「组句『自信前缀』的更本质度量」：同精度下召回比"5 条
--      lead 全一致"高 51%；阈值 0.90 会掉进双峰低谷，0.95–0.97 才稳）；
--   ② 窗口侧：该 lead 文本必须是**窗口融合序第 1** 且 span 对齐（文本一致
--      铁律：同码同长同音字不得按区间捡）——位次即 CE 全序比较，再加 CE
--      margin 净收益反降（研究库 §「窗口侧只认第 1」）；
--   ③ 守卫（2026-11-24 真机定案，音节单位）：确认后**剩余 ≥2 音节**，
--      单字 lead 不再有"余 1 例外"（下载 xiazai 在 xia 确认「下」→ 剩 zai
--      只能出单字，2 字词被拆）。组句句子字数 = 音节数（中文一字一音节）；
--      不用码数——简拼/双拼/混拼下码数与音节数无固定关系。
-- 挂起后由 llm_processor 下一键执行 ctx:select → Segment::Close 截段 →
-- Forward + Compose 只重译剩余码（组合区内预确认，不上屏）。
-- 开关 = 方案节 `llm_rerank/ngram_group`（GUI「N-gram 组句候选」复选框）：
-- 前缀确认的唯一信号源是组句 lead，2026-11-24 用户定案并入同一开关
-- （独立键 `prefix_confirm` 退役、读取端忽略）；生效条件 = 整句模式 +
-- 组句开 + 方案输出简体。
-- θ 与单字倍数已退役（位次门不需要 θ）；组句返回空（码切在音节中间）的窗
-- 不再自动确认（研究库：该档窗口 A 精度仅 56.8%）。
local PREFIX_CONFIRM_P = 0.95
-- 冒烟/调参入口：_G.llm_prefix_confirm_p（0..1）覆盖阈值。
local function prefix_confirm_p()
    local v = tonumber(_G.llm_prefix_confirm_p)
    if v and v >= 0 and v <= 1 then return v end
    return PREFIX_CONFIRM_P
end
-- 整句模式同步等待预算（2026-11-23 修）：原先整句模式"投递即走"，当前键
-- 只能显示层 1 序，LLM 评分只在同指纹重查时才用上（真机实测连续打字从未
-- 上屏）。改为每键最多等这么久——真机 100ms/键实测 6 个长词候选的
-- 3-token 打分约 65ms，150ms 留余量；超时仍回退挂账 pending（层 1 序）。
local SENTENCE_WAIT_MS = 150
-- 冒烟/调参入口（同 theta 模式）：_G.llm_sentence_wait_ms 置 0 = 不等，
-- 强制走旧的挂账 pending 路径（超时回退分支的测试用）。
local function sentence_wait_ms()
    local v = tonumber(_G.llm_sentence_wait_ms)
    if v and v >= 0 then return v end
    return SENTENCE_WAIT_MS
end
local FREQ_BETA = 14 -- 对数词频融合系数（2026-11-14 默认模型改
                     -- Qwen2.5-0.5B 后重标定: 用户域 34k + wiki 池化
                     -- 180k 网格, kCeW (1.0,1.10,0.60)+β14 偶半选→奇半
                     -- 验四半区一致, 见研究库 calibrate_model_05b; 旧
                     -- v3 (1.05/0.45/β12) 为 0.8B 标定值）
                     -- fused = score + β·log(1+eff) + log(0.5·p1)
                     --   p1 = 用户累计 Unigram 平滑概率（llm_processor 维护,
                     --   _G.user_unigram_term 查询; 累计 Bigram 项已退役
                     --   2026-11-08, 见研究库 §三十七）
-- sentence_mode 整句模式（2026-11-22 用户定案，取代 two_code_sentence 两码整句）：
-- 候选覆盖整个活动段（cand.start/_end == 段边界 = 音节数一致的满覆盖候选，
-- 由引擎音节切分 lattice 决定，简拼/单韵母短码天然正确）进 LLM 评分窗，
-- 部分覆盖候选保持引擎序排后。两码一字方案下与旧「词长==⌊码长/2⌋」
-- 逐位等价（4 码 = 2 音节满覆盖 ⟺ 词长 2）。默认 false。

-- 词码对扣分修正（2026-11-21 用户定案解耦：只承载负分 CE 偏差降噪）：
-- 表放用户目录 llm_pairfix.tsv，行 `词<TAB>码<TAB>-分数`
--   （无第三列 = 旧默认扣 5）；`#` 注释；无文件 = 机制休眠；
-- 每次窗口准入/融合轻量重读，编辑即时生效。负分保留 fade（用户该词码对
-- 累计 >= PAIRFIX_FADE_UNI 次 -> 预置让位）。正分行读取端跳过（2026-11-17
-- 的 +200 固定首选/+100 固定次选语义废除——固定候选归拼读双拼
-- pin_candidates.tsv + pin_filter.lua 全局重排，与 LLM 重排解耦）。
-- 旧 2026-11-13 pairfix 推导（wiki 拆半/用户域回放）保留在文件头历史注释：
-- 与@vkh 等污染对按字频抬分；负分只破 CE 险胜的近平局。
local PAIRFIX_PENALTY_DEFAULT = 5.0
local PAIRFIX_FADE_UNI = 3
-- 2026-11-21 用户定案：词码对扣分修正与固定候选**解耦**——本表只承载
-- 负分（CE 系统性偏差降噪，只在重排评分窗内生效，受 fade）；正分（固定
-- 候选）行读取端跳过，固定候选归拼读双拼 pin_candidates.tsv +
-- pin_filter.lua（全局生效、优先于重排，0/9/8/7/6 键写入/解除）。

-- ── LLM 记录子目录（2026-11-21 用户定案）────────────────────────────
-- 用户文件夹下建 llm_rerank 子目录收纳全部 LLM 数据/日志文件
-- （corpus/debug/账本/词码对）；固定候选 pin_candidates.tsv 属拼读双拼
-- 本机功能，仍留用户文件夹根。resolve 规则：
--   子目录已有 → 用之；根目录旧文件在 → 建目录后 os.rename 一次性迁移
--   （目录建不出/改名失败 → 暂读暂写根目录，下次再迁，绝不丢数据）；
--   全新写场景 → 建目录后用子目录；读场景两处皆无 → nil（机制休眠）。
-- 目录由 rime_llm.dll ensure_dir 建立（rime-lua 无 mkdir）。
local function llm_user_dir()
    local ok, ud = pcall(function() return rime_api.get_user_data_dir() end)
    if ok and type(ud) == "string" and ud ~= "" then return ud end
    return os.getenv("TEMP") or "C:\\Windows\\Temp"
end

local function llm_dir_ensure(dir)
    local ok, cpp = pcall(require, "rime_llm")
    if not ok or not cpp or not cpp.ensure_dir then return false end
    local ok2, made = pcall(cpp.ensure_dir, dir)
    return ok2 and made == true
end

-- ── 按方案分文件夹（2026-11-22 用户定案：四件全分）──────────────────
-- 目录 = <用户文件夹>\llm_rerank\<方案 ID>\，四个文件全部按方案隔离：
--   rime_llm_corpus.tsv / rime_llm_debug.txt / user_ledger.tsv /
--   llm_pairfix.tsv
-- 迁移规则（"有状态资产"与"日志"区别对待）：
--   · 账本/词码对 = 有状态资产 → 该方案**首次读写时从旧位置复制一份**
--     （旧位置 = llm_rerank\<名> 或 用户文件夹根\<名>），旧文件保留不删；
--     每个方案各得一份快照，此后独立演进（键 = 词+码，与方案绑定、天然
--     不相交，历史条目跨方案共存无害）。
--   · corpus/debug = 日志 → 不复制（否则每方案各背一份全量历史、违背
--     分目录初衷）；该方案下从空文件开始写，旧混合日志留作历史。
-- 方案 ID 不可得 → "unknown"（部署期等边缘场景，同样隔离不污染根）。
local function schema_safe(sid)
    if type(sid) ~= "string" or sid == "" then return "" end
    sid = sid:gsub("[^%w_%.%-]", "_")
    if #sid > 64 then sid = sid:sub(1, 64) end
    return sid
end

local function rerank_root()
    local ud = llm_user_dir()
    if not ud or ud == "" then return nil end
    return ud .. "\\llm_rerank"
end

-- 当前方案记录目录（每键由 filter/processor 写入 _G.llm_schema_id）
-- 方案不可得（部署期/冒烟桩）→ nil，调用方退回 llm_rerank 根（旧行为）
local function rerank_dir()
    local root = rerank_root()
    if not root then return nil end
    local sid = schema_safe(_G.llm_schema_id)
    if sid == "" then return nil end
    return root .. "\\" .. sid
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

local function dir_ensure2(dir)
    -- ensure_dir 只建单层：父目录 llm_rerank 先建，再建方案层
    local root = rerank_root()
    if root then llm_dir_ensure(root) end
    return llm_dir_ensure(dir)
end

local function llm_resolve(name, for_write, migrate)
    local root = rerank_root()
    if not root then
        -- 用户目录不可得：退回 %TEMP%（与旧行为一致，不进方案目录）
        local tmp = os.getenv("TEMP") or "C:\\Windows\\Temp"
        return tmp .. "\\" .. name
    end
    local sid = schema_safe(_G.llm_schema_id)
    -- 方案不可得 → 直接用 llm_rerank 根（部署期/冒烟桩；旧行为）
    local dir = sid ~= "" and (root .. "\\" .. sid) or root
    local new = dir .. "\\" .. name
    local f = io.open(new, "rb")
    if f then f:close() return new end
    -- 旧位置 1 = llm_rerank 根（方案层还不存在时）；旧位置 2 = 用户文件夹根
    local legacy = {}
    if dir ~= root then legacy[#legacy + 1] = root .. "\\" .. name end
    legacy[#legacy + 1] = (llm_user_dir() or "") .. "\\" .. name
    if migrate then
        for _, old in ipairs(legacy) do
            local g = io.open(old, "rb")
            if g then
                g:close()
                if dir_ensure2(dir) and file_copy(old, new) then
                    return new
                end
                return old   -- 复制失败：暂读旧位置，下次再试
            end
        end
    end
    if for_write and dir_ensure2(dir) then return new end
    return nil
end

-- 读参考表 → { ["词\t码"] = 有符号分数 }; 无文件返回 nil（机制休眠）
local function pairfix_table()
    -- migrate=true：词码对属有状态资产，该方案首次读取时从旧位置复制
    local path = llm_resolve("llm_pairfix.tsv", false, true)
    if not path then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local tbl = {}
    for line in f:lines() do
        line = line:gsub("\r$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local w, c, sv = line:match("^(.-)\t(.-)\t(.+)$")
            local delta
            if sv then
                sv = sv:match("^([%+%-]?[%d%.]+)$")
                if not sv then
                    w, c = nil, nil   -- 第三列非法：跳过，不并进码键
                else
                    delta = tonumber(sv)
                    if delta > 0 then
                        -- 2026-11-21 解耦：正分（固定候选）行跳过——归
                        -- pin_candidates.tsv / pin_filter.lua，本表只留负分
                        w, c = nil, nil
                    end
                end
            else
                w, c = line:match("^(.-)\t(.-)$")
                delta = -PAIRFIX_PENALTY_DEFAULT  -- 旧两列格式 = 默认扣 5
            end
            if w and w ~= "" and c and c ~= "" and delta then
                tbl[w .. "\t" .. c] = delta
            end
        end
    end
    f:close()
    return tbl
end

-- 命中返回有符号分数修正；正分（固定首选/次选）不受 fade 限制
local function pairfix_delta(tbl, text, input)
    if not tbl then return 0 end
    local key = text .. "\t" .. (input or "")
    local d = tbl[key]
    if not d or d == 0 then return 0 end
    if d > 0 then return d end
    local uni = _G.user_uni_count
                    and _G.user_uni_count(text, input) or 0
    if uni >= PAIRFIX_FADE_UNI then return 0 end
    return d
end

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
    max_tokens       = 20,  -- 截取的上文 token 数（2026-11-19 随生产模型切 Qwen3-0.6B base 定案，旧 10 为 0.5B 时代值）
    max_candidates   = 6,   -- 2026-11-19：0.6B k*=6（候选段 100ms / 最优 3.65%）
    cpu_cores        = nil,  -- nil = 不设置，走 C++ 默认（固定 4，bench_threads 实测后可配）
    debug_fusion     = false, -- true = 逐候选融合明细写 rime_llm_debug.txt (诊断用)
    sentence_mode    = false, -- 整句模式：等长词+子词统一进评分窗、显示统一
                              -- 概率序（2026-11-24 统一准入取代 2026-11-22
                              -- 满覆盖优先；2026-11-22 取代 two_code_sentence
                              -- 两码整句；旧键读取端兜底一次，保存/重建节剥除）
    prefix_confirm   = false, -- 【已退役，2026-11-24 并入 ngram_group】前缀自动
                              -- 确认的唯一信号源 = 组句 lead，故与组句同开关；
                              -- 旧键读取端忽略、保存/重建节时剥除。
                              -- _G.llm_prefix_confirm = _G.llm_ngram_group
    ngram_group      = false, -- N-gram 组句候选（2026-11-23 整句模式第②段）：
                              -- 用万象 LTS `.gram` + 万象词库做词级 beam，生成
                              -- top-20 整句候选（显示 1 条、概率供前缀确认；
                              -- 2026-11-24 phrase-only，组句不参与 CE）。
                              -- **只在 sentence_mode 且方案输出简体时
                              -- 生效**；资产缺失（用户目录 llm_ngram\）自动关闭
    -- freq_beta 不再从 schema 读取（2026-11-05 用户配置面移除，标定产物退出配置面）
    -- → 内置常数 FREQ_BETA；方案里残留旧行读取端忽略，保存/重建节时剥除
}

-- ============================================================
-- 记录文件（2026-11-17 用户定案：只保留两个文件）
--   常开语料 rime_llm_corpus.tsv（TSV，不轮转，独立可分析）
--   按需 debug rime_llm_debug.txt（| 分隔，10MB 单轮转）
-- 事件 ID 串联两文件；debug 只写语料没有的字段（CE/eff/耗时/错误），
-- 不重复词/码/上下文/候选序/配置。llm_processor.lua 复用这些 _G 函数。
-- ============================================================
_G.llm_ev_seq = _G.llm_ev_seq or 0
_G.llm_debug_enabled = _G.llm_debug_enabled or false

local function rec_esc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub("\t", "\\t")
         :gsub("\r", "\\r"):gsub("\n", "\\n")
    return s
end

local function rec_cand_esc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub(",", "\\,")
         :gsub("\t", "\\t"):gsub("\r", "\\r"):gsub("\n", "\\n")
    return s
end

local function rec_join(v, maxn)
    local out = {}
    for i = 1, math.min(#(v or {}), maxn) do
        out[i] = rec_cand_esc(v[i])
    end
    return table.concat(out, ",")
end

local function rec_ctx_tail(s, n)
    s = s or ""
    if #s <= n then return s end
    local cut = #s - n + 1
    while cut <= #s and (s:byte(cut) or 0) >= 0x80
            and (s:byte(cut) or 0) < 0xC0 do
        cut = cut + 1
    end
    return s:sub(cut)
end

local function rec_stamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

function _G.llm_new_event(kind, tick)
    _G.llm_ev_seq = (_G.llm_ev_seq or 0) + 1
    return os.date("%Y%m%dT%H%M%S") .. "-" .. tostring(tick or 0)
        .. "-" .. string.format("%04d", _G.llm_ev_seq)
end

local function rec_header_ok(path, magic, header)
    local f = io.open(path, "rb")
    if f then
        local first = f:read("*l")
        f:close()
        if not first then
            f = io.open(path, "ab")
            if not f then return false end
            f:write(header .. "\n"); f:close(); return true
        end
        return first:sub(1, #magic) == magic
    end
    f = io.open(path, "ab")
    if not f then return false end
    f:write(header .. "\n"); f:close(); return true
end

local function rec_append(path, line)
    local f = io.open(path, "ab")
    if not f then return end
    f:write(line, "\n")
    f:close()
end

function _G.llm_corpus_write(line)
    local path = llm_resolve("rime_llm_corpus.tsv", true)
    if not path then return end
    if _G.llm_corpus_header_path ~= path then
        _G.llm_corpus_header_path = path
        _G.llm_corpus_ok = rec_header_ok(path, "#RIME_CORPUS\tv2\t",
            "#RIME_CORPUS\tv2\t" .. rec_stamp() .. "\tplugin")
    end
    if not _G.llm_corpus_ok then return end
    rec_append(path, line)
end

function _G.llm_debug_write(line, force)
    if not force and not _G.llm_debug_enabled then return end
    local path = llm_resolve("rime_llm_debug.txt", true)
    if not path then return end
    if _G.llm_debug_header_path ~= path then
        _G.llm_debug_header_path = path
        _G.llm_debug_ok = rec_header_ok(path, "#RIME_DEBUG|v2|",
            "#RIME_DEBUG|v2|" .. rec_stamp() .. "|plugin")
    end
    if not _G.llm_debug_ok then return end
    local f = io.open(path, "rb")
    if f then
        local sz = f:seek("end")
        f:close()
        if sz and sz > 10 * 1024 * 1024 then
            os.remove(path .. ".old")
            os.rename(path, path .. ".old")
        end
    end
    rec_append(path, line)
end

local function rec_rank(v, word)
    for i, x in ipairs(v or {}) do
        if x == word then return i end
    end
    return -1
end

function _G.llm_write_w(id, src, code, ctx, engine, window, final, tick,
                        status, skip, prep, flags)
    local line = table.concat({
        "W", id, rec_stamp(), rec_esc(src), rec_esc(code),
        rec_esc(rec_ctx_tail(ctx, 120)), rec_join(engine, 10),
        rec_join(window, 20), rec_join(final, 20), tostring(tick or 0),
        status or "ok", rec_esc(skip or ""), prep and "1" or "0",
        rec_esc(flags or "")
    }, "\t")
    _G.llm_corpus_write(line)
    _G.llm_last_event_id = id
    _G.llm_last_window = { id = id, code = code, engine = engine or {},
                           window = window or {}, final = final or {},
                           tick = tick or 0 }
    return id
end

function _G.llm_write_c(word, code, tick, cjk)
    local ref, re, rw, rf = "", -1, -1, -1
    local wl = _G.llm_last_window
    if wl and code and code ~= "" and wl.code == code then
        ref = wl.id or ""
        re = rec_rank(wl.engine, word)
        rw = rec_rank(wl.window, word)
        rf = rec_rank(wl.final, word)
    end
    _G.llm_last_window = nil
    local id = _G.llm_new_event("C", tick)
    local line = table.concat({
        "C", id, rec_stamp(), ref, rec_esc(word), rec_esc(code or ""),
        tostring(re), tostring(rw), tostring(rf), tostring(tick or 0),
        cjk and "cjk=1" or ""
    }, "\t")
    _G.llm_corpus_write(line)
    _G.llm_last_event_id = id
    return id
end

function _G.llm_write_m(kind)
    local id = _G.llm_new_event("M", 0)
    local line = table.concat({
        "M", id, rec_stamp(), _G.llm_last_event_id or "", kind or "unknown",
        "", ""
    }, "\t")
    _G.llm_corpus_write(line)
    _G.llm_debug_write(id .. "|R|gen=" .. tostring(_G.llm_reset_gen or 0),
                       false)
    return id
end

local function rec_base(path)
    path = path or ""
    return (path:match("([^\\/]+)$") or path)
end

function _G.llm_write_h(schema, model)
    local id = _G.llm_new_event("H", _G.user_freq_tick or 0)
    local line = table.concat({
        "H", id, rec_stamp(), "plugin", rec_esc(schema or "unknown"),
        rec_esc(rec_base(model)), rec_esc(cfg.code_pattern or ""),
        tostring(cfg.max_candidates or 5), tostring(cfg.max_tokens or 10),
        cfg.sentence_mode and "1" or "0", "14.00", "400"
    }, "\t")
    _G.llm_corpus_write(line)
end

local function rec_num(v)
    if type(v) ~= "number" or v ~= v or v <= -1e307 or v >= 1e307 then
        return "-inf"
    end
    return string.format("%.3f", v)
end

function _G.llm_debug_p(id, total, prep)
    _G.llm_debug_write(string.format("%s|P|total=%.1f|prep=%d", id,
                                     total or 0, prep and 1 or 0), false)
end

function _G.llm_debug_d(id, rank, ce, ce1, ce2, ce3, eff, fb, u1, full,
                        key, sdelta, cerank, finrank)
    _G.llm_debug_write(string.format(
        "%s|D|%d|ce=%s|ce1=%s|ce2=%s|ce3=%s|eff=%.3f|fb=%.3f|u1=%.3f"
        .. "|full=%d|key=%s|sdelta=%g|cerank=%d|finrank=%d",
        id, rank, rec_num(ce), rec_num(ce1), rec_num(ce2), rec_num(ce3),
        eff or 0, fb or 0, u1 or 0, full and 1 or 0, rec_num(key),
        sdelta or 0, cerank or 0, finrank or 0), false)
end

function _G.llm_debug_e(id, before, after, dirty)
    _G.llm_debug_write(string.format(
        "%s|E|eff_before=%.3f|eff_after=%.3f|dirty=%d", id, before or 0,
        after or 0, dirty or 0), false)
end

-- [回撤退款]（2026-11-20）: 退款成功标记行（debug 开启才写）；词/码在
-- cid 关联的 C 行里，此处只记 id + tick，避免 | 分隔协议转义问题。
function _G.llm_debug_refund(cid, tick)
    _G.llm_debug_write(string.format("%s|RF|refund=1|tick=%d", cid,
        tick or 0), false)
end

local lat_max   = 0
local lat_count = 0

local function is_finite_number(v)
    return type(v) == "number" and v == v
        and v > -math.huge and v < math.huge
end

local function is_valid_llm_score(v)
    return is_finite_number(v) and v > -1e9
end

-- 挂账回填（2026-11-22 异步基建）：整句模式异步评分结果收割时补写语料。
-- final 序 = 窗内候选按融合分重排（文本域现算：eff/uni/pairfix 为微秒级
-- 内存查询；账本 tick 与提交时刻的漂移 ≤1 词提交，v1 接受——回填只写
-- W ok（flags=async）+ debug P 行，D/L/C 明细行省略）。
local function write_pending_result(pend, snap)
    local win = pend.l1win or {}
    local scores = snap.scores or {}
    local pftbl = pairfix_table()
    local min_valid = nil
    for _, t in ipairs(win) do
        local s = scores[t]
        if is_valid_llm_score(s) and (not min_valid or s < min_valid) then
            min_valid = s
        end
    end
    local arr = {}
    for i, t in ipairs(win) do
        local s = scores[t]
        local n = _G.user_freq_eff and _G.user_freq_eff(t, pend.code) or 0
        local u1 = _G.user_unigram_term
                and _G.user_unigram_term(t, pend.code) or 0
        local delta = pairfix_delta(pftbl, t, pend.code)
        local v
        if is_valid_llm_score(s) then
            v = s + FREQ_BETA * math.log(1 + n) + u1 + delta
        else
            -- 无 CE 分（哨兵/缺失）：层1 分 + 窗内最低 LLM 分（压制窗底，
            -- 与同步版同语义）
            v = (FREQ_BETA * math.log(1 + n) + u1)
                    + (min_valid and min_valid or 0) + delta
        end
        arr[i] = { t = t, v = v, i = i }
    end
    table.sort(arr, function(a, b)
        if a.v ~= b.v then return a.v > b.v end
        return a.i < b.i    -- 同分稳定保提交序（层1 序）
    end)
    local final = {}
    for i, e in ipairs(arr) do final[i] = e.t end
    if pend.wid then
        _G.llm_write_w(pend.wid, pend.ctx_src, pend.code, pend.context,
                       pend.engine_top, pend.l1win, final, pend.tick,
                       "ok", "", snap.prep and true or false, "async")
        _G.llm_debug_p(pend.wid, snap.ev_ms or 0, snap.prep and true or false)
    end
end

-- ═══ 异步基建（2026-11-22，两版同构）═══
-- 评分结果缓存（指纹 → 评分快照）：指纹 = 上文\x1f候选\x1e拼接串（与 DLL
-- 任务槽同构，上文/候选变化自然失效，无需失效链）。命中场景 = 同指纹重复
-- query（翻页/候选窗重建/收割回填）——同步路径零 LLM。快照结构
-- {cands, scores, ce3, segs, prep, ctx_used, ev_ms} 与 DLL async_wait/poll
-- 返回一致；融合分（eff/pairfix 叠加）每次命中现算，不缓存融合结果。
-- pending：指纹 → 语料挂账——整句模式异步投递时登记，评分结果收割时补写
-- W ok/P 行；任务被覆盖/取消则条目随容量清理丢弃（快速连打的中间键不落
-- 语料 = "只有完成的评分才落 W"的异步语义）。
local res_cache, pending = {}, {}
local function cache_trim()
    local n = 0
    for _ in pairs(res_cache) do n = n + 1 end
    if n > 16 then res_cache = {} end
    n = 0
    for _ in pairs(pending) do n = n + 1 end
    if n > 32 then pending = {} end
end
-- 指纹（2026-11-22）：上文 \x1f 候选 \x1e 拼接；2026-11-23 追加子词清单
-- （整句模式才有，\x1d 分隔）——子词复用分与候选集属同一快照，指纹必须
-- 绑定，否则同 FM 不同 PM 的 query 会错命中缓存（与 DLL async_fingerprint
-- 同构；字词模式 pm 为空 → 指纹格式保持不变）。
local function make_fp(context, cands, pm, prefix)
    local fp = context
    -- 已确认前缀（2026-11-23）：拼在上文后、候选前（\x1c 分隔），与 DLL
    -- async_fingerprint 同构——确认前后上文相同但前缀不同，必须区分
    if prefix and prefix ~= "" then
        fp = fp .. "\x1c" .. prefix
    end
    fp = fp .. "\x1f" .. table.concat(cands, "\x1e")
    if pm and #pm > 0 then
        fp = fp .. "\x1d" .. table.concat(pm, "\x1e")
    end
    return fp
end

-- 收割点（2026-11-22）：回收最近完成的评分成果——回填缓存 + 补写挂账。
-- 两个调用点：① filter 入口（每次 query，翻页/候选窗重建命中缓存即
-- 0 LLM）；② llm_async_cancel（上屏时本词评分多半已完成——先收割落账
-- 再取消在跑的，场景内最后一词也有 ok 行）。
function _G.llm_async_harvest()
    if not (llm and llm.async_poll) then return end
    local okp, old = pcall(function() return llm.async_poll() end)
    if okp and type(old) == "table" and old.fp and old.scores then
        res_cache[old.fp] = old
        local pend = pending[old.fp]
        if pend then
            write_pending_result(pend, old)
            pending[old.fp] = nil
        end
        cache_trim()
    end
end

-- 提交/上下文变化后由 llm_processor 的 commit 通知调用：先收割（上屏时
-- 本词评分多半已完成，立即落账），再中断在跑的评分（DLL 代次递增 + 清
-- 任务槽），挂账条目随代次废弃（下次容量清理丢弃）。
function _G.llm_async_cancel()
    _G.llm_async_harvest()
    if llm and llm.async_cancel then
        pcall(llm.async_cancel)
        pending = {}
    end
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
        -- 日志目录: RIME 用户目录 llm_rerank\<方案> 子目录（2026-11-22 按
        -- 方案分文件夹；dll 设置端建目录，未设置时 C++ 回退 %TEMP%）。
        -- 方案不可得时退回 llm_rerank 根（旧行为）
        local sdir = rerank_dir() or rerank_root()
        if sdir then
            dir_ensure2(sdir)
            cpp.log_dir = sdir
            _G.llm_log_dir = sdir
        end
        llm = cpp
        llm_loaded_for = true
    end
end

local function init_config(env)
    local sc = env.engine.schema.config
    -- 当前方案 ID（2026-11-22 分目录）：每键刷新，供 llm_resolve 选子目录。
    -- 不可得 → nil，schema_safe 兜底 "unknown"（不污染根目录）
    local sid0 = env.engine.schema and env.engine.schema.schema_id
    if sid0 and sid0 ~= "" then _G.llm_schema_id = sid0 end
    -- 编码匹配模式（2026-09-30 取代 min/max_code_len）：get_string 未配置返回
    -- nil，配置了空串则视为"总是匹配"（与源码版一致）
    local pat = sc:get_string("llm_rerank/code_pattern")
    if pat ~= nil then cfg.code_pattern = pat end
    -- expected_length_weight 不再读取（2026-11-07 由布尔开关取代;
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
    -- 整句模式开关（2026-11-22 取代 two_code_sentence）：新键优先；旧键只在
    -- 新键未配置时兜底一次（真机旧方案 two_code_sentence: true 直升整句模式，
    -- 保存后自然换新键——避免硬忽略造成已启用整句的机器静默退化）
    local sm = sc:get_bool("llm_rerank/sentence_mode")
    if sm ~= nil then
        cfg.sentence_mode = sm
    else
        local tcs = sc:get_bool("llm_rerank/two_code_sentence")
        if tcs ~= nil then cfg.sentence_mode = tcs end
    end
    -- 整句模式锁定编码匹配（2026-11-22 用户定案）：sentence_mode on 时
    -- code_pattern 恒 '.{2,}'（2 码起参与重排），上方读取的方案节该行被
    -- 覆盖（手改 yaml 也不生效）；off 时方案节值生效
    if cfg.sentence_mode then cfg.code_pattern = '.{2,}' end
    -- 前缀自动确认已并入 ngram_group（2026-11-24 用户定案）：确认信号完全
    -- 来自组句 lead，没有组句就没有确认，故不保留独立开关。旧键
    -- `llm_rerank/prefix_confirm` 读取端忽略、保存/重建节时剥除。
    -- _G.llm_prefix_confirm 在下方按 ngram 门派生（含整句模式/简体门）。
    -- N-gram 组句候选（2026-11-23 整句模式第②段）：开关 + 只需在整句模式。
    -- 组句词表 = 万象（简体）词库——只在方案输出简体时注入。
    -- 输出字形门（2026-11-23 晚修，与源码版同构）：旧判据只认
    -- simplifier/option_name 非空，把朙月 luna_pinyin 这类**无 option_name
    -- 的恒转换** simplifier（缺节 → opencc 默认 t2s，候选恒简体）误判成
    -- 繁体方案 → 组句静默关闭、单字前缀确认永不触发（真机报障根因）。
    -- 新判据 = filters 里确有 simplifier（排除 s2t 反向）；option_name
    -- 存在时在注入点按开关当前状态再 gate。
    local ngg = sc:get_bool("llm_rerank/ngram_group")
    if ngg ~= nil then cfg.ngram_group = ngg end
    _G.llm_simplifier_option = sc:get_string("simplifier/option_name") or ""
    _G.llm_simplified_scheme = false
    local flist = sc:get_list("engine/filters")
    if flist then
        for i = 0, flist.size - 1 do
            local fv = flist:get_value_at(i)
            local fname = fv and fv:get_string()
            if fname and (fname == "simplifier"
                          or fname:sub(1, 11) == "simplifier@") then
                _G.llm_simplified_scheme = true
                break
            end
        end
    end
    if _G.llm_simplified_scheme then
        local occ = sc:get_string("simplifier/opencc_config")
        if occ and occ:find("s2t", 1, true) then  -- 简→繁不算"输出简体"
            _G.llm_simplified_scheme = false
        end
    end
    _G.llm_ngram_group = cfg.ngram_group and cfg.sentence_mode
                             and _G.llm_simplified_scheme
    -- 前缀自动确认 = 组句同一开关（2026-11-24 用户定案）：确认信号只有
    -- 组句 lead 一条来源；要前缀确认就必须有万象资产，所以并成一个开关。
    _G.llm_prefix_confirm = _G.llm_ngram_group
    _G.llm_debug_enabled = cfg.debug_fusion
    -- H 行（进程/方案配置起点）：按方案各写一次——分目录后每个方案的语料
    -- 文件需要自己的 H 行，切方案时不得跳过（旧 one-shot 只写首方案）
    local sid = (env.engine.schema and env.engine.schema.schema_id)
                or "unknown"
    if _G.llm_h_written ~= sid then
        _G.llm_h_written = sid
        local mp = sc:get_string("llm_rerank/model_path") or ""
        _G.llm_write_h(sid, mp)
    end
end

local function texts_of(list, maxn)
    local out = {}
    for i = 1, math.min(#list, maxn) do out[i] = list[i].text end
    return out
end

-- ═══ 整句模式（2026-11-22 定案）：活动段切片取码 + 满覆盖（FM）判定 ═══
-- 候选 start/_end 恰为活动段 [start,_end) = 覆盖全部音节（"音节数一致"）。
-- 引擎 lattice 已把全部合法解析（歧义、简拼、单韵母短码）编码进候选集，
-- filter 不复刻音节化。三级兜底（官方 weasel 内置 librime-lua 版本不可控）：
--   ① composition 可用 → 活动段 = composition:back()（多段续打正确；
--     librime 翻译只发生在未确认的最后一段）；
--   ② composition 不可用 → 单段启发 [0, #input)（连续输入的常见形态，
--     多段时该段满覆盖候选 start>0 不满足 → 视为 PM → 安全退化不重排）；
--   ③ 候选无 start/_end（librime-lua 过旧）→ 回退旧长度规则
--      词长==⌊码长/2⌋（两码方案保真；全拼下满覆盖组为空 → skip 透传）。
local function resolve_segment(env, input)
    local ok, seg = pcall(function()
        local comp = env.engine.context.composition
        if not comp or type(comp.back) ~= "function" then return nil end
        return comp:back()
    end)
    if ok and seg and type(seg.start) == "number"
            and type(seg._end) == "number"
            and seg.start >= 0 and seg._end <= #input
            and seg._end > seg.start then
        return seg.start, seg._end
    end
    return 0, #input
end

-- 候选覆盖区间（不可用返回 nil）——librime-lua 候选属性 start / _end
local function cand_span(c)
    local ok, s = pcall(function() return c.start end)
    if not ok or type(s) ~= "number" then return nil end
    local ok2, e = pcall(function() return c._end end)
    if not ok2 or type(e) ~= "number" then return nil end
    return s, e
end

-- ═══ N-gram 组句候选（2026-11-23 整句模式第②段）═══
-- 组句器在 rime_llm.dll（万象 LTS `.gram` + 万象词库词级 beam，算法与
-- 研究库 eval/tools/sentence_gen_gram.py 同构；生产参数 beam=32 /
-- max_edges=8 实测 15ms 每句、hit@5 73%/61%，见研究库 §11.10）。
-- 本文件只负责：资产路径解析、进程内一次加载、候选构造、前置注入。
-- 资产在用户目录 llm_ngram\（安装器可选下载），缺失时整块功能自动关闭，
-- 每 60 秒最多重试一次（避免每键反复打开大文件）。
local NGRAM_FILES = { "zi", "jichu", "duoyin", "diming", "mingren", "yiren" }
-- topk 20（2026-11-24 定案）：前缀确认的组句侧自信度 = 按 lead 分组的
-- top-20 softmax 概率质量；beam 本来就探索 32，只是输出截断不同（实测
-- 4.0 → 4.1ms/窗，零额外成本）。显示端仍只置顶 1 条（ngram 序首选）。
local NGRAM_PARAMS = {
    topk = 20, beam = 32, min_weight = 10, max_edges = 8, ctx_tail = 10,
}
local ngram_ready = false
local ngram_retry_at = 0

local function ngram_ensure(env)
    if ngram_ready then return true end
    if not (llm and llm.ngram_load) then return false end
    local now = os.time()
    if now < ngram_retry_at then return false end
    local user = llm_user_dir()
    if not user or user == "" then return false end
    local function envp(name, def)
        local v = os.getenv(name)
        if v and v ~= "" then return v end
        return def
    end
    local gram = envp("RIME_LLM_NGRAM_PATH",
                      user .. "\\llm_ngram\\wanxiang-lts-zh-hans.gram")
    local dict = envp("RIME_LLM_NGRAM_DICT", user .. "\\llm_ngram\\dicts")
    local sid = schema_safe((env.engine.schema and env.engine.schema.schema_id)
                            or "unknown")
    local cache_dir = user .. "\\llm_rerank\\ngram_lex"
    dir_ensure2(cache_dir)
    local cache = cache_dir .. "\\" .. sid .. ".bin"
    local okc, r1, r2 = pcall(llm.ngram_load, gram, dict, NGRAM_FILES, "", cache)
    if okc and r1 then
        ngram_ready = true
        return true
    end
    ngram_retry_at = now + 60
    if llm.live_write then
        pcall(llm.live_write, "G|ngram_load_failed|" ..
              live_esc(tostring(okc and r2 or r1)))
    end
    return false
end

-- 生成并把候选构造好（text/lead/lead_end 供前缀判定）；ctx = 上文 + 已确认前缀
local function ngram_make(env, code, context, prefix_text, seg_start, seg_end)
    if not ngram_ensure(env) then return nil end
    local ctor = _G.Candidate
    if not ctor then return nil end
    local ctx = context or ""
    if prefix_text and prefix_text ~= "" then ctx = ctx .. prefix_text end
    local ok, items = pcall(llm.ngram_sentences, code, ctx, NGRAM_PARAMS)
    if not ok or type(items) ~= "table" then return nil end
    local out = {}
    for _, it in ipairs(items) do
        local text = it.text
        if type(text) == "string" and text ~= "" then
            out[#out + 1] = {
                text = text,
                lead = it.lead,
                lead_end = it.lead_end,
                score = it.score,
                cand = ctor("ngram_group", seg_start, seg_end, text, ""),
            }
        end
    end
    return (#out > 0) and out or nil
end

-- 合并前缀门（2026-11-24 定案；纯计算，供 filter 与冒烟/排障直测）：
--   gen = 组句结果（top-20，含 lead / lead_end / score / text）
--   b1  = 窗口融合序第 1 候选（含 start / _end / text）
-- 返回 lead, prob, endp；不满足 = nil。
-- 判据：top-20 按 lead 分组 softmax → argmax lead 的概率质量 ≥ p_thr；
-- b1 文本 == lead、span 对齐；**音节守卫**（2026-11-24 标定，取代码数）：
--   组句句子的字符数 = 该句覆盖的音节数（中文一字一音节），lead 字数 =
--   已覆盖音节；确认后剩余 ≥2 音节；**单音节 lead 例外（剩余 ≥1）**
--   ——单字词边界无歧义，实测该档精度 99.1%（lead≥2 音节 + 余 1 音节
--   只有 90.5%，因末音节会把前一个字抢到边界另一侧）。
-- 不用码数：全拼 1 音节 2–6 码、简拼 1 码、双拼固定 2 码/音节，混拼后
-- 码数与音节数无固定关系（旧「≥6 码 / 余 ≥4 码」是拍的，已退役）。
local function nchars(s)
    if utf8 and utf8.len then
        local n = utf8.len(s)
        if n then return n end
    end
    return #s
end
local function prefix_gate(gen, b1, seg_start, seg_end, p_thr)
    if not gen or #gen == 0 or not b1 then return nil end
    local n = seg_end - seg_start
    if n < 1 then return nil end
    local mx = -math.huge
    for _, it in ipairs(gen) do
        if is_finite_number(it.score) and it.score > mx then mx = it.score end
    end
    if mx == -math.huge then return nil end
    local mass, le_of, txt_of, tot = {}, {}, {}, 0
    for _, it in ipairs(gen) do
        local s = it.score
        if is_finite_number(s) and it.lead and it.lead_end then
            local w = math.exp(s - mx)
            tot = tot + w
            mass[it.lead] = (mass[it.lead] or 0) + w
            -- gen 按分数降序（ngram 序）→ 首见即该 lead 的最高分句
            le_of[it.lead] = le_of[it.lead] or it.lead_end
            txt_of[it.lead] = txt_of[it.lead] or (it.text or "")
        end
    end
    local lead, best = nil, -1
    for t, m in pairs(mass) do
        -- 同质量时按文本序取定（避免 pairs 顺序导致非确定性）
        if m > best or (m == best and lead and t < lead) then
            lead, best = t, m
        end
    end
    if not lead or tot <= 0 then return nil end
    local p = best / tot
    if p < (p_thr or prefix_confirm_p()) then return nil end
    local le = le_of[lead]
    if le < 0 or le >= n then return nil end     -- 必须是严格前缀
    -- 音节守卫（2026-11-24 真机定案）：**剩余必须 ≥2 音节**——单字 lead 的
    -- "余 1 例外"退役：`xiazai` 想在 xia 就确认「下」，剩 zai 只能出单字，
    -- 「下载」这个 2 字词被拆开（标定：该例外仅 +112 触发，去掉后精度
    -- 95.48% / 召回 40.23% / K=5 1935，几乎无损）。
    local st = nchars(txt_of[lead])
    local sr = st - nchars(lead)
    if st < 1 or sr < 2 then return nil end
    local s1pos, b1e = cand_span(b1)
    if b1.text ~= lead or s1pos ~= seg_start or b1e ~= seg_start + le then
        return nil
    end
    return lead, p, b1e
end
_G.llm_prefix_gate = prefix_gate

-- === Filter ===
return function(translation, env)
    -- 每次调用都从 schema 读取 enabled，确保重新部署后立即生效
    local sc = env.engine.schema.config
    local enabled = sc:get_bool("llm_rerank/enabled") or false

    -- 每次调用重读方案配置（2026-11-21 A3）：原模块级 cfg._inited 守卫每进程只
    -- 读一次，而 Lua state 进程级单例 → code_pattern/max_tokens/max_candidates/
    -- cpu_cores/debug_fusion/two_code_sentence 重部署后冻结到重启，"保存并生效"
    -- 改参数不生效（enabled 每键读、model_path processor 每键同步所以正常）。
    -- 改每调用重读后与 enabled 同模式；配置树查询微秒级，无性能顾虑
    init_config(env)

    -- DLL 日志目录跟随当前方案（2026-11-22 分目录）：g_log_dir 是进程级，
    -- load_llm 只在首次加载时设一次 → 切方案后 X 行会继续写旧方案目录。
    -- 这里按方案变化刷新（字符串比较级开销）
    if llm then
        local sdir = rerank_dir()
        if sdir and _G.llm_log_dir ~= sdir then
            dir_ensure2(sdir)
            llm.log_dir = sdir
            _G.llm_log_dir = sdir
        end
    end

    local input = env.engine.context.input or ""
    -- 整句模式取码（2026-11-22）：活动段切片。多段续打（前段已选定）时
    -- code_pattern 匹配/词频键/语料 W.code 都随切片；单段组合 = 全串
    -- （双拼与既有行为逐位一致）。input 本身保留给 composition 兜底路径。
    local seg_start, seg_end = resolve_segment(env, input)
    local code = input:sub(seg_start + 1, seg_end)
    local all = {}
    -- 限量收集（2026-11-22 卡死修复）：旧 while 全量收集强制引擎一次性
    -- 完整翻译所有候选——朙月大词库的候选爆炸主要来自连续声母简拼
    -- （全拼串的 completion 有限，简拼串海量），单码秒级 CPU
    -- （enabled=false 对照实测 40 倍差）→ 每键卡死。截断后引擎惰性
    -- 停在当前位置。break 即不再拉取，exhausted 不触发。
    -- 双重限制（源码版同构）：16 上限 + 30ms 时间预算（个数闸管收多少、
    -- 预算闸管贵不贵）。上限取 16（2026-11-23 wiki 全拼实测：真实引擎候选
    -- 序中正确候选位置 p95=2 / p99=7 / p99.9=20，16 覆盖 99.82% 词型、
    -- 99.92% 词频加权；32 的边际覆盖仅 +0.16pp，性价比不足）。
    local collect_start = os.clock()
    for cand in translation:iter() do
        table.insert(all, cand)
        if #all >= 16 then break end
        if (os.clock() - collect_start) > 0.03 then break end
    end
    local ctx_text, ctx_src = "", "rime"
    if _G.llm_context_get then
        ctx_text, ctx_src = _G.llm_context_get()
    end
    -- 去空白: 上文中允许字母存在 (英文/数字是合法上文)。
    -- 不需过滤尾部 ASCII: Rime 编码显示在候选窗, 不写入编辑器,
    -- 外挂读到的光标前文本不会包含编码字母 (微软拼音式 inline composition 才会)
    local context = (ctx_text or ""):gsub('%s+', '')
    -- 组合区已确认前缀（2026-11-23）：前缀软确认后这些词是确定 token，
    -- LLM 的 ctx 必须包含它们（§11.8 协同：CE(整句) = CE(P|C) + CE(R|C+P)）
    local prefix_text = ""
    if _G.llm_confirmed_prefix then
        local okp, pt = pcall(_G.llm_confirmed_prefix, env)
        if okp and type(pt) == "string" then prefix_text = pt end
    end
    local tick = _G.user_freq_tick or 0
    -- DLL 需先加载：match_code 用 std::regex；Lua 回退不支持 .{4} 量词。
    if enabled and not llm_loaded_for then
        load_llm(env)
    end
    -- 异步基建收割点（2026-11-22）：query 开头先收割最近完成的异步评分
    --（回填缓存 + 挂账补写）——同指纹重复 query（翻页/候选窗重建）即命中
    -- 0 LLM。收割与当前 query 的指纹无关（收割的是历史任务成果）。
    _G.llm_async_harvest()
    local pattern_ok = enabled and match_code_pattern(code) or false
    -- 常开语料 W：只在 enabled + pattern 匹配时尝试（部分输入码不落行）。
    local rec = enabled and pattern_ok
    local wid = rec and _G.llm_new_event("W", tick) or nil
    local engine_top = texts_of(all, 10)
    -- ═══ N-gram 组句候选前置注入（2026-11-23 第②段；2026-11-24 phrase-only）═══
    -- 生成 top-20 整句候选放在候选流最前（同文本去重），后面层1/准入/评分/
    -- 前缀判定沿用既有逻辑：它们 span == 活动段 → FM。组句**不参与 CE**
    -- （显示只置顶 ngram 序第 1，其余 19 条不上屏；top-20 分数供 lead 概率）。
    -- 只对 ≥4 码（≈2 音节）、纯小写字母、方案输出简体时启用；engine_top
    -- 保持引擎原序。
    -- 注入点开关态 gate：option_name 存在时按当前开关判定（显式开关方案）；
    -- 空 = simplifier 恒转换，恒可注入。
    local simp_on = true
    if _G.llm_simplifier_option and _G.llm_simplifier_option ~= "" then
        simp_on = env.engine.context:get_option(_G.llm_simplifier_option)
    end
    local gen = nil
    local genset = nil   -- 只放"显示置顶"的那 1 条组句文本（2026-11-24 定案）
    -- 2026-11-24 用户定案：无上文也要组句——前缀确认此时按"剩余项融合"
    -- 判定（见下方 freq_only），组句侧证据照常需要。
    if cfg.sentence_mode and _G.llm_ngram_group and simp_on and pattern_ok
            and #code >= 4 and code:match("^[a-z]+$") then
        gen = ngram_make(env, code, context, prefix_text, seg_start, seg_end)
        if gen then
            -- 只注入/抑制显示的那一条（ngram 序第 1）；其余只供前缀概率。
            -- 2026-11-24 真机报障（象/向/想 等整字从候选里消失）：旧实现把
            -- top-20 全部文本都登记进 genset 参与抑制/去重，而显示端只留 1
            -- 条——与组句 top-20 同名的引擎候选被整条删掉且无替代。
            local merged, seen_t = {}, {}
            genset = { [gen[1].text] = true }
            seen_t[gen[1].text] = true
            merged[1] = gen[1].cand
            for _, c in ipairs(all) do
                if not seen_t[c.text] then merged[#merged + 1] = c end
            end
            all = merged
        end
    end
    -- 清掉上一轮快照，避免未重排/失败路径的陈旧窗口被 C 误引用。
    _G.llm_last_window = nil

    if #all < 2 then
        live("S|" .. os.date("%H:%M:%S") .. "|few_candidates|" ..
             live_esc(code) .. "|-")
        if wid then
            _G.llm_write_w(wid, ctx_src, code, context, engine_top, {}, {},
                           tick, "skip", "few_candidates", false, "")
        end
        for _, c in ipairs(all) do yield(c) end
        return
    end

    -- enabled false → 原样透传，不推理（常开语料也不写 W）
    if not enabled then
        for _, c in ipairs(all) do yield(c) end; return
    end

    if not llm then
        if wid then
            _G.llm_write_w(wid, ctx_src, code, context, engine_top, {}, {},
                           tick, "skip", "model_loading", false, "")
        end
        live("S|" .. os.date("%H:%M:%S") .. "|model_loading|" ..
             live_esc(code) .. "|-")
        for _, c in ipairs(all) do yield(c) end; return
    end

    -- 触发条件：编码串是否匹配 code_pattern（2026-09-30 取代 min/max_code_len 区间）
    -- 全串匹配（同 Rime auto_select_pattern 语义）。优先用 DLL 的 std::regex
    -- （与源码版 boost::regex 同一套 ECMAScript 语法）；DLL 不提供该函数时
    -- 回退 Lua 模式——两种写法对 .{4} / .{4,} / .{3,4} / [abcde]{4} 等价。
    if not pattern_ok then
        live("S|" .. os.date("%H:%M:%S") .. "|pattern|" .. live_esc(code)
             .. "|-")
        for _, c in ipairs(all) do yield(c) end; return
    end

    -- 无上文（2026-11-24 用户定案）：CE 不可算，但**前缀确认照常**——融合分
    -- 按剩余项（β·log1p(eff) + log(uni+1) + 词码对修正）计算，组句 lead 与
    -- 窗口融合序第 1 比较。只在整句模式 + 前缀确认 + 组句都开且组句有结果时
    -- 走这条（其余保持旧行为：跳过，W 记 ctx_empty）。
    -- 组合区已确认前缀 prefix_text 非空 = 已有临时上文 → 不进 freq_only，
    -- 下一键自动回到完整 CE 融合（"选一次 phrase 就有了上文"）。
    local freq_only = (context == "" and prefix_text == "" and gen ~= nil
            and _G.llm_prefix_confirm)
    if context == "" and prefix_text == "" and not freq_only then
        if wid then
            _G.llm_write_w(wid, ctx_src, code, context, engine_top, {}, {},
                           tick, "skip", "ctx_empty", false, "")
        end
        live("S|" .. os.date("%H:%M:%S") .. "|ctx_empty|" ..
             live_esc(code) .. "|" .. live_esc(ctx_src))
        for _, c in ipairs(all) do yield(c) end; return
    end
    if freq_only then
        live("S|" .. os.date("%H:%M:%S") .. "|freq_only|" ..
             live_esc(code) .. "|" .. live_esc(ctx_src))
    end
    -- ═══ 层1: 全体候选 用户词频打分重排（v3 两层重排, 2026-11-07 定案）═══
    -- 全体候选 S1 = FREQ_BETA·log1p(eff) + 累计 Unigram 项, 稳定降序（同分保引擎序）,
    -- 取前 max_candidates 进 LLM 评分（层2 三项融合重排）, 其余按层1 序透传。
    -- 目标在层1 前 k 外 → 必然不在首位（评测 sweep_2layer 同语义, 全窗参评）。
    -- 文件序无关性: 引擎调频与否仅影响冷词同分打破（目标卷入 ≤0.05pp 窗,
    -- 实测见研究库 §三十三·附 6）。
    local layer1 = {}
    local s1_of = {}
    do
        -- 词码对记账（2026-11-13 用户定案）: eff/uni 查询键 = (候选, 当前
        -- 窗码)——多音词属不同词条, 每个码对只看自己的历史（wiki 59,681
        -- 窗: 分键全面更优 −0.34~−0.73pp 随龄扩大）。2026-11-22 整句模式:
        -- 窗码 = 活动段切片 code（多段续打正确；单段 == 全串不变）。
        local fe, bt = _G.user_freq_eff, _G.user_unigram_term
        for i, c in ipairs(all) do
            local n = fe and fe(c.text, code) or 0
            local s = FREQ_BETA * math.log(1 + n)
            if bt then s = s + bt(c.text, code) end
            layer1[i] = { c = c, s = s, idx = i }
            s1_of[c.text] = s
        end
        table.sort(layer1, function(a, b)
            if a.s ~= b.s then return a.s > b.s end
            return a.idx < b.idx   -- 稳定: 同分保引擎序
        end)
    end
    -- 词码对分数表（2026-11-21 解耦后只含负分扣分修正）：不参与窗口
    -- 准入，仅融合时叠加（评分窗内生效）。分数表在窗口准入前读一次，
    -- 本窗融合复用同一份。
    local pftbl = pairfix_table()
    local cands = {}
    local l1win = {}
    local win_seen = {}
    local function add_win(e)
        if #cands >= cfg.max_candidates then return end
        local t = e.c.text
        if win_seen[t] then return end
        win_seen[t] = true
        cands[#cands + 1] = t
        l1win[#l1win + 1] = t
    end
    -- 整句模式准入（2026-11-22 定案取代 two_code_sentence 满长规则）：候选
    -- 覆盖整个活动段（FM）才进窗——"音节数一致"由引擎 lattice 保证；部分
    -- 覆盖候选不进窗、不算 CE。FM 判定三级兜底（见 cand_span 注释）：候选
    -- 无 start/_end 时回退旧长度规则 词长==⌊码长/2⌋（两码方案保真）。
    local sent_on = cfg.sentence_mode
    local fm_set = nil     -- 候选对象 → FM 布尔（sent_on 时有效）
    if sent_on then
        local span_ok = true
        fm_set = {}
        for _, c in ipairs(all) do
            local s, e = cand_span(c)
            if not s then span_ok = false; break end
            fm_set[c] = (s == seg_start and e == seg_end)
        end
        if not span_ok then
            local elen = math.floor(#code / 2)
            fm_set = nil    -- span 不可用：回退旧长度规则（码 <2 = 不重排）
            if elen >= 1 then
                fm_set = {}
                for _, c in ipairs(all) do
                    fm_set[c] = (utf8.len(c.text or "") or 0) == elen
                end
            end
        end
    end
    local function is_fm(c)
        if not sent_on then return true end   -- 关闭态：不区分（混合语义）
        if fm_set then return fm_set[c] == true end
        return false
    end
    -- 统一准入（2026-11-24 用户定案，取代 2026-11-22「满覆盖优先占满窗」）：
    -- 层1 词频在**等长词 + 子词**里统一取前 max_candidates 进评分窗，窗内全部
    -- 真算 CE——与字词模式完全一致。等长 ≠ 概率高，等长词不再结构性在前。
    -- 组句不参与准入（不占席、不评分），显示端只置顶 ngram 序第 1。
    -- 子词复用分通道（pm_texts / reuse）随之退役：子词已进窗拿真分。
    for _, e in ipairs(layer1) do
        if not (genset and genset[e.c.text]) then add_win(e) end
    end
    local w_written = false
    -- 评分结果缓存已删除（2026-11-11 用户定案）：同 (上文+编码) 的复用在
    -- 生产里命中率极低（每个新词的上文都变），却要维护一整套失效逻辑（编辑键清
    -- 缓存/候选集变化重放），删掉以简化。每次触发都是真实推理。
    -- 满覆盖准入后窗不足 2 个（不足即空着的极端形态）：无重排意义、整窗跳过
    -- 评分（与源码版一致显式发 S 事件，避免静默零输出）——ok 保持 nil，
    -- 下游走层1 序展示。skip 名沿用 full_len_lt2（语料解析兼容）。
    if sent_on and #cands < 2 then
        live("S|" .. os.date("%H:%M:%S") .. "|full_len_lt2|" ..
             live_esc(code) .. "|" .. live_esc(ctx_src))
        if wid then
            _G.llm_write_w(wid, ctx_src, code, context, engine_top, l1win,
                           {}, tick, "skip", "full_len_lt2", false, "")
            w_written = true
        end
        cands = {}
    end
    -- ═══ 评分（2026-11-22 异步基建重构：snap 快照中心）═══
    -- snap = 评分快照 {cands, scores, ce3, segs, prep, ctx_used, ev_ms}，四路
    -- 来源：①缓存命中（同指纹重复 query，0 LLM）②整句模式异步投递（不等待
    -- → 层1 序 + 挂账，评分结果由后续 query 收割回填）③字词模式 submit+wait
    -- （immediate 跳过去抖 + 250ms 上限——与既有同步评分等价的延迟面，当前
    -- 词重排零回归）④旧 DLL 回退（无 async_* 接口时同步 llm.score 原路径）。
    -- 融合块统一从 snap 读 CE 三分量/段显/ctx_used/prep。
    local ok, result, scores
    local snap = nil
    local ev_ms = 0   -- 本轮评分耗时（实时调试 L 行用；异步路径 = 纯评分耗时）
    local sent_pending = false   -- 整句模式已投递挂账（本轮层1 序输出）
    local prep_flag = "0"
    if #cands >= 2 and not freq_only then
        -- 提交清单 = 评分窗（≤max_candidates）。组句候选**不进评分**（2026-11-24
        -- 定案：phrase-only——组句只提供文本与"自信前缀"概率，位次证据来自
        -- 窗口融合序；句子本身不再参与 CE，显示 = ngram 序首选 1 条）。
        local submit = {}
        for _, t in ipairs(cands) do submit[#submit + 1] = t end
        local fp = make_fp(context, submit, nil, prefix_text)
        snap = res_cache[fp]
        if snap and not snap.scores then snap = nil end
        if not snap and llm.async_submit then
            -- 评测立即开跑（两模式都不走去抖）：短预算等待后再决定
            -- 是否挂账——整句模式此前"投递即走"，当前键只能显示层1 序，
            -- 快照只在同指纹重查时才用上；真机实测连续整句打字 LLM 结果
            -- 从未上屏（2026-11-23 修）。
            local okp, fp_r = pcall(llm.async_submit, context, submit,
                                    true, {}, prefix_text)
            if okp and fp_r then
                if sent_on then
                    -- 整句模式：短预算同步等待（SENTENCE_WAIT_MS）。正常
                    -- 打分在预算内完成 → 当前键就用 LLM 序（子词复用分同时
                    -- 就位，前缀自动确认才可能触发）；超时 → 回退挂账
                    -- pending（本轮层1 序，后续收割点补写语料/缓存）。
                    local okw, res = pcall(llm.async_wait, fp_r,
                                           sentence_wait_ms())
                    if okw and type(res) == "table" and res.scores then
                        res_cache[fp_r] = res
                        snap = res
                        cache_trim()
                    else
                        pending[fp_r] = { wid = wid, code = code,
                                          ctx_src = ctx_src, context = context,
                                          engine_top = engine_top,
                                          l1win = l1win, tick = tick }
                        cache_trim()
                        sent_pending = true
                    end
                else
                    -- 字词模式：同步等待评分完成（等价既有同步评分——当前
                    -- 词重排零回归；wait 超时 = skip，评分线程继续跑完，
                    -- 后续 query 可收割）
                    local okw, res = pcall(llm.async_wait, fp_r, 250)
                    if okw and type(res) == "table" and res.scores then
                        res_cache[fp_r] = res
                        snap = res
                        cache_trim()
                    end
                end
            end
        end
        if not snap and not sent_pending and not llm.async_submit then
            -- 旧 DLL 回退：同步评分（既有路径原样）
            do
            local t0 = os.clock()
            ok, result = pcall(function()
                return llm.score(context, cands, prefix_text)
            end)
            local elapsed_ms = (os.clock() - t0) * 1000
            ev_ms = elapsed_ms
            if ok and type(result) == "table" then
                scores = get_scores(cands)
            end

            lat_count = lat_count + 1
            if elapsed_ms > lat_max then lat_max = elapsed_ms end
            end   -- if #cands >= 2（满长准入窗 <2 跳过评分）
        end
    end

    if snap then
        ev_ms = snap.ev_ms or 0
        prep_flag = snap.prep and "1" or "0"
    end

    -- 失败原因（用于 W skip）；snap 成功或 freq_only（无上文）时为空
    local skip_reason = nil
    if #cands >= 2 and not snap and not freq_only then
        if sent_pending then
            skip_reason = "async_pending"    -- 已投递待收割（本轮层1 序）
        elseif llm.async_submit then
            -- 异步路径未拿到结果（wait 超时 / 任务不成立）
            local okr, ready = pcall(function() return llm.is_ready() end)
            skip_reason = (okr and ready) and "async_timeout" or "not_ready"
        elseif not ok then
            skip_reason = "score_failed"
        elseif type(result) ~= "table" then
            local okr, ready = pcall(function() return llm.is_ready() end)
            skip_reason = (okr and ready) and "ctx_short" or "not_ready"
        elseif not scores then
            skip_reason = "scores_nil"
        end
    end

    local live_ready = "n/a"
    local dbg = cfg.debug_fusion and {} or nil
    if dbg then
        local okr, r = pcall(function() return llm.is_ready() end)
        if okr then live_ready = r and "1" or "0" end
        if not snap and not freq_only then
            local okp, ph = pcall(function() return llm.prep_hit end)
            prep_flag = (okp and ph) and "1" or "0"
        end
        if skip_reason then
            live("S|" .. os.date("%H:%M:%S") .. "|" .. skip_reason .. "|" ..
                 live_esc(input) .. "|" .. live_esc(ctx_src))
        end
    end

    if freq_only or snap or (ok and result) then
        if snap and not result then
            -- 快照路径（缓存命中 / 字词 wait）：cands = 提交序文本数组。
            -- 融合块对 ordered 全量重排，初序仅影响浮点精确同分的打破序
            --（旧 DLL = CE 降序，快照路径 = 层1 提交序——同分罕见，v1 接受）
            result = snap.cands
            scores = snap.scores
        end
        if freq_only and not result then
            -- 无上文：无评分，窗口初序 = 层1 序（cands 已是准入序）
            result = cands
        end
        local seen = {}
        local ordered_all = {}
        for i = 1, #result do
            for _, c in ipairs(all) do
                if c.text == result[i] and not seen[c.text] then
                    seen[c.text] = true
                    table.insert(ordered_all, c)
                    break
                end
            end
        end
        -- 组句候选不进评分、也不在窗口序里（2026-11-24 phrase-only 定案）：
        -- ordered = 窗口融合序；组句仅以 ngram 序首选置顶。
        local ordered = ordered_all
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
        --      布尔开关直接实现（2026-11-22 起为 sentence_mode 整句模式——
        --      满覆盖候选在窗口准入时结构性占满评分窗）。
        --   ④ 冷启动 eff≡0 且 uni 无计数时自动退化为 score 序, 成熟期三项叠加。
        --   ⑤ 词码对分数修正（2026-11-17 有符号表）: 正分 = 固定首选/次选
        --      （+200/+100，不受 fade）；负分 = pairfix 降噪（原 −λ，保留
        --      fade）。**只对已算 CE 的候选生效**（2026-11-24 用户定案：
        --      pairfix 修的是 CE 系统性偏差，无 CE 分支/无上文 freq_only 不叠
        --      修正）；debug 行尾 修正%+g，C 行尾追加
        --      sdelta（有符号；旧 pf 字段仍为负分幅度，兼容旧查看器）。
        -- 失败哨兵分 (≤-1e9) 排尾部不参与; 同分稳定保序 (融合序)。
        local fused_scores = nil
        -- freq_only（无上文）：scores 为 nil，融合只剩词频/词码对项——
        -- 下方 else 分支按 s1_of 计算，min_valid 为 nil（加 0）。
        if #ordered > 1 and (scores or freq_only) then
            local freq_eff = _G.user_freq_eff
            -- CE 三分量（2026-11-11 协议 v2）：text → {c1,c2,c3} 原始分量
            --（未乘权重）。异步基建（2026-11-22）：快照路径从 snap 读（避免
            -- 与评分线程的"最近一次评分"竞争）；旧 DLL 同步路径走 getter
            local ce3map = nil
            if snap then
                ce3map = snap.ce3
            elseif llm.get_ce3 then
                local okc, m = pcall(llm.get_ce3)
                if okc and type(m) == "table" then ce3map = m end
            end
            -- token 边界段显（2026-11-21 协议 v7）：text → "cm/ak"——段只落
            -- 在 token 边界 ∩ 字符边界（单 token 多字不劈，字内多 token
            -- 合并不劈字）；旧 DLL 无此函数时静默缺省（"词"列显示原词）
            local segmap = nil
            if snap then
                segmap = snap.segs
            elseif llm.get_seg then
                local oks, ms = pcall(llm.get_seg)
                if oks and type(ms) == "table" then segmap = ms end
            end
            -- 无 CE 分候选的融合（2026-11-13 用户定案，取代 2026-11-07
            -- "回退后两项和"）: CE 取窗内已算 CE 的**最低分**（score =
            -- −CE 负值域，最低分 = 最差证据 → 该候选排到窗底但保留与
            -- 层1 的正常耦合）。旧语义（融合=层1 分）会让无 CE 候选以
            -- S1=0 压过全部负分候选跳首选——aki 实况窗两例实证。
            -- 触发器随时代更替：当年 = tokenizer 打不出「𬤊」（2026-11-15
            -- llama 升级后已可表示——2026-11-21 全词典 8133 单字核查，
            -- 99.7% 单 token、余 24 字 2 token，无一不可表示）；现在 =
            -- 评分批次 decode 失败的逐候选哨兵分（score_batch step2/3
            -- 失败路径 + 失败自愈）。全窗无有效 CE 时 min_valid 为 nil、
            -- 加 0 = 自然回退层1 序。
            local min_valid = nil
            for _, c in ipairs(ordered) do
                local s = scores and scores[c.text]
                if is_valid_llm_score(s)
                        and (not min_valid or s < min_valid) then
                    min_valid = s
                end
            end
            fused_scores = {}
            -- 本窗已在窗口准入前读过同一份表（正分占位用），这里复用。
            local arr = {}
            for i, c in ipairs(ordered) do
                local s = scores and scores[c.text]
                if is_valid_llm_score(s) then
                    local n = freq_eff and freq_eff(c.text, code) or 0
                    local u1_term = _G.user_unigram_term
                            and _G.user_unigram_term(c.text, code) or 0
                    local delta = pairfix_delta(pftbl, c.text, code)
                    local t = s + FREQ_BETA * math.log(1 + n) + u1_term
                            + delta
                    fused_scores[c.text] = t
                    arr[i] = { c = c, t = t, idx = i }
                    if dbg then
                        dbg[c.text] = { ce = s, eff = n,
                                        fb = FREQ_BETA * math.log(1 + n),
                                        u1 = u1_term,
                                        pf = delta < 0 and -delta or nil,
                                        sdelta = delta ~= 0 and delta or nil,
                                        uni = _G.user_uni_count
                                              and _G.user_uni_count(c.text,
                                                                    code) or 0,
                                        ce3 = ce3map and ce3map[c.text] or nil,
                                        fused = t, cerank = i }
                    end
                else
                    -- 无 CE 分（评分失败/无法表示/无上文 freq_only）→ 层1 分
                    -- + 窗内最低 LLM 分（压制到窗底, 保留层1 耦合; 见上注）。
                    -- 无上文时 min_valid=nil → 融合 = β·log1p(eff) +
                    -- log(uni+1)（2026-11-24 用户定案）。
                    -- **不叠词码对修正**：pairfix 修的是 CE 的系统性偏差，
                    -- 没有 CE 就无从修（2026-11-24 用户定案）。
                    local s1 = s1_of[c.text]
                    local t = (s1 or -math.huge)
                            + (min_valid and min_valid or 0)
                    fused_scores[c.text] = t
                    arr[i] = { c = c, t = t, idx = i }
                    if dbg then
                        local n = freq_eff and freq_eff(c.text, code) or 0
                        local u1_term = _G.user_unigram_term
                                and _G.user_unigram_term(c.text, code) or 0
                        dbg[c.text] = { ce = s, eff = n,
                                        fb = FREQ_BETA * math.log(1 + n),
                                        u1 = u1_term,
                                        uni = _G.user_uni_count
                                              and _G.user_uni_count(c.text,
                                                                    code) or 0,
                                        ce3 = ce3map and ce3map[c.text] or nil,
                                        fused = t, cerank = i,
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
        -- ═══ 前缀软确认：合并单一路线（2026-11-24 定案）═══
        -- 组句给文本（top-20 按 lead 分组的 softmax 概率 ≥ 0.95）∧ 该文本是
        -- 窗口融合序第 1（span 对齐、文本一致）→ 挂起。窗口路径 A（margin）
        -- 与句级 CE 序分支已退役：融合序位次本身就是 CE(+词频) 的全序比较，
        -- 再叠 margin 净收益反降（研究库）；θ 与单字倍数整条退役。组句返回
        -- 空（码切在音节中间，占 39.5%）的窗不再自动确认。守卫在
        -- prefix_gate 内（音节单位：剩余 ≥2；单音节 lead 例外 ≥1）——
        -- 链式确认同样逐次重新判门（每次确认后下一键的 filter 会在更短的码
        -- 上重算，不沿用旧 pending）。
        if sent_on and _G.llm_prefix_confirm and gen and fused_scores
                and #ordered >= 1 then
            local lead, prob, endp =
                prefix_gate(gen, ordered[1], seg_start, seg_end)
            if lead then
                _G.llm_pending_confirm = {
                    input = input, text = lead, endp = endp,
                }
                if dbg then
                    live("G|" .. os.date("%H:%M:%S") .. "|"..
                         live_esc(code) .. "|" .. live_esc(lead) ..
                         "|p=" .. string.format("%.3f", prob))
                end
            end
        end
        -- ═══ 最终序（2026-11-24 phrase-only 定案）═══
        -- 组句 ngram 序首选 1 条置顶（句子不再参与 CE 重排）→ 窗口融合序
        -- （等长词与子词统一概率序）→ 窗外层1 序。三块输出与"匹配在前、
        -- 部分在后"不变量早已退役。组句文本不进窗口/评分，故层1 尾块必须
        -- 显式排除 genset（否则未评分的组句会以尾部身份重复出现）。
        local best_gen = (gen and #gen > 0) and gen[1] or nil
        local out = {}
        if best_gen then out[#out + 1] = best_gen.cand end
        for _, c in ipairs(ordered) do out[#out + 1] = c end
        for _, e in ipairs(layer1) do
            if not seen[e.c.text]
               and not (genset and genset[e.c.text]) then
                out[#out + 1] = e.c
            end
        end
        -- 组句首选可能与窗口候选同文本（注入时组句版已替换引擎版）——按
        -- 文本去重、保首现（首选在前），避免同一词出现两次。
        do
            local u, ded = {}, {}
            for _, c in ipairs(out) do
                if not u[c.text] then
                    u[c.text] = true
                    ded[#ded + 1] = c
                end
            end
            out = ded
        end
        -- 调试行 full 标志（协议字段，win 行 = FM=1）按整句模式 FM 判定补：
        if sent_on and dbg then
            for _, c in ipairs(out) do
                if dbg[c.text] then dbg[c.text].full = is_fm(c) end
            end
        end

        -- 诊断输出: 逐候选明细 + 名次变化汇总
        if dbg then
            local final_rank = {}
            for i, c in ipairs(ordered) do final_rank[c.text] = i end
            local all_rank = {}
            for i, c in ipairs(all) do all_rank[c.text] = i end

            -- 实时调试（2026-11-10；2026-11-11 协议 v2：频两项改发原始值
            -- eff/uni——"显示未乘系数的数字"，尾接 CE 三分量 ce1/ce2/ce3
            -- （未乘 kCeW 权重，查看器点击 CE 单元格展开）；L 尾加 prep=预解码命中）：
            -- L 头行（完整上文，不截断）+ 逐候选 C 行（含层1 透传尾窗，上限
            -- 20 行；win=1 层2窗内/0 尾窗透传，ce 空串=无 CE 分，fin=最终
            -- 输出位置）。与 debug.txt 人类格式互补，供查看器渲染。
            local prep = prep_flag
            -- 协议 v4（2026-11-12）：L 尾追加 ctx_used = 推理实际使用的
            -- 上文尾部文本（去空白上文中末 ≤max_ctx token 的原文段，
            -- get_ctx_used 容错旧 DLL；查看器据此灰显未用前缀）
            local cu = freq_only and "" or (snap and snap.ctx_used)
            if cu == nil then
                local okcu, cu2 = pcall(function() return llm.get_ctx_used() end)
                cu = (okcu and type(cu2) == "string") and cu2 or ""
            end
            local ctxused = live_esc(cu)
            -- L 第 3 字段原为评分缓存 HIT/MISS——缓存已删（2026-11-11），
            -- 保留位置发 "-"（旧查看器显示"评缓 -"，字段数不变免错位）
            -- 尾两字段: prep=预解码命中, ctx_used=推理用尾部。
            -- n_seen 字段已删（2026-11-17 用户定案：不参与打分, 连记录
            -- 一并取消）——查看器按字段数兼容旧行（>12 取第 13 字段，
            -- 否则第 12 字段）。
            live(string.format("L|%s|%s|%s|%s|%s|%s|%.0f|%s|%d|%s|%s",
                os.date("%H:%M:%S"), live_esc(code), "-",
                live_esc(ctx_src), live_esc(context),
                tostring(_G.user_freq_tick), ev_ms, live_ready, #cands, prep,
                ctxused))
            local winset = {}
            for _, w in ipairs(l1win) do winset[w] = true end
            local emitted = 0
            local function live_c(c, fin)
                if emitted >= 20 then return end
                emitted = emitted + 1
                local d = dbg[c.text]
                local d3 = d and d.ce3
                live(table.concat({
                    "C", tostring(all_rank[c.text] or 0), live_esc(c.text),
                    live_fmt3(s1_of[c.text]),
                    (d and d.ce and d.ce > -1e9) and live_fmt3(d.ce) or "",
                    d and live_fmt3(d.eff) or "",
                    tostring(d and d.uni or 0),
                    d and live_fmt3(d.fused) or "",
                    (d and d.full) and "1" or "0",
                    tostring(d and d.cerank or 0),
                    tostring(fin), winset[c.text] and "1" or "0",
                    d3 and live_fmt3(d3[1]) or "",
                    d3 and live_fmt3(d3[2]) or "",
                    d3 and live_fmt3(d3[3]) or "",
                    d and live_fmt3(d.fb) or "",   -- 词频得分 β·log1p(eff)
                    d and live_fmt3(d.u1) or "",   -- 累计得分 log(p1)
                    -- v5: 旧 pf = 负分幅度（仅扣分，0=未命中），保留给旧查看器
                    d and live_fmt3(d.pf or 0) or "0",
                    -- v6 (2026-11-17): 有符号词码对修正分（+200/+100/−5/0）
                    d and live_fmt3(d.sdelta or 0) or "0",
                    -- v7 (2026-11-21): token 边界段显（"词"列：单 token 词原样、
                    -- 真实多 token 词段间 '/'；尾窗透传无 d → 空串，查看器显示原词）
                    segmap and segmap[c.text] or ""
                }, "|"))
            end
            for i, c in ipairs(out) do live_c(c, i) end
            -- debug P/D：只写语料没有的字段；词/候选序在语料 W，
            -- 靠 wid 关联；不写 debug 文件的人类可读块。
            _G.llm_debug_p(wid, ev_ms, prep_flag == "1")
            for i, c in ipairs(out) do
                local d = dbg[c.text]
                if d then
                    local d3 = d.ce3 or {}
                    _G.llm_debug_d(wid, i, d.ce, d3[1], d3[2], d3[3],
                                   d.eff, d.fb, d.u1, d.full, d.fused,
                                   d.sdelta, d.cerank, i)
                end
            end
        end
        -- 常开语料 W ok（最终序 + 引擎前 10 + 层1 窗）
        -- flags 追加 nofreq（2026-11-24）：本窗无 CE、融合只含词频剩余项
        if wid and not w_written then
            _G.llm_write_w(wid, ctx_src, code, context, engine_top, l1win,
                           texts_of(out, 20), tick, "ok", "",
                           prep_flag == "1", freq_only and "nofreq" or "")
            w_written = true
        end
        -- 来源徽章已删（2026-11-10 用户定案：实时调试窗口上线——上文来源/
        -- 内容与逐候选分数都在调试窗口看，候选窗保持干净、不再动 comment；
        -- 固定候选提示亦归拼读双拼 pin_filter.lua，2026-11-21 解耦）
        -- 输出 = 组句首选 1 条 + 窗口融合序 + 窗外层1 序（2026-11-24 定案）。
        for _, c in ipairs(out) do yield(c) end
    else
        -- 评分未就绪/失败: 按层1 序展示（2026-11-24 统一口径：组句首选 1 条
        -- 置顶 = ngram 序首选，其余全部层1 序；不再分 FM/子词两块）。
        if wid and not w_written then
            _G.llm_write_w(wid, ctx_src, code, context, engine_top, l1win,
                           {}, tick, "skip", skip_reason or "score_failed",
                           prep_flag == "1", "")
            w_written = true
        end
        if sent_on then
            if gen and gen[1] then yield(gen[1].cand) end
            for _, e in ipairs(layer1) do
                if not (genset and genset[e.c.text]) then yield(e.c) end
            end
        else
            for _, e in ipairs(layer1) do yield(e.c) end
        end
    end
end
