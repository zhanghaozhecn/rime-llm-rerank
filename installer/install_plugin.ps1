# install_plugin.ps1 — 插件版安装器（单文件；GUI / CLI）
# 历史：原拆分 install_plugin.ps1（入口壳）+ common.ps1（两版共用逻辑）是为
# 跨仓同步——2026-08-27 源码版改用 setup.exe 安装包后共用已名存实亡，
# 2026-09-04 按用户定案合并为本仓库单文件，源码版动作与双版分支随之删除。
# GUI：双击 install_plugin.bat（提权）→ TabControl 两页：
#   『安装』页 = 复制文件 / 下载模型 / 方案配置加·去 LLM（四按钮）+ 日志
#   『参数配置』页 = 源码版 WeaselLLMSetup 界面同步（2026-09-29）：源码版同款
#     分组参数编辑器（触发条件/推理规模/候选排序融合公式行/排障），读写选中
#     方案 llm_rerank 节，保存后自动重新部署（插件版参数在 schema 节、改后
#     需部署生效——与源码版 llm_rerank.yaml 热重载不同）
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
$RIME_USER = Join-Path $env:APPDATA "Rime"
$LUA_DIR = Join-Path $RIME_USER "lua"

# ── 模型（下载按钮用；curl 为 Win10 1803+ 自带）──
# 默认模型路径 = 用户文件夹（2026-08-27 用户定案：不假设存在 D: 分区；
# 有 D 盘模型的机器在 GUI/schema 里显式填 D:\gguf_models\...）
$DEFAULT_MODEL = Join-Path (Join-Path $env:APPDATA "Rime") "Qwen3.5-0.8B-Q4_K_M.gguf"
$MODEL_URL = "https://modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/resolve/master/Qwen3.5-0.8B-Q4_K_M.gguf"

function Find-WeaselDir {
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
$PARAM_DEFAULTS = [ordered]@{
  enabled = $false
  min_code_len = 4; max_code_len = 0; min_tokens = 1
  max_tokens = 10; max_candidates = 5; cpu_cores = 4
  freq_beta = 1.5; expected_length_weight = 0.2; debug_fusion = $false
}
$PARAM_INT_KEYS  = @("min_code_len","max_code_len","min_tokens","max_tokens","max_candidates","cpu_cores")
$PARAM_DBL_KEYS  = @("freq_beta","expected_length_weight")
$PARAM_BOOL_KEYS = @("debug_fusion")

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
      if ($v -match '^".*"$') { $v = $v.Trim('"') }
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
  if ($start -lt 0) { throw "方案内没有 llm_rerank 配置节——请先执行『方案配置加 LLM』" }
  $end = $start + 1
  while ($end -lt $lines.Count -and $lines[$end] -notmatch '^\S') { $end++ }
  # 注意：@() 数组元素里 "str" + $(if ...) 会被拆成两个元素（实测，2026-09-29
  # 沙箱测试抓出：enabled: 与 false 分家两行）——拼接一律用字符串内插 $()
  $sec = @(
    "llm_rerank:",
    "  enabled: $(if ($p.enabled) { 'true' } else { 'false' })",
    "  min_code_len: $($p.min_code_len)",
    "  max_code_len: $($p.max_code_len) # 0=不限制",
    "  min_tokens: $($p.min_tokens)",
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
  }
  return $d
}

# llm_rerank 配置节；modelPath 非空时写为生效行（反斜杠→正斜杠，含空格则加引号），
# 留空则保持注释示例（运行时默认 %APPDATA%\Rime\Qwen3.5-0.8B-Q4_K_M.gguf）。
# prior = 重跑加 LLM 时方案里已有的参数（Read-LlmParams 结果）——先剥后插
# 重建节时逐键保留，防止重跑把用户自定义参数重置回默认（model_path 同思路）。
function Get-LlmCfgLines([string]$modelPath, $prior) {
  $d = Merge-LlmParams $prior
  $l = @(
    "", "llm_rerank:",
    "  enabled: true",
    "  min_code_len: $($d.min_code_len)",
    "  max_code_len: $($d.max_code_len) # 0=不限制",
    "  min_tokens: $($d.min_tokens)",
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
# prior = 方案中已有参数（Read-LlmParams 结果），重建配置节时逐键保留
function Edit-SchemaPlugin([string]$schemaPath, [string]$modelPath, $Log, $prior) {
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
    Get-LlmCfgLines $modelPath $prior | ForEach-Object { [void]$out.Add($_) }
    & $Log "  + llm_rerank: 配置节（enabled: true）"; $changed = $true
  } elseif ($modelPath) {
    if (Add-ModelPathToExisting $out $modelPath $Log) { $changed = $true }
  }
  if ($changed) { Write-Schema $schemaPath $out; & $Log "  schema 已更新（幂等，重复运行不重复插入）" }
  else { & $Log "  schema 组件已存在，无需修改" }
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
  $p = Join-Path $RIME_USER $schemaName
  if (-not (Test-Path $p)) { throw "方案文件不存在: $p（请先把方案 yaml 放入 %APPDATA%\Rime，或用界面浏览选择）" }
  return $p
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

# 下载模型（v1/v2 实测实现移植：curl 断点续传 + 分片转正；子进程轮询分片
# 大小打进度行 → GUI 日志滚动显示。失败保留分片，重试 curl -C - 续传）
function Download-ModelAction([string]$modelPath, $Log) {
  & $Log "── 下载模型 ──"
  if (-not $modelPath) { $modelPath = $DEFAULT_MODEL }
  & $Log ("  目标: " + $modelPath)
  if (Test-Path $modelPath) {
    & $Log ("  模型已存在（{0:N0} MB），无需下载" -f ((Get-Item $modelPath).Length / 1MB))
    & $Log "完成。"
    return
  }
  $dir = Split-Path $modelPath -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = $modelPath + ".download"
  if ((Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 0)) {
    & $Log ("  发现未完成分片 {0:N0} MB — 断点续传" -f ((Get-Item $tmp).Length / 1MB))
  }
  $p = Start-Process -FilePath "curl.exe" `
    -ArgumentList @("-L", "-C", "-", "-s", "-S", "-o", "`"$tmp`"", "`"$MODEL_URL`"") `
    -PassThru -WindowStyle Hidden
  while (-not $p.HasExited) {
    Start-Sleep -Seconds 5
    if (Test-Path $tmp) {
      & $Log ("  进度: {0:N0} MB / 约 500MB" -f ((Get-Item $tmp).Length / 1MB))
    }
  }
  $code = $p.ExitCode
  if ($code -eq 0 -and (Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 100MB)) {
    Move-Item $tmp $modelPath -Force
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
  $form.ClientSize = New-Object System.Drawing.Size(684, 514)
  $form.StartPosition = "CenterScreen"
  $form.FormBorderStyle = "FixedDialog"
  $form.MaximizeBox = $false
  $fontBold = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)

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
  function Add-Hdr($parent, [string]$text, $x, $y, $w) {
    $c = Add-Ctl "Label" $text $parent $x $y $w 18
    $c.Font = $fontBold
    return $c
  }

  # ── 共用顶栏：方案文件（『安装』『参数配置』两页共用上下文）──
  [void](Add-Ctl "Label" "方案文件:" $form 12 16 70 20)
  $cmbSchema = Add-Ctl "ComboBox" "" $form 85 13 400 21
  $cmbSchema.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $btnRefresh = Add-Ctl "Button" "刷新" $form 492 12 80 23
  $btnBrowse = Add-Ctl "Button" "浏览..." $form 578 12 94 23

  $tabs = New-Object System.Windows.Forms.TabControl
  $tabs.Location = New-Object System.Drawing.Point(8, 42)
  $tabs.Size = New-Object System.Drawing.Size(668, 464)
  $tabInstall = New-Object System.Windows.Forms.TabPage("安装")
  $tabParams = New-Object System.Windows.Forms.TabPage("参数配置")
  [void]$tabs.TabPages.Add($tabInstall)
  [void]$tabs.TabPages.Add($tabParams)
  $form.Controls.Add($tabs)

  # ── 『安装』页：原四按钮动作流 ────────────────
  $lblIntro = Add-Ctl "Label" "『复制文件』= 停服务→替换二进制→启服务；『下载模型』= ModelScope 断点续传（目标 = 模型路径框，留空 = 默认 %APPDATA%\Rime\Qwen3.5-0.8B-Q4_K_M.gguf）；『方案配置加/去 LLM』只改选中方案并自动重新部署（模型路径填写则写入配置）。参数在『参数配置』页写入选中方案；切换版本 = 重装小狼毫 + 跑另一版安装器（方案配置先剥后插，自动转换）。" $tabInstall 10 8 648 64
  $lblIntro.ForeColor = [System.Drawing.Color]::DimGray
  [void](Add-Ctl "Label" "模型路径:" $tabInstall 10 86 70 20)
  $txtModel = Add-Ctl "TextBox" "" $tabInstall 85 83 560 21
  $btnFiles = Add-Ctl "Button" "复制文件" $tabInstall 10 114 152 36
  $btnModel = Add-Ctl "Button" "下载模型" $tabInstall 168 114 152 36
  $btnAdd = Add-Ctl "Button" "方案配置加 LLM" $tabInstall 326 114 164 36
  $btnRemove = Add-Ctl "Button" "方案配置去 LLM" $tabInstall 496 114 158 36
  $lblStatus = Add-Ctl "Label" "" $tabInstall 10 160 648 18
  $lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
  $txtLog = Add-Ctl "TextBox" "" $tabInstall 10 182 648 238
  $txtLog.Multiline = $true
  $txtLog.ReadOnly = $true
  # 自动折行：长路径 / 模型 URL 超出框宽时不截断隐藏（无需横向滚动条）
  $txtLog.ScrollBars = "Vertical"
  $txtLog.WordWrap = $true
  $txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)

  # ── 『参数配置』页：源码版 WeaselLLMSetup 同款分组（触发条件/推理规模/
  # 候选排序融合/排障），β·log(1+eff) 与 elw·span·匹配词长 挖空同列 x=122。
  # 读写选中方案 llm_rerank 节；模型路径不在本页（安装页配置），保存时原样保留。
  $p2 = $tabParams
  [void](Add-Hdr $p2 "参数写入选中方案的 llm_rerank 配置节；保存后自动重新部署生效（模型路径在『安装』页配置）" 10 6 645)
  $chkEnabled = Add-Ctl "CheckBox" "启用 LLM 重排" $p2 10 28 260 24
  [void](Add-Hdr $p2 "触发条件 —— 何时打分" 10 54 320)
  [void](Add-Ctl "Label" "最小编码长度" $p2 10 78 108 20)
  $txtMinCode = Add-Ctl "TextBox" "" $p2 122 74 52 22
  [void](Add-Ctl "Label" "最大编码长度（0=不限）" $p2 210 78 168 20)
  $txtMaxCode = Add-Ctl "TextBox" "" $p2 384 74 52 22
  [void](Add-Ctl "Label" "最少上文 token" $p2 10 106 108 20)
  $txtMinTok = Add-Ctl "TextBox" "" $p2 122 102 52 22
  [void](Add-Hdr $p2 "推理规模 —— 每次算多少、多快" 10 132 360)
  [void](Add-Ctl "Label" "上文 token 上限" $p2 10 156 108 20)
  $txtMaxTok = Add-Ctl "TextBox" "" $p2 122 152 52 22
  [void](Add-Ctl "Label" "候选数上限" $p2 210 156 96 20)
  $txtMaxCand = Add-Ctl "TextBox" "" $p2 384 152 52 22
  [void](Add-Ctl "Label" "CPU 线程数" $p2 10 184 108 20)
  $txtCores = Add-Ctl "TextBox" "" $p2 122 180 52 22
  [void](Add-Hdr $p2 "候选排序融合 —— 分数怎么合成" 10 210 380)
  [void](Add-Ctl "Label" "融合分 = score + " $p2 10 234 108 20)
  $txtBeta = Add-Ctl "TextBox" "" $p2 122 230 52 22
  [void](Add-Ctl "Label" "·log(1+eff)" $p2 178 234 90 20)
  $lblPlus = Add-Ctl "Label" "+" $p2 10 262 108 20
  $lblPlus.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
  $txtElw = Add-Ctl "TextBox" "" $p2 122 258 52 22
  [void](Add-Ctl "Label" "·span·匹配词长" $p2 178 262 130 20)
  [void](Add-Ctl "Label" "β = 词频系数（0=关闭）；elw = 预期词长权重（0=关闭）" $p2 10 290 490 18)
  [void](Add-Ctl "Label" "elw 仅两码一字方案生效：词长=码长/2 的候选获得 span×elw 加成" $p2 10 310 520 18)
  $chkDebug = Add-Ctl "CheckBox" "诊断日志 debug_fusion（逐候选融合明细写用户文件夹 rime_llm_debug.txt）" $p2 10 336 630 24
  $btnParamRead = Add-Ctl "Button" "读取参数" $p2 10 368 100 28
  $btnParamSave = Add-Ctl "Button" "保存并生效" $p2 120 368 110 28
  $lblParamStatus = Add-Ctl "Label" "" $p2 245 374 400 18
  $lblParamStatus.ForeColor = [System.Drawing.Color]::DarkBlue

  # 参数字段注册表（键 = llm_rerank 键名）；默认值回填（= lua cfg 默认）
  $paramEdits = @{
    min_code_len = $txtMinCode
    max_code_len = $txtMaxCode
    min_tokens = $txtMinTok
    max_tokens = $txtMaxTok
    max_candidates = $txtMaxCand
    cpu_cores = $txtCores
    freq_beta = $txtBeta
    expected_length_weight = $txtElw
  }
  foreach ($k in $PARAM_INT_KEYS) { $paramEdits[$k].Text = [string]$PARAM_DEFAULTS[$k] }
  $txtBeta.Text = Format-F2 ([double]$PARAM_DEFAULTS["freq_beta"])
  $txtElw.Text = Format-F2 ([double]$PARAM_DEFAULTS["expected_length_weight"])

  function Read-ParamsToUi {
    if ($cmbSchema.SelectedItem -eq $null) { return }
    $name = $cmbSchema.SelectedItem.ToString()
    $path = Join-Path $RIME_USER $name
    $sec = $null
    try { if (Test-Path $path) { $sec = Read-LlmParams $path } } catch { }
    $v = @{}
    foreach ($k in $PARAM_DEFAULTS.Keys) { $v[$k] = $PARAM_DEFAULTS[$k] }
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
      if ($sec.ContainsKey("enabled")) { $v.enabled = ($sec["enabled"] -ieq "true") }
    }
    foreach ($k in $PARAM_INT_KEYS) { $paramEdits[$k].Text = [string]$v[$k] }
    $txtBeta.Text = Format-F2 ([double]$v.freq_beta)
    $txtElw.Text = Format-F2 ([double]$v.expected_length_weight)
    $chkEnabled.Checked = $v.enabled
    $chkDebug.Checked = $v.debug_fusion
    if ($sec) {
      $lblParamStatus.Text = "已加载 $name 的参数"
      $lblParamStatus.ForeColor = [System.Drawing.Color]::DarkBlue
    } else {
      $lblParamStatus.Text = "$name 未接入 LLM —— 显示默认值；接入用『安装』页『方案配置加 LLM』"
      $lblParamStatus.ForeColor = [System.Drawing.Color]::Firebrick
    }
  }

  function Save-ParamsFromUi {
    if ($cmbSchema.SelectedItem -eq $null) {
      $lblParamStatus.Text = "请先在顶部选择方案文件"
      return
    }
    $name = $cmbSchema.SelectedItem.ToString()
    $path = Join-Path $RIME_USER $name
    if (-not (Test-Path $path)) {
      $lblParamStatus.Text = "方案文件不存在: $path"
      return
    }
    $p = @{}
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
    try {
      $modelPath = Get-ActiveModelPath $path   # 模型路径本页不管理——原样保留
      Update-LlmSection $path $p $modelPath
    } catch {
      $lblParamStatus.Text = "[失败] " + $_.Exception.Message
      $lblParamStatus.ForeColor = [System.Drawing.Color]::Firebrick
      return
    }
    $lblParamStatus.Text = "已保存到 $name，正在重新部署…"
    $form.Refresh()
    $installDir = Find-WeaselDir
    if ($installDir) {
      Invoke-Redeploy $installDir { param($t) $txtLog.AppendText($t + "`r`n") }
      $lblParamStatus.Text = "已保存并触发重新部署——部署完成后参数生效"
    } else {
      $lblParamStatus.Text = "已保存；未找到小狼毫目录，请托盘手动重新部署"
    }
  }

  function Refresh-Ui {
    $cmbSchema.Items.Clear()
    if (Test-Path $RIME_USER) {
      Get-ChildItem $RIME_USER -Filter "*.schema.yaml" -Name -ErrorAction SilentlyContinue |
        ForEach-Object { [void]$cmbSchema.Items.Add($_) }
      if ($cmbSchema.Items.Count -gt 0) { $cmbSchema.SelectedIndex = 0 }
    }
    $dir = Find-WeaselDir
    $lblStatus.Text = ("安装文件: " + $(if ($PluginReady) { "就绪" } else { "缺失" }) + "  |  小狼毫: " +
                       $(if ($dir) { $dir } else { "未找到（请先安装官方小狼毫）" }))
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
    $btnFiles.Enabled = ($PluginReady -and $dir)
    $btnModel.Enabled = $true
    $btnAdd.Enabled = ($cmbSchema.Items.Count -gt 0)
    $btnRemove.Enabled = ($cmbSchema.Items.Count -gt 0)
  }

  # 后台子进程执行（自身 CLI 模式，stdout 重定向轮询刷日志）
  $script:WorkProc = $null
  $script:WorkLog  = Join-Path $env:TEMP "llm_installer_plugin.log"
  $script:WorkOff  = 0
  $script:WorkDone = $true
  $entryScript = Join-Path $PSScriptRoot "install_plugin.ps1"

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 250

  function Start-Work([string]$action, [string]$schemaName, [string]$modelPath) {
    if (-not $script:WorkDone) { return }
    $script:WorkDone = $false; $script:WorkOff = 0
    if (Test-Path $script:WorkLog) { Remove-Item $script:WorkLog -Force }
    $txtLog.AppendText("────────────────────`r`n")
    $lblStatus.Text = "执行中…（文件复制/替换/模型下载可能需要较长时间）"
    $btnFiles.Enabled = $false; $btnModel.Enabled = $false
    $btnAdd.Enabled = $false; $btnRemove.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
      $psExe = (Get-Process -Id $PID).Path
      $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$entryScript`"",
                   "-CliAction", $action)
      if ($schemaName) { $argList += @("-SchemaName", "`"$schemaName`"") }
      if ($modelPath)  { $argList += @("-ModelPath", "`"$modelPath`"") }
      $script:WorkProc = Start-Process -FilePath $psExe -ArgumentList $argList `
        -WindowStyle Hidden -RedirectStandardOutput $script:WorkLog -PassThru
      $timer.Start()
    } catch {
      $script:WorkDone = $true; $script:WorkProc = $null
      $form.Cursor = [System.Windows.Forms.Cursors]::Default
      $txtLog.AppendText("[失败] 无法启动子进程: " + $_.Exception.Message + "`r`n")
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
        $txtLog.AppendText([Text.Encoding]::UTF8.GetString($buf, 0, $n))
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
    $failed = ($txtLog.Text -match '(?m)^\[ERROR\]') -or
              ($null -ne $code -and $code -ne 0)
    $timer.Stop()
    $script:WorkDone = $true
    $script:WorkProc = $null
    $form.Cursor = [System.Windows.Forms.Cursors]::Default
    Refresh-Ui
    if ($failed) {
      $txtLog.AppendText("[失败]`r`n")
      $errLine = ($txtLog.Text -split "`r`n" | Where-Object { $_ -match '^\[ERROR\]' } | Select-Object -Last 1)
      $msg = if ($errLine) { $errLine -replace '^\[ERROR\]\s*', '' } else { "详见日志" }
      [System.Windows.Forms.MessageBox]::Show($msg, "操作失败",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } else {
      $txtLog.AppendText("[完成]`r`n")
    }
  })

  $btnRefresh.Add_Click({ Refresh-Ui })
  $btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "RIME 方案 (*.schema.yaml)|*.schema.yaml|YAML (*.yaml)|*.yaml"
    if (Test-Path $RIME_USER) { $dlg.InitialDirectory = $RIME_USER }
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
      $name = Split-Path $dlg.FileName -Leaf
      $dest = Join-Path $RIME_USER $name
      if ($dlg.FileName -ne $dest) {
        Copy-Item $dlg.FileName $dest -Force
        $txtLog.AppendText("已拷贝方案到用户目录: $name`r`n")
      }
      Refresh-Ui
      if ($cmbSchema.Items.Contains($name)) { $cmbSchema.SelectedItem = $name }
    }
  })
  $btnFiles.Add_Click({ Start-Work "copy-files" "" "" })
  $btnModel.Add_Click({ Start-Work "download-model" "" $txtModel.Text.Trim() })
  $btnAdd.Add_Click({
    if ($cmbSchema.SelectedItem -eq $null) {
      [System.Windows.Forms.MessageBox]::Show("请先选择方案文件", "提示") | Out-Null
      return
    }
    Start-Work "schema-add" $cmbSchema.SelectedItem.ToString() $txtModel.Text.Trim()
  })
  $btnRemove.Add_Click({
    if ($cmbSchema.SelectedItem -eq $null) {
      [System.Windows.Forms.MessageBox]::Show("请先选择方案文件", "提示") | Out-Null
      return
    }
    Start-Work "schema-remove" $cmbSchema.SelectedItem.ToString() ""
  })

  # 『参数配置』页：读取 / 保存（读写选中方案 llm_rerank 节；状态行走标签不弹窗）
  $cmbSchema.Add_SelectedIndexChanged({ Read-ParamsToUi })
  $btnParamRead.Add_Click({ Read-ParamsToUi })
  $btnParamSave.Add_Click({ Save-ParamsFromUi })

  $form.Add_Shown({
    Refresh-Ui
    # 测试钩子：自动化测试直接落在参数页（TabControl 无跨进程可靠的通知消息）
    if ($env:LLM_INSTALLER_TAB2) { $tabs.SelectedIndex = 1 }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
      $txtLog.AppendText("[警告] 当前未以管理员运行。请关闭本窗口，用 install_plugin.bat 启动。`r`n")
      $lblStatus.Text = "[警告] 未以管理员运行，请用 install_plugin.bat 启动"
      $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
    }
  })

  [void]$form.ShowDialog()
}

Invoke-Installer -CliAction $CliAction -SchemaName $SchemaName -ModelPath $ModelPath
