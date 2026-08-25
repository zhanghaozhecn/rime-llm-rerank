# install_source.ps1 — 源码版安装器（GUI / CLI）
# GUI：双击 install_source.bat（提权）→ 选方案 → 安装
# CLI：powershell -ExecutionPolicy Bypass -File install_source.ps1 -CliAction status|install -SchemaName pdsp.schema.yaml
param(
  [string]$CliAction = "",
  [string]$SchemaName = ""
)
. (Join-Path $PSScriptRoot "common.ps1")
Invoke-Installer -Edition source -CliAction $CliAction -SchemaName $SchemaName
