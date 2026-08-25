# install_llm_gui.ps1 — LLM 重排一键安装器（插件版 / 源码版 GUI）
# 由 install_llm_gui.bat 提权启动（GUI 模式）；也支持命令行模式（供测试/高级用户）：
#   powershell -ExecutionPolicy Bypass -File install_llm_gui.ps1 -CliAction status
#     -CliAction install-plugin | install-source | restore-plugin | restore-source | status
#     -SchemaName pdsp.schema.yaml  -ModelPath d:\...\model.gguf
# 兼容 Windows PowerShell 5.1 / PowerShell 7（本文件须保存为 UTF-8 with BOM）。
#
# GUI：选择方案 schema + 模型路径（留空=默认）→ 一键安装插件版/源码版 / 还原。
# 安装动作在本脚本的 CLI 子进程执行（stdout 重定向到临时文件轮询刷日志），
# GUI 线程不卡顿；子进程继承管理员权限。
#
# 版本文件来源（自动探测）：
#   plugin\  rime_llm.dll + llm_filter.lua + llm_processor.lua（发布树）
#   source\  rime.dll / WeaselServer.exe / WeaselDeployer.exe / weaselx64.dll /
#            weasel32.dll / opencc.dll / vcomp140.dll（发布树）
#   开发机从仓库树运行时回退 ..\user\ 与 ..\..\rime-llm-ime\bin\
#
# 安装清单：%APPDATA%\Rime\llm_installer.json（edition/date/schema/install_dir）。
# 还原策略（降低出错概率）：**仅修改配置文件** —— 剥离 schema 的 LLM 组件行与
# llm_rerank 配置节 + 触发重新部署；不删/不恢复任何二进制。二进制回官方基线
# 由用户重装官方小狼毫完成（还原时给出指引）。剥离后 LLM 组件不被 schema
# 引用即不加载，输入法可正常使用。

param(
  [string]$CliAction = "",
  [string]$SchemaName = "",
  [string]$ModelPath = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── 常量与路径探测 ────────────────────────────────
$RIME_USER  = Join-Path $env:APPDATA "Rime"
$LUA_DIR    = Join-Path $RIME_USER "lua"
$MANIFEST   = Join-Path $RIME_USER "llm_installer.json"
$DEFAULT_MODEL = "d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf"
$MODEL_URL  = "https://modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/resolve/master/Qwen3.5-0.8B-Q4_K_M.gguf"

$PluginSrc = Join-Path $PSScriptRoot "plugin"
if (-not (Test-Path (Join-Path $PluginSrc "rime_llm.dll"))) {
  $alt = Join-Path (Split-Path $PSScriptRoot -Parent) "user"
  if (Test-Path (Join-Path $alt "rime_llm.dll")) { $PluginSrc = $alt }
}
$SourceSrc = Join-Path $PSScriptRoot "source"
if (-not (Test-Path (Join-Path $SourceSrc "rime.dll"))) {
  $alt = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "rime-llm-ime\bin"
  if (Test-Path (Join-Path $alt "rime.dll")) { $SourceSrc = $alt }
}
$PluginReady = Test-Path (Join-Path $PluginSrc "rime_llm.dll")
$SourceReady = Test-Path (Join-Path $SourceSrc "rime.dll")

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

function Test-SourceBuild([string]$dir) {
  # 官方 rime.dll 不含 "llm_filter" 字符串；源码版编译进 DLL
  $bytes = [IO.File]::ReadAllBytes((Join-Path $dir "rime.dll"))
  return ([Text.Encoding]::ASCII.GetString($bytes)).Contains("llm_filter")
}

function Get-Manifest {
  if (Test-Path $MANIFEST) {
    try { return Get-Content $MANIFEST -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  }
  return $null
}

# ── schema 编辑（幂等）────────────────────────────
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Schema([string]$path) {
  [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)
}
function Write-Schema([string]$path, $lines) {
  [IO.File]::WriteAllLines($path, $lines, $Utf8NoBom)
}

function Test-SchemaConflict($lines, [string]$edition) {
  if ($edition -eq "plugin") {
    if (($lines | Where-Object { $_ -match '^\s*-\s+llm_filter\s*$' }).Count -gt 0) {
      return "检测到源码版组件（- llm_filter）：插件版与源码版二选一，请先还原源码版"
    }
  } else {
    if (($lines | Where-Object { $_ -match 'lua_filter@\*llm_filter' }).Count -gt 0) {
      return "检测到插件版组件（lua_filter@*llm_filter）：插件版与源码版二选一，请先还原插件版"
    }
  }
  return $null
}

# 插件版：processors 最前 lua_processor + uniquifier 后 lua_filter + llm_rerank 节
function Edit-SchemaPlugin([string]$schemaPath, $Log) {
  $lines = Read-Schema $schemaPath
  $conflict = Test-SchemaConflict $lines "plugin"
  if ($conflict) { throw $conflict }
  $changed = $false
  $out = New-Object System.Collections.Generic.List[string]
  $hasProc = ($lines | Where-Object { $_ -match 'lua_processor@\*llm_processor' }).Count -gt 0
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
    if ($inserted) { & $Log "  + processors: lua_processor@*llm_processor（最前）"; $changed = $true }
    else { throw "未找到 processors 块，无法插入组件（请检查方案文件）" }
    $lines = @(); foreach ($l in $out) { $lines += $l }
    $out = New-Object System.Collections.Generic.List[string]
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
    @("", "llm_rerank:", "  enabled: true", "  min_code_len: 4",
      "  # max_code_len: 0", "  # long_word_first: false",
      "  # expected_length_weight: 0.20", "  # freq_weight: 0.25", "  # freq_k: 5",
      "  # min_tokens: 1", "  # max_tokens: 10", "  # max_candidates: 5",
      "  # cpu_cores: 4",
      "  # model_path: d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
    ) | ForEach-Object { [void]$out.Add($_) }
    & $Log "  + llm_rerank: 配置节（enabled: true）"; $changed = $true
  }
  if ($changed) { Write-Schema $schemaPath $out; & $Log "  schema 已更新（幂等，重复安装不重复插入）" }
  else { & $Log "  schema 组件已存在，无需修改" }
}

# 源码版：uniquifier 后 llm_filter + llm_rerank 节
function Edit-SchemaSource([string]$schemaPath, $Log) {
  $lines = Read-Schema $schemaPath
  $conflict = Test-SchemaConflict $lines "source"
  if ($conflict) { throw $conflict }
  $changed = $false
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($l in $lines) { [void]$out.Add($l) }
  $hasFilt = ($lines | Where-Object { $_ -match '^\s*-\s+llm_filter\s*$' }).Count -gt 0
  $hasCfg  = ($lines | Where-Object { $_ -match '^llm_rerank:' }).Count -gt 0
  if (-not $hasFilt) {
    $inFilt = $false; $inserted = $false
    for ($i = 0; $i -lt $out.Count; $i++) {
      if ($out[$i] -match '^\s+filters:') { $inFilt = $true; continue }
      if ($inFilt -and $out[$i] -match '^\s+- uniquifier') {
        $out.Insert($i + 1, "    - llm_filter")
        $inserted = $true; break
      }
    }
    if ($inserted) { & $Log "  + filters: llm_filter（uniquifier 之后、pin_fix 之前）"; $changed = $true }
    else { throw "未找到 filters 块或 uniquifier，无法插入组件" }
  }
  if (-not $hasCfg) {
    @("", "llm_rerank:", "  enabled: true", "  min_code_len: 4",
      "  # max_code_len: 0", "  # long_word_first: false",
      "  # freq_weight: 0.25", "  # freq_k: 5",
      "  # min_tokens: 1", "  # max_tokens: 10", "  # max_candidates: 5",
      "  # cpu_cores: 4",
      "  # model_path: d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf"
    ) | ForEach-Object { [void]$out.Add($_) }
    & $Log "  + llm_rerank: 配置节（enabled: true）"; $changed = $true
  }
  if ($changed) { Write-Schema $schemaPath $out; & $Log "  schema 已更新（幂等）" }
  else { & $Log "  schema 组件已存在，无需修改" }
}

# 还原：剥离两版组件行 + llm_rerank 配置节（保留用户其他改动）
function Strip-SchemaLlm([string]$schemaPath, $Log) {
  $lines = Read-Schema $schemaPath
  $out = New-Object System.Collections.Generic.List[string]
  $inCfg = $false; $removed = 0
  foreach ($ln in $lines) {
    if ($ln -match '^llm_rerank:') { $inCfg = $true; $removed++; continue }
    if ($inCfg) {
      if ($ln -match '^\S') { $inCfg = $false }   # 下一个顶层键：配置节结束
      else { $removed++; continue }
    }
    if ($ln -match '^\s*-\s+lua_processor@\*llm_processor\s*$' -or
        $ln -match '^\s*-\s+lua_filter@\*llm_filter\s*$' -or
        $ln -match '^\s*-\s+llm_filter\s*$') { $removed++; continue }
    [void]$out.Add($ln)
  }
  while ($out.Count -ge 2 -and $out[$out.Count - 1] -eq "" -and $out[$out.Count - 2] -eq "") {
    $out.RemoveAt($out.Count - 1)
  }
  if ($removed -gt 0) {
    Write-Schema $schemaPath $out
    & $Log "  schema 已剥离 LLM 组件与配置节（删除 $removed 行）"
  } else {
    & $Log "  schema 未发现 LLM 组件，无需修改"
  }
}

# ── 模型 ─────────────────────────────────────────
function Ensure-Model([string]$model, $Log) {
  if (-not $model) { $model = $DEFAULT_MODEL }
  if (Test-Path $model) {
    & $Log ("  模型已存在（{0:N0} MB）：{1}" -f ((Get-Item $model).Length / 1MB), $model)
    return $true
  }
  & $Log "  模型未找到: $model — 开始下载（约 500MB，断点续传，可中断重试）"
  $dir = Split-Path $model -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = $model + ".download"
  # 5.1: EAP=Stop 下原生命令写 stderr 会误抛异常，下载段局部降为 Continue
  $ErrorActionPreference = "Continue"
  & curl.exe -L -C - -s -S -o $tmp $MODEL_URL 2>$null
  $code = $LASTEXITCODE
  $ErrorActionPreference = "Stop"
  if ($code -eq 0 -and (Test-Path $tmp) -and (Get-Item $tmp).Length -gt 100MB) {
    Move-Item $tmp $model -Force
    & $Log ("  下载完成: {0:N0} MB → {1}" -f ((Get-Item $model).Length / 1MB), $model)
    return $true
  }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  & $Log "  [错误] 模型下载失败（可重新运行续传）。手动下载：$MODEL_URL"
  return $false
}

# ── 安装 / 还原动作（CLI 子进程执行，禁止 UI 调用）──
function Write-Manifest([string]$edition, [string]$schemaName, [string]$installDir) {
  $m = @{
    edition     = $edition
    date        = (Get-Date -Format "yyyy-MM-dd HH:mm")
    schema      = $schemaName
    install_dir = $installDir
  }
  $m | ConvertTo-Json | Out-File $MANIFEST -Encoding utf8 -Force
}

function Invoke-Redeploy([string]$installDir, $Log) {
  $deployer = Join-Path $installDir "WeaselDeployer.exe"
  if (Test-Path $deployer) {
    & $Log "  触发重新部署（WeaselDeployer /deploy）…"
    try {
      $p = Start-Process -FilePath $deployer -ArgumentList "/deploy" -PassThru -Wait -ErrorAction Stop
      & $Log ("  重新部署退出码: " + $p.ExitCode)
    } catch { & $Log "  [警告] 自动重新部署失败，请手动：托盘小狼毫图标 → 右键 → 重新部署" }
  } else {
    & $Log "  请手动重新部署：托盘小狼毫图标 → 右键 → 重新部署"
  }
}

# 替换安装目录二进制：WeaselServer.exe（算法服务）加载 rime.dll / rime_llm.dll
# （及 ggml 系），必须停进程才能替换；且 TSF 客户端在击键时会自动把 server
# 拉起，单次 taskkill+等待与复制存在竞态（曾致 rime.dll 替换失败）。
# 策略：先直接试复制（未加载则零打扰）；失败 → 停算法服务 → 重试。
function Copy-BinaryRetry([string]$s, [string]$d, $Log) {
  for ($i = 0; $i -le 6; $i++) {
    try { Copy-Item $s $d -Force -ErrorAction Stop; return }
    catch {
      if ($i -eq 6) {
        throw ("无法替换 " + $d + "：请手动结束 WeaselServer.exe（任务管理器）或退出小狼毫后重试")
      }
      taskkill /f /im WeaselServer.exe 2>$null | Out-Null
      taskkill /f /im WeaselDeployer.exe 2>$null | Out-Null
      & $Log ("  " + [IO.Path]::GetFileName($d) + " 被算法服务占用，已停止服务，重试（" + ($i + 1) + "/6）…")
      Start-Sleep -Seconds 2
    }
  }
}

function Install-PluginAction([string]$schemaName, [string]$model, $Log) {
  & $Log "── 安装插件版 ──"
  $installDir = Find-WeaselDir
  if (-not $installDir) { throw "未找到小狼毫安装目录（找不到 rime.dll）。请先安装官方小狼毫 0.17.x" }
  & $Log "  安装目录: $installDir"
  if (Test-SourceBuild $installDir) {
    throw "安装目录的 rime.dll 是『源码版 LLM 组件』。插件版需要官方 rime.dll —— 请先还原源码版（或重装官方小狼毫）"
  }
  # 预检（任何失败都在改动文件之前中止）
  $schemaPath = Join-Path $RIME_USER $schemaName
  if (-not (Test-Path $schemaPath)) { throw "方案文件不存在: $schemaPath" }
  $conflict = Test-SchemaConflict (Read-Schema $schemaPath) "plugin"
  if ($conflict) { throw $conflict }
  foreach ($f in @("rime_llm.dll", "llm_filter.lua", "llm_processor.lua")) {
    if (-not (Test-Path (Join-Path $PluginSrc $f))) {
      throw "插件版文件不完整: 缺 $f（plugin\ 目录）"
    }
  }
  if (-not (Ensure-Model $model $Log)) { throw "模型缺失，安装中止（文件未改动）" }

  & $Log "[1/3] 复制插件文件（若被运行中的算法服务加载，自动停止后重试）"
  foreach ($d in @("rime_llm.dll", "llama.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll")) {
    $s = Join-Path $PluginSrc $d
    if (Test-Path $s) {
      Copy-BinaryRetry $s (Join-Path $installDir $d) $Log
      & $Log ("  + " + $d)
    }
  }
  if (-not (Test-Path $LUA_DIR)) { New-Item -ItemType Directory -Path $LUA_DIR -Force | Out-Null }
  foreach ($l in @("llm_filter.lua", "llm_processor.lua")) {
    $s = Join-Path $PluginSrc $l
    if (Test-Path $s) {
      Copy-Item $s (Join-Path $LUA_DIR $l) -Force
      & $Log ("  + lua\" + $l)
    }
  }
  & $Log "[2/3] 修改方案 schema"
  Edit-SchemaPlugin $schemaPath $Log
  & $Log "[3/3] 写安装清单 + 重新部署"
  Write-Manifest "plugin" $schemaName $installDir
  Invoke-Redeploy $installDir $Log
  & $Log "安装插件版完成。验证：打满 4 码首选候选带 AI 标记；日志 %APPDATA%\Rime\rime_llm_events.txt"
}

function Install-SourceAction([string]$schemaName, [string]$model, $Log) {
  & $Log "── 安装源码版 ──"
  $installDir = Find-WeaselDir
  if (-not $installDir) { throw "未找到小狼毫安装目录。请先安装官方小狼毫 0.17.4" }
  & $Log "  安装目录: $installDir"
  # 预检（任何失败都在改动文件之前中止）
  $schemaPath = Join-Path $RIME_USER $schemaName
  if (-not (Test-Path $schemaPath)) { throw "方案文件不存在: $schemaPath" }
  $conflict = Test-SchemaConflict (Read-Schema $schemaPath) "source"
  if ($conflict) { throw $conflict }
  foreach ($f in @("rime.dll", "WeaselServer.exe", "weaselx64.dll")) {
    if (-not (Test-Path (Join-Path $SourceSrc $f))) {
      throw "源码版文件不完整: 缺 $f（source\ 目录）"
    }
  }
  if (-not (Ensure-Model $model $Log)) { throw "模型缺失，安装中止（文件未改动）" }

  & $Log "[1/4] 停止 WeaselServer（算法服务持有 rime.dll，必须停止才能替换）"
  taskkill /f /im WeaselServer.exe 2>$null | Out-Null
  taskkill /f /im WeaselDeployer.exe 2>$null | Out-Null
  Start-Sleep -Seconds 2

  & $Log "[2/4] 复制 LLM 二进制（TSF 击键会自动重启服务，占用则自动停止重试）"
  foreach ($pair in @(
      @("rime.dll", "rime.dll"), @("WeaselServer.exe", "WeaselServer.exe"),
      @("WeaselDeployer.exe", "WeaselDeployer.exe"), @("opencc.dll", "opencc.dll"),
      @("vcomp140.dll", "vcomp140.dll"), @("weaselx64.dll", "weaselx64.dll"),
      @("weasel32.dll", "weasel.dll"))) {
    $s = Join-Path $SourceSrc $pair[0]
    if (Test-Path $s) {
      Copy-BinaryRetry $s (Join-Path $installDir $pair[1]) $Log
      & $Log ("  + " + $pair[1])
    } else {
      & $Log ("  [MISS] " + $pair[0] + "（跳过，保留安装目录现有文件）")
    }
  }

  & $Log "[3/4] WeaselSetup 注册（TSF 组件部署）"
  & (Join-Path $installDir "WeaselSetup.exe") /u 2>$null
  & (Join-Path $installDir "WeaselSetup.exe") /i 2>$null
  $reg = reg query "HKLM\SOFTWARE\Classes\WOW6432Node\CLSID\{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}\InprocServer32" /ve 2>$null | Select-String -SimpleMatch "weasel"
  if (-not $reg) {
    & $Log "  32 位视图注册缺失，注册中…"
    $env:TEXTSERVICE_PROFILE = "hans"
    & "$env:WINDIR\SysWOW64\regsvr32.exe" /s "$env:WINDIR\SysWOW64\weasel.dll" 2>$null
  }

  & $Log "[4/4] 启动 server + 修改方案 schema + 重新部署"
  Start-Process -FilePath (Join-Path $installDir "WeaselServer.exe") -WorkingDirectory $installDir
  Edit-SchemaSource $schemaPath $Log
  Write-Manifest "source" $schemaName $installDir
  Invoke-Redeploy $installDir $Log
  & $Log "安装源码版完成。⚠ 必须重启系统激活 System32 TSF 组件，重启后托盘重新部署生效"
}

# 还原策略：仅修改配置（schema 剥离 + 重新部署 + 清清单）。
# 不删文件、不恢复二进制 —— 避免误删/恢复错版本；二进制回官方由用户重装官方小狼毫完成。
function Restore-PluginAction($Log) {
  & $Log "── 还原插件版（仅配置）──"
  $m = Get-Manifest
  $schemaName = ""; if ($m -and $m.schema) { $schemaName = $m.schema }
  if (-not $schemaName) { & $Log "  无安装清单，需手动确认方案文件；将尝试从所有方案剥离" }
  if ($schemaName -and (Test-Path (Join-Path $RIME_USER $schemaName))) {
    Strip-SchemaLlm (Join-Path $RIME_USER $schemaName) $Log
  } else {
    # 无清单时对用户目录所有方案尝试剥离（幂等，无 LLM 组件的方案不受影响）
    Get-ChildItem $RIME_USER -Filter "*.schema.yaml" -ErrorAction SilentlyContinue | ForEach-Object {
      Strip-SchemaLlm $_.FullName $Log
    }
  }
  if (Test-Path $MANIFEST) { Remove-Item $MANIFEST -Force; & $Log "  已清除安装清单" }
  $installDir = Find-WeaselDir
  if ($installDir) { Invoke-Redeploy $installDir $Log }
  & $Log "还原完成。LLM 组件已不被 schema 引用，输入法回到原行为。"
  & $Log "残留文件不影响使用，可手动删除："
  if ($installDir) {
    foreach ($d in @("rime_llm.dll", "llama.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll")) {
      $p = Join-Path $installDir $d
      if (Test-Path $p) { & $Log ("  " + $p) }
    }
  }
  foreach ($l in @("llm_filter.lua", "llm_processor.lua")) {
    $p = Join-Path $LUA_DIR $l
    if (Test-Path $p) { & $Log ("  " + $p) }
  }
}

function Restore-SourceAction($Log) {
  & $Log "── 还原源码版（仅配置）──"
  $m = Get-Manifest
  $schemaName = ""; if ($m -and $m.schema) { $schemaName = $m.schema }
  if ($schemaName -and (Test-Path (Join-Path $RIME_USER $schemaName))) {
    Strip-SchemaLlm (Join-Path $RIME_USER $schemaName) $Log
  } else {
    Get-ChildItem $RIME_USER -Filter "*.schema.yaml" -ErrorAction SilentlyContinue | ForEach-Object {
      Strip-SchemaLlm $_.FullName $Log
    }
  }
  if (Test-Path $MANIFEST) { Remove-Item $MANIFEST -Force; & $Log "  已清除安装清单" }
  $installDir = Find-WeaselDir
  if ($installDir) { Invoke-Redeploy $installDir $Log }
  & $Log "还原完成。schema 已剥离，LLM 组件不再加载，输入法可正常使用。"
  & $Log "二进制回到官方基线请重装官方小狼毫 0.17.4（覆盖安装即可）："
  & $Log "  https://github.com/rime/weasel/releases"
  & $Log "重装后：托盘小狼毫图标 → 右键 → 重新部署。"
}

# ── CLI 模式（子进程 / 无界面调用）────────────────
if ($CliAction) {
  # 子进程 stdout 被重定向到文件，GUI 按 UTF-8 读取（默认管道编码是 OEM 代码页）
  try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
  $Log = { param($t) Write-Host $t }
  try {
    switch ($CliAction) {
      "status" {
        Write-Host "RIME 用户目录: $RIME_USER"
        Write-Host ("插件版文件: " + $(if ($PluginReady) { "就绪 ($PluginSrc)" } else { "缺失" }))
        Write-Host ("源码版文件: " + $(if ($SourceReady) { "就绪 ($SourceSrc)" } else { "缺失" }))
        $dir = Find-WeaselDir
        $dirDesc = "未找到"
        if ($dir) { $dirDesc = $dir + $(if (Test-SourceBuild $dir) { " [rime.dll=源码版]" } else { " [官方]" }) }
        Write-Host ("小狼毫目录: " + $dirDesc)
        $m = Get-Manifest
        Write-Host ("已安装: " + $(if ($m) { $m.edition + " (" + $m.date + ")" } else { "无清单" }))
      }
      "install-plugin" { Install-PluginAction $SchemaName $ModelPath $Log }
      "install-source" { Install-SourceAction $SchemaName $ModelPath $Log }
      "restore-plugin" { Restore-PluginAction $Log }
      "restore-source" { Restore-SourceAction $Log }
      default { Write-Host "未知动作: $CliAction"; exit 1 }
    }
  } catch {
    Write-Host ("[ERROR] " + $_.Exception.Message)
    exit 1
  }
  exit 0
}

# ══════════ GUI ══════════
$RimeMissing = -not (Test-Path $RIME_USER)

$form = New-Object System.Windows.Forms.Form
$form.Text = "LLM 重排一键安装器"
$form.Size = New-Object System.Drawing.Size(700, 645)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$lblSchema = New-Object System.Windows.Forms.Label
$lblSchema.Text = "方案文件:"; $lblSchema.Location = New-Object System.Drawing.Point(15, 18)
$lblSchema.Size = New-Object System.Drawing.Size(70, 20); $form.Controls.Add($lblSchema)

$cmbSchema = New-Object System.Windows.Forms.ComboBox
$cmbSchema.Location = New-Object System.Drawing.Point(90, 15)
$cmbSchema.Size = New-Object System.Drawing.Size(400, 21)
$cmbSchema.DropDownStyle = "DropDownList"
$form.Controls.Add($cmbSchema)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "刷新"; $btnRefresh.Location = New-Object System.Drawing.Point(500, 14)
$btnRefresh.Size = New-Object System.Drawing.Size(80, 23); $form.Controls.Add($btnRefresh)

$btnBrowseSchema = New-Object System.Windows.Forms.Button
$btnBrowseSchema.Text = "浏览..."; $btnBrowseSchema.Location = New-Object System.Drawing.Point(588, 14)
$btnBrowseSchema.Size = New-Object System.Drawing.Size(85, 23); $form.Controls.Add($btnBrowseSchema)

$lblModel = New-Object System.Windows.Forms.Label
$lblModel.Text = "模型路径:"; $lblModel.Location = New-Object System.Drawing.Point(15, 53)
$lblModel.Size = New-Object System.Drawing.Size(70, 20); $form.Controls.Add($lblModel)

$txtModel = New-Object System.Windows.Forms.TextBox
$txtModel.Location = New-Object System.Drawing.Point(90, 50)
$txtModel.Size = New-Object System.Drawing.Size(490, 21); $form.Controls.Add($txtModel)

$btnBrowseModel = New-Object System.Windows.Forms.Button
$btnBrowseModel.Text = "浏览..."; $btnBrowseModel.Location = New-Object System.Drawing.Point(588, 49)
$btnBrowseModel.Size = New-Object System.Drawing.Size(85, 23); $form.Controls.Add($btnBrowseModel)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = "（模型路径留空 = 默认 $DEFAULT_MODEL；缺失时询问是否下载）"
$lblHint.Location = New-Object System.Drawing.Point(90, 75)
$lblHint.Size = New-Object System.Drawing.Size(580, 16)
$lblHint.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblHint)

$grpInstall = New-Object System.Windows.Forms.GroupBox
$grpInstall.Text = "安装（二选一）"; $grpInstall.Location = New-Object System.Drawing.Point(12, 100)
$grpInstall.Size = New-Object System.Drawing.Size(660, 66); $form.Controls.Add($grpInstall)

$btnInstallPlugin = New-Object System.Windows.Forms.Button
$btnInstallPlugin.Text = "安装插件版（lua 插件）"
$btnInstallPlugin.Location = New-Object System.Drawing.Point(15, 24)
$btnInstallPlugin.Size = New-Object System.Drawing.Size(300, 32)
$grpInstall.Controls.Add($btnInstallPlugin)

$btnInstallSource = New-Object System.Windows.Forms.Button
$btnInstallSource.Text = "安装源码版（源码级集成）"
$btnInstallSource.Location = New-Object System.Drawing.Point(340, 24)
$btnInstallSource.Size = New-Object System.Drawing.Size(300, 32)
$grpInstall.Controls.Add($btnInstallSource)

$grpRestore = New-Object System.Windows.Forms.GroupBox
$grpRestore.Text = "还原（仅剥离配置；二进制回官方请重装小狼毫）"
$grpRestore.Location = New-Object System.Drawing.Point(12, 174)
$grpRestore.Size = New-Object System.Drawing.Size(660, 66); $form.Controls.Add($grpRestore)

$btnRestorePlugin = New-Object System.Windows.Forms.Button
$btnRestorePlugin.Text = "还原插件版"
$btnRestorePlugin.Location = New-Object System.Drawing.Point(15, 24)
$btnRestorePlugin.Size = New-Object System.Drawing.Size(300, 32)
$grpRestore.Controls.Add($btnRestorePlugin)

$btnRestoreSource = New-Object System.Windows.Forms.Button
$btnRestoreSource.Text = "还原源码版"
$btnRestoreSource.Location = New-Object System.Drawing.Point(340, 24)
$btnRestoreSource.Size = New-Object System.Drawing.Size(300, 32)
$grpRestore.Controls.Add($btnRestoreSource)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(15, 248)
$lblStatus.Size = New-Object System.Drawing.Size(660, 18)
$lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
$form.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 270)
$txtLog.Size = New-Object System.Drawing.Size(655, 295)
$txtLog.Multiline = $true; $txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Vertical"; $txtLog.WordWrap = $false
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($txtLog)

# ── 状态刷新 ─────────────────────────────────────
function Refresh-SchemaCombo {
  $cmbSchema.Items.Clear()
  if (Test-Path $RIME_USER) {
    Get-ChildItem $RIME_USER -Filter "*.schema.yaml" -Name -ErrorAction SilentlyContinue |
      ForEach-Object { [void]$cmbSchema.Items.Add($_) }
  }
  if ($cmbSchema.Items.Count -gt 0) {
    $m = Get-Manifest
    $prefer = ""; if ($m -and $m.schema) { $prefer = $m.schema }
    if ($prefer -and $cmbSchema.Items.Contains($prefer)) { $cmbSchema.SelectedItem = $prefer }
    else { $cmbSchema.SelectedIndex = 0 }
  }
}
function Refresh-Status {
  $parts = @()
  $parts += ("插件版文件: " + $(if ($PluginReady) { "就绪" } else { "缺失" }))
  $parts += ("源码版文件: " + $(if ($SourceReady) { "就绪" } else { "缺失" }))
  $dir = Find-WeaselDir
  if ($dir) {
    $parts += ("小狼毫: " + $(if (Test-SourceBuild $dir) { "源码版 rime.dll" } else { "官方 rime.dll" }))
  } else { $parts += "小狼毫: 未找到" }
  $m = Get-Manifest
  $parts += ("已安装: " + $(if ($m) { $m.edition + " " + $m.date } else { "无" }))
  $lblStatus.Text = $parts -join "  |  "
  $lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
  $btnInstallPlugin.Enabled = $PluginReady -and -not $RimeMissing
  $btnInstallSource.Enabled = $SourceReady -and -not $RimeMissing
  $btnRestorePlugin.Enabled = -not $RimeMissing
  $btnRestoreSource.Enabled = -not $RimeMissing
}

# ── 后台子进程执行框架 ───────────────────────────
# GUI 以 CLI 模式调起自身（同一 PowerShell 解释器），stdout 重定向到临时文件，
# 定时器增量读取刷日志；子进程继承管理员权限。
$script:WorkProc  = $null
$script:WorkLog   = Join-Path $env:TEMP "llm_installer_child.log"
$script:WorkOff   = 0
$script:WorkDone  = $true
$script:WorkModel = ""    # 本次动作的模型路径（下载进度显示用）

function Start-Work([string]$action, [string]$schemaName, [string]$modelPath) {
  if (-not $script:WorkDone) { return }
  $script:WorkDone = $false; $script:WorkOff = 0
  $script:WorkModel = $modelPath.Trim(); if (-not $script:WorkModel) { $script:WorkModel = $DEFAULT_MODEL }
  if (Test-Path $script:WorkLog) { Remove-Item $script:WorkLog -Force }
  $txtLog.AppendText("────────────────────`r`n")
  $lblStatus.Text = "执行中: $action …（大文件复制/模型下载可能需要数分钟）"
  foreach ($b in @($btnInstallPlugin, $btnInstallSource, $btnRestorePlugin, $btnRestoreSource)) {
    $b.Enabled = $false
  }
  $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
  try {
    $psExe = (Get-Process -Id $PID).Path
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"",
                 "-CliAction", $action)
    if ($schemaName) { $argList += @("-SchemaName", "`"$schemaName`"") }
    if ($modelPath)  { $argList += @("-ModelPath", "`"$($modelPath.Trim())`"") }
    $script:WorkProc = Start-Process -FilePath $psExe -ArgumentList $argList `
      -WindowStyle Hidden -RedirectStandardOutput $script:WorkLog -PassThru
    $timer.Start()
  } catch {
    $script:WorkDone = $true; $script:WorkProc = $null
    $form.Cursor = [System.Windows.Forms.Cursors]::Default
    $txtLog.AppendText("[失败] 无法启动子进程: " + $_.Exception.Message + "`r`n")
    Refresh-Status
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
      $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
      $txtLog.AppendText($txt)
    } finally { $fs.Close() }
  } catch { }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
  Read-WorkLog
  if (-not $script:WorkProc) { return }
  if (-not $script:WorkProc.HasExited) {
    # 模型下载进度（.download 临时文件大小 → 状态栏，避免长时间静默被当成卡死）
    $dl = $script:WorkModel + ".download"
    if ($script:WorkModel -and (Test-Path $dl)) {
      try {
        $mb = [math]::Round((Get-Item $dl -ErrorAction Stop).Length / 1MB)
        $lblStatus.Text = "执行中: 模型下载 $mb MB / 约 500MB（断点续传，可中断后重试）"
      } catch { }
    }
    return
  }
  # 完成处理：先停表并复位状态，最后才弹窗 —— MessageBox 的模态循环期间
  # 定时器仍会触发，若不先清 WorkProc 会无限重入弹窗（源码版机器装插件版
  # 必失败路径曾因此无限弹"操作失败"）
  Start-Sleep -Milliseconds 200   # 等缓冲落盘
  Read-WorkLog
  # 失败判定多信号：子进程契约是失败必打 [ERROR] 行（catch → exit 1）；
  # ExitCode 偶发不可读（还原成功却误报失败，2026-08-25 实测），故以
  # [ERROR] 行为主、退出码为辅
  $code = $null
  try { $code = $script:WorkProc.ExitCode } catch { }
  $failed = ($txtLog.Text -match '(?m)^\[ERROR\]') -or
            ($null -ne $code -and $code -ne 0)
  if ($null -eq $code) {
    $txtLog.AppendText("[警告] 子进程退出码不可读，已按日志 [ERROR] 行判定`r`n")
  } else {
    $txtLog.AppendText(("[信息] 子进程退出码: " + $code + "`r`n"))
  }
  $timer.Stop()
  $script:WorkDone = $true
  $script:WorkProc = $null
  $form.Cursor = [System.Windows.Forms.Cursors]::Default
  Refresh-Status
  if ($failed) {
    $txtLog.AppendText("[失败] 操作未完成，见上方 [ERROR] 行`r`n")
    $errLine = ($txtLog.Text -split "`r`n" | Where-Object { $_ -match '^\[ERROR\]' } |
                Select-Object -Last 1)
    $msg = if ($errLine) { $errLine -replace '^\[ERROR\]\s*', '' } else { "详见日志窗口中的 [ERROR] 行" }
    [System.Windows.Forms.MessageBox]::Show(
      $msg, "操作失败",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
  } else {
    $txtLog.AppendText("[完成]`r`n")
  }
})

# ── 控件事件 ─────────────────────────────────────
$btnRefresh.Add_Click({ Refresh-SchemaCombo; Refresh-Status })

$btnBrowseSchema.Add_Click({
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
    Refresh-SchemaCombo
    if ($cmbSchema.Items.Contains($name)) { $cmbSchema.SelectedItem = $name }
  }
})

$btnBrowseModel.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = "GGUF 模型 (*.gguf)|*.gguf|所有文件 (*.*)|*.*"
  $t = $txtModel.Text.Trim()
  if ($t) { $d = Split-Path $t -Parent; if ($d -and (Test-Path $d)) { $dlg.InitialDirectory = $d } }
  if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $txtModel.Text = $dlg.FileName }
})

function Confirm-ModelOrCancel([string]$model) {
  $m = $model.Trim(); if (-not $m) { $m = $DEFAULT_MODEL }
  if (Test-Path $m) { return $true }
  $r = [System.Windows.Forms.MessageBox]::Show(
    "模型不存在:`n$m`n`n是否现在下载？（约 500MB，断点续传，可中断后重试）",
    "模型缺失", [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question)
  return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

$btnInstallPlugin.Add_Click({
  if ($cmbSchema.SelectedItem -eq $null) {
    [System.Windows.Forms.MessageBox]::Show("请先选择方案文件（或用浏览按钮选择）", "提示") | Out-Null
    return
  }
  if (-not (Confirm-ModelOrCancel $txtModel.Text)) { return }
  Start-Work "install-plugin" $cmbSchema.SelectedItem.ToString() $txtModel.Text.Trim()
})

$btnInstallSource.Add_Click({
  if ($cmbSchema.SelectedItem -eq $null) {
    [System.Windows.Forms.MessageBox]::Show("请先选择方案文件（或用浏览按钮选择）", "提示") | Out-Null
    return
  }
  if (-not (Confirm-ModelOrCancel $txtModel.Text)) { return }
  Start-Work "install-source" $cmbSchema.SelectedItem.ToString() $txtModel.Text.Trim()
})

$btnRestorePlugin.Add_Click({ Start-Work "restore-plugin" "" "" })
$btnRestoreSource.Add_Click({ Start-Work "restore-source" "" "" })

$form.Add_Shown({
  Refresh-SchemaCombo
  Refresh-Status
  # 管理员检查：非提权运行时安装必然失败（Program Files 写入），提前警示
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    $txtLog.AppendText("[警告] 当前未以管理员运行 —— 安装/还原需要写小狼毫安装目录。`r`n")
    $txtLog.AppendText("请关闭本窗口，改用 install_llm_gui.bat 启动（自动请求管理员权限）。`r`n")
    $lblStatus.Text = "[警告] 未以管理员运行，请用 install_llm_gui.bat 启动"
    $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
  }
})

[void]$form.ShowDialog()
