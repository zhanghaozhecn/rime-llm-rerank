# install_plugin.ps1 — 插件版安装器（GUI / CLI）
# GUI：双击 install_plugin.bat（提权）→ 复制文件 / 方案配置加·去 LLM（三按钮）
# CLI：-CliAction status|install|copy-files|schema-add|schema-remove
#      -SchemaName pdsp.schema.yaml -ModelPath d:\gguf_models\xxx.gguf（可选，写入配置）
param(
  [string]$CliAction = "",
  [string]$SchemaName = "",
  [string]$ModelPath = ""
)
. (Join-Path $PSScriptRoot "common.ps1")
Invoke-Installer -Edition plugin -CliAction $CliAction -SchemaName $SchemaName -ModelPath $ModelPath
