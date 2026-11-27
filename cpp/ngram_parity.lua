-- ngram_parity.lua — 组句器离线对拍（C++ vs 研究库 sentence_gen_gram.py）
--
-- 输入/输出全走环境变量（新代码不写死本机绝对路径）：
--   NGRAM_GRAM   .gram 模型路径（空 = 只用词频）
--   NGRAM_DICT   词典目录
--   NGRAM_FILES  逗号分隔的词典文件名（如 zi,jichu,duoyin,diming,mingren,yiren）
--   NGRAM_ESSAY  essay.txt 路径（可空）
--   NGRAM_IN     TSV：sid \t code \t before（before = 句前上文尾部）
--   NGRAM_OUT    TSV 输出：sid \t rank \t score \t text
--   NGRAM_PARAMS 可选 JSON 风格键值对，如 "beam=64,topk=5,min_weight=10"
--   NGRAM_MODE   incr = 增量对拍（默认 cold = 常规对拍输出）
--   NGRAM_LSTART 增量模式起始前缀长（默认 2）
--
-- 用法（lua_host 的 cwd = cpp\）：
--   lua_host ngram_parity.lua
--
-- 增量模式：每条测试行按前缀长 L = LSTART..#code 逐步喂缓存入口
-- llm.ngram_sentences_cached，每步与全量 llm.ngram_sentences 对拍（文本/
-- 分数/分词逐位一致——增量是纯加速不改结果），末步再查一次验证 memo 路径；
-- NGRAM_OUT 落两份 TSV（<out> = 全量、<out>.incr = 增量），并按码长分桶打
-- 印两路耗时。
package.cpath = [[build/Release/?.dll]]

local llm = require("rime_llm")

local function env(name, def)
  local v = os.getenv(name)
  if v == nil or v == "" then return def end
  return v
end

local gram = env("NGRAM_GRAM", "")
local dict_dir = env("NGRAM_DICT")
local essay = env("NGRAM_ESSAY", "")
local cache = env("NGRAM_CACHE", "")
local in_path = env("NGRAM_IN")
local out_path = env("NGRAM_OUT")
if not dict_dir or not in_path or not out_path then
  error("NGRAM_DICT / NGRAM_IN / NGRAM_OUT required")
end

local files = {}
for name in string.gmatch(env("NGRAM_FILES", ""), "[^,]+") do
  files[#files + 1] = name
end
if #files == 0 then error("NGRAM_FILES empty") end

local params = { topk = 5, beam = 64, min_weight = 10.0, max_edges = 0,
                 ctx_tail = 10, max_len = 6, min_len = 2 }
for k, v in string.gmatch(env("NGRAM_PARAMS", ""), "([%w_]+)=([%w%.%-]+)") do
  params[k] = tonumber(v) or v
end

local t0 = os.clock()
local ok, err = llm.ngram_load(gram, dict_dir, files, essay, cache)
print(string.format("[ngram] load ok=%s %s (%.2fs)", tostring(ok),
                    tostring(err or ""), os.clock() - t0))
if not ok then error("ngram_load failed: " .. tostring(err)) end
print("[ngram] " .. tostring(llm.ngram_status()))

-- ── 增量对拍模式（NGRAM_MODE=incr）────────────────────────────────────
if env("NGRAM_MODE", "cold") == "incr" then
  local lstart = tonumber(env("NGRAM_LSTART", "2")) or 2
  local t_fresh, t_incr, c_fresh, c_incr = {}, {}, {}, {}
  local function acc(t, c, len, dt)
    t[len] = (t[len] or 0.0) + dt
    c[len] = (c[len] or 0) + 1
  end
  -- 全量 vs 增量须逐位一致：句数、文本、分数（原始 double 相等）、分词路径
  local function cmp(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
      return string.format("count %s vs %s",
        type(a) == "table" and tostring(#a) or type(a),
        type(b) == "table" and tostring(#b) or type(b))
    end
    for i = 1, #a do
      local x, y = a[i], b[i]
      if x.text ~= y.text then
        return string.format("rank%d text %q vs %q", i, x.text, y.text)
      end
      if x.score ~= y.score then
        return string.format("rank%d score %.17g vs %.17g", i, x.score, y.score)
      end
      local wx, wy = x.words or {}, y.words or {}
      if #wx ~= #wy then
        return string.format("rank%d words %d vs %d", i, #wx, #wy)
      end
      for k = 1, #wx do
        if wx[k].w ~= wy[k].w or wx[k].e ~= wy[k].e then
          return string.format("rank%d word%d %s@%d vs %s@%d", i, k,
                               wx[k].w, wx[k].e, wy[k].w, wy[k].e)
        end
      end
    end
    return nil
  end
  local outf_f = assert(io.open(out_path, "wb"))
  local outf_i = assert(io.open(out_path .. ".incr", "wb"))
  local n_rows, n_steps, n_fail = 0, 0, 0
  for line in io.lines(in_path) do
    line = line:gsub("[\r\n]+$", "")
    if line ~= "" then
      local sid, code, before = line:match("^(%S+)\t(%S+)\t?(.*)$")
      if sid and code then
        n_rows = n_rows + 1
        local prev_cached = nil
        for L = lstart, #code do
          local pre = code:sub(1, L)
          local ts = os.clock()
          local fr = llm.ngram_sentences(pre, before or "", params)
          local tf = os.clock() - ts
          ts = os.clock()
          local ca = llm.ngram_sentences_cached(pre, before or "", params)
          local tc = os.clock() - ts
          acc(t_fresh, c_fresh, L, tf)
          acc(t_incr, c_incr, L, tc)
          n_steps = n_steps + 1
          local diff = cmp(fr, ca)
          if diff then
            n_fail = n_fail + 1
            print(string.format("[incr] FAIL sid=%s L=%d: %s", sid, L, diff))
          end
          if fr then
            for i, c in ipairs(fr) do
              outf_f:write(string.format("%s\t%d\t%d\t%.6f\t%s\n",
                                         sid, L, i, c.score, c.text))
            end
          end
          if ca then
            for i, c in ipairs(ca) do
              outf_i:write(string.format("%s\t%d\t%d\t%.6f\t%s\n",
                                         sid, L, i, c.score, c.text))
            end
          end
          prev_cached = ca
        end
        -- memo 路径：同输入再查一次，须与上一步完全一致
        if prev_cached then
          local memo = llm.ngram_sentences_cached(code, before or "", params)
          local diff = cmp(prev_cached, memo)
          if diff then
            n_fail = n_fail + 1
            print(string.format("[incr] MEMO-FAIL sid=%s: %s", sid, diff))
          end
        end
      end
    end
  end
  outf_f:close()
  outf_i:close()
  print(string.format("[incr] rows=%d steps=%d fail=%d", n_rows, n_steps, n_fail))
  local lens = {}
  for L in pairs(c_incr) do lens[#lens + 1] = L end
  table.sort(lens)
  print("[incr]  len   fresh_ms   incr_ms  speedup   (n)")
  for _, L in ipairs(lens) do
    local f = 1000.0 * t_fresh[L] / c_fresh[L]
    local g = 1000.0 * t_incr[L] / c_incr[L]
    print(string.format("[incr] %4d  %8.2f  %8.3f  %6.1fx  (%d)",
                        L, f, g, f / math.max(g, 1e-9), c_incr[L]))
  end
  print("[ngram] " .. tostring(llm.ngram_status()))
  return
end

local outf = assert(io.open(out_path, "wb"))
local n, t_sum = 0, 0.0
for line in io.lines(in_path) do
  line = line:gsub("[\r\n]+$", "")
  if line ~= "" then
    local sid, code, before = line:match("^(%S+)\t(%S+)\t?(.*)$")
    if sid and code then
      local ts = os.clock()
      local cands = llm.ngram_sentences(code, before or "", params)
      t_sum = t_sum + (os.clock() - ts)
      n = n + 1
      if cands then
        for i, c in ipairs(cands) do
          outf:write(string.format("%s\t%d\t%.6f\t%s\n", sid, i, c.score,
                                   c.text))
        end
      end
    end
  end
end
outf:close()
print(string.format("[ngram] sentences=%d gen=%.1fms/each", n,
                    1000.0 * t_sum / math.max(n, 1)))
