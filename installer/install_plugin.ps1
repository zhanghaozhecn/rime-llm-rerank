# install_plugin.ps1 — 插件版安装器（GUI / CLI）
# GUI：双击 install_plugin.bat（提权）→ 选方案 → 安装
# CLI：powershell -ExecutionPolicy Bypass -File install_plugin.ps1 -CliAction status|install -SchemaName pdsp.schema.yaml
param(
  [string]$CliAction = "",
  [string]$SchemaName = ""
)
. (Join-Path $PSScriptRoot "common.ps1")
Invoke-Installer -Edition plugin -CliAction $CliAction -SchemaName $SchemaName
