-- llm_context.lua — 上屏文字收集（to_table 防标点顶屏）
-- commit_history 上限 20 条，每次重建；C++ 侧负责 token 截断

local history = {}

local function processor(key, env)
    if key:release() then return 2 end

    local ch = env.engine.context.commit_history
    if not ch then return 2 end

    local all = ch:to_table()
    if all and #all > 0 then
        history = {}
        for i = 1, #all do
            local entry = all[i]
            if entry and entry.text and #entry.text >= 1 then
                if #history == 0 or history[#history] ~= entry.text then
                    table.insert(history, entry.text)
                end
            end
        end
    end

    return 2
end

local function get_context()
    return table.concat(history, "")
end

_G.llm_context_get = get_context
return processor
