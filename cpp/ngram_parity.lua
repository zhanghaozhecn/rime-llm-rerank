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
--
-- 用法（lua_host 的 cwd = cpp\）：
--   lua_host ngram_parity.lua
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
