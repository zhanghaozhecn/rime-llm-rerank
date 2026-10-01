# install_plugin.ps1 — 插件版安装器（单文件；GUI / CLI）
# 历史：原拆分 install_plugin.ps1（入口壳）+ common.ps1（两版共用逻辑）是为
# 跨仓同步——2026-08-27 源码版改用 setup.exe 安装包后共用已名存实亡，
# 2026-09-04 按用户定案合并为本仓库单文件，源码版动作与双版分支随之删除。
# GUI：双击 install_plugin.bat（提权）→ **单页**（2026-09-30 用户定案：与源码版
#   WeaselLLMSetup 尽量一致、并去掉"加/去 LLM 在另一页"的割裂）：
#     方案接入（方案下拉）→ 总控（启用 + 模型路径 + 下载模型 + 模型状态）→ 触发条件 →
#     推理规模 → 候选排序融合 → 诊断日志 → 安装（复制文件）→ 保存并生效 / 剥离 / 关闭。
# 底色：表单 BackColor = White（2026-10-01 用户定案：**两版底色统一为白**；
#   WinForms 的 BackColor 是环境属性，GroupBox/Label/CheckBox 未显式设色时会跟着继承）。
#   界面**不留日志框**：正常只更新状态行；出错写 installer\install_error.log
#   （GUI 程序所在目录）并弹一次框给出日志路径。
#   参数读写选中方案的 llm_rerank 配置节，保存后自动重新部署（两版配置节相同）。
# CLI：-CliAction status|install|copy-files|schema-add|schema-remove|download-model
#      -SchemaName pdsp.schema.yaml -ModelPath d:\gguf_models\xxx.gguf（可选，写入配置）
# 设计（2026-08-25 定稿）：安装器只做 文件操作 + schema 加/去 LLM 组件行（幂等）。
# 不碰注册表、不调 WeaselSetup、不做还原（切换 = 重装小狼毫 + 换原始方案配置）。

param(
  [string]$CliAction = "",
  [string]$SchemaName = "",
  [string]$ModelPath = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── 路径探测（载荷 = 本仓库 user\）─────────────────
$PluginSrc = Join-Path (Split-Path $PSScriptRoot -Parent) "user"   # 插件版仓库 user\
$PluginReady = Test-Path (Join-Path $PluginSrc "rime_llm.dll")
# Rime 用户文件夹，优先级：环境变量 RIME_LLM_USER_DIR（便携/测试显式指定）
# → 注册表 HKCU\Software\Rime\Weasel\RimeUserDir（便携模式小狼毫写的就是它）
# → %APPDATA%\Rime。2026-10-01：此前硬编码 APPDATA，便携部署下会指错目录。
function Get-RimeUserDir {
  if ($env:RIME_LLM_USER_DIR -and (Test-Path $env:RIME_LLM_USER_DIR)) { return $env:RIME_LLM_USER_DIR }
  try {
    $v = (Get-ItemProperty -Path 'HKCU:\Software\Rime\Weasel' -Name RimeUserDir -ErrorAction Stop).RimeUserDir
    if ($v -and (Test-Path $v)) { return $v }
  } catch { }
  return (Join-Path $env:APPDATA "Rime")
}
$RIME_USER = Get-RimeUserDir
$LUA_DIR = Join-Path $RIME_USER "lua"

# ── 模型（下载按钮用；curl 为 Win10 1803+ 自带）──
# 默认模型路径 = 用户文件夹（2026-08-27 用户定案：不假设存在 D: 分区；
# 有 D 盘模型的机器在 GUI/schema 里显式填 D:\gguf_models\...）
# 与运行期默认保持一致：C++ 侧取 RIME 用户目录根（同上注册表优先）
$DEFAULT_MODEL = Join-Path $RIME_USER "Qwen3.5-0.8B-Q4_K_M.gguf"
# 完整模型的体量下限（与"下载完成转正"判据同一个数）：小于它 = 疑似半截/损坏
$MODEL_MIN_BYTES = 100MB
$MODEL_URL = "https://modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/resolve/master/Qwen3.5-0.8B-Q4_K_M.gguf"

function Find-WeaselDir {
  # ① 注册表 WeaselRoot（安装器写入；最可靠）
  foreach ($k in @("HKLM:\SOFTWARE\Rime\Weasel", "HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel")) {
    $root = (Get-ItemProperty $k -Name WeaselRoot -ErrorAction SilentlyContinue).WeaselRoot
    if ($root -and (Test-Path (Join-Path $root "rime.dll"))) { return $root }
  }
  # ② 常见安装位置（含 weasel-* 任意版本）
  foreach ($base in @("C:\Program Files\Rime", "C:\Program Files (x86)\Rime")) {
    $hit = Get-ChildItem $base -Directory -Filter "weasel-*" -ErrorAction SilentlyContinue |
           Where-Object { Test-Path (Join-Path $_.FullName "rime.dll") } |
           Sort-Object Name -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  foreach ($p in @("C:\Program Files\Rime\weasel-0.17.4",
                   "C:\Program Files (x86)\Rime\weasel-0.17.4",
                   "C:\Program Files\Rime\weasel-0.18.0",
                   "C:\Program Files (x86)\Rime\weasel-0.18.0")) {
    if (Test-Path (Join-Path $p "rime.dll")) { return $p }
  }
  $k = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
       Where-Object { $_.DisplayName -like "*小狼毫*" -or $_.DisplayName -like "*Weasel*" } |
       Select-Object -First 1
  if ($k -and $k.InstallLocation -and (Test-Path (Join-Path $k.InstallLocation "rime.dll"))) {
    return $k.InstallLocation
  }
  return $null
}

# ── 程序文件夹（预装数据）里的方案 ──────────────────────────────
# Rime 的配置分两处：**用户文件夹** %APPDATA%\Rime（可写、优先）与**程序文件夹**
# <小狼毫安装目录>\data（预装方案 luna_pinyin / cangjie5 / bopomofo …，随安装包一起更新）。
# 两处的 *.schema.yaml 都要能选；但**只有用户文件夹里的才算"用户的方案"**：
# 写程序文件夹既需要管理员、又会被下次升级覆盖 → 对预装方案一律先复制到用户文件夹
# 再改（Rime 解析顺序本就是用户文件夹优先，这也是 Rime 官方的手改做法）。
function Get-SharedDataDir {
  $d = Find-WeaselDir
  if ($d) {
    $s = Join-Path $d "data"
    if (Test-Path $s) { return $s }
  }
  return ""
}

# 解析方案路径：用户文件夹命中即返回；只在程序文件夹（预装）时按需复制到用户文件夹。
# $copyToUser = $true（任何写入前）→ 返回用户文件夹里的路径（并可选日志说明复制动作）
function Resolve-SchemaPath([string]$name, [bool]$copyToUser, $Log) {
  $up = Join-Path $RIME_USER $name
  if (Test-Path $up) { return $up }
  $shared = Get-SharedDataDir
  if ($shared) {
    $sp = Join-Path $shared $name
    if (Test-Path $sp) {
      if (-not $copyToUser) { return $sp }
      if (-not (Test-Path $RIME_USER)) { New-Item -ItemType Directory -Path $RIME_USER -Force | Out-Null }
      Copy-Item $sp $up -Force
      if ($Log) { & $Log ("  程序文件夹预装方案 → 已复制到用户文件夹: " + $name) }
      return $up
    }
  }
  throw "方案文件不存在: $name（用户文件夹与程序文件夹均未找到；点『刷新』重扫）"
}

# 5.1 陷阱: EAP=Stop 下原生命令写 stderr 会抛终止错误（2>$null 不豁免）
function Invoke-Native([string]$exe, [string[]]$argList) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try { & $exe @argList 2>$null } catch { }
  finally { $ErrorActionPreference = $prev }
}

function Stop-WeaselService {
  Invoke-Native taskkill @("/f", "/im", "WeaselServer.exe") | Out-Null
  Invoke-Native taskkill @("/f", "/im", "WeaselDeployer.exe") | Out-Null
  Start-Sleep -Seconds 2
}
function Start-WeaselService([string]$installDir, $Log) {
  $exe = Join-Path $installDir "WeaselServer.exe"
  if (Test-Path $exe) {
    # 降权启动（2026-09-10 真机踩坑）：本安装器经 bat 提权垫片以管理员运行，
    # 直接 Start-Process 会让 WeaselServer 继承管理员令牌——提权进程读非提权
    # 应用（WPS/Word）的 ROT 对象被 DCOM 安全边界拒绝，COM 光标上文旁路
    # 整层失效（UIA 不受影响——辅助功能框架允许跨权限读取）。经 explorer.exe
    # 代启回落普通用户令牌（explorer 恒为非提权，其子进程继承之）。
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$exe`""
    & $Log "  算法服务已启动（explorer 代启·普通权限）"
  }
}

# 替换二进制：一律改名腾位（2026-08-26 简化——只此一条路径，不再直接复制 /
# MoveFileEx 延迟替换）。Windows 允许改名加载中的镜像：目标先改名 *.llm_old
# （旧镜像留给运行中的进程继续用），再复制新文件；复制失败则回滚改名，避免
# 目标缺失。*.llm_old 由下次安装开始时的 Clean-OldBinaries 清理。
function Copy-Binary([string]$s, [string]$d, $Log) {
  $bak = $null
  if (Test-Path $d) {
    $bak = $d + ".llm_old"
    Move-Item $d $bak -Force -ErrorAction Stop
    & $Log ("  " + [IO.Path]::GetFileName($d) + " → .llm_old（旧镜像留给运行中的进程，下次安装时清理）")
  }
  try { Copy-Item $s $d -Force -ErrorAction Stop }
  catch {
    if ($bak -and (Test-Path $bak)) { Move-Item $bak $d -Force -ErrorAction SilentlyContinue }
    throw
  }
}
function Clean-OldBinaries([string]$dir, $Log) {
  $old = Get-ChildItem $dir -Filter "*.llm_old" -ErrorAction SilentlyContinue
  if ($old) { $old | Remove-Item -Force -ErrorAction SilentlyContinue; & $Log ("  清理 " + $old.Count + " 个改名残留") }
}

function Invoke-Redeploy([string]$installDir, $Log) {
  # 测试钩子：沙箱 GUI/CLI 自动化静默跳过（机制同源码版
  # WEASEL_LLM_SETUP_NO_REDEPLOY；测试子进程继承环境变量一并生效）
  if ($env:LLM_INSTALLER_NO_REDEPLOY) { & $Log "  （测试模式：跳过重新部署）"; return }
  $deployer = Join-Path $installDir "WeaselDeployer.exe"
  if (Test-Path $deployer) {
    & $Log "  触发重新部署（WeaselDeployer /deploy）…"
    try {
      $p = Start-Process -FilePath $deployer -ArgumentList "/deploy" -PassThru -ErrorAction Stop
      # 只等 15 秒拿快速退出码（成功 / 互斥冲突）。真机曾遇 deployer 在
      # EndMaintenance 的管道应答 ReadFile（无超时）中挂死——部署本身已完成，
      # 不能无限 -Wait 卡死安装器；超时则留后台继续，不杀进程
      if ($p.WaitForExit(15000)) {
        & $Log ("  重新部署退出码: " + $p.ExitCode)
      } else {
        & $Log "  重新部署仍在后台进行（已不再等待）；完成后输入法自动生效，若候选异常请托盘手动重新部署"
      }
    } catch { & $Log "  [警告] 自动重新部署失败，请手动：托盘小狼毫 → 重新部署" }
  } else {
    & $Log "  请手动重新部署：托盘小狼毫 → 重新部署"
  }
}

# ── schema 加 LLM 组件行（幂等，位置校验）────────
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Read-Schema([string]$path) { [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8) }
function Write-Schema([string]$path, $lines) { [IO.File]::WriteAllLines($path, $lines, $Utf8NoBom) }

# ── 参数编辑（『参数配置』页 + schema-add 参数保留共用）──────────
# 键集与默认值 = user\llm_filter.lua / llm_processor.lua 的 cfg；
# model_path 不在参数表（安装页模型路径框 / 加 LLM 写入），更新节时原样保留。
# com_context 已删（2026-09-29 定案：旁路无常关配置，排障改 llm_processor.lua
# 头部 com_ctx_enabled）——方案里残留的旧行在 GUI 保存/重跑加 LLM 重建节时剥除。
# min_tokens 已删（2026-09-30 定案：最少上文 token 恒为 1，代码默认保留、不给用户改）
# ——同样只在重建节时剥除，不做专门清理。
# min_code_len / max_code_len 已废弃（2026-09-30 定案：改为 code_pattern 正则匹配，
# 语义同 Rime speller/auto_select_pattern 的全串匹配）——旧行同样在重建节时剥除。
$PARAM_DEFAULTS = [ordered]@{
  enabled = $false
  code_pattern = '.{4}'   # 仅 4 码；4 码以上 .{4,} / 3-4 码 .{3,4} / 指定字母 [abcde]{4}
  max_tokens = 10; max_candidates = 5; cpu_cores = 4
  freq_beta = 1.5; expected_length_weight = 0.2; debug_fusion = $false
}
$PARAM_INT_KEYS  = @("max_tokens","max_candidates","cpu_cores")
$PARAM_DBL_KEYS  = @("freq_beta","expected_length_weight")
$PARAM_BOOL_KEYS = @("debug_fusion")
# 字符串型参数（不做数值解析，原样写回；空串合法 = 总是匹配）
$PARAM_STR_KEYS  = @("code_pattern")

function Format-F2([double]$x) {
  [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:F2}", $x)
}
function Convert-ParamDouble([string]$s, [ref]$out) {
  [double]::TryParse($s, [System.Globalization.NumberStyles]::Float,
                     [System.Globalization.CultureInfo]::InvariantCulture, $out)
}

# 读方案 llm_rerank 节的裸 key:value（注释行/行尾注释剔除、引号去壳；
# 无节返回 $null）。值一律字符串，类型解析由调用方按键做。
# 注意：键必须在行匹配后立刻取局部变量——后面的引号判断 -match 会覆盖
# $Matches（且该正则无捕获组，$Matches[1] 变 null → 哈希索引抛错，
# 2026-09-29 沙箱测试 trace 抓出：带引号 model_path 一行即炸整节读取）
function Read-LlmParams([string]$schemaPath) {
  $inCfg = $false; $p = $null
  foreach ($ln in (Read-Schema $schemaPath)) {
    if (-not $inCfg) {
      if ($ln -match '^llm_rerank:') { $inCfg = $true; $p = @{} }
      continue
    }
    if ($ln -match '^\S') { break }
    if ($ln -match '^\s+([A-Za-z_][A-Za-z0-9_]*):(.*)$') {
      $key = $Matches[1]
      $v = $Matches[2].Trim()
      $v = $v -replace '\s+#.*$', ''
      # 引号去壳：双引号（历史 model_path 风格）与单引号（code_pattern 正则风格，
      # 2026-09-30）都要剥——只剥双引号会让正则值带壳，读回界面/逐键保留全错
      if ($v -match '^".*"$' -or $v -match "^'.*'$") { $v = $v.Substring(1, $v.Length - 2) }
      if ($v -ne '') { $p[$key] = $v }
    }
  }
  return $p
}

# 用参数表重写 llm_rerank 节（原位替换，组件行不动；节必须已存在）。
# modelPath 非空写生效行，空写注释占位（与 Get-LlmCfgLines 同款）。
function Update-LlmSection([string]$schemaPath, [hashtable]$p, [string]$modelPath) {
  $lines = Read-Schema $schemaPath
  $start = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^llm_rerank:') { $start = $i; break }
  }
  if ($start -lt 0) { throw "方案内没有 llm_rerank 配置节——请先点『接入 LLM』" }
  $end = $start + 1
  while ($end -lt $lines.Count -and $lines[$end] -notmatch '^\S') { $end++ }
  # 注意：@() 数组元素里 "str" + $(if ...) 会被拆成两个元素（实测，2026-09-29
  # 沙箱测试抓出：enabled: 与 false 分家两行）——拼接一律用字符串内插 $()
  $sec = @(
    "llm_rerank:",
    "  enabled: $(if ($p.enabled) { 'true' } else { 'false' })",
    "  code_pattern: $(Convert-ToYamlScalar $p.code_pattern)",
    "  max_tokens: $($p.max_tokens)",
    "  max_candidates: $($p.max_candidates)",
    "  cpu_cores: $($p.cpu_cores)",
    "  freq_beta: $(Format-F2 ([double]$p.freq_beta))",
    "  expected_length_weight: $(Format-F2 ([double]$p.expected_length_weight))",
    "  debug_fusion: $(if ($p.debug_fusion) { 'true' } else { 'false' })"
  )
  if ($modelPath) { $sec += "  model_path: " + (Convert-ToYamlPath $modelPath) }
  else { $sec += "  # model_path: <绝对路径；默认 = ${env:APPDATA}\Rime\Qwen3.5-0.8B-Q4_K_M.gguf>" }
  $out = @()
  if ($start -gt 0) { $out += $lines[0..($start - 1)] }
  $out += $sec
  if ($end -lt $lines.Count) { $out += $lines[$end..($lines.Count - 1)] }
  Write-Schema $schemaPath $out
}

# prior（Read-LlmParams 结果）按类型并入默认表；enabled 不并入——
# 加 LLM 视为重新启用意图，节内恒写 true（关闭用参数页/去 LLM）
function Merge-LlmParams($prior) {
  $d = @{}
  foreach ($k in $PARAM_DEFAULTS.Keys) { $d[$k] = $PARAM_DEFAULTS[$k] }
  if ($prior) {
    foreach ($k in $PARAM_INT_KEYS) {
      if ($prior.ContainsKey($k)) {
        $n = 0
        if ([int]::TryParse($prior[$k], [ref]$n)) { $d[$k] = $n }
      }
    }
    foreach ($k in $PARAM_DBL_KEYS) {
      if ($prior.ContainsKey($k)) {
        $x = 0.0
        if (Convert-ParamDouble $prior[$k] ([ref]$x)) { $d[$k] = $x }
      }
    }
    foreach ($k in $PARAM_BOOL_KEYS) {
      if ($prior.ContainsKey($k)) { $d[$k] = ($prior[$k] -ieq "true") }
    }
    foreach ($k in $PARAM_STR_KEYS) {
      if ($prior.ContainsKey($k)) { $d[$k] = [string]$prior[$k] }
    }
  }
  return $d
}

# llm_rerank 配置节；modelPath 非空时写为生效行（反斜杠→正斜杠，含空格则加引号），
# 留空则保持注释示例（运行时默认 %APPDATA%\Rime\Qwen3.5-0.8B-Q4_K_M.gguf）。
# prior = 重跑加 LLM 时方案里已有的参数（Read-LlmParams 结果）——先剥后插
# 重建节时逐键保留，防止重跑把用户自定义参数重置回默认（model_path 同思路）。
function Get-LlmCfgLines([string]$modelPath, $prior, [bool]$enabled = $true) {
  $d = Merge-LlmParams $prior
  $l = @(
    "", "llm_rerank:",
    "  enabled: $(if ($enabled) { 'true' } else { 'false' })",
    "  code_pattern: $(Convert-ToYamlScalar $d.code_pattern)",
    "  max_tokens: $($d.max_tokens)",
    "  max_candidates: $($d.max_candidates)",
    "  cpu_cores: $($d.cpu_cores)",
    "  freq_beta: $(Format-F2 ([double]$d.freq_beta))",
    "  expected_length_weight: $(Format-F2 ([double]$d.expected_length_weight))",
    "  debug_fusion: $(if ($d.debug_fusion) { 'true' } else { 'false' })"
  )
  if ($modelPath) { $l += "  model_path: " + (Convert-ToYamlPath $modelPath) }
  else { $l += "  # model_path: <绝对路径；默认 = ${env:APPDATA}\Rime\Qwen3.5-0.8B-Q4_K_M.gguf>" }
  return $l
}
function Convert-ToYamlPath([string]$p) {
  $q = $p -replace '\\', '/'
  if ($q -match '\s') { $q = '"' + $q + '"' }
  return $q
}
# 任意标量（非路径）：含 YAML 特殊首字符/空格/注释符/反斜杠时加引号。
# code_pattern 常含 { } [ ] . \ 等——其中 {[ 是 YAML 流式集合起始符，
# 且**双引号标量里 \d 这类非法转义会直接报错**，故一律用单引号
# （内部单引号写两遍转义），正则原样保留。
function Convert-ToYamlScalar([string]$s) {
  if ($null -eq $s) { return "''" }
  if ($s -eq '' -or $s -match '^\s|\s$' -or $s -match '[\\\{\[\]\}:,\#&*!\|>%@`"'']') {
    return "'" + ($s -replace "'", "''") + "'"
  }
  return $s
}
# 方案已有 llm_rerank 节时补写 model_path（节内已有生效行则不动）
function Add-ModelPathToExisting([System.Collections.Generic.List[string]]$out, [string]$modelPath, $Log) {
  $idx = -1
  for ($i = 0; $i -lt $out.Count; $i++) { if ($out[$i] -match '^llm_rerank:') { $idx = $i; break } }
  if ($idx -lt 0) { return $false }
  for ($i = $idx + 1; $i -lt $out.Count; $i++) {
    if ($out[$i] -match '^\S') { break }
    if ($out[$i] -match '^\s+model_path:\s*\S') { & $Log "  llm_rerank 已有生效 model_path，未改动"; return $false }
  }
  $out.Insert($idx + 1, "  model_path: " + (Convert-ToYamlPath $modelPath))
  & $Log ("  + model_path: " + (Convert-ToYamlPath $modelPath))
  return $true
}

# 插件版组件行：processors 最前 lua_processor + uniquifier 后 lua_filter + llm_rerank 节
# prior = 参数来源（Read-LlmParams 结果 或 界面参数表），重建配置节时逐键保留
# enabled = 写进节的 enabled（GUI 保存 = 复选框状态；CLI 接入 = true）
function Edit-SchemaPlugin([string]$schemaPath, [string]$modelPath, $Log, $prior, [bool]$enabled = $true) {
  $lines = Read-Schema $schemaPath
  if (($lines | Where-Object { $_ -match '^\s*-\s+llm_filter\s*$' }).Count -gt 0) {
    throw "方案里已有源码版组件（- llm_filter）——插件版与源码版二选一，请先重装小狼毫并恢复原始方案配置"
  }
  $changed = $false
  $hasProc = ($lines | Where-Object { $_ -match 'lua_processor@\*llm_processor' }).Count -gt 0
  $hasFilt = ($lines | Where-Object { $_ -match 'lua_filter@\*llm_filter' }).Count -gt 0
  $hasCfg  = ($lines | Where-Object { $_ -match '^llm_rerank:' }).Count -gt 0
  # $out 必须无条件填充（原实现只在插 processor 时填充——幂等重跑时为空表，
  # 导致后续 filter/cfg 分支在空表上操作）
  $out = New-Object System.Collections.Generic.List[string]
  if (-not $hasProc) {
    $inEngine = $false; $inProc = $false; $inserted = $false
    foreach ($ln in $lines) {
      if ($ln -match '^engine:') { $inEngine = $true }
      elseif ($inEngine -and $ln -match '^\S') { $inEngine = $false; $inProc = $false }
      if ($inEngine -and $ln -match '^\s+processors:') { $inProc = $true; [void]$out.Add($ln); continue }
      if ($inProc -and $ln -match '^\s+-\s') {
        [void]$out.Add("    - lua_processor@*llm_processor"); $inProc = $false; $inserted = $true
      }
      [void]$out.Add($ln)
    }
    if ($inserted) { & $Log "  + processors: lua_processor@*llm_processor（最前）"; $changed = $true }
    else { throw "未找到 processors 块，无法插入组件" }
  } else {
    foreach ($l in $lines) { [void]$out.Add($l) }
  }
  if (-not $hasFilt) {
    $inFilt = $false; $inserted = $false
    for ($i = 0; $i -lt $out.Count; $i++) {
      if ($out[$i] -match '^\s+filters:') { $inFilt = $true; continue }
      if ($inFilt -and $out[$i] -match '^\s+- uniquifier') {
        $out.Insert($i + 1, "    - lua_filter@*llm_filter")
        $inserted = $true; break
      }
    }
    if ($inserted) { & $Log "  + filters: lua_filter@*llm_filter（uniquifier 之后）"; $changed = $true }
    else { throw "未找到 filters 块或 uniquifier，无法插入组件" }
  }
  if (-not $hasCfg) {
    Get-LlmCfgLines $modelPath $prior $enabled | ForEach-Object { [void]$out.Add($_) }
    & $Log ("  + llm_rerank: 配置节（enabled: " + $(if ($enabled) { 'true' } else { 'false' }) + "）"); $changed = $true
  } elseif ($modelPath) {
    if (Add-ModelPathToExisting $out $modelPath $Log) { $changed = $true }
  }
  if ($changed) { Write-Schema $schemaPath $out; & $Log "  schema 已更新（幂等，重复运行不重复插入）" }
  else { & $Log "  schema 组件已存在，无需修改" }
}

# 方案是否需要"重建接入"（缺节 / 缺本版组件行 / 残留另一版组件行）
# 返回 @{ Rebuild=$true/$false; Why="..." }
function Test-SchemaNeedsRebuild([string]$schemaPath) {
  $lines = Read-Schema $schemaPath
  $hasProc = ($lines | Where-Object { $_ -match 'lua_processor@\*llm_processor' }).Count -gt 0
  $hasFilt = ($lines | Where-Object { $_ -match 'lua_filter@\*llm_filter' }).Count -gt 0
  $hasCfg  = ($lines | Where-Object { $_ -match '^llm_rerank:' }).Count -gt 0
  $hasOther = ($lines | Where-Object { $_ -match '^\s*-\s+llm_filter\s*$' }).Count -gt 0
  $why = @()
  if (-not $hasCfg) { $why += "无配置节" }
  if (-not $hasProc) { $why += "缺 lua_processor" }
  if (-not $hasFilt) { $why += "缺 lua_filter" }
  if ($hasOther) { $why += "残留源码版组件行" }
  return [pscustomobject]@{ Rebuild = ($why.Count -gt 0); Why = ($why -join "、") }
}

# 用**界面参数**重建接入（剥净两版组件行 → 插入本版组件行 → 按界面值写节）
function Edit-SchemaRebuild([string]$schemaPath, [hashtable]$p, [string]$modelPath, $Log, $quiet = $null) {
  $sink = if ($quiet) { $quiet } else { $Log }
  Edit-SchemaRemove $schemaPath $sink      # 剥净两版组件行 + 旧节
  Edit-SchemaPlugin $schemaPath $modelPath $sink $p $p.enabled
}

# 读方案 llm_rerank 节内已生效的 model_path（先剥离后添加时保留用户已设路径）
function Get-ActiveModelPath([string]$schemaPath) {
  $lines = Read-Schema $schemaPath
  $inCfg = $false
  foreach ($ln in $lines) {
    if ($ln -match '^llm_rerank:') { $inCfg = $true; continue }
    if ($inCfg) {
      if ($ln -match '^\S') { return $null }
      if ($ln -match '^\s+model_path:\s*(.+?)\s*$') { return $Matches[1].Trim('"') }
    }
  }
  return $null
}

# 去除 LLM 组件：processor/filter 组件行 + llm_rerank 整节（含前置空行）。
# 同时剥另一版组件行（- llm_filter）——从源码版切换过来的方案直接收敛
function Edit-SchemaRemove([string]$schemaPath, $Log) {
  $lines = Read-Schema $schemaPath
  $out = New-Object System.Collections.Generic.List[string]
  $inCfg = $false; $removed = 0
  foreach ($ln in $lines) {
    if ($inCfg) {
      if ($ln -match '^\S') { $inCfg = $false } else { $removed++; continue }
    }
    if ($ln -match '^\s*-\s+lua_processor@\*llm_processor\s*$' -or
        $ln -match '^\s*-\s+lua_filter@\*llm_filter\s*$' -or
        $ln -match '^\s*-\s+llm_filter\s*$') { $removed++; continue }
    if ($ln -match '^llm_rerank:') {
      $removed++
      if ($out.Count -gt 0 -and $out[$out.Count - 1] -match '^\s*$') {
        [void]$out.RemoveAt($out.Count - 1); $removed++
      }
      $inCfg = $true; continue
    }
    [void]$out.Add($ln)
  }
  if ($removed -eq 0) { & $Log "  未发现 LLM 组件，文件未改动"; return }
  Write-Schema $schemaPath $out
  & $Log ("  已移除 LLM 组件（含配置节）共 " + $removed + " 行")
}

function Get-SchemaPath([string]$schemaName) {
  # 写入动作一律落到用户文件夹（预装方案会先被复制过来）
  return (Resolve-SchemaPath $schemaName $true $null)
}

# ── 安装动作（GUI 的 CLI 子进程执行）──────────────
function Copy-FilesPluginAction($Log) {
  & $Log "── 复制插件版文件 ──"
  $installDir = Find-WeaselDir
  if (-not $installDir) { throw "未找到小狼毫安装目录。请先安装官方小狼毫 0.17.x" }
  & $Log "  安装目录: $installDir"
  foreach ($f in @("rime_llm.dll", "llm_filter.lua", "llm_processor.lua")) {
    if (-not (Test-Path (Join-Path $PluginSrc $f))) { throw "插件版文件不完整: 缺 $f" }
  }

  & $Log "[1/3] 停止算法服务 + 清理上次安装的旧二进制"
  Stop-WeaselService
  Clean-OldBinaries $installDir $Log
  & $Log "[2/3] 复制插件文件"
  foreach ($d in @("rime_llm.dll", "llama.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll")) {
    $s = Join-Path $PluginSrc $d
    if (Test-Path $s) {
      Copy-Binary $s (Join-Path $installDir $d) $Log
      & $Log ("  + " + $d)
    }
  }
  if (-not (Test-Path $LUA_DIR)) { New-Item -ItemType Directory -Path $LUA_DIR -Force | Out-Null }
  foreach ($l in @("llm_filter.lua", "llm_processor.lua")) {
    Copy-Item (Join-Path $PluginSrc $l) (Join-Path $LUA_DIR $l) -Force
    & $Log ("  + lua\" + $l)
  }
  & $Log "[3/3] 启动服务"
  Start-WeaselService $installDir $Log
  & $Log "完成。"
}

function Schema-AddAction([string]$schemaName, [string]$modelPath, $Log) {
  & $Log "── 方案配置加入 LLM 组件 ──"
  $schemaPath = Get-SchemaPath $schemaName
  & $Log ("  方案: " + $schemaPath)
  # 先剥离再添加（2026-08-26 定案）：无论原状是无 LLM / 本版 / 另一版配置，
  # 先统一剥净再全新插入（另一版组件行被 Edit-SchemaRemove 一并剥掉，无冲突）。
  # 模型路径本次未填时，保留方案中原有的生效 model_path（剥离会删整个节）；
  # 参数同理——先读后剥，重建节时逐键保留（2026-09-29 参数页上线，防重跑重置）
  $keepModel = Get-ActiveModelPath $schemaPath
  $prior = Read-LlmParams $schemaPath
  Edit-SchemaRemove $schemaPath $Log
  $useModel = if ($modelPath) { $modelPath } else { $keepModel }
  if ($useModel) { & $Log ("  模型: " + $useModel) }
  Edit-SchemaPlugin $schemaPath $useModel $Log $prior
  $installDir = Find-WeaselDir
  if ($installDir) { Invoke-Redeploy $installDir $Log }
  else { & $Log "  [警告] 未找到小狼毫目录，跳过自动重新部署（请托盘手动重新部署）" }
  & $Log "完成。"
}

function Schema-RemoveAction([string]$schemaName, $Log) {
  & $Log "── 方案配置去除 LLM 组件 ──"
  $schemaPath = Get-SchemaPath $schemaName
  & $Log ("  方案: " + $schemaPath)
  Edit-SchemaRemove $schemaPath $Log
  $installDir = Find-WeaselDir
  if ($installDir) { Invoke-Redeploy $installDir $Log }
  else { & $Log "  [警告] 未找到小狼毫目录，跳过自动重新部署" }
  & $Log "完成。"
}

# 同目标残留的 curl 写入者（2026-10-01：关窗后子进程可能仍在后台跑，重开再点会
# 变成"同一分片两个写入者"）。动作 = 结束旧进程后由本次 -C - 接管（分片不丢）。
function Stop-StaleDownloader([string]$tmp, $Log) {
  try {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'curl.exe'" -ErrorAction Stop)
  } catch { return 0 }
  $n = 0
  foreach ($pr in $procs) {
    if ($pr.CommandLine -and ($pr.CommandLine -like ("*" + $tmp + "*"))) {
      try {
        Stop-Process -Id $pr.ProcessId -Force -ErrorAction Stop
        $n++
        if ($Log) { & $Log ("  已结束上次遗留的下载进程（PID {0}），由本次续传接管" -f $pr.ProcessId) }
      } catch { }
    }
  }
  return $n
}

# 下载模型（v1/v2 实测实现移植：curl 断点续传 + 分片转正；子进程轮询分片
# 大小打进度行 → GUI 日志滚动显示。失败保留分片，重试 curl -C - 续传）
function Download-ModelAction([string]$modelPath, $Log) {
  & $Log "── 下载模型 ──"
  if (-not $modelPath) { $modelPath = $DEFAULT_MODEL }
  & $Log ("  目标: " + $modelPath)
  if (Test-Path $modelPath) {
    $sz = (Get-Item $modelPath).Length
    if ($sz -ge $MODEL_MIN_BYTES) {
      & $Log ("  模型已存在（{0:N0} MB），无需下载" -f ($sz / 1MB))
      & $Log "完成。"
      return
    }
    # ① 半截/损坏文件不再被当成"已存在"：小于下限 → 清掉重下（GUI 侧已确认过）
    & $Log ("  已存在文件仅 {0:N0} MB（小于 {1} MB，疑似未下完/损坏）→ 删除后重新下载" -f ($sz / 1MB), ($MODEL_MIN_BYTES / 1MB))
    Remove-Item -LiteralPath $modelPath -Force -ErrorAction SilentlyContinue
  }
  $dir = Split-Path $modelPath -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = $modelPath + ".download"
  [void](Stop-StaleDownloader $tmp $Log)
  if ((Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 0)) {
    & $Log ("  发现未完成分片 {0:N0} MB — 断点续传" -f ((Get-Item $tmp).Length / 1MB))
  }
  $p = Start-Process -FilePath "curl.exe" `
    -ArgumentList @("-L", "-C", "-", "-s", "-S", "-o", "`"$tmp`"", "`"$MODEL_URL`"") `
    -PassThru -WindowStyle Hidden
  # 记 PID：GUI 关窗时据此结束 curl（否则孙进程会脱离本进程继续写分片）
  try { Set-Content -LiteralPath ($tmp + ".pid") -Value $p.Id -Encoding ascii -Force } catch { }
  while (-not $p.HasExited) {
    Start-Sleep -Seconds 5
    if (Test-Path $tmp) {
      & $Log ("  进度: {0:N0} MB / 约 500MB" -f ((Get-Item $tmp).Length / 1MB))
    }
  }
  $code = $p.ExitCode
  if ($code -eq 0 -and (Test-Path $tmp) -and ((Get-Item $tmp).Length -ge $MODEL_MIN_BYTES)) {
    Move-Item $tmp $modelPath -Force
    Remove-Item -LiteralPath ($tmp + ".pid") -Force -ErrorAction SilentlyContinue
    & $Log ("  下载完成: {0:N0} MB → {1}" -f ((Get-Item $modelPath).Length / 1MB), $modelPath)
    & $Log "完成。"
  } else {
    & $Log ("  [ERROR] 下载失败（curl 退出码 $code）；分片已保留，重试可续传；或手动下载: $MODEL_URL")
    throw ("模型下载失败（curl 退出码 $code）——重试可断点续传")
  }
}

# 完整安装 = 复制文件 + 方案配置（CLI -CliAction install，自动化旧路径）
function Install-PluginAction([string]$schemaName, $Log) {
  Copy-FilesPluginAction $Log
  Schema-AddAction $schemaName "" $Log
}

# ── CLI / GUI 入口 ────────────────────────────────
function Invoke-Installer([string]$cliAction, [string]$schemaName, [string]$modelPath) {
  if ($cliAction) {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    # 5.1 坑：stdout 重定向到文件时 Write-Host 行尾只有裸 LF（0A），WinForms
    # TextBox 不认孤立 \n → GUI 日志区全部挤成一行（含 ^\[ERROR\] 行首锚定
    # 失效）。显式 CRLF + 逐条 Flush（GUI 250ms 轮询要实时增量）
    $Log = { param($t) [Console]::Out.Write($t + "`r`n"); [Console]::Out.Flush() }
    try {
      switch ($cliAction) {
        "status" {
          & $Log ("安装文件: " + $(if ($PluginReady) { "就绪 ($PluginSrc)" } else { "缺失" }))
          $dir = Find-WeaselDir
          & $Log ("小狼毫目录: " + $(if ($dir) { $dir } else { "未找到" }))
        }
        "install" {
          if (-not $schemaName) { throw "需要 -SchemaName 指定方案文件" }
          Install-PluginAction $schemaName $Log
        }
        "copy-files" { Copy-FilesPluginAction $Log }
        "schema-add" {
          if (-not $schemaName) { throw "需要 -SchemaName 指定方案文件" }
          Schema-AddAction $schemaName $modelPath $Log
        }
        "schema-remove" {
          if (-not $schemaName) { throw "需要 -SchemaName 指定方案文件" }
          Schema-RemoveAction $schemaName $Log
        }
        "download-model" { Download-ModelAction $modelPath $Log }
        default { & $Log "未知动作: $cliAction（status | install | copy-files | schema-add | schema-remove | download-model）"; exit 1 }
      }
    } catch {
      & $Log ("[ERROR] " + $_.Exception.Message)
      exit 1
    }
    exit 0
  }
  Run-InstallerGui
}

# ── GUI 框架（含全部历史修复：防弹窗重入/多信号判定/管理员警告）──
# 2026-09-29 改版（源码版 WeaselLLMSetup 界面同步）：TabControl 两页，
# 方案文件下拉为两页共用。布局铁律（源码版叠字事故同款）：任何两控件
# 矩形不得相交；Label 一律 AutoSize=false 固定宽度。
function Run-InstallerGui {
  $form = New-Object System.Windows.Forms.Form
  $form.Text = "LLM 重排安装器 — 插件版"
  $form.ClientSize = New-Object System.Drawing.Size(700, 726)
  $form.StartPosition = "CenterScreen"
  $form.FormBorderStyle = "FixedDialog"
  $form.MaximizeBox = $false
  # 底色 = 白（2026-10-01 用户定案：两版底色统一）。WinForms 的 BackColor 是**环境属性**，
  # 未显式设色的子控件（GroupBox / Label / CheckBox）会继承 → 一处置白即可全白。
  $form.BackColor = [System.Drawing.Color]::White
  # 字体/缩放交给系统（AutoScaleMode=Font 时 WinForms 按系统 DPI 缩放，控件不糊）
  $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
  # 状态色（原 DarkBlue/Firebrick 偏刺眼，改柔和且语义清晰）
  $colInfo = [System.Drawing.Color]::FromArgb(0, 90, 158)
  $colOk = [System.Drawing.Color]::FromArgb(0, 120, 60)
  $colErr = [System.Drawing.Color]::FromArgb(178, 34, 34)

  # ── 悬停提示（2026-09-30 用户定案）──
  # 配置说明**不再直出界面**：改为"一个配置项一行 + 行末『?』徽标"，
  # 鼠标悬停才显示该项说明。界面因此只剩参数本身，密度高且自解释。
  $script:tip = New-Object System.Windows.Forms.ToolTip
  $script:tip.InitialDelay = 300
  $script:tip.ReshowDelay = 100
  $script:tip.AutoPopDelay = 30000
  $script:tip.ShowAlways = $true
  # 说明文案（与源码版 WeaselLLMSetup **逐字对齐**，两版界面保持一致）。
  # 长文案**手工断行**：WinForms ToolTip 不设最大宽度，单行会长到出屏
  # （2026-09-30 实测 code_pattern 单行 1366px 顶到屏幕边缘）。
  $tipEnabled = "总开关：开 = 加载模型参与候选重排；关 = 卸载模型释放内存。`n保存后自动重新部署生效。"
  $tipModel = "GGUF 模型文件路径（留空 = 用户文件夹里的默认名）。`n下拉列出用户文件夹与本机 gguf_models 下的模型；`n换模型保存后会自动卸载并重载。"
  $tipCodePat = "触发条件：编码串全串正则匹配，只有匹配上的编码才交给 LLM 重排`n（写法与 Rime speller/auto_select_pattern 一致）。`n默认 .{4} = 恰 4 码。例：`n　.{4,} 4 码以上　　.{3,4} 3~4 码`n　[abcde]{4} 指定首码　　空 = 不限制`n含 \ 的写法要用单引号，如 '\d{4}'。"
  $tipMaxTok = "上文长度上限：取光标前多少个 token 作为重排依据（默认 10）。`n越大越准，但每次都更慢。"
  $tipMaxCand = "每次按键参与 LLM 打分的候选数上限（默认 5）。`n一般不用改——调大更准但更慢。"
  $tipCores = "推理用的 CPU 线程数（默认 4）。不要超过本机物理核；`n可用 bin\bench_threads.exe 实测最优值。"
  $tipBeta = "用户词频权重 β（默认 1.5，0 = 关闭）。`n融合分 = CE 分 + β·log(1+词频计数) + elw·词长加成`n越常上屏的词加分越多；加分在 log 域，可翻盘 LLM 的分差。"
  $tipElw = "预期词长权重 elw（默认 0.2，0 = 关闭）。`n融合分 = CE 分 + β·log(1+词频计数) + elw·词长加成`n按 词长 = 码长÷2 给候选加成，只对两码一字的方案有意义；`n成熟机器建议 0。"
  $tipDebug = "诊断日志：开启后每次重排都往用户文件夹写 rime_llm_debug.txt`n（逐候选 CE / 词频 / 词长与名次变化）。排障用，平时关闭。"
  $tipSave = "把上面的参数写进选中方案的 llm_rerank 配置节（键名与 yaml 里相同），`n随后自动重新部署生效。`n方案还没接入（缺配置节 / 缺组件行 / 残留另一版组件行）时，`n本按钮会先剥净再补齐组件行 + 写入配置节（原「接入 LLM」已并入这里）。"
  $tipScheme = "配置就写在选中的方案文件里。下拉列出**用户文件夹** %APPDATA%\Rime 与`n**程序文件夹** <小狼毫目录>\data（预装方案，带「（程序）」后缀）两处的 *.schema.yaml；`n**打开下拉即重扫两处**（外部新增/删除方案后无需手动刷新），界面无改动时还会重读当前文件。`n预装方案在写入前会自动复制到用户文件夹（Rime 解析顺序：用户文件夹优先）。"
  $tipStrip = "剥离：把选中方案里的 LLM 组件行与 llm_rerank 配置节整个删掉`n（方案回到『未接入』状态），并自动重新部署。`n日常只想改参数请用『保存并生效』。"
  $tipFiles = "复制文件：停服务 → 清理旧二进制 → 替换 rime_llm.dll 与 lua → 启服务。"
  $tipDownload = "下载模型：ModelScope 断点续传（curl -C -），落点 = 左边的模型路径框`n（留空 = 用户文件夹里的默认名 Qwen3.5-0.8B-Q4_K_M.gguf）。`n失败会保留 .download 分片，再点一次即续传。"

  # 控件工厂：AutoSize=false —— Label 默认宽度会被缩到文字宽，
  # 破坏公式行"+"右对齐列与编辑框同列对齐（固定宽度才可核对不相交）
  function Add-Ctl([string]$type, [string]$text, $parent, $x, $y, $w, $h) {
    $c = New-Object ("System.Windows.Forms." + $type)
    $c.Text = $text
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.AutoSize = $false
    $c.Size = New-Object System.Drawing.Size($w, $h)
    $parent.Controls.Add($c)
    return $c
  }
  # 原生分组框：把参数按用途装进去（替代"加粗裸文字"标题）
  function Add-Group($parent, [string]$title, $x, $y, $w, $h) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $title
    $g.Location = New-Object System.Drawing.Point($x, $y)
    $g.Size = New-Object System.Drawing.Size($w, $h)
    $g.AutoSize = $false
    $parent.Controls.Add($g)
    return $g
  }
  # 「?」徽标：18×18 自绘小圆 + 问号。说明只在悬停时弹出（ToolTip）。
  # 自绘走 Add_Paint 脚本块（沿用页签自绘的老办法，不用 Add-Type——
  # pwsh 7 里 Add-Type System.Drawing 会连环 CS0012，2026-09-30 踩过）。
  # 坑：Label 自己的文字在 Paint 事件**之前**画 → 圆底会把文字盖掉，
  # 故徽标文字由本函数自己 DrawString（Label.Text 仍留 "?"，供自动化/读屏识别）。
  # x 一律取分组框 ClientSize 右端，避免不同主题的边框宽度把徽标挤出可视区。
  $script:helpFont = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
  $script:helpBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(45, 78, 120))
  function Add-Help($parent, [string]$tip, $x, $y) {
    $c = Add-Ctl "Label" "?" $parent $x $y 18 18
    $c.BackColor = [System.Drawing.Color]::Transparent
    $c.ForeColor = [System.Drawing.Color]::FromArgb(45, 78, 120)
    $c.Font = $script:helpFont
    $c.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $c.Cursor = [System.Windows.Forms.Cursors]::Help
    $c.Add_Paint({
      param($s, $e)
      $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $fill = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(228, 235, 244))
      $edge = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(150, 172, 200))
      $e.Graphics.FillEllipse($fill, 0.5, 0.5, ($s.Width - 1.5), ($s.Height - 1.5))
      $e.Graphics.DrawEllipse($edge, 0.5, 0.5, ($s.Width - 1.5), ($s.Height - 1.5))
      $fmt = New-Object System.Drawing.StringFormat
      $fmt.Alignment = [System.Drawing.StringAlignment]::Center
      $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
      $rect = New-Object System.Drawing.RectangleF(0, 0, $s.Width, $s.Height)
      $e.Graphics.DrawString("?", $script:helpFont, $script:helpBrush, $rect, $fmt)
      $fmt.Dispose(); $edge.Dispose(); $fill.Dispose()
    })
    $script:tip.SetToolTip($c, $tip)
    return $c
  }
  # 行内「?」徽标 x：分组框客户区右端再退 24（18 宽徽标 + 6 余量）
  function Help-X($g) { $g.ClientSize.Width - 24 }

  # ── 按钮配色（2026-10-01 用户定案：按钮换背景色、更显眼）──────────────
  # WinForms 主题按钮**忽略** BackColor（UseVisualStyleBackColor=true 时不生效）
  # → 一律 FlatStyle=Flat + UseVisualStyleBackColor=false 才能上色。
  # 主按钮（保存并生效）= 深蓝白字；其余按钮 = 浅蓝深字；
  # 三态（常态/悬停/按下）各一套色。色值与源码版 WeaselLLMSetup.cpp
  # 的 kBtnAccent* / kBtnSoft* **逐值一致**，两版界面保持同款。
  $colBtnBg     = [System.Drawing.Color]::FromArgb(232, 240, 250)
  $colBtnBgHot  = [System.Drawing.Color]::FromArgb(214, 229, 246)
  $colBtnBgDown = [System.Drawing.Color]::FromArgb(196, 216, 240)
  $colBtnEdge   = [System.Drawing.Color]::FromArgb(157, 187, 220)
  $colBtnFg     = [System.Drawing.Color]::FromArgb(31, 78, 121)
  $colPriBg     = [System.Drawing.Color]::FromArgb(45, 108, 192)
  $colPriBgHot  = [System.Drawing.Color]::FromArgb(62, 128, 214)
  $colPriBgDown = [System.Drawing.Color]::FromArgb(30, 84, 156)
  $colPriEdge   = [System.Drawing.Color]::FromArgb(24, 70, 130)
  function Style-Btn($b, [bool]$primary) {
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.UseVisualStyleBackColor = $false
    $b.FlatAppearance.BorderSize = 1
    if ($primary) {
      $b.BackColor = $colPriBg
      $b.ForeColor = [System.Drawing.Color]::White
      $b.FlatAppearance.BorderColor = $colPriEdge
      $b.FlatAppearance.MouseOverBackColor = $colPriBgHot
      $b.FlatAppearance.MouseDownBackColor = $colPriBgDown
    } else {
      $b.BackColor = $colBtnBg
      $b.ForeColor = $colBtnFg
      $b.FlatAppearance.BorderColor = $colBtnEdge
      $b.FlatAppearance.MouseOverBackColor = $colBtnBgHot
      $b.FlatAppearance.MouseDownBackColor = $colBtnBgDown
    }
  }

  # 错误日志（2026-09-30 用户定案：界面不留日志框，**只在出错时**写文件到
  # GUI 程序所在目录 = installer\，便于用户回传；正常流程只更新状态行）
  $script:ErrLog = Join-Path $PSScriptRoot "install_error.log"
  function Write-ErrLog([string]$context, [string]$detail) {
    try {
      $head = "===== {0}  {1} =====" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $context
      Add-Content -Path $script:ErrLog -Value ($head + "`r`n" + $detail) -Encoding UTF8
      return $script:ErrLog
    } catch { return "(错误日志写入失败: $($_.Exception.Message))" }
  }

  # ══════════════════════════════════════════════════════════════════
  # 单页布局（2026-09-30 用户定案：与源码版 WeaselLLMSetup 尽量一致）
  #   —— 方案接入 / 总控 / 触发条件 / 推理规模 / 候选排序融合 / 诊断日志
  #   六块与源码版同序同标题同措辞；插件版多一块「安装」（复制文件 + 下载模型）
  #   与「导入方案…」按钮。原先分两页导致"加/去 LLM"与"参数"割裂，现合并：
  #   接入 / 剥离 / 启用 / 模型路径 / 参数 / 保存 全在同一页。
  #   界面**不留日志框**：正常只更新状态行，出错才写 install_error.log。
  # ══════════════════════════════════════════════════════════════════
  $GX = 12; $GW = 676

  # ── 方案接入（配置写在方案里 → 先选方案再改参数）──
  $g0 = Add-Group $form "方案接入" $GX 8 $GW 84
  [void](Add-Ctl "Label" "方案文件:" $g0 14 24 70 20)
  $cmbSchema = Add-Ctl "ComboBox" "" $g0 88 21 528 21
  $cmbSchema.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $script:tip.SetToolTip($cmbSchema, $tipScheme)
  Add-Help $g0 $tipScheme (Help-X $g0) 23 | Out-Null
  $lblScheStatus = Add-Ctl "Label" "" $g0 14 56 630 18
  $lblScheStatus.ForeColor = $colInfo

  # ── 总控：开关 + 模型路径 + 模型状态 ──
  $g1 = Add-Group $form "总控" $GX 100 $GW 114
  $chkEnabled = Add-Ctl "CheckBox" "启用 LLM 重排" $g1 14 22 200 24
  $script:tip.SetToolTip($chkEnabled, $tipEnabled)
  Add-Help $g1 $tipEnabled (Help-X $g1) 25 | Out-Null
  [void](Add-Ctl "Label" "模型路径:" $g1 14 54 70 20)
  $cmbModel = Add-Ctl "ComboBox" "" $g1 88 51 300 21
  $cmbModel.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
  $btnModelBrowse = Add-Ctl "Button" "浏览…" $g1 392 50 74 24
  $btnDownload = Add-Ctl "Button" "下载模型" $g1 470 50 128 24
  Style-Btn $btnModelBrowse $false
  Style-Btn $btnDownload $false
  $script:tip.SetToolTip($cmbModel, $tipModel)
  $script:tip.SetToolTip($btnModelBrowse, "选择已有的 .gguf 模型文件。")
  $script:tip.SetToolTip($btnDownload, $tipDownload)
  Add-Help $g1 $tipModel (Help-X $g1) 53 | Out-Null
  $lblModelStatus = Add-Ctl "Label" "" $g1 14 84 140 18
  $lblModelHint = Add-Ctl "Label" "" $g1 158 84 480 18
  $lblModelHint.ForeColor = [System.Drawing.Color]::DimGray

  # ── 触发条件（单行）──
  $g2 = Add-Group $form "触发条件" $GX 222 $GW 66
  [void](Add-Ctl "Label" "编码匹配:" $g2 14 24 76 20)
  $txtCodePat = Add-Ctl "TextBox" "" $g2 92 21 240 22
  $script:tip.SetToolTip($txtCodePat, $tipCodePat)
  Add-Help $g2 $tipCodePat (Help-X $g2) 23 | Out-Null

  # ── 推理规模 + 候选排序融合：五个参数各一行，标签列用同一个实测宽度 ──
  $lwP = 0
  foreach ($t in @("上文 token 上限:", "参与打分的候选数:", "CPU 线程数:",
                   "用户词频权重:", "预期词长权重:")) {
    $w = ([System.Windows.Forms.TextRenderer]::MeasureText($t, $form.Font)).Width + 8
    if ($w -gt $lwP) { $lwP = $w }
  }
  $g3 = Add-Group $form "推理规模" $GX 296 $GW 122
  $rowY = 22
  [void](Add-Ctl "Label" "上文 token 上限:" $g3 14 $rowY ($lwP + 4) 20)
  $txtMaxTok = Add-Ctl "TextBox" "" $g3 (14 + $lwP + 10) ($rowY - 3) 64 22
  $script:tip.SetToolTip($txtMaxTok, $tipMaxTok)
  Add-Help $g3 $tipMaxTok (Help-X $g3) ($rowY - 1) | Out-Null
  $rowY += 32
  [void](Add-Ctl "Label" "参与打分的候选数:" $g3 14 $rowY ($lwP + 4) 20)
  $txtMaxCand = Add-Ctl "TextBox" "" $g3 (14 + $lwP + 10) ($rowY - 3) 64 22
  $script:tip.SetToolTip($txtMaxCand, $tipMaxCand)
  Add-Help $g3 $tipMaxCand (Help-X $g3) ($rowY - 1) | Out-Null
  $rowY += 32
  [void](Add-Ctl "Label" "CPU 线程数:" $g3 14 $rowY ($lwP + 4) 20)
  $txtCores = Add-Ctl "TextBox" "" $g3 (14 + $lwP + 10) ($rowY - 3) 64 22
  $script:tip.SetToolTip($txtCores, $tipCores)
  Add-Help $g3 $tipCores (Help-X $g3) ($rowY - 1) | Out-Null

  $g4 = Add-Group $form "候选排序融合" $GX 426 $GW 92
  $rowY = 22
  [void](Add-Ctl "Label" "用户词频权重:" $g4 14 $rowY ($lwP + 4) 20)
  $txtBeta = Add-Ctl "TextBox" "" $g4 (14 + $lwP + 10) ($rowY - 3) 64 22
  $script:tip.SetToolTip($txtBeta, $tipBeta)
  Add-Help $g4 $tipBeta (Help-X $g4) ($rowY - 1) | Out-Null
  $rowY += 32
  [void](Add-Ctl "Label" "预期词长权重:" $g4 14 $rowY ($lwP + 4) 20)
  $txtElw = Add-Ctl "TextBox" "" $g4 (14 + $lwP + 10) ($rowY - 3) 64 22
  $script:tip.SetToolTip($txtElw, $tipElw)
  Add-Help $g4 $tipElw (Help-X $g4) ($rowY - 1) | Out-Null

  # ── 诊断日志（与源码版同位置：参数组之后、按钮之前）──
  $chkDebug = Add-Ctl "CheckBox" "诊断日志 debug_fusion" $form 16 528 260 22
  $script:tip.SetToolTip($chkDebug, $tipDebug)
  Add-Help $form $tipDebug 664 530 | Out-Null

  # ── 安装（插件版特有：二进制；源码版由 setup.exe 完成）──
  #    模型下载归「总控」的模型路径行（2026-10-01 用户定案：下载 = 配置动作，两版一致）
  $g5 = Add-Group $form "安装" $GX 556 $GW 76
  $btnFiles = Add-Ctl "Button" "复制文件" $g5 14 24 152 30
  Style-Btn $btnFiles $false
  $script:tip.SetToolTip($btnFiles, $tipFiles)
  $lblInstallStatus = Add-Ctl "Label" "" $g5 174 30 460 18
  $lblInstallStatus.ForeColor = $colInfo

  # ── 操作行：保存 / 剥离 / 关闭（剥离 = 保存的破坏性补充，2026-10-01 起并排）──
  #    2026-10-01 用户定案：本行按钮**同宽**（按最长的"保存并生效"实测，随字体/DPI 自适应）
  #    + 统一配色（主按钮深蓝白字，其余浅蓝深字）；『打开用户文件夹』已按用户要求删除
  #    （要看用户文件夹走小狼毫托盘右键的「用户文件夹」）
  $btnRowTexts = @("保存并生效", "剥离", "关闭")
  $btnRowW = 0
  foreach ($t in $btnRowTexts) {
    $w = ([System.Windows.Forms.TextRenderer]::MeasureText($t, $form.Font)).Width + 26
    if ($w -gt $btnRowW) { $btnRowW = $w }
  }
  $btnRowGap = 8
  $btnParamSave = Add-Ctl "Button" "保存并生效" $form 16 640 $btnRowW 32
  $btnStrip = Add-Ctl "Button" "剥离" $form (16 + $btnRowW + $btnRowGap) 640 $btnRowW 32
  $btnClose = Add-Ctl "Button" "关闭" $form (16 + 2 * ($btnRowW + $btnRowGap)) 640 $btnRowW 32
  Style-Btn $btnParamSave $true
  Style-Btn $btnStrip $false
  Style-Btn $btnClose $false
  # 回车 = 保存并生效（源码版同语义：DM_GETDEFID 回答 IDC_SAVE）
  $form.AcceptButton = $btnParamSave
  $script:tip.SetToolTip($btnParamSave, $tipSave)
  $script:tip.SetToolTip($btnStrip, $tipStrip)
  $lblParamStatus = Add-Ctl "Label" "" $form 16 678 668 18
  $lblParamStatus.ForeColor = $colInfo
  $lblFooter = Add-Ctl "Label" ("保存后自动重新部署生效　|　本机逻辑核 " + [Environment]::ProcessorCount + "　|　出错日志：install_error.log（本目录）") $form 16 700 668 16
  $lblFooter.ForeColor = [System.Drawing.Color]::DimGray
  $lblFooter.Font = New-Object System.Drawing.Font($form.Font.FontFamily, [float]($form.Font.Size - 0.75))

  # 参数字段注册表（键 = llm_rerank 键名）；默认值回填（= lua cfg 默认）
  $paramEdits = @{
    code_pattern = $txtCodePat
    max_tokens = $txtMaxTok
    max_candidates = $txtMaxCand
    cpu_cores = $txtCores
    freq_beta = $txtBeta
    expected_length_weight = $txtElw
  }
  foreach ($k in $PARAM_STR_KEYS) { $paramEdits[$k].Text = [string]$PARAM_DEFAULTS[$k] }
  foreach ($k in $PARAM_INT_KEYS) { $paramEdits[$k].Text = [string]$PARAM_DEFAULTS[$k] }
  $txtBeta.Text = Format-F2 ([double]$PARAM_DEFAULTS["freq_beta"])
  $txtElw.Text = Format-F2 ([double]$PARAM_DEFAULTS["expected_length_weight"])

  # ── 模型路径下拉扫描 + 模型状态（与源码版同款：只扫用户文件夹与
  #    %USERPROFILE%\gguf_models，避免遍历整盘）──
  function Get-ModelDirs {
    $d = @()
    if ($RIME_USER) { $d += $RIME_USER }
    if ($env:USERPROFILE) { $d += (Join-Path $env:USERPROFILE "gguf_models") }
    return $d
  }
  function Update-ModelCombo {
    $cur = $cmbModel.Text.Trim()
    $cmbModel.Items.Clear()
    foreach ($d in (Get-ModelDirs)) {
      if (-not (Test-Path $d)) { continue }
      Get-ChildItem $d -Filter *.gguf -File -ErrorAction SilentlyContinue |
        Select-Object -First 8 | ForEach-Object {
          if ($_.FullName -ne $cur) { [void]$cmbModel.Items.Add($_.FullName) }
        }
    }
  }
  function Update-ModelStatus {
    $p = $cmbModel.Text.Trim()
    if (-not $p) { $p = $DEFAULT_MODEL }
    if (Test-Path $p) {
      $len = (Get-Item $p).Length
      $mb = [int][Math]::Floor($len / 1MB)
      if ($len -ge $MODEL_MIN_BYTES) {
        $lblModelStatus.Text = "模型已就绪：$mb MB"
        $lblModelHint.Text = ""
      } else {
        # ① 半截/损坏文件不能显示成"已就绪"（否则重排静默失败、用户找不到原因）
        $lblModelStatus.Text = "模型文件可疑：仅 $mb MB"
        $lblModelHint.Text = "疑似未下完或损坏（完整约 508MB）——点『下载模型』会删除后重下，或用『浏览…』换一个"
      }
    } else {
      $lblModelStatus.Text = "模型文件不存在"
      $lblModelHint.Text = "点『下载模型』下到左边这个路径（可断点续传），或用『浏览…』选已有的 .gguf"
    }
  }

  # ── 方案清单：用户文件夹（无后缀）+ 程序文件夹预装方案（「（程序）」后缀）；
  #    同名以用户文件夹为准（Rime 解析顺序一致）──
  $SHARED_SUFFIX = "（程序）"
  $script:SchemaItems = @()      # display / name / path / shared
  function Get-SchemaList {
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    if (Test-Path $RIME_USER) {
      Get-ChildItem $RIME_USER -Filter *.schema.yaml -File -ErrorAction SilentlyContinue |
        Sort-Object Name | ForEach-Object {
          $seen[$_.Name] = $true
          [void]$list.Add([pscustomobject]@{ display = $_.Name; name = $_.Name; path = $_.FullName; shared = $false })
        }
    }
    $shared = Get-SharedDataDir
    if ($shared) {
      Get-ChildItem $shared -Filter *.schema.yaml -File -ErrorAction SilentlyContinue |
        Sort-Object Name | ForEach-Object {
          if (-not $seen.ContainsKey($_.Name)) {
            [void]$list.Add([pscustomobject]@{ display = ($_.Name + $SHARED_SUFFIX); name = $_.Name; path = $_.FullName; shared = $true })
          }
        }
    }
    return $list
  }
  function Get-SelectedSchema {
    if ($cmbSchema.SelectedItem -eq $null) { return $null }
    $disp = $cmbSchema.SelectedItem.ToString()
    return ($script:SchemaItems | Where-Object { $_.display -eq $disp } | Select-Object -First 1)
  }

  # ── 外部改动保护（2026-10-01 用户定案）────────────────────────────
  # 读参数时记下文件指纹；保存前若发现文件已被外部改过 → 弹框确认，避免用陈旧界面值覆盖。
  function Get-FileStamp([string]$path) {
    # 用**内容哈希**而不是时间戳：同内容重写/触摸文件不该误报"被外部修改"
    if (-not (Test-Path $path)) { return "" }
    return (Get-FileHash $path -Algorithm SHA1).Hash
  }
  # 界面是否有未保存改动：与"上次读入时的界面签名"比对（比事件脏标记简单可靠）
  function Get-UiSignature {
    $parts = @()
    foreach ($k in @($PARAM_STR_KEYS) + @($PARAM_INT_KEYS) + @($PARAM_DBL_KEYS)) {
      $parts += [string]$paramEdits[$k].Text.Trim()
    }
    $parts += [string]$chkEnabled.Checked
    $parts += [string]$chkDebug.Checked
    $parts += $cmbModel.Text.Trim()
    return ($parts -join "|")
  }
  function Test-UiDirty { return ((Get-UiSignature) -ne $script:UiSig) }
  $script:SuppressRead = $false
  $script:UiSig = ""
  $script:FileStamp = $null
  $script:LoadedDisplay = ""   # 当前已读入界面的方案（切换取消时把下拉拨回它）

  function Read-ParamsToUi {
    $item = Get-SelectedSchema
    if (-not $item) { return }
    $name = $item.name
    $path = $item.path
    $sec = $null
    try { if (Test-Path $path) { $sec = Read-LlmParams $path } } catch { }
    $v = @{}
    foreach ($k in $PARAM_DEFAULTS.Keys) { $v[$k] = $PARAM_DEFAULTS[$k] }
    # 无 llm_rerank 节 = 该方案还没接入：默认勾上「启用」，让"保存并生效"一步完成接入
    # （用户若不想启用，取消勾选再保存即可——那会写入 enabled: false）
    if (-not $sec) { $v.enabled = $true }
    if ($sec) {
      foreach ($k in $PARAM_INT_KEYS) {
        if ($sec.ContainsKey($k)) {
          $n = 0
          if ([int]::TryParse($sec[$k], [ref]$n)) { $v[$k] = $n }
        }
      }
      foreach ($k in $PARAM_DBL_KEYS) {
        if ($sec.ContainsKey($k)) {
          $d = 0.0
          if (Convert-ParamDouble $sec[$k] ([ref]$d)) { $v[$k] = $d }
        }
      }
      foreach ($k in $PARAM_BOOL_KEYS) {
        if ($sec.ContainsKey($k)) { $v[$k] = ($sec[$k] -ieq "true") }
      }
      foreach ($k in $PARAM_STR_KEYS) {
        if ($sec.ContainsKey($k)) { $v[$k] = [string]$sec[$k] }
      }
      if ($sec.ContainsKey("enabled")) { $v.enabled = ($sec["enabled"] -ieq "true") }
    }
    foreach ($k in $PARAM_INT_KEYS) { $paramEdits[$k].Text = [string]$v[$k] }
    foreach ($k in $PARAM_STR_KEYS) { $paramEdits[$k].Text = [string]$v[$k] }
    $txtBeta.Text = Format-F2 ([double]$v.freq_beta)
    $txtElw.Text = Format-F2 ([double]$v.expected_length_weight)
    $chkEnabled.Checked = $v.enabled
    $chkDebug.Checked = $v.debug_fusion
    # 模型路径：节里是正斜杠，显示统一反斜杠；未配置显示默认路径
    # （model_path 不在 $PARAM_*_KEYS 里——那是六个参数框的键集，故直接从节读）
    $mp = ""
    if ($sec -and $sec.ContainsKey("model_path")) { $mp = [string]$sec["model_path"] }
    if ($mp) { $cmbModel.Text = ($mp -replace '/', '\') } else { $cmbModel.Text = $DEFAULT_MODEL }
    Update-ModelCombo
    Update-ModelStatus
    if ($sec) {
      $lblScheStatus.Text = "已加载 $name 的 llm_rerank 配置节"
      $lblScheStatus.ForeColor = $colInfo
    } elseif ($item.shared) {
      $lblScheStatus.Text = "[未接入] $name 是程序文件夹里的预装方案——点『保存并生效』会先复制到用户文件夹，再补组件行 + 配置节"
      $lblScheStatus.ForeColor = $colErr
    } else {
      $lblScheStatus.Text = "[未接入] $name 里没有 llm_rerank 节——显示默认值（已默认勾选启用），点『保存并生效』即接入"
      $lblScheStatus.ForeColor = $colErr
    }
    # 记文件指纹 + 界面签名（外部改动保护 / 脏标记）
    $script:FileStamp = [pscustomobject]@{ Path = $path; Sig = (Get-FileStamp $path) }
    $script:UiSig = Get-UiSignature
    $script:LoadedDisplay = $item.display
  }

  function Test-ModelPathOk([string]$p) {
    # ③ model_path 必须是绝对路径（运行期直接交给 llama，不做 %VAR% 展开、
    #    也不解析相对路径——相对值会按服务进程 cwd 解析，几乎必然加载失败）
    if (-not $p) { return $true }   # 空 = 用默认
    if ($p -match '^[A-Za-z]:[\\/]') { return $true }   # X:\ 或 X:/
    if ($p -match '^\\\\') { return $true }             # UNC \\server\share
    return $false
  }

  function Save-ParamsFromUi {
    $item = Get-SelectedSchema
    if (-not $item) {
      $lblParamStatus.Text = "请先在顶部选择方案文件"
      $lblParamStatus.ForeColor = $colErr
      return
    }
    $name = $item.name
    $copied = $false
    try {
      # 写入一律落用户文件夹：预装方案先复制过来（Rime 解析顺序 = 用户文件夹优先）
      if ($item.shared) { $copied = $true }
      $path = Resolve-SchemaPath $name $true $null
    } catch {
      $lblParamStatus.Text = "[失败] " + $_.Exception.Message
      $lblParamStatus.ForeColor = $colErr
      Write-ErrLog "保存参数失败（$name）" ($_.Exception.ToString()) | Out-Null
      return
    }
    if (-not (Test-Path $path)) {
      $lblParamStatus.Text = "方案文件不存在: $path"
      $lblParamStatus.ForeColor = $colErr
      return
    }
    # 外部改动保护：读入后文件又被别处改过（手工编辑 / 别的工具写）→ 先问再覆盖
    if ($script:FileStamp -and $script:FileStamp.Path -eq $path -and -not $copied) {
      $now = Get-FileStamp $path
      if ($now -ne $script:FileStamp.Sig) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
          ("方案文件已被外部修改：`n$path`n`n用界面上的值覆盖它？（选『否』= 丢弃界面改动并重新读取）"),
          "文件已变更", [System.Windows.Forms.MessageBoxButtons]::YesNo,
          [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) {
          Read-ParamsToUi
          $lblParamStatus.Text = "已取消保存并重新读取磁盘上的方案"
          $lblParamStatus.ForeColor = $colInfo
          return
        }
      }
    }
    $p = @{}
    foreach ($k in $PARAM_STR_KEYS) {
      $p[$k] = [string]$paramEdits[$k].Text.Trim()
    }
    foreach ($k in $PARAM_INT_KEYS) {
      $n = 0
      if (-not [int]::TryParse($paramEdits[$k].Text.Trim(), [ref]$n)) {
        $lblParamStatus.Text = "『$k』不是有效整数：$($paramEdits[$k].Text)"
        return
      }
      $p[$k] = $n
    }
    foreach ($k in $PARAM_DBL_KEYS) {
      $d = 0.0
      if (-not (Convert-ParamDouble $paramEdits[$k].Text.Trim() ([ref]$d))) {
        $lblParamStatus.Text = "『$k』不是有效数字：$($paramEdits[$k].Text)"
        return
      }
      if ($d -lt 0) {
        $lblParamStatus.Text = "『$k』不能为负（0 = 关闭）"
        return
      }
      $p[$k] = $d
    }
    $p.enabled = $chkEnabled.Checked
    $p.debug_fusion = $chkDebug.Checked
    # ③ 模型路径：空 = 默认；非空必须是绝对路径（相对路径运行期必然加载失败）
    $mpRaw = $cmbModel.Text.Trim()
    if ($mpRaw -and -not (Test-ModelPathOk $mpRaw)) {
      $lblParamStatus.Text = "『模型路径』必须是绝对路径（如 D:\gguf_models\xxx.gguf）或留空用默认：$mpRaw"
      $lblParamStatus.ForeColor = $colErr
      return
    }
    # 模型路径归本页管理（= llm_rerank.model_path）；与源码版同规则：
    # 空 或 等于默认路径 → 写注释占位（默认路径由 llm_filter 兜底）
    $mp = $cmbModel.Text.Trim()
    if ($mp -eq $DEFAULT_MODEL) { $mp = "" }
    # 保存 = 自适应（2026-10-01 用户定案，替代原「接入 LLM」+「保存」两按钮）：
    #   节缺失 / 组件行缺失 / 残留另一版组件行 → 重建接入（剥净 + 插本版组件 + 按界面值写节）
    #   否则                                   → 只重写节
    $need = $null
    try { $need = Test-SchemaNeedsRebuild $path } catch {
      $lblParamStatus.Text = "[失败] 读取方案失败：" + $_.Exception.Message
      $lblParamStatus.ForeColor = $colErr
      Write-ErrLog "保存参数失败（读取 $name）" ($_.Exception.ToString()) | Out-Null
      return
    }
    $logLines = New-Object System.Collections.Generic.List[string]
    $sink = { param($t) [void]$logLines.Add([string]$t) }
    try {
      if ($need.Rebuild) { Edit-SchemaRebuild $path $p $mp $sink }   # enabled 走 $p.enabled（复选框）
      else { Update-LlmSection $path $p $mp }
    } catch {
      $lblParamStatus.Text = "[失败] " + $_.Exception.Message
      $lblParamStatus.ForeColor = $colErr
      Write-ErrLog "保存参数失败（$name）" ($_.Exception.ToString() + "`n" + ($logLines -join "`n")) | Out-Null
      return
    }
    $didRebuild = $need.Rebuild
    $script:FileStamp = [pscustomobject]@{ Path = $path; Sig = (Get-FileStamp $path) }
    $lblParamStatus.Text = "正在重新部署…"
    $lblParamStatus.ForeColor = $colInfo
    $form.Refresh()
    if ($copied) { Refresh-Ui }        # 预装方案已进用户文件夹 → 下拉改列用户那份
    Read-ParamsToUi                    # 让「方案接入」状态行从"未接入"变"已加载"，并刷新脏标记快照
    $act = $(if ($didRebuild) { "已接入并保存" } else { "已保存" })
    $note = @($(if ($copied) { "原为程序文件夹预装方案，已复制到用户文件夹" }), $(if ($didRebuild) { "补齐了组件行：" + $need.Why }) |
              Where-Object { $_ })
    $note = $(if ($note.Count) { "（" + ($note -join "；") + "）" } else { "" })
    $installDir = Find-WeaselDir
    if ($installDir) {
      $notes = New-Object System.Collections.Generic.List[string]
      Invoke-Redeploy $installDir { param($t) [void]$notes.Add($t) }
      $bad = @($notes | Where-Object { $_ -match '提示|失败|错误' })
      if ($bad.Count) {
        $lblParamStatus.Text = "$act$note；重新部署有提示：" + ($bad[-1] -replace '^\s+', '')
        $lblParamStatus.ForeColor = $colErr
      } else {
        $lblParamStatus.Text = "$act $name$note 并触发重新部署——部署完成后参数生效"
      }
    } else {
      $lblParamStatus.Text = "$act$note；未找到小狼毫目录，请托盘手动重新部署"
      $lblParamStatus.ForeColor = $colErr
    }
  }

  function Refresh-Ui {
    $sel = if ($cmbSchema.SelectedItem) { $cmbSchema.SelectedItem.ToString() } else { "" }
    $script:SchemaItems = Get-SchemaList
    $cmbSchema.Items.Clear()
    foreach ($it in $script:SchemaItems) { [void]$cmbSchema.Items.Add($it.display) }
    if ($cmbSchema.Items.Count -gt 0) {
      # Items.Clear 会先把选择置空，恢复选择时必然触发 SelectedIndexChanged——
      # 这里抑制它，避免"仅重扫列表"顺带把界面改动冲掉（重读由调用方按需显式做）
      $script:SuppressRead = $true
      try {
        if ($sel -and $cmbSchema.Items.Contains($sel)) {
          $cmbSchema.SelectedItem = $sel     # 刷新保持当前选择
        } else {
          $cmbSchema.SelectedIndex = 0
        }
      } finally { $script:SuppressRead = $false }
      # 下拉列表按最长项加宽（预装方案名 + 「（程序）」比框宽长）
      $dw = 0
      foreach ($it in $script:SchemaItems) {
        $w = ([System.Windows.Forms.TextRenderer]::MeasureText($it.display, $form.Font)).Width
        if ($w -gt $dw) { $dw = $w }
      }
      if ($dw -gt 0) { $cmbSchema.DropDownWidth = $dw + 24 }
    }
    $dir = Find-WeaselDir
    $lblInstallStatus.Text = ("安装文件: " + $(if ($PluginReady) { "就绪" } else { "缺失" }) + "  |  小狼毫: " +
                              $(if ($dir) { $dir } else { "未找到（请先安装官方小狼毫）" }))
    $lblInstallStatus.ForeColor = $(if ($dir) { $colInfo } else { $colErr })
    $btnFiles.Enabled = ($PluginReady -and $dir)
    $btnDownload.Enabled = $true
    $hasScheme = ($cmbSchema.Items.Count -gt 0)
    $btnStrip.Enabled = $hasScheme
    $btnParamSave.Enabled = $hasScheme
  }

  # 后台子进程执行（自身 CLI 模式，stdout 落临时文件轮询读入内存）
  # 2026-09-30：界面不再有日志框——输出只用于①状态行最后一行②出错时写
  # install_error.log，因此这里收进 StringBuilder 而不是 TextBox。
  $script:WorkProc = $null
  $script:WorkLog  = Join-Path $env:TEMP "llm_installer_plugin.log"
  $script:WorkOff  = 0
  $script:WorkDone = $true
  $script:WorkText = New-Object System.Text.StringBuilder
  $script:WorkAction = ""
  $entryScript = Join-Path $PSScriptRoot "install_plugin.ps1"
  $actionDone = @{
    "copy-files"     = "文件复制完成（rime_llm.dll + lua 已部署，服务已重启）"
    "download-model" = "模型下载完成"
    "schema-add"     = "已接入 LLM（组件行 + llm_rerank 配置节）"
    "schema-remove"  = "已剥离 LLM（组件行 + 配置节）"
  }

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 250

  function Start-Work([string]$action, [string]$schemaName, [string]$modelPath) {
    if (-not $script:WorkDone) { return }
    $script:WorkDone = $false; $script:WorkOff = 0
    $script:WorkAction = $action
    [void]$script:WorkText.Clear()
    if (Test-Path $script:WorkLog) { Remove-Item $script:WorkLog -Force }
    $lblInstallStatus.Text = "执行中…（复制文件 / 模型下载可能需要几分钟）"
    $lblInstallStatus.ForeColor = $colInfo
    $btnFiles.Enabled = $false; $btnDownload.Enabled = $false
    $btnStrip.Enabled = $false
    $btnParamSave.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
      $psExe = (Get-Process -Id $PID).Path
      $argList = @("-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", "`"$entryScript`"",
                   "-CliAction", $action)
      if ($schemaName) { $argList += @("-SchemaName", "`"$schemaName`"") }
      if ($modelPath)  { $argList += @("-ModelPath", "`"$modelPath`"") }
      $script:WorkProc = Start-Process -FilePath $psExe -ArgumentList $argList `
        -WindowStyle Hidden -RedirectStandardOutput $script:WorkLog -PassThru
      $timer.Start()
    } catch {
      $script:WorkDone = $true; $script:WorkProc = $null
      $form.Cursor = [System.Windows.Forms.Cursors]::Default
      $lblInstallStatus.Text = "[失败] 无法启动子进程：" + $_.Exception.Message
      $lblInstallStatus.ForeColor = $colErr
      Write-ErrLog "启动子进程失败（$action）" ($_.Exception.ToString()) | Out-Null
      Refresh-Ui
    }
  }
  function Read-WorkLog {
    if (-not (Test-Path $script:WorkLog)) { return }
    try {
      $fs = [IO.File]::Open($script:WorkLog, 'Open', 'Read', 'ReadWrite')
      try {
        if ($fs.Length -le $script:WorkOff) { return }
        $fs.Seek($script:WorkOff, 'Begin') | Out-Null
        $buf = New-Object byte[] ($fs.Length - $script:WorkOff)
        $n = $fs.Read($buf, 0, $buf.Length)
        $script:WorkOff += $n
        $chunk = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
        [void]$script:WorkText.Append($chunk)
        # 进度反馈：把子进程输出的最后一行（curl 百分比等）显示到状态行
        $last = ($chunk -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        if ($last) {
          $last = $last.Trim()
          if ($last.Length -gt 110) { $last = $last.Substring(0, 110) + "…" }
          $lblInstallStatus.Text = $last
          $lblInstallStatus.ForeColor = $colInfo
        }
      } finally { $fs.Close() }
    } catch { }
  }

  $timer.Add_Tick({
    Read-WorkLog
    if (-not $script:WorkProc) { return }
    if (-not $script:WorkProc.HasExited) { return }
    # 先停表复位再弹窗（防 MessageBox 模态循环重入）；失败判定多信号
    Start-Sleep -Milliseconds 200
    Read-WorkLog
    $code = $null
    try { $code = $script:WorkProc.ExitCode } catch { }
    $text = $script:WorkText.ToString()
    $failed = ($text -match '(?m)^\[ERROR\]') -or ($null -ne $code -and $code -ne 0)
    $act = $script:WorkAction
    $timer.Stop()
    $script:WorkDone = $true
    $script:WorkProc = $null
    $script:WorkAction = ""
    $form.Cursor = [System.Windows.Forms.Cursors]::Default
    Refresh-Ui
    Read-ParamsToUi
    if ($failed) {
      $errLine = ($text -split "`r?`n" | Where-Object { $_ -match '^\[ERROR\]' } | Select-Object -Last 1)
      $msg = if ($errLine) { $errLine -replace '^\[ERROR\]\s*', '' } else { "操作失败（退出码 $code）" }
      $logPath = Write-ErrLog "操作失败：$act（退出码 $code）" ($text.Trim())
      $lblInstallStatus.Text = "[失败] $msg"
      $lblInstallStatus.ForeColor = $colErr
      [System.Windows.Forms.MessageBox]::Show(($msg + "`n`n详细日志：`n" + $logPath), "操作失败",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } else {
      $lblInstallStatus.Text = $(if ($actionDone.ContainsKey($act)) { $actionDone[$act] } else { "完成" })
      $lblInstallStatus.ForeColor = $colOk
    }
  })

  # ── 事件接线（单页：接入已并入「保存并生效」，本页只剩 剥离 / 保存）──
  # 下拉打开即重扫两处方案列表（外部新增/删除方案无需手动刷新）；界面无未保存改动时
  # 顺便重读当前文件（吸收外部编辑）；有改动则只重扫列表，不覆盖用户输入。
  $cmbSchema.Add_DropDown({
    Refresh-Ui
    if (-not (Test-UiDirty)) { Read-ParamsToUi }
  })
  # 模型路径：手输/下拉/浏览后刷新状态行与下载目标
  $cmbModel.Add_TextChanged({ Update-ModelStatus })
  $cmbModel.Add_SelectedIndexChanged({ Update-ModelStatus })
  $btnModelBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "GGUF 模型 (*.gguf)|*.gguf|所有文件 (*.*)|*.*"
    $dlg.InitialDirectory = $(if (Test-Path $RIME_USER) { $RIME_USER } else { $env:USERPROFILE })
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
      $cmbModel.Text = $dlg.FileName
      Update-ModelStatus
    }
  })
  $btnFiles.Add_Click({ Start-Work "copy-files" "" "" })
  $btnDownload.Add_Click({
    # ① 已存在但明显偏小 → 先确认再覆盖（此前会被当成"已存在"直接跳过）
    $target = $cmbModel.Text.Trim()
    if (-not $target) { $target = $DEFAULT_MODEL }
    if (Test-Path $target) {
      $len = (Get-Item $target).Length
      if ($len -lt $MODEL_MIN_BYTES) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
          ("目标路径已有文件，但只有 {0:N0} MB（疑似未下完或损坏）：`n{1}`n`n删除它并重新下载？" -f ($len / 1MB), $target),
          "模型文件可疑", [System.Windows.Forms.MessageBoxButtons]::YesNo,
          [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) {
          $lblParamStatus.Text = "已取消下载（保留现有文件）"
          $lblParamStatus.ForeColor = $colInfo
          return
        }
      }
    }
    Start-Work "download-model" "" $cmbModel.Text.Trim()
  })
  $btnStrip.Add_Click({
    $item = Get-SelectedSchema
    if (-not $item) {
      [System.Windows.Forms.MessageBox]::Show("请先选择方案文件", "提示") | Out-Null
      return
    }
    if ($item.shared) {
      # 预装方案（程序文件夹）根本没接入过 LLM，剥离无意义也不该动它
      $lblScheStatus.Text = "[提示] $($item.name) 是程序文件夹预装方案（未被修改过）——无可剥离；若要改它请点『保存并生效』（会复制到用户文件夹）"
      $lblScheStatus.ForeColor = $colErr
      return
    }
    Start-Work "schema-remove" $item.name ""
  })
  $btnParamSave.Add_Click({ Save-ParamsFromUi })
  $btnClose.Add_Click({ $form.Close() })
  # 切方案 = 切配置（配置节在方案里）；重扫列表时的恢复选择被抑制。
  # ④ 有未保存改动时先问（否则切换会把界面改动静默丢掉）；选"否"把下拉拨回去
  $cmbSchema.Add_SelectedIndexChanged({
    if ($script:SuppressRead) { return }
    if (Test-UiDirty) {
      $ans = [System.Windows.Forms.MessageBox]::Show(
        "当前方案有未保存的改动。`n`n切换方案会丢弃这些改动，继续吗？",
        "未保存的改动", [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
      if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) {
        $script:SuppressRead = $true
        try {
          if ($script:LoadedDisplay -and $cmbSchema.Items.Contains($script:LoadedDisplay)) {
            $cmbSchema.SelectedItem = $script:LoadedDisplay
          }
        } finally { $script:SuppressRead = $false }
        $lblParamStatus.Text = "已取消切换（保留未保存的改动）"
        $lblParamStatus.ForeColor = $colInfo
        return
      }
    }
    Read-ParamsToUi
  })

  $form.Add_Shown({
    Refresh-Ui
    Read-ParamsToUi
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
      $lblParamStatus.Text = "[警告] 未以管理员运行，请用 install_plugin.bat 启动"
      $lblParamStatus.ForeColor = $colErr
    }
  })

  try {
    [void]$form.ShowDialog()
  } catch {
    # GUI 顶层异常：写错误日志 + 弹一次框（正常流程不会有）
    $logPath = Write-ErrLog "GUI 未捕获异常" ($_.Exception.ToString() + "`n" + ($_.ScriptStackTrace))
    [System.Windows.Forms.MessageBox]::Show(("安装器出错：`n" + $_.Exception.Message + "`n`n详细日志：`n" + $logPath),
      "出错", [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    throw
  } finally {
    if ($script:WorkProc -and -not $script:WorkProc.HasExited) {
      try { $script:WorkProc.Kill() } catch { }
    }
    # ② 关窗时把 curl 一并结束：下载动作的 curl 是"子进程的孙进程"，
    #    只杀包装 pwsh 会留下一个仍在写分片的孤儿（重开再点会变成两个写入者）。
    #    分片本身保留 → 下次点『下载模型』照样断点续传。
    try {
      $dlTarget = if ($cmbModel) { $cmbModel.Text.Trim() } else { "" }
      if (-not $dlTarget) { $dlTarget = $DEFAULT_MODEL }
      Stop-StaleDownloader ($dlTarget + ".download") $null | Out-Null
    } catch { }
  }
}

Invoke-Installer -CliAction $CliAction -SchemaName $SchemaName -ModelPath $ModelPath
