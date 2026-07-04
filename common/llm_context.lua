-- llm_context.lua — per-app context with to_table for 标点顶屏

local MAX_CHARS = 30
local IDLE_CLEAR_SEC = 10
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
        apps[app] = { history = {}, _size = 0, last_time = 0 }
    end
    return apps[app]
end

local function processor(key, env)
    if not inited then
        inited = true
        local sc = env.engine.schema.config
        local ns = sc:get_map("llm_rerank")
        if ns then
            local v = tonumber(ns:get_value("idle_clear_sec"))
            if v then IDLE_CLEAR_SEC = v end
        end
    end

    local ctx = env.engine.context
    local now = os.time()
    local app = get_current_app()
    current_app = app
    local st = get_app_state(app)

    if st.last_time > 0 and (now - st.last_time) > IDLE_CLEAR_SEC then
        st.history = {}
        -- 同步 _size 到当前 commit_history 长度，防止下面把旧记录重新读入
        local ch0 = ctx.commit_history
        if ch0 then
            local all0 = ch0:to_table()
            if all0 then st._size = #all0 end
        end
    end

    local ch = ctx.commit_history
    if ch then
        local all = ch:to_table()
        if all and #all > st._size then
            local new_entries = {}
            for i = st._size + 1, #all do
                local entry = all[i]
                if entry and entry.text and #entry.text >= 1 then
                    if #st.history == 0 or st.history[#st.history] ~= entry.text then
                        table.insert(st.history, entry.text)
                        table.insert(new_entries, entry.text)
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
            st.last_time = now
            -- debug: log only what was added this key event
            if #new_entries > 0 then
                local f = io.open((os.getenv("TEMP") or "C:\\Windows\\Temp") .. "\\rime_ctx_debug.txt", "a")
                if f then
                    f:write(string.format("[ctx] +%s\n", table.concat(new_entries, " ")))
                    f:close()
                end
            end
        end
    end

    return 2
end

local function get_context()
    local st = get_app_state(current_app)
    if st.last_time > 0 and (os.time() - st.last_time) > IDLE_CLEAR_SEC then
        st.history = {}
    end
    return table.concat(st.history, "")
end

_G.llm_context_get = get_context
return processor
