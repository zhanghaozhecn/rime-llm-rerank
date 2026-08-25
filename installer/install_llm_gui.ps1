# install_llm_gui.ps1 — LLM 重排一键安装器（极简版 v3）
# 设计原则（2026-08-25 用户定案）：**只做文件操作**——停算法服务 → 复制/替换
# 文件（锁定则改名腾位，再不行延迟替换重启生效）。不碰 schema（方案配置由
# 用户自己维护，需自带 LLM 组件行）、不碰 TSF 注册（不调 WeaselSetup——
# /u 后 /i 静默失败会变砖）、不做还原（切换版本 = 重装小狼毫 + 恢复原始
# 方案配置后跑另一个按钮）。
#
# 动作：
#   插件版：停服务 → rime_llm.dll 等 → 安装目录；lua ×2 → %APPDATA%\Rime\lua\
#           → 启服务。（前置：官方小狼毫 + 官方 rime.dll）
#   源码版：停服务 → 7 二进制 → 安装目录；weasel TSF DLL → System32/SysWOW64
#           （锁定则延迟替换）→ 启服务。重启系统后托盘重新部署生效。
#
# 命令行模式（测试/自动化）：
#   powershell -ExecutionPolicy Bypass -File install_llm_gui.ps1 -CliAction status|install-plugin|install-source
# 兼容 Windows PowerShell 5.1 / PowerShell 7（本文件须 UTF-8 with BOM）。

param(
  [string]$CliAction = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── 路径探测 ─────────────────────────────────────
$PluginSrc = Join-Path $PSScriptRoot "plugin"
if (-not (Test-Path (Join-Path $PluginSrc "rime_llm.dll"))) {
  $alt = Join-Path (Split-Path $PSScriptRoot -Parent) "user"
  if (Test-Path (Join-Path $alt "rime_llm.dll")) { $PluginSrc = $alt }
}
$SourceSrc = Join-Path $PSScriptRoot "source"
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

function Stop-WeaselService($Log) {
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

# 替换文件：直接复制（未加载零打扰）→ 被占用则改名旧文件腾位（Windows 允许
# 改名加载中的镜像；旧进程跑旧镜像，服务重启后加载新文件）→ 连改名都失败
# 则 MoveFileEx 延迟替换（重启生效）。
Add-Type -Namespace LlmInst -Name Native -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool MoveFileExW(string lpExistingFileName, string lpNewFileName, int dwFlags);
"@
function Copy-Binary([string]$s, [string]$d, $Log) {
  for ($i = 0; $i -le 2; $i++) {
    try { Copy-Item $s $d -Force -ErrorAction Stop; return }
    catch {
      try {
        Move-Item $d ($d + ".llm_old") -Force -ErrorAction Stop
        Copy-Item $s $d -Force -ErrorAction Stop
        & $Log ("  " + [IO.Path]::GetFileName($d) + " 被占用，改名替换（旧镜像留给运行中的进程）")
        return
      } catch {
        Invoke-Native taskkill @("/f", "/im", "WeaselServer.exe") | Out-Null
        Start-Sleep -Seconds 2
      }
    }
  }
  # 延迟替换：复制到临时名，重启时由系统移到目标位
  $tmp = $d + ".llm_new"
  Copy-Item $s $tmp -Force
  if ([LlmInst.Native]::MoveFileExW($tmp, $d, 4)) {   # MOVEFILE_DELAY_UNTIL_REBOOT
    & $Log ("  " + [IO.Path]::GetFileName($d) + " 已排队延迟替换 —— 需重启系统生效")
    return
  }
  throw ("无法替换 " + $d + "：" + $_.Exception.Message)
}
function Clean-OldBinaries([string]$dir, $Log) {
  $old = Get-ChildItem $dir -Filter "*.llm_old" -ErrorAction SilentlyContinue
  if ($old) { $old | Remove-Item -Force -ErrorAction SilentlyContinue; & $Log ("  清理 " + $old.Count + " 个改名残留") }
}

# ── 安装动作（CLI 子进程执行）────────────────────
function Install-PluginAction($Log) {
  & $Log "── 安装插件版（仅文件操作）──"
  $installDir = Find-WeaselDir
  if (-not $installDir) { throw "未找到小狼毫安装目录。请先安装官方小狼毫 0.17.x" }
  & $Log "  安装目录: $installDir"
  foreach ($f in @("rime_llm.dll", "llm_filter.lua", "llm_processor.lua")) {
    if (-not (Test-Path (Join-Path $PluginSrc $f))) { throw "插件版文件不完整: 缺 $f" }
  }

  & $Log "[1/3] 停止算法服务"
  Stop-WeaselService $Log
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
  Clean-OldBinaries $installDir $Log
  & $Log "[3/3] 启动服务"
  Start-WeaselService $installDir $Log
  & $Log "完成。生效步骤：托盘小狼毫 → 右键 → 重新部署（方案配置需已含 LLM 组件行）"
}

function Install-SourceAction($Log) {
  & $Log "── 安装源码版（仅文件操作）──"
  $installDir = Find-WeaselDir
  if (-not $installDir) { throw "未找到小狼毫安装目录。请先安装官方小狼毫 0.17.4" }
  & $Log "  安装目录: $installDir"
  foreach ($f in @("rime.dll", "WeaselServer.exe", "weaselx64.dll", "weasel32.dll")) {
    if (-not (Test-Path (Join-Path $SourceSrc $f))) { throw "源码版文件不完整: 缺 $f" }
  }

  & $Log "[1/4] 停止算法服务"
  Stop-WeaselService $Log
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
  Clean-OldBinaries $installDir $Log

  & $Log "[3/4] 替换 System32 / SysWOW64 的 TSF DLL（不碰注册表）"
  Copy-Binary (Join-Path $SourceSrc "weaselx64.dll") "C:\Windows\System32\weasel.dll" $Log
  & $Log "  + System32\weasel.dll"
  Copy-Binary (Join-Path $SourceSrc "weasel32.dll") "C:\Windows\SysWOW64\weasel.dll" $Log
  & $Log "  + SysWOW64\weasel.dll"

  & $Log "[4/4] 启动服务"
  Start-WeaselService $installDir $Log
  & $Log "完成。生效步骤：重启系统（若提示延迟替换）→ 托盘小狼毫 → 重新部署（方案配置需已含 LLM 组件行）"
}

# ── CLI 模式 ─────────────────────────────────────
if ($CliAction) {
  try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
  $Log = { param($t) Write-Host $t }
  try {
    switch ($CliAction) {
      "status" {
        Write-Host ("插件版文件: " + $(if ($PluginReady) { "就绪 ($PluginSrc)" } else { "缺失" }))
        Write-Host ("源码版文件: " + $(if ($SourceReady) { "就绪 ($SourceSrc)" } else { "缺失" }))
        $dir = Find-WeaselDir
        Write-Host ("小狼毫目录: " + $(if ($dir) { $dir } else { "未找到" }))
      }
      "install-plugin" { Install-PluginAction $Log }
      "install-source" { Install-SourceAction $Log }
      default { Write-Host "未知动作: $CliAction（status | install-plugin | install-source）"; exit 1 }
    }
  } catch {
    Write-Host ("[ERROR] " + $_.Exception.Message)
    exit 1
  }
  exit 0
}

# ══════════ GUI ══════════
$form = New-Object System.Windows.Forms.Form
$form.Text = "LLM 重排一键安装器"
$form.Size = New-Object System.Drawing.Size(700, 330)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$lblIntro = New-Object System.Windows.Forms.Label
$lblIntro.Text = "前提：已安装官方小狼毫，方案配置已含 LLM 组件行。切换版本：重装小狼毫 + 恢复原始方案配置后，点另一按钮。"
$lblIntro.Location = New-Object System.Drawing.Point(15, 15)
$lblIntro.Size = New-Object System.Drawing.Size(660, 32)
$lblIntro.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblIntro)

$grpInstall = New-Object System.Windows.Forms.GroupBox
$grpInstall.Text = "安装（二选一；仅文件操作，不碰配置与注册表）"
$grpInstall.Location = New-Object System.Drawing.Point(12, 50)
$grpInstall.Size = New-Object System.Drawing.Size(660, 66)
$form.Controls.Add($grpInstall)

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

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(15, 122)
$lblStatus.Size = New-Object System.Drawing.Size(660, 18)
$lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
$form.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 144)
$txtLog.Size = New-Object System.Drawing.Size(655, 140)
$txtLog.Multiline = $true; $txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Vertical"; $txtLog.WordWrap = $false
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($txtLog)

function Refresh-Status {
  $parts = @()
  $parts += ("插件版文件: " + $(if ($PluginReady) { "就绪" } else { "缺失" }))
  $parts += ("源码版文件: " + $(if ($SourceReady) { "就绪" } else { "缺失" }))
  $dir = Find-WeaselDir
  $parts += ("小狼毫: " + $(if ($dir) { $dir } else { "未找到（请先安装官方小狼毫）" }))
  $lblStatus.Text = $parts -join "  |  "
  $lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
  $btnInstallPlugin.Enabled = $PluginReady -and $dir
  $btnInstallSource.Enabled = $SourceReady -and $dir
}

# ── 后台子进程执行框架（与旧版相同的三处修复均保留）──
$script:WorkProc  = $null
$script:WorkLog   = Join-Path $env:TEMP "llm_installer_child.log"
$script:WorkOff   = 0
$script:WorkDone  = $true

function Start-Work([string]$action) {
  if (-not $script:WorkDone) { return }
  $script:WorkDone = $false; $script:WorkOff = 0
  if (Test-Path $script:WorkLog) { Remove-Item $script:WorkLog -Force }
  $txtLog.AppendText("────────────────────`r`n")
  $lblStatus.Text = "执行中: $action …"
  foreach ($b in @($btnInstallPlugin, $btnInstallSource)) { $b.Enabled = $false }
  $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
  try {
    $psExe = (Get-Process -Id $PID).Path
    $script:WorkProc = Start-Process -FilePath $psExe `
      -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-CliAction", $action) `
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
      $txtLog.AppendText([Text.Encoding]::UTF8.GetString($buf, 0, $n))
    } finally { $fs.Close() }
  } catch { }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
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
  Refresh-Status
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

$btnInstallPlugin.Add_Click({ Start-Work "install-plugin" })
$btnInstallSource.Add_Click({ Start-Work "install-source" })

$form.Add_Shown({
  Refresh-Status
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    $txtLog.AppendText("[警告] 当前未以管理员运行。请关闭本窗口，用 install_llm_gui.bat 启动。`r`n")
    $lblStatus.Text = "[警告] 未以管理员运行，请用 install_llm_gui.bat 启动"
    $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
  }
})

[void]$form.ShowDialog()
