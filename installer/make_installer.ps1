# make_installer.ps1 — 二进制同步工具（v4：仓库直发，无打包）
# 从平行的源码版仓库 bin\ 同步 7 个二进制到 installer\source\，然后手动
# commit 推送即可（分发 = git clone 仓库，不再打 zip / 发 Release）。
# 用法（开发机）: pwsh -File make_installer.ps1 [-SourceBin D:\rime-llm-ime\bin]
param(
  [string]$SourceBin = "D:\rime-llm-ime\bin"
)
$ErrorActionPreference = "Stop"
$here = Split-Path $PSCommandPath -Parent
if (-not (Test-Path (Join-Path $SourceBin "rime.dll"))) {
  throw "source binaries not found: $SourceBin (use -SourceBin)"
}
$dst = Join-Path $here "source"
New-Item -ItemType Directory -Path $dst -Force | Out-Null
foreach ($f in @("rime.dll", "WeaselServer.exe", "WeaselDeployer.exe",
                 "weaselx64.dll", "weasel32.dll", "opencc.dll", "vcomp140.dll")) {
  $s = Join-Path $SourceBin $f
  if (Test-Path $s) { Copy-Item $s $dst -Force; Write-Host "+ $f" }
  else { Write-Host "MISS $f" -ForegroundColor Yellow }
}
Write-Host "同步完成 — git add installer/source && commit && push 即发布"
