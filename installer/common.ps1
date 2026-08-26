# common.ps1 — 安装器共享逻辑（两仓库各存一份、内容必须一致；同步工具 =
# rime-llm-ime 仓库 installer\make_installer.ps1。各仓库只带自己版本的入口
# install_*.ps1，本文件含两版动作属共用代码）
# 设计（2026-08-25 定稿）：安装器只做 文件操作 + schema 加/去 LLM 组件行（幂等）。
# 不碰注册表、不调 WeaselSetup、不做还原（切换 = 重装小狼毫 + 换原始方案配置）。

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── 路径探测 ─────────────────────────────────────
# 分仓布局（2026-08-26）：插件版仓库（rime-llm-rerank，载荷 = 仓库 user\）与
# 源码版仓库（rime-llm-ime，载荷 = installer\source\）各只带本版安装器；本文件
# 两仓各一份，对面版本路径缺失时对应 *Ready=false（各版入口只用自己路径）。
# 开发机两仓平行时，源码版载荷可回退平行仓库根 bin\（刚构建未同步场景）。
$PluginSrc = Join-Path (Split-Path $PSScriptRoot -Parent) "user"   # 插件版仓库 user\
$SourceSrc = Join-Path $PSScriptRoot "source"
if (-not (Test-Path (Join-Path $SourceSrc "rime.dll"))) {
  # 平行的源码版仓库 bin\（开发机布局：..\..\ = 两仓库的共同父目录）
  $alt = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "rime-llm-ime\bin"
  if (Test-Path (Join-Path $alt "rime.dll")) { $SourceSrc = $alt }
}
$PluginReady = Test-Path (Join-Path $PluginSrc "rime_llm.dll")
$SourceReady = Test-Path (Join-Path $SourceSrc "rime.dll")
$RIME_USER = Join-Path $env:APPDATA "Rime"
$LUA_DIR = Join-Path $RIME_USER "lua"

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
    Start-Process -FilePath $exe -WorkingDirectory $installDir
    & $Log "  算法服务已启动"
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
  $deployer = Join-Path $installDir "WeaselDeployer.exe"
  if (Test-Path $deployer) {
    & $Log "  触发重新部署（WeaselDeployer /deploy）…"
    try {
      $p = Start-Process -FilePath $deployer -ArgumentList "/deploy" -PassThru -Wait -ErrorAction Stop
      & $Log ("  重新部署退出码: " + $p.ExitCode)
    } catch { & $Log "  [警告] 自动重新部署失败，请手动：托盘小狼毫 → 重新部署" }
  } else {
    & $Log "  请手动重新部署：托盘小狼毫 → 重新部署"
  }
}

# ── schema 加 LLM 组件行（幂等，位置校验）────────
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Read-Schema([string]$path) { [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8) }
function Write-Schema([string]$path, $lines) { [IO.File]::WriteAllLines($path, $lines, $Utf8NoBom) }

# llm_rerank 配置节；modelPath 非空时写为生效行（反斜杠→正斜杠，含空格则加引号），
# 留空则保持注释示例（运行时默认 d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf）
function Get-LlmCfgLines([string]$modelPath) {
  $l = @(
    "", "llm_rerank:", "  enabled: true", "  min_code_len: 4",
    "  # max_code_len: 0", "  # long_word_first: false",
    "  # expected_length_weight: 0.20", "  # freq_weight: 0.25", "  # freq_k: 5",
    "  # min_tokens: 1", "  # max_tokens: 10", "  # max_candidates: 5",
    "  # cpu_cores: 4"
  )
  if ($modelPath) { $l += "  model_path: " + (Convert-ToYamlPath $modelPath) }
  else { $l += "  # model_path: d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf" }
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

# 插件版：processors 最前 lua_processor + uniquifier 后 lua_filter + llm_rerank 节
function Edit-SchemaPlugin([string]$schemaPath, [string]$modelPath, $Log) {
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
    Get-LlmCfgLines $modelPath | ForEach-Object { [void]$out.Add($_) }
    & $Log "  + llm_rerank: 配置节（enabled: true）"; $changed = $true
  } elseif ($modelPath) {
    if (Add-ModelPathToExisting $out $modelPath $Log) { $changed = $true }
  }
  if ($changed) { Write-Schema $schemaPath $out; & $Log "  schema 已更新（幂等，重复运行不重复插入）" }
  else { & $Log "  schema 组件已存在，无需修改" }
}

# 源码版：uniquifier 后 llm_filter + llm_rerank 节
function Edit-SchemaSource([string]$schemaPath, [string]$modelPath, $Log) {
  $lines = Read-Schema $schemaPath
  if (($lines | Where-Object { $_ -match 'lua_filter@\*llm_filter' }).Count -gt 0) {
    throw "方案里已有插件版组件（lua_filter@*llm_filter）——插件版与源码版二选一，请先重装小狼毫并恢复原始方案配置"
  }
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
    Get-LlmCfgLines $modelPath | ForEach-Object { [void]$out.Add($_) }
    & $Log "  + llm_rerank: 配置节（enabled: true）"; $changed = $true
  } elseif ($modelPath) {
    if (Add-ModelPathToExisting $out $modelPath $Log) { $changed = $true }
  }
  if ($changed) { Write-Schema $schemaPath $out; & $Log "  schema 已更新（幂等）" }
  else { & $Log "  schema 组件已存在，无需修改" }
}

# 去除 LLM 组件（两版通用）：processor/filter 组件行 + llm_rerank 整节（含前置空行）
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

# ── 安装动作（CLI 子进程执行）────────────────────
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

function Copy-FilesSourceAction($Log) {
  & $Log "── 复制源码版文件 ──"
  $installDir = Find-WeaselDir
  if (-not $installDir) { throw "未找到小狼毫安装目录。请先安装官方小狼毫 0.17.4" }
  & $Log "  安装目录: $installDir"
  foreach ($f in @("rime.dll", "WeaselServer.exe", "weaselx64.dll", "weasel32.dll")) {
    if (-not (Test-Path (Join-Path $SourceSrc $f))) { throw "源码版文件不完整: 缺 $f" }
  }

  & $Log "[1/4] 停止算法服务 + 清理上次安装的旧二进制"
  Stop-WeaselService
  Clean-OldBinaries $installDir $Log
  Clean-OldBinaries "C:\Windows\System32" $Log
  Clean-OldBinaries "C:\Windows\SysWOW64" $Log
  & $Log "[2/4] 复制安装目录二进制"
  foreach ($pair in @(
      @("rime.dll", "rime.dll"), @("WeaselServer.exe", "WeaselServer.exe"),
      @("WeaselDeployer.exe", "WeaselDeployer.exe"), @("opencc.dll", "opencc.dll"),
      @("vcomp140.dll", "vcomp140.dll"), @("weaselx64.dll", "weaselx64.dll"),
      @("weasel32.dll", "weasel.dll"))) {
    $s = Join-Path $SourceSrc $pair[0]
    if (Test-Path $s) {
      Copy-Binary $s (Join-Path $installDir $pair[1]) $Log
      & $Log ("  + " + $pair[1])
    } else {
      & $Log ("  [MISS] " + $pair[0] + "（跳过，保留现有文件）")
    }
  }
  & $Log "[3/4] 替换 System32 / SysWOW64 的 TSF DLL（不碰注册表）"
  Copy-Binary (Join-Path $SourceSrc "weaselx64.dll") "C:\Windows\System32\weasel.dll" $Log
  & $Log "  + System32\weasel.dll"
  Copy-Binary (Join-Path $SourceSrc "weasel32.dll") "C:\Windows\SysWOW64\weasel.dll" $Log
  & $Log "  + SysWOW64\weasel.dll"
  & $Log "[4/4] 启动服务 + 重新部署"
  Start-WeaselService $installDir $Log
  Invoke-Redeploy $installDir $Log
  & $Log "完成。无需重启系统（存量 TSF 宿主退出后自动走新 DLL）。"
}

function Schema-AddAction([string]$edition, [string]$schemaName, [string]$modelPath, $Log) {
  & $Log "── 方案配置加入 LLM 组件 ──"
  $schemaPath = Get-SchemaPath $schemaName
  & $Log ("  方案: " + $schemaPath)
  if ($modelPath) { & $Log ("  模型: " + $modelPath) }
  if ($edition -eq "plugin") { Edit-SchemaPlugin $schemaPath $modelPath $Log }
  else { Edit-SchemaSource $schemaPath $modelPath $Log }
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

# 完整安装 = 复制文件 + 方案配置（CLI -CliAction install，自动化旧路径）
function Install-PluginAction([string]$schemaName, $Log) {
  Copy-FilesPluginAction $Log
  Schema-AddAction "plugin" $schemaName "" $Log
}
function Install-SourceAction([string]$schemaName, $Log) {
  Copy-FilesSourceAction $Log
  Schema-AddAction "source" $schemaName "" $Log
}

# ── CLI / GUI 入口（由入口脚本调用）──────────────
function Invoke-Installer([string]$edition, [string]$cliAction, [string]$schemaName, [string]$modelPath) {
  if ($cliAction) {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    $Log = { param($t) Write-Host $t }
    try {
      switch ($cliAction) {
        "status" {
          $ready = if ($edition -eq "plugin") { $PluginReady } else { $SourceReady }
          $src   = if ($edition -eq "plugin") { $PluginSrc } else { $SourceSrc }
          Write-Host ("安装文件: " + $(if ($ready) { "就绪 ($src)" } else { "缺失" }))
          $dir = Find-WeaselDir
          Write-Host ("小狼毫目录: " + $(if ($dir) { $dir } else { "未找到" }))
        }
        "install" {
          if (-not $schemaName) { throw "需要 -SchemaName 指定方案文件" }
          if ($edition -eq "plugin") { Install-PluginAction $schemaName $Log }
          else { Install-SourceAction $schemaName $Log }
        }
        "copy-files" {
          if ($edition -eq "plugin") { Copy-FilesPluginAction $Log }
          else { Copy-FilesSourceAction $Log }
        }
        "schema-add" {
          if (-not $schemaName) { throw "需要 -SchemaName 指定方案文件" }
          Schema-AddAction $edition $schemaName $modelPath $Log
        }
        "schema-remove" {
          if (-not $schemaName) { throw "需要 -SchemaName 指定方案文件" }
          Schema-RemoveAction $schemaName $Log
        }
        default { Write-Host "未知动作: $cliAction（status | install | copy-files | schema-add | schema-remove）"; exit 1 }
      }
    } catch {
      Write-Host ("[ERROR] " + $_.Exception.Message)
      exit 1
    }
    exit 0
  }
  Run-InstallerGui $edition
}

# ── GUI 框架（含全部历史修复：防弹窗重入/多信号判定/管理员警告）──
function Run-InstallerGui([string]$edition) {
  $isPlugin = ($edition -eq "plugin")
  $title = if ($isPlugin) { "LLM 重排安装器 — 插件版" } else { "LLM 重排安装器 — 源码版" }
  $ready = if ($isPlugin) { $PluginReady } else { $SourceReady }

  $form = New-Object System.Windows.Forms.Form
  $form.Text = $title
  $form.Size = New-Object System.Drawing.Size(700, 400)
  $form.StartPosition = "CenterScreen"
  $form.FormBorderStyle = "FixedDialog"
  $form.MaximizeBox = $false

  $lblIntro = New-Object System.Windows.Forms.Label
  $lblIntro.Text = "『复制文件』= 停服务→替换二进制→启服务。『方案配置加/去 LLM』只改选中的方案文件并自动重新部署；模型路径留空 = 默认 d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf，填写则写入配置。切换版本：重装小狼毫 + 恢复原始方案配置。"
  $lblIntro.Location = New-Object System.Drawing.Point(15, 12)
  $lblIntro.Size = New-Object System.Drawing.Size(660, 40)
  $lblIntro.ForeColor = [System.Drawing.Color]::DimGray
  $form.Controls.Add($lblIntro)

  $lblSchema = New-Object System.Windows.Forms.Label
  $lblSchema.Text = "方案文件:"; $lblSchema.Location = New-Object System.Drawing.Point(15, 58)
  $lblSchema.Size = New-Object System.Drawing.Size(70, 20); $form.Controls.Add($lblSchema)

  $cmbSchema = New-Object System.Windows.Forms.ComboBox
  $cmbSchema.Location = New-Object System.Drawing.Point(90, 55)
  $cmbSchema.Size = New-Object System.Drawing.Size(400, 21)
  $cmbSchema.DropDownStyle = "DropDownList"
  $form.Controls.Add($cmbSchema)

  $btnRefresh = New-Object System.Windows.Forms.Button
  $btnRefresh.Text = "刷新"; $btnRefresh.Location = New-Object System.Drawing.Point(500, 54)
  $btnRefresh.Size = New-Object System.Drawing.Size(80, 23); $form.Controls.Add($btnRefresh)

  $btnBrowse = New-Object System.Windows.Forms.Button
  $btnBrowse.Text = "浏览..."; $btnBrowse.Location = New-Object System.Drawing.Point(588, 54)
  $btnBrowse.Size = New-Object System.Drawing.Size(85, 23); $form.Controls.Add($btnBrowse)

  $lblModel = New-Object System.Windows.Forms.Label
  $lblModel.Text = "模型路径:"; $lblModel.Location = New-Object System.Drawing.Point(15, 88)
  $lblModel.Size = New-Object System.Drawing.Size(70, 20); $form.Controls.Add($lblModel)

  $txtModel = New-Object System.Windows.Forms.TextBox
  $txtModel.Location = New-Object System.Drawing.Point(90, 85)
  $txtModel.Size = New-Object System.Drawing.Size(583, 21)
  $form.Controls.Add($txtModel)

  $btnFiles = New-Object System.Windows.Forms.Button
  $btnFiles.Text = "复制文件"
  $btnFiles.Location = New-Object System.Drawing.Point(12, 115)
  $btnFiles.Size = New-Object System.Drawing.Size(210, 36)
  $form.Controls.Add($btnFiles)

  $btnAdd = New-Object System.Windows.Forms.Button
  $btnAdd.Text = "方案配置加 LLM"
  $btnAdd.Location = New-Object System.Drawing.Point(230, 115)
  $btnAdd.Size = New-Object System.Drawing.Size(226, 36)
  $form.Controls.Add($btnAdd)

  $btnRemove = New-Object System.Windows.Forms.Button
  $btnRemove.Text = "方案配置去 LLM"
  $btnRemove.Location = New-Object System.Drawing.Point(462, 115)
  $btnRemove.Size = New-Object System.Drawing.Size(206, 36)
  $form.Controls.Add($btnRemove)

  $lblStatus = New-Object System.Windows.Forms.Label
  $lblStatus.Location = New-Object System.Drawing.Point(15, 158)
  $lblStatus.Size = New-Object System.Drawing.Size(660, 18)
  $lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
  $form.Controls.Add($lblStatus)

  $txtLog = New-Object System.Windows.Forms.TextBox
  $txtLog.Location = New-Object System.Drawing.Point(15, 180)
  $txtLog.Size = New-Object System.Drawing.Size(655, 180)
  $txtLog.Multiline = $true; $txtLog.ReadOnly = $true
  $txtLog.ScrollBars = "Vertical"; $txtLog.WordWrap = $false
  $txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
  $form.Controls.Add($txtLog)

  function Refresh-Ui {
    $cmbSchema.Items.Clear()
    if (Test-Path $RIME_USER) {
      Get-ChildItem $RIME_USER -Filter "*.schema.yaml" -Name -ErrorAction SilentlyContinue |
        ForEach-Object { [void]$cmbSchema.Items.Add($_) }
      if ($cmbSchema.Items.Count -gt 0) { $cmbSchema.SelectedIndex = 0 }
    }
    $dir = Find-WeaselDir
    $lblStatus.Text = ("安装文件: " + $(if ($ready) { "就绪" } else { "缺失" }) + "  |  小狼毫: " +
                       $(if ($dir) { $dir } else { "未找到（请先安装官方小狼毫）" }))
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
    $btnFiles.Enabled = ($ready -and $dir)
    $btnAdd.Enabled = ($cmbSchema.Items.Count -gt 0)
    $btnRemove.Enabled = ($cmbSchema.Items.Count -gt 0)
  }

  # 后台子进程执行（自身 CLI 模式，stdout 重定向轮询刷日志）
  $script:WorkProc = $null
  $script:WorkLog  = Join-Path $env:TEMP ("llm_installer_" + $edition + ".log")
  $script:WorkOff  = 0
  $script:WorkDone = $true
  $entryScript = if ($isPlugin) { Join-Path $PSScriptRoot "install_plugin.ps1" }
                 else { Join-Path $PSScriptRoot "install_source.ps1" }

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 250

  function Start-Work([string]$action, [string]$schemaName, [string]$modelPath) {
    if (-not $script:WorkDone) { return }
    $script:WorkDone = $false; $script:WorkOff = 0
    if (Test-Path $script:WorkLog) { Remove-Item $script:WorkLog -Force }
    $txtLog.AppendText("────────────────────`r`n")
    $lblStatus.Text = "执行中…（文件复制/替换可能需要数十秒）"
    $btnFiles.Enabled = $false; $btnAdd.Enabled = $false; $btnRemove.Enabled = $false
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

  $form.Add_Shown({
    Refresh-Ui
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
      $txtLog.AppendText("[警告] 当前未以管理员运行。请关闭本窗口，用对应的 install_*.bat 启动。`r`n")
      $lblStatus.Text = "[警告] 未以管理员运行，请用 install_*.bat 启动"
      $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
    }
  })

  [void]$form.ShowDialog()
}
