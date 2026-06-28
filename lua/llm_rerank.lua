-- llm_rerank.lua — LLM 候选重排 filter
-- 职责：LLM 评估所有候选 → 首选移到最前 + ⚡
-- 固顶逻辑由独立的 pin_fix_filter.lua 处理
local http = require("rime_pipe")
http.TIMEOUT = 0.2

-- === 延迟统计 ===
local lat_max = 0
local lat_count = 0

local function parse_first(raw)
    if not raw or #raw == 0 then return nil end
    local fp = raw:find('"first"')
    if not fp then return nil end
    local s = raw:sub(fp)
    local w = s:match('"first":%s*"([^"]+)"')
    return w
end

local function clean_context(s)
    return (s:gsub('%s+', ''))
end

local function filter(translation, env)
    local all = {}
    for cand in translation:iter() do table.insert(all, cand) end
    if #all < 2 then for _, c in ipairs(all) do yield(c) end; return end

    local TEMP = os.getenv("TEMP") or "C:\\Windows\\Temp"
    if io.open(TEMP .. "\\rime_llm_off", "r") then
        for _, c in ipairs(all) do yield(c) end; return
    end

    local ctx = env.engine.context
    if #(ctx.input or "") < 4 then
        for _, c in ipairs(all) do yield(c) end; return
    end

    -- 上下文收集
    local context = clean_context(
        (_G.llm_context_get and _G.llm_context_get()) or ""
    )
    if #context < 6 then
        for _, c in ipairs(all) do yield(c) end; return
    end
    if #context > 60 then context = string.sub(context, -60) end

    -- 发送所有候选到 LLM
    local max_send = 9
    local parts = {}
    for i, c in ipairs(all) do
        if i > max_send then break end
        table.insert(parts, '"' .. c.text:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"')
    end
    local esc = context:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
    local body = '{"context":"' .. esc .. '","candidates":[' .. table.concat(parts, ",") .. ']}'

    local t0 = os.clock()
    local raw_resp = nil
    local ok, result = pcall(function()
        local r, s = http.request("http://127.0.0.1:9877/rerank", body)
        if type(s) == "number" and s >= 200 and s < 300 and type(r) == "string" then
            raw_resp = r
            return parse_first(r)
        end
        return nil
    end)
    local elapsed_ms = (os.clock() - t0) * 1000

    -- 更新峰值延迟
    lat_count = lat_count + 1
    if elapsed_ms > lat_max then lat_max = elapsed_ms end
    local pf = io.open(TEMP .. "\\rime_latency.txt", "w")
    if pf then pf:write(string.format("count=%d  max=%.0fms  last=%.0fms", lat_count, lat_max, elapsed_ms)); pf:close() end

    if ok and result then
        local srv_ms = ""
        if raw_resp then
            local lm = raw_resp:match('"latency_ms":%s*([%d.]+)')
            if lm then srv_ms = string.format(" srv=%.0fms", tonumber(lm)) end
        end
        local f = io.open(TEMP .. "\\rime_ctx_log.txt", "a")
        if f then f:write(string.format("「%s」→ %s  total=%.0fms%s\n",
            context, tostring(result) or "?", elapsed_ms, srv_ms)); f:close() end

        -- LLM 首选移到最前面 + ⚡
        local llm_cand = nil
        for _, c in ipairs(all) do
            if c.text == result then llm_cand = c; break end
        end
        if llm_cand then
            yield(ShadowCandidate(llm_cand, llm_cand.type, llm_cand.text,
                llm_cand.comment .. " ⚡", true))
        end
        for _, c in ipairs(all) do
            if c ~= llm_cand then yield(c) end
        end
    else
        -- LLM 失败 → 保持原序
        for _, c in ipairs(all) do yield(c) end
    end
end

return filter
