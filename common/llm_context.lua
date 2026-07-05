-- llm_context.lua — per-app context with to_table for 标点顶屏
-- 分应用隔离（RIME 原生 rime_api）。
-- clear_key: 配置在 llm_rerank 下，设为按键名（如 "grave"）启用，默认 ""=不启用。

local MAX_CHARS = 30
local clear_key = ""
local inited = false

local apps = {}
local current_app = ""

local function get_current_app()
    local ok, result = pcall(function()
        return rime_api.get_property(0, "client_app")
    end)
    if ok and type(result) == "string" then return result end
    return "unknown"
end

local function get_app_state(app)
    if not apps[app] then
        apps[app] = { history = {}, _size = 0 }
    end
    return apps[app]
end

local function processor(key, env)
    if not inited then
        inited = true
        local sc = env.engine.schema.config
        local ns = sc:get_map("llm_rerank")
        if ns then
            local v = ns:get_value("clear_key")
            if v and v:get_string() then clear_key = v:get_string() end
        end
    end

    if key:release() then return 2 end

    local ctx = env.engine.context

    -- 自定义快捷键清除当前应用上文（默认 ""=不启用）
    if clear_key ~= "" and key:repr() == clear_key then
        local app = get_current_app()
        local st = get_app_state(app)
        st.history = {}
        local ch = ctx.commit_history
        if ch then
            local all = ch:to_table()
            if all then st._size = #all end
        end
        return 1  -- kAccepted
    end

    local app = get_current_app()
    current_app = app
    local st = get_app_state(app)

    local ch = ctx.commit_history
    if ch then
        local all = ch:to_table()
        if all and #all > st._size then
            for i = st._size + 1, #all do
                local entry = all[i]
                if entry and entry.text and #entry.text >= 1 then
                    if #st.history == 0 or st.history[#st.history] ~= entry.text then
                        table.insert(st.history, entry.text)
                        local total_bytes = 0
                        for _, t in ipairs(st.history) do total_bytes = total_bytes + #t end
                        while total_bytes > MAX_CHARS * 3 and #st.history > 1 do
                            total_bytes = total_bytes - #st.history[1]
                            table.remove(st.history, 1)
                        end
                    end
                end
            end
            st._size = #all
        end
    end

    return 2
end

local function get_context()
    local st = get_app_state(current_app)
    return table.concat(st.history, "")
end

_G.llm_context_get = get_context
return processor
