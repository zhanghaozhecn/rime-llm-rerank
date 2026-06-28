-- llm_context.lua — 累积上屏历史，用 CommitHistory API 拿到真正上屏文字

local MAX_CHARS = 20  -- 充足上文缓冲，服务端按5token截断保证延迟稳定
local IDLE_CLEAR_SEC = 20

local history = {}
local last_commit_time = 0
local last_app = ""
local last_back_text = ""  -- 直接用 ch:back() 的 text 去重，不依赖 count

local function get_current_app()
    local ok, result = pcall(function()
        return rime_api.get_property(0, "client_app")
    end)
    if ok and type(result) == "string" then return result end
    return "unknown"
end

local function processor(key, env)
    local ctx = env.engine.context
    local now = os.time()

    -- 切换应用 → 清空
    local current_app = get_current_app()
    if current_app ~= last_app and last_app ~= "" then
        history = {}
        last_back_text = ""
    end
    last_app = current_app

    -- 时间衰减
    if last_commit_time > 0 and (now - last_commit_time) > IDLE_CLEAR_SEC then
        history = {}
        last_back_text = ""
    end

    -- 用 CommitHistory:back() 直接检测新上屏（不依赖 size/count）
    local ch = ctx.commit_history
    if ch then
        local last = ch:back()
        if last and last.text and #last.text >= 3 then
            if last.text ~= last_back_text then
                -- 新上屏文字
                last_back_text = last.text
                if #history == 0 or history[#history] ~= last.text then
                    table.insert(history, last.text)
                    -- 按实际字节数截断（无分隔符）
                    local total = 0
                    for _, t in ipairs(history) do total = total + #t end
                    while total > MAX_CHARS * 3 and #history > 1 do
                        total = total - #history[1]
                        table.remove(history, 1)
                    end
                end
                last_commit_time = now
                -- 调试日志
                local TEMP = os.getenv("TEMP") or "C:\\Windows\\Temp"
                local f = io.open(TEMP .. "\\rime_ctx_debug.txt", "a")
                if f then
                    f:write(string.format("[ctx] +\"%s\"  hist_len=%d  total_bytes=%d\n",
                        last.text, #history, #table.concat(history, "")))
                    f:close()
                end
            end
        end
    end

    return 2
end

local function get_context()
    if last_commit_time > 0 and (os.time() - last_commit_time) > IDLE_CLEAR_SEC then
        history = {}
        last_back_text = ""
    end
    return table.concat(history, "")  -- 无分隔符，纯汉字连写
end

_G.llm_context_get = get_context
return processor
