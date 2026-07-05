-- llm_context.lua — 上屏文字收集（to_table 防标点顶屏）

local MAX_CHARS = 30
local history = {}
local _size = 0

local function processor(key, env)
    if key:release() then return 2 end

    local ch = env.engine.context.commit_history
    if ch then
        local all = ch:to_table()
        if all and #all > _size then
            for i = _size + 1, #all do
                local entry = all[i]
                if entry and entry.text and #entry.text >= 1 then
                    if #history == 0 or history[#history] ~= entry.text then
                        table.insert(history, entry.text)
                        local total_bytes = 0
                        for _, t in ipairs(history) do total_bytes = total_bytes + #t end
                        while total_bytes > MAX_CHARS * 3 and #history > 1 do
                            total_bytes = total_bytes - #history[1]
                            table.remove(history, 1)
                        end
                    end
                end
            end
            _size = #all
        end
    end

    return 2
end

local function get_context()
    return table.concat(history, "")
end

_G.llm_context_get = get_context
return processor
