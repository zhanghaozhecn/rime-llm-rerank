#!/usr/bin/env python3
"""
LLM 重排自动化测试

用法:
  python run_tests.py                   运行全部测试（CPU 后端）
  python run_tests.py --baseline        生成/更新基线
  python run_tests.py --samples 500     指定样本数（默认 200）
  python run_tests.py --gpu             使用 GPU 后端测试（需 CUDA 环境）
  python run_tests.py --quick           快速模式（仅 CE 正确性，跳过回归）

测试内容:
  1. CE 正确性 — 分层 vs gold，固定 6 个用例
  2. 准确率回归 — wiki 语料采样，对比基线
  3. 延迟回归 — p50 对比基线
"""

import subprocess
import sys
import os
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CPP_DIR = PROJECT_ROOT / "cpp"
BUILD_DIR = CPP_DIR / "build_cpu"
TEST_EXE = BUILD_DIR / "test_core.exe"
BASELINE_FILE = BUILD_DIR / "test_baseline.json"

# VS 编译环境
MSVC_BIN = "C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64"
WINKIT_BIN = "C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64"
WINKIT_INC = "C:/Program Files (x86)/Windows Kits/10/Include/10.0.26100.0"
WINKIT_LIB = "C:/Program Files (x86)/Windows Kits/10/Lib/10.0.26100.0"
MSVC_INC = "C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44.35207/include"
MSVC_LIB = "C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44.35207/lib/x64"
CMAKE_BIN = "C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin"


def green(s):  return f"\033[92m{s}\033[0m"
def red(s):    return f"\033[91m{s}\033[0m"
def yellow(s): return f"\033[93m{s}\033[0m"


def build():
    """编译 test_core.exe（CPU 后端，使用 build_cpu 目录）"""
    print(f"\n{yellow('[build]')} Compiling test_core.exe...")

    env = os.environ.copy()
    env["PATH"] = f"{CMAKE_BIN};{MSVC_BIN};{WINKIT_BIN};{env.get('PATH', '')}"
    env["INCLUDE"] = f"{MSVC_INC};{WINKIT_INC}/ucrt;{WINKIT_INC}/um;{WINKIT_INC}/shared"
    env["LIB"] = f"{MSVC_LIB};{WINKIT_LIB}/ucrt/x64;{WINKIT_LIB}/um/x64"

    if not BUILD_DIR.exists():
        print(red(f"  Build dir not found: {BUILD_DIR}"))
        print(red(f"  First configure: cmake -G Ninja -S {CPP_DIR} -B {BUILD_DIR}"))
        return False

    r = subprocess.run(
        ["ninja", "test_core"],
        cwd=str(BUILD_DIR), env=env,
        capture_output=True, text=True, errors='replace'
    )
    if r.returncode != 0:
        print(red(f"  Build failed:\n{r.stderr[-500:]}"))
        return False

    print(green("  Build OK"))
    return True


def run_test(args: list) -> tuple[int, str]:
    """运行 test_core.exe，返回 (exit_code, output)"""
    r = subprocess.run(
        [str(TEST_EXE)] + args,
        cwd=str(BUILD_DIR),
        capture_output=True, text=True, errors='replace',
        timeout=600  # 10 分钟超时
    )
    return r.returncode, r.stdout + r.stderr


def main():
    quick = "--quick" in sys.argv
    baseline = "--baseline" in sys.argv
    samples = 200
    for i, a in enumerate(sys.argv):
        if a == "--samples" and i + 1 < len(sys.argv):
            samples = int(sys.argv[i + 1])

    print(f"{'='*50}")
    print(f"  LLM Rerank Automated Tests")
    print(f"  Samples: {samples}" + (" (quick mode)" if quick else ""))
    print(f"{'='*50}")

    # Step 1: Build
    if not build():
        sys.exit(3)

    # Step 2: Generate baseline (if requested)
    if baseline:
        print(f"\n{yellow('[baseline]')} Generating baseline with {samples} samples...")
        code, out = run_test(["--baseline", "--samples", str(samples)])
        print(out)
        if code == 0:
            print(green("\n  Baseline created: " + str(BASELINE_FILE)))
        else:
            print(red("\n  Baseline generation failed"))
        sys.exit(code)

    # Step 3: Run tests
    if quick:
        # CE correctness only — skip accuracy/latency regression
        # Run with 0 samples to skip wiki tests
        code, out = run_test(["--samples", "0"])
        print(out)
        # Filter to show only CE test results
        for line in out.splitlines():
            if "PASS:" in line or "FAIL:" in line:
                print(f"  {line.strip()}")
        sys.exit(code)
    else:
        code, out = run_test(["--samples", str(samples)])
        print(out)

    # Step 4: Report
    print(f"\n{'='*50}")
    if code == 0:
        print(green("  ALL TESTS PASSED"))
    else:
        print(red(f"  TESTS FAILED (exit code {code})"))
    print(f"{'='*50}")
    sys.exit(code)


if __name__ == "__main__":
    main()
