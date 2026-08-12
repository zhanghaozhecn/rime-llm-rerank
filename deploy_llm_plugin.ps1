# deploy_llm_plugin.ps1 — rime-llm-rerank 插件版一键部署
# 用法（管理员，由 deploy_llm_plugin.bat 提权调用）：
#   powershell -ExecutionPolicy Bypass -File deploy_llm_plugin.ps1 [-ModelPath <路径>] [-InstallDir <路径>] [-SchemaName pdsp.schema.yaml] [-Force]
#
# 部署内容：
#   1. 程序文件夹（小狼毫安装目录）: rime_llm.dll + llama.dll + ggml*.dll（CPU 版）
#   2. 用户文件夹（%APPDATA%\Rime）:
#      lua\llm_filter.lua + lua\llm_processor.lua
#      <SchemaName> 插入 engine 组件（幂等，可重复运行）:
#        processors 最前:      lua_processor@*llm_processor
#        filters uniquifier 后: lua_filter@*llm_filter   ← 必须在 pin_fix_filter
#                                                          之前: 先 LLM 重排再固顶
#                                                          词提升, 否则固顶词会被顶掉
#      顶层 llm_rerank: 配置节
#   3. 完成后: 重启（若替换过 TSF 组件）→ 托盘重新部署 → 生效
#
# 前置：官方小狼毫 0.17.x 已安装。若安装目录被"源码版 LLM"组件替换过
# （rime.dll 含 llm_filter），脚本会警告并要求先恢复官方（见 RESTORE 提示）。

param(
  [string]$ModelPath = "",
  [string]$InstallDir = "",
  [string]$SchemaName = "pdsp.schema.yaml",
  [switch]$Force
)

$ErrorActionPreference = "Stop"
# 脚本与 user\ 同级；兼容脚本位于子目录（如 scripts\）的情况
$SRC_USER = Join-Path $PSScriptRoot "user"
if (-not (Test-Path (Join-Path $SRC_USER "rime_llm.dll"))) {
  $SRC_USER = Join-Path (Split-Path $PSScriptRoot -Parent) "user"
  if (-not (Test-Path (Join-Path $SRC_USER "rime_llm.dll"))) {
    Write-Host "[ERROR] user\ 目录未找到（需要 rime_llm.dll 等插件文件）" -ForegroundColor Red
    Write-Host "  请确认在 rime-llm-rerank 发布树内运行（deploy_llm_plugin.bat 与 user\ 同级）"
    exit 1
  }
}
$APPDATA_RIME = Join-Path $env:APPDATA "Rime"
$LUA_DIR = Join-Path $APPDATA_RIME "lua"

# ── 0. 定位小狼毫安装目录 ──────────────────────────
if (-not $InstallDir) {
  foreach ($p in @("C:\Program Files\Rime\weasel-0.17.4",
                   "C:\Program Files (x86)\Rime\weasel-0.17.4",
                   "C:\Program Files\Rime\weasel-0.18.0",
                   "C:\Program Files (x86)\Rime\weasel-0.18.0")) {
    if (Test-Path (Join-Path $p "rime.dll")) { $InstallDir = $p; break }
  }
}
if (-not $InstallDir) {
  # 注册表探测
  $k = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
       Where-Object { $_.DisplayName -like "*小狼毫*" -or $_.DisplayName -like "*Weasel*" } |
       Select-Object -First 1
  if ($k -and $k.InstallLocation) { $InstallDir = $k.InstallLocation }
}
if (-not $InstallDir -or -not (Test-Path (Join-Path $InstallDir "rime.dll"))) {
  Write-Host "[ERROR] 未找到小狼毫安装目录（找不到 rime.dll）。" -ForegroundColor Red
  Write-Host "  请先安装官方小狼毫 0.17.x，或用 -InstallDir 指定"
  exit 1
}
Write-Host "安装目录: $InstallDir" -ForegroundColor Cyan

# ── 1. 检测安装目录组件（源码版 rime.dll 冲突检查） ──
$RIME_DLL = Join-Path $InstallDir "rime.dll"
$bytes = [IO.File]::ReadAllBytes($RIME_DLL)
$ascii = [Text.Encoding]::ASCII.GetString($bytes)
$src_build = $ascii.Contains("llm_filter")
if ($src_build) {
  Write-Host "[警告] 安装目录的 rime.dll 是『源码版 LLM 组件』（含内置 llm_filter）。" -ForegroundColor Yellow
  Write-Host "  插件版需要官方 rime.dll（含 Lua 支持）。源码版与插件版二选一，混用会冲突。"
  if (-not $Force) {
    Write-Host "  恢复官方组件（二选一）：" -ForegroundColor Yellow
    Write-Host "    a) 重装官方: 下载 https://github.com/rime/weasel/releases 的 0.17.4 x64 安装包，运行重装"
    Write-Host "    b) 用 -Force 跳过本检查（风险自负：源码版 rime.dll 的 llm_filter 组件未被 schema 引用时"
    Write-Host "       不激活，Lua 插件可运行；但行为未经官方基线验证）"
    Write-Host "  中止。重装官方后重跑本脚本。"
    exit 2
  }
}

# ── 2. 模型检查 ────────────────────────────────────
if (-not $ModelPath) { $ModelPath = "d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf" }
if (-not (Test-Path $ModelPath)) {
  Write-Host "[警告] 模型未找到: $ModelPath" -ForegroundColor Yellow
  Write-Host "  请先下载 Qwen3.5-0.8B-Q4_K_M.gguf（约 500MB）:" -ForegroundColor Yellow
  Write-Host "  https://www.modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/files"
  Write-Host "  放到 d:\gguf_models\ 或下载后重新运行本脚本加参数: -ModelPath <完整路径>"
  if (-not $Force) { exit 3 }
}

# ── 3. 复制插件 DLL → 安装目录（CPU 版；GPU 版仅本地留存，不发布） ──
$dlls = @("rime_llm.dll", "llama.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll")
Write-Host ""; Write-Host "[1/4] 复制插件 DLL → 安装目录" -ForegroundColor Cyan
foreach ($d in $dlls) {
  $s = Join-Path $SRC_USER $d
  if (-not (Test-Path $s)) { Write-Host "  [跳过] 缺失: $d" -ForegroundColor DarkGray; continue }
  Copy-Item $s $InstallDir -Force
  Write-Host "  + $d"
}

# ── 4. 复制 lua → RIME 用户目录 ────────────────────
Write-Host ""; Write-Host "[2/4] 复制 Lua 组件 → $LUA_DIR" -ForegroundColor Cyan
if (-not (Test-Path $LUA_DIR)) { New-Item -ItemType Directory -Path $LUA_DIR | Out-Null }
foreach ($l in @("llm_filter.lua", "llm_processor.lua")) {
  $s = Join-Path $SRC_USER $l
  if (Test-Path $s) { Copy-Item $s (Join-Path $LUA_DIR $l) -Force; Write-Host "  + $l" }
  else { Write-Host "  [跳过] 缺失: $l" -ForegroundColor DarkGray }
}

# ── 5. schema 修改（幂等）──────────────────────────
Write-Host ""; Write-Host "[3/4] 修改方案 schema: $SchemaName" -ForegroundColor Cyan
$schema = Join-Path $APPDATA_RIME $SchemaName
if (-not (Test-Path $schema)) {
  Write-Host "[ERROR] 方案文件不存在: $schema（确认方案名，或复制方案 yaml 到 RIME 用户目录）" -ForegroundColor Red
  exit 4
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$lines = [IO.File]::ReadAllLines($schema, [Text.Encoding]::UTF8)
$changed = $false
$out = New-Object System.Collections.Generic.List[string]

# 5a. processors 最前插入 lua_processor@*llm_processor
$hasProc = ($lines | Where-Object { $_ -match 'lua_processor@\*llm_processor' }).Count -gt 0
# 5b. filters: uniquifier 后插入 lua_filter@*llm_filter
$hasFilt = ($lines | Where-Object { $_ -match 'lua_filter@\*llm_filter' }).Count -gt 0
$hasCfg  = ($lines | Where-Object { $_ -match '^llm_rerank:' }).Count -gt 0

if (-not $hasProc) {
  $inEngine = $false; $inProc = $false; $inserted = $false
  foreach ($ln in $lines) {
    if ($ln -match '^engine:') { $inEngine = $true }
    elseif ($inEngine -and $ln -match '^\S') { $inEngine = $false; $inProc = $false }
    if ($inEngine -and $ln -match '^\s+processors:') { $inProc = $true; $out.Add($ln); continue }
    if ($inProc -and $ln -match '^\s+-\s') {
      $out.Add("    - lua_processor@*llm_processor"); $inProc = $false; $inserted = $true
    }
    $out.Add($ln)
  }
  if ($inserted) { Write-Host "  + processors: lua_processor@*llm_processor（最前）"; $changed = $true }
  else { Write-Host "  [警告] 未找到 processors 块，跳过插入（请手动添加）" -ForegroundColor Yellow }
}

if (-not $hasFilt) {
  $inFilt = $false; $inserted = $false
  for ($i = 0; $i -lt $out.Count; $i++) {
    if ($out[$i] -match '^\s+filters:') { $inFilt = $true; continue }
    # 在 uniquifier 行之后插入（先 LLM 重排、再固顶词提升）
    if ($inFilt -and $out[$i] -match '^\s+- uniquifier') {
      $out.Insert($i + 1, "    - lua_filter@*llm_filter")
      $inserted = $true; $inFilt = $false
      break
    }
  }
  if ($inserted) { Write-Host "  + filters: lua_filter@*llm_filter（uniquifier 之后、pin_fix 之前）"; $changed = $true }
  else { Write-Host "  [警告] 未找到 filters 块或 uniquifier，跳过插入（请手动添加）" -ForegroundColor Yellow }
}

if (-not $hasCfg) {
  $cfgLines = @(
    "",
    "llm_rerank:",
    "  backend: cpu",          # "cpu" 或 "off"（GPU 版仅本地留存，不发布）
    "  min_code_len: 4",       # 编码达到此长度才触发 LLM（四码方案=满码）
    "  # min_tokens: 1",       # 最少上文 token 才重排
    "  # max_tokens: 10",      # 上文 token 上限（10 为性价比最优点）
    "  # max_candidates: 5",   # 参与评分的候选数
    "  # cpu_cores: 4",        # CPU 线程数（bench_threads.exe 实测后调整）
    "  # model_path: d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"  # 模型路径（不设置=内置默认；换模型/路径取消注释并修改）
  )
  foreach ($cl in $cfgLines) { $out.Add($cl) }
  Write-Host "  + llm_rerank: 配置节（backend: cpu）"; $changed = $true
}

if ($changed) {
  [IO.File]::WriteAllLines($schema, $out, $utf8NoBom)
  Write-Host "  schema 已更新（UTF-8 无 BOM，幂等：重复运行不重复插入）"
} else {
  Write-Host "  schema 无需修改（组件已存在）"
}

# ── 6. 完成指引 ────────────────────────────────────
Write-Host ""; Write-Host "[4/4] 完成" -ForegroundColor Green
Write-Host "部署完成！生效步骤：" -ForegroundColor Green
Write-Host "  1. 若之前替换过 TSF 组件（weaselx64.dll）→ 重启系统；未替换过可跳过"
Write-Host "  2. 托盘小狼毫图标 → 右键 → 重新部署（必须，重建词典 build）"
Write-Host "  3. 验证："
Write-Host "     - 打满 4 码，首选候选 comment 出现 AI 标记（重排生效）"
Write-Host "     - 日志: $APPDATA_RIME\rime_llm_events.txt"
Write-Host "  4. 关闭 LLM：把安装目录 rime_llm*.dll 改后缀为 .bak，重新部署"
Write-Host ""
Write-Host "  位置说明（schema 插入点）："
Write-Host "    processors 最前 : lua_processor@*llm_processor（上屏历史收集+预解码）"
Write-Host "    filters uniquifier 后: lua_filter@*llm_filter（重排在固顶词之前）"
