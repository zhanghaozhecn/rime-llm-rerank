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

# Check Python
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    Write-Host "[ERROR] Python not found."
    Write-Host "Install Python 3.12 from python.org"
    Write-Host "(llama-cpp-python does not support Python 3.14+ yet)"
    Read-Host "Press Enter to exit"
    exit 1
}
$pyVer = python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
$pyMajor = [int]($pyVer.Split('.')[0])
$pyMinor = [int]($pyVer.Split('.')[1])
Write-Host "[OK] Python: $pyVer"
if ($pyMajor -eq 3 -and $pyMinor -ge 14) {
    Write-Host "[WARN] Python 3.14+ may not work with llama-cpp-python yet."
    Write-Host "If install fails, download Python 3.12 from python.org"
    Write-Host "(leave Python 3.12 checked in PATH during install)"
    Write-Host ""
}

# [1/3] Python packages
Write-Host ""
Write-Host "[1/3] Python packages..."
$hasPkg = python -c "import llama_cpp" 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  [SKIP] Already installed"
} else {
    Write-Host "  Installing llama-cpp-python pywin32 numpy..."
    pip install llama-cpp-python pywin32 numpy --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Install failed. Try:"
        Write-Host "  pip install llama-cpp-python pywin32 numpy -i https://pypi.tuna.tsinghua.edu.cn/simple"
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
    pip install modelscope --quiet 2>$null
    python -c "from modelscope import snapshot_download; snapshot_download('unsloth/Qwen3.5-0.8B-GGUF', cache_dir='d:/gguf_models', allow_file_pattern='*Q4_K_M*')"
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
