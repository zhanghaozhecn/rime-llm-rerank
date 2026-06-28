param(
    [switch] $DryRun
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Project = Resolve-Path "$ScriptDir\.."
$Work = "$Project\llm_rerank"
$Lua = "$Project\配置文件\lua"
$Publish = "D:\rime-llm-rerank"

function Write-Action($msg, $color = "White") {
    Write-Host $msg -ForegroundColor $color
}

# -- 1. Server files --
$ServerFiles = @("pipe_server.py", "rime_pipe.dll", "setup.bat", "setup.ps1", "start_server.bat", "stop_server.bat", "README.md")
foreach ($f in $ServerFiles) {
    $src = "$Work\$f"
    $dst = "$Publish\server\$f"
    if (-not (Test-Path $src)) { continue }
    $srcHash = (Get-FileHash $src -Algorithm MD5).Hash
    if (Test-Path $dst) {
        $dstHash = (Get-FileHash $dst -Algorithm MD5).Hash
        if ($srcHash -eq $dstHash) {
            Write-Action "  - unchanged: server\$f" "DarkGray"
            continue
        }
    }
    if ($DryRun) {
        Write-Action "  -> would update: server\$f" "Cyan"
    } else {
        Copy-Item $src $dst -Force
        Write-Action "  + updated: server\$f" "Green"
    }
}

# -- 3. Lua files --
$LuaFiles = @("llm_context.lua", "llm_rerank.lua")
foreach ($f in $LuaFiles) {
    $src = "$Lua\$f"
    $dst = "$Publish\lua\$f"
    if (-not (Test-Path $src)) { continue }
    $srcHash = (Get-FileHash $src -Algorithm MD5).Hash
    $dstHash = if (Test-Path $dst) { (Get-FileHash $dst -Algorithm MD5).Hash } else { "" }
    if ($srcHash -ne $dstHash) {
        if ($DryRun) {
            Write-Action "  -> would update: lua\$f" "Cyan"
        } else {
            Copy-Item $src $dst -Force
            Write-Action "  + updated: lua\$f" "Green"
        }
    } else {
        Write-Action "  - unchanged: lua\$f" "DarkGray"
    }
}

# -- 4. Dev files --
$DevFiles = @("rime_pipe.c", "eval_and_analyze.py", "bench_tok_cand.py", "bench_configs.py", "bench_parallel_mp.py")
foreach ($f in $DevFiles) {
    $src = "$Work\$f"
    $dst = "$Publish\dev\$f"
    if (-not (Test-Path $src)) { continue }
    $srcHash = (Get-FileHash $src -Algorithm MD5).Hash
    $dstHash = if (Test-Path $dst) { (Get-FileHash $dst -Algorithm MD5).Hash } else { "" }
    if ($srcHash -ne $dstHash) {
        if ($DryRun) {
            Write-Action "  -> would update: dev\$f" "Cyan"
        } else {
            Copy-Item $src $dst -Force
            Write-Action "  + updated: dev\$f" "Green"
        }
    } else {
        Write-Action "  - unchanged: dev\$f" "DarkGray"
    }
}

Write-Host ""
Write-Action "  Sync complete!" "Green"
