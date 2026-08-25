# make_installer.ps1 — 组装 GUI 安装器发布包
# 从仓库树收集两版文件到 installer\plugin\ 与 installer\source\，打成 zip。
# 用法（开发机）: pwsh -File make_installer.ps1 [-SourceBin D:\rime-llm-ime\bin]
param(
  [string]$SourceBin = "D:\rime-llm-ime\bin"
)
$ErrorActionPreference = "Stop"
$here = Split-Path $PSCommandPath -Parent
$repoUser = Join-Path (Split-Path $here -Parent) "user"

# plugin\ : rime_llm.dll + lua x2（来自插件版仓库 user\）
$plugDst = Join-Path $here "plugin"
New-Item -ItemType Directory -Path $plugDst -Force | Out-Null
foreach ($f in @("rime_llm.dll", "llm_filter.lua", "llm_processor.lua",
                 "llama.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll")) {
  $s = Join-Path $repoUser $f
  if (Test-Path $s) { Copy-Item $s $plugDst -Force; Write-Host "plugin + $f" }
}

# source\ : 源码版 7 二进制（来自 rime-llm-ime\bin）
$srcDst = Join-Path $here "source"
New-Item -ItemType Directory -Path $srcDst -Force | Out-Null
if (-not (Test-Path (Join-Path $SourceBin "rime.dll"))) {
  throw "source binaries not found: $SourceBin (use -SourceBin)"
}
foreach ($f in @("rime.dll", "WeaselServer.exe", "WeaselDeployer.exe",
                 "weaselx64.dll", "weasel32.dll", "opencc.dll", "vcomp140.dll")) {
  $s = Join-Path $SourceBin $f
  if (Test-Path $s) { Copy-Item $s $srcDst -Force; Write-Host "source + $f" }
  else { Write-Host "source MISS $f" -ForegroundColor Yellow }
}

# zip（bat + ps1 + plugin\ + source\）
$zip = Join-Path $here "rime-llm-installer.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $here "install_llm_gui.bat"),
                  (Join-Path $here "install_llm_gui.ps1"),
                  $plugDst, $srcDst -DestinationPath $zip
Get-Item $zip | Select-Object FullName, @{n='MB';e={[math]::Round($_.Length/1MB,1)}} | Format-List
