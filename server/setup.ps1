Write-Host "============================================"
Write-Host "  RIME LLM Rerank - One-Click Setup"
Write-Host "============================================"
Write-Host ""
Write-Host "This will:"
Write-Host "  1. Install Python packages"
Write-Host "  2. Copy rime_pipe.dll"
Write-Host "  3. Download model (~500MB)"
Write-Host ""
Write-Host "NOTE: Run as Administrator for DLL install."
Write-Host "Estimated time: 5-15 min."
Write-Host ""

# Check Python: must be 3.12 (llama-cpp-python does not support 3.14+)
$pythonCmd = $null
$pyVer = ""
$usePy = Get-Command py -ErrorAction SilentlyContinue

# Try current 'python' first
$py = Get-Command python -ErrorAction SilentlyContinue
if ($py) {
    $pyVer = & $pythonCmd -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
    if ($pyVer -eq "3.12") { $pythonCmd = "python" }
}

# If not 3.12, try 'py -3.12'
if (-not $pythonCmd -and $usePy) {
    $py312 = py -3.12 -c "import sys; print('ok')" 2>$null
    if ($LASTEXITCODE -eq 0) { $pythonCmd = "py -3.12"; $pyVer = "3.12" }
}

# Still no? Error
if (-not $pythonCmd) {
    Write-Host "[ERROR] Python 3.12 is required."
    Write-Host "llama-cpp-python does not support Python 3.14+ yet."
    if ($pyVer) { Write-Host "Current Python is $pyVer (need 3.12)." }
    Write-Host ""
    Write-Host "Download Python 3.12 from https://www.python.org/downloads/"
    Write-Host "During install, check 'Add Python to PATH'."
    Write-Host "If you have multiple Python versions, use:"
    Write-Host "  py -3.12 -m & $pythonCmd -m pip install ..."
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "[OK] Python: 3.12 (via: $pythonCmd)"

# [1/3] Python packages
Write-Host ""
Write-Host "[1/3] Python packages..."
$hasPkg = & $pythonCmd -c "import llama_cpp" 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  [SKIP] Already installed"
} else {
    Write-Host "  Installing llama-cpp-python pywin32 numpy..."
    & $pythonCmd -m pip install llama-cpp-python pywin32 numpy --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Install failed. Try:"
        Write-Host "  & $pythonCmd -m pip install llama-cpp-python pywin32 numpy -i https://pypi.tuna.tsinghua.edu.cn/simple"
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "  [OK] Installed"
}

# [2/3] DLL
Write-Host ""
Write-Host "[2/3] Pipe DLL..."
$rimeDir = "C:\Program Files\Rime"
$dllDst = $null
if (Test-Path "$rimeDir\weasel-0.17.4") { $dllDst = "$rimeDir\weasel-0.17.4\rime_pipe.dll" }
elseif (Test-Path "$rimeDir\weasel-0.16.3") { $dllDst = "$rimeDir\weasel-0.16.3\rime_pipe.dll" }
if (-not $dllDst) {
    Write-Host "  [WARN] RIME not found. Manually copy rime_pipe.dll."
} elseif (Test-Path $dllDst) {
    Write-Host "  [SKIP] Already installed"
} else {
    try {
        Copy-Item "$PSScriptRoot\rime_pipe.dll" $dllDst -Force
        Write-Host "  [OK] Installed"
    } catch {
        Write-Host "  [WARN] Permission denied. Right-click -> Run as Administrator."
    }
}

# [3/3] Model
Write-Host ""
Write-Host "[3/3] Model file..."
$modelFile = "d:\gguf_models\Qwen3.5-0.8B-Q4_K_M.gguf"
if (Test-Path $modelFile) {
    Write-Host "  [SKIP] Already downloaded"
} else {
    if (-not (Test-Path "d:\gguf_models")) { New-Item -ItemType Directory "d:\gguf_models" -Force | Out-Null }
    Write-Host "  Downloading from ModelScope (~500MB)..."
    & $pythonCmd -m pip install modelscope --quiet 2>$null
    & $pythonCmd -c "from modelscope import snapshot_download; snapshot_download('unsloth/Qwen3.5-0.8B-GGUF', cache_dir='d:/gguf_models', allow_file_pattern='*Q4_K_M*')"
    if (Test-Path $modelFile) {
        Write-Host "  [OK] Download complete"
    } else {
        Write-Host "  [ERROR] Download failed. Check internet."
        Read-Host "Press Enter to exit"
        exit 1
    }
}

Write-Host ""
Write-Host "============================================"
Write-Host "  Setup complete!"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "  1. Copy lua\*.lua to your schema lua/ folder"
Write-Host "  2. Add config from schema-patch.yaml"
Write-Host "  3. Double-click start_server.bat"
Write-Host "  4. Right-click Weasel tray -> Redeploy"
Write-Host "============================================"
Read-Host "Press Enter to exit"
