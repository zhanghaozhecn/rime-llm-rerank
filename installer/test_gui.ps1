# test_gui.ps1 — 插件版安装器 GUI/CLI 自动化测试（沙箱隔离）
#
# 隔离：$env:APPDATA 重定向到沙箱目录，GUI/CLI 子进程继承——所有 schema
# 读写物理落在沙箱，杜绝误伤活配置（2026-09-29 源码版 GUI 测试事故同款
# 教训：无隔离 + 下拉默认第一项 = 打在活方案上）。
# 测试钩子（install_plugin.ps1 内置）：
#   LLM_INSTALLER_NO_REDEPLOY=1  跳过重新部署（沙箱内无小狼毫可部署）
#   LLM_INSTALLER_TAB2=1         GUI 启动直接落在『参数配置』页
# 用 pwsh 7 运行：pwsh -File test_gui.ps1
$ErrorActionPreference = "Stop"
$entry = Join-Path $PSScriptRoot "install_plugin.ps1"
$sandbox = Join-Path $env:TEMP ("llminst_sandbox_" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
$rime = Join-Path $sandbox "Rime"
$test = Join-Path $rime "zz_test_gui.schema.yaml"
$psExe = (Get-Process -Id $PID).Path
$script:fail = 0
function Assert([string]$name, [bool]$cond) {
  if ($cond) { Write-Host ("  [PASS] " + $name) }
  else { $script:fail++; Write-Host ("  [FAIL] " + $name) }
}
function Show-File {
  Get-Content $test -Encoding UTF8 | ForEach-Object -Begin { $i = 1 } -Process { Write-Host ("    {0}: {1}" -f $i, $_); $i++ }
}
function Run-Cli([string]$action) {
  & $psExe -NoProfile -ExecutionPolicy Bypass -File $entry -CliAction $action -SchemaName "zz_test_gui.schema.yaml" 2>$null
}

$env:APPDATA = $sandbox                    # 全部子进程继承 → 读写全落沙箱
$env:LLM_INSTALLER_NO_REDEPLOY = "1"
try {
  New-Item -ItemType Directory -Path $rime -Force | Out-Null

  # ══ CLI 相位：schema-add 参数保留 / 剥离 ══════════════════
  Write-Host "== C1: 干净方案 schema-add（全键生效行 + 默认值）=="
  @'
schema:
  schema_id: zz_test
engine:
  processors:
    - ascii_composer
  filters:
    - simplifier
    - uniquifier
'@ | Out-File -FilePath $test -Encoding ascii
  Run-Cli "schema-add" | Out-Null
  $f = Get-Content $test -Encoding UTF8
  Assert "llm_rerank 节恰 1" ((($f | Where-Object { $_ -match '^llm_rerank:' }).Count) -eq 1)
  Assert "组件行已插" ((($f | Select-String "lua_processor@\*llm_processor").Count) -eq 1 -and
                      (($f | Select-String "lua_filter@\*llm_filter").Count) -eq 1)
  Assert "enabled: true" (($f | Where-Object { $_ -match '^\s+enabled: true\s*$' }).Count -eq 1)
  Assert "模板无 com_context（配置项已删）" (($f | Where-Object { $_ -match 'com_context' }).Count -eq 0)
  Assert "freq_beta: 1.50" (($f | Where-Object { $_ -match '^\s+freq_beta: 1\.50\s*$' }).Count -eq 1)
  Assert "expected_length_weight: 0.20" (($f | Where-Object { $_ -match '^\s+expected_length_weight: 0\.20\s*$' }).Count -eq 1)
  Assert "code_pattern: '.{4}'（默认）" (($f | Where-Object { $_ -match "^\s+code_pattern: '\.\{4\}'" }).Count -eq 1)

  Write-Host "== C2: 自定义参数 + model_path 后重跑 schema-add（逐键保留）=="
  @'
schema:
  schema_id: zz_test
engine:
  processors:
    - lua_processor@*llm_processor
    - ascii_composer
  filters:
    - simplifier
    - uniquifier
    - lua_filter@*llm_filter

llm_rerank:
  enabled: true
  com_context: false
  min_code_len: 3
  max_code_len: 0 # 0=不限制（旧键，应被剥除）
  min_tokens: 2
  code_pattern: '[abcde]{4}'
  max_tokens: 12
  max_candidates: 5
  cpu_cores: 6
  freq_beta: 2.25
  expected_length_weight: 0.35
  debug_fusion: true
  model_path: "d:/gguf_models/zz_test.gguf"
'@ | Out-File -FilePath $test -Encoding ascii
  Run-Cli "schema-add" | Out-Null
  $f = Get-Content $test -Encoding UTF8
  Assert "freq_beta 保留 2.25" (($f | Where-Object { $_ -match '^\s+freq_beta: 2\.25\s*$' }).Count -eq 1)
  Assert "elw 保留 0.35" (($f | Where-Object { $_ -match '^\s+expected_length_weight: 0\.35\s*$' }).Count -eq 1)
  Assert "max_tokens 保留 12" (($f | Where-Object { $_ -match '^\s+max_tokens: 12\s*$' }).Count -eq 1)
  Assert "code_pattern 保留 [abcde]{4}（单引号保留）" (($f | Where-Object { $_ -match "^\s+code_pattern: '\[abcde\]\{4\}'\s*$" }).Count -eq 1)
  Assert "残留 min_tokens 行已剥（死键收敛）" (($f | Where-Object { $_ -match 'min_tokens' }).Count -eq 0)
  Assert "残留 min_code_len 行已剥（死键收敛）" (($f | Where-Object { $_ -match 'min_code_len' }).Count -eq 0)
  Assert "残留 max_code_len 行已剥（死键收敛）" (($f | Where-Object { $_ -match 'max_code_len' }).Count -eq 0)
  Assert "cpu_cores 保留 6" (($f | Where-Object { $_ -match '^\s+cpu_cores: 6\s*$' }).Count -eq 1)
  Assert "残留 com_context 行已剥（死键收敛）" (($f | Where-Object { $_ -match 'com_context' }).Count -eq 0)
  Assert "debug_fusion 保留 true" (($f | Where-Object { $_ -match '^\s+debug_fusion: true\s*$' }).Count -eq 1)
  Assert "model_path 保留" (($f | Where-Object { $_ -match '^\s+model_path: d:/gguf_models/zz_test\.gguf\s*$' }).Count -eq 1)
  Assert "llm_rerank 节仍恰 1" ((($f | Where-Object { $_ -match '^llm_rerank:' }).Count) -eq 1)
  Assert "组件行仍恰各 1" ((($f | Select-String "lua_processor@\*llm_processor").Count) -eq 1 -and
                          (($f | Select-String "lua_filter@\*llm_filter").Count) -eq 1)

  Write-Host "== C3: schema-remove 剥净 =="
  Run-Cli "schema-remove" | Out-Null
  $f = Get-Content $test -Encoding UTF8
  Assert "llm_rerank 节已删" ((($f | Where-Object { $_ -match '^llm_rerank:' }).Count) -eq 0)
  Assert "组件行已删" ((($f | Select-String "lua_processor@|lua_filter@").Count) -eq 0)

  # ══ GUI 相位：参数配置页 ═══════════════════════════════
  Write-Host "== GUI 启动（沙箱 + TAB2 钩子）=="
  $env:LLM_INSTALLER_TAB2 = "1"
  $proc = Start-Process -FilePath $psExe -ArgumentList @("-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$entry`"") -PassThru
  $hw = [IntPtr]::Zero
  for ($t = 0; $t -lt 24; $t++) {
    Start-Sleep -Milliseconds 500
    $proc.Refresh()
    if ($proc.HasExited) { break }
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { $hw = $proc.MainWindowHandle; break }
  }
  if ($hw -eq [IntPtr]::Zero) { throw "GUI 窗口未出现（脚本解析失败或崩溃）" }
  Start-Sleep -Seconds 2

  Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;
public class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", EntryPoint="SendMessageW")] public static extern IntPtr SendMsg(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)] public static extern IntPtr SendMsgBuf(IntPtr h, uint m, IntPtr w, [Out][MarshalAs(UnmanagedType.LPWStr)] StringBuilder s);
  [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)] public static extern IntPtr SendMsgStr(IntPtr h, uint m, IntPtr w, [MarshalAs(UnmanagedType.LPWStr)] string s);
  static List<IntPtr> found;
  static bool Cb(IntPtr h, IntPtr l) { found.Add(h); return true; }
  public static List<IntPtr> Children(IntPtr p) { found = new List<IntPtr>(); EnumChildWindows(p, Cb, IntPtr.Zero); return new List<IntPtr>(found); }
}
"@

  function Get-WText([IntPtr]$h) {
    $len = [int][W]::SendMsg($h, 0x000E, [IntPtr]::Zero, [IntPtr]::Zero)
    if ($len -le 0) { return "" }
    $sb = New-Object System.Text.StringBuilder ($len + 2)
    [void][W]::SendMsgBuf($h, 0x000D, [IntPtr]($len + 1), $sb)
    return $sb.ToString()
  }
  function Get-Ctls {
    $list = @()
    foreach ($h in [W]::Children($hw)) {
      $cn = New-Object System.Text.StringBuilder 256
      [void][W]::GetClassName($h, $cn, 256)
      $r = New-Object "W+RECT"
      [void][W]::GetWindowRect($h, [ref]$r)
      $list += [pscustomobject]@{
        h = $h; cls = $cn.ToString(); text = (Get-WText $h)
        vis = [W]::IsWindowVisible($h)
        parent = [W]::GetParent($h)
        x = $r.L; y = $r.T
      }
    }
    return $list
  }
  function Find-Button([string]$text) {
    (Get-Ctls | Where-Object { $_.vis -and $_.cls -match "BUTTON" -and $_.text -eq $text } | Select-Object -First 1).h
  }
  function Find-Check([string]$needle) {
    (Get-Ctls | Where-Object { $_.vis -and $_.cls -match "BUTTON" -and $_.text -like ("*" + $needle + "*") } | Select-Object -First 1).h
  }
  function Click-Btn([IntPtr]$h) {
    [void][W]::SendMsg($h, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)   # BM_CLICK
    Start-Sleep -Milliseconds 600
  }
  function Check-State([IntPtr]$h) { [int][W]::SendMsg($h, 0x00F0, [IntPtr]::Zero, [IntPtr]::Zero) }  # BM_GETCHECK
  function Set-Check([IntPtr]$h, [int]$v) { [void][W]::SendMsg($h, 0x00F1, [IntPtr]$v, [IntPtr]::Zero) }  # BM_SETCHECK
  function Any-Text([string]$needle) {
    $t = (Get-Ctls | Where-Object { $_.vis } | ForEach-Object { $_.text }) -join "`n"
    return $t.Contains($needle)
  }
  # TAB2 激活时参数页的 EDIT 参数框（2026-09-30 起共 7 个）。按 (y,x) 排序 = 布局常量序：
  # [0]编码匹配(code_pattern) [1]上文上限 [2]候选上限 [3]线程 [4]β [5]elw
  # 注意：不能用 IsWindowVisible 判定——跨进程读 WinForms 页的可见性不可靠
  # （实测同一页内"CPU 线程数"框被判不可见，页内控件还会与另一页互相串扰）；
  # 改为按**屏幕坐标**过滤：参数页从 y+42 起，页内首个参数框 y 偏移 ≥ 60。
  function Get-ParamEdits {
    # 最可靠判据：控件**祖辈里含**『参数配置』TabPage（另一页的控件不满足；
    # 2026-09-30 起参数框嵌在 GroupBox 里，父窗口不再直接是页 → 需向上追溯）。
    # 坐标/可见性都不可靠：跨进程读 WinForms 页可见性会把隐藏的"未以管理员运行"
    # 警告 Edit 也算进来，且两页控件挂在同一个顶层窗口下（实测）。
    @(Get-Ctls | Where-Object {
        if ($_.cls -notmatch '\.Edit\.') { return $false }
        $p = $_.parent
        for ($i = 0; $i -lt 4 -and $p -ne [IntPtr]::Zero; $i++) {
          if ($p -eq $script:ParamsTab) { return $true }
          $p = [W]::GetParent($p)
        }
        return $false
      } | Sort-Object y, x)
  }
  function Set-Edit($e, [string]$v) { [void][W]::SendMsgStr($e.h, 0x000C, [IntPtr]::Zero, $v) }  # WM_SETTEXT

  Write-Host "== G1: 未接入方案读参数（默认值）=="
  # 『参数配置』页（TAB2 钩子已激活它）= 类名匹配页窗口、屏幕 y 更大的那个
  # 『参数配置』页 = 可见的那个 TabPage（TAB2 钩子已激活它）；另一页 vis=False。
  # 注意：两页屏幕坐标几乎相同，按 y 排序取"更大/更小"不可靠（实测取到过隐藏页）。
  $script:ParamsTab = (Get-Ctls | Where-Object { $_.cls -match '\.Window\.\d+\.' -and $_.vis -and $_.text -eq '参数配置' } |
                       Select-Object -First 1).h
  if ($env:LLM_TEST_DUMP) {
    Get-Ctls | Where-Object { $_.cls -match '\.Window\.\d+\.' } | Sort-Object y, x | ForEach-Object {
      Write-Host ("  PAGE h={0} text='{1}' y={2} x={3} vis={4}" -f $_.h, ($_.text -replace "`r?`n", ' / '), $_.y, $_.x, $_.vis)
    }
    foreach ($c in (Get-Ctls | Where-Object { $_.cls -match '\.Edit\.' } | Sort-Object y, x)) {
      Write-Host ("  edit text='{0}' y={1} x={2} parent={3}" -f ($c.text -replace "`r?`n", ' / '), $c.y, $c.x, $c.parent)
    }
  }
  Click-Btn (Find-Button "读取参数")
  Assert "状态含 未接入" (Any-Text "未接入 LLM")
  $e = Get-ParamEdits
  Assert ("参数框数 = 6（实测 $($e.Count)：$(($e | ForEach-Object { $_.text }) -join '|')）") ($e.Count -eq 6)
  Assert "code_pattern = .{4}" ((Get-WText $e[0].h) -eq ".{4}")
  Assert "max_tokens = 10" ((Get-WText $e[1].h) -eq "10")
  Assert "max_candidates = 5" ((Get-WText $e[2].h) -eq "5")
  Assert "cpu_cores = 4" ((Get-WText $e[3].h) -eq "4")
  Assert "freq_beta = 1.50" ((Get-WText $e[4].h) -eq "1.50")
  Assert "elw = 0.20" ((Get-WText $e[5].h) -eq "0.20")
  # 复选框状态不在此断言：BM_GETCHECK 跨进程读不到 WinForms 主题复选框的
  # 内部态（渲染/保存均正确，2026-09-29 截图+落盘双验证）——复选框断言
  # 统一走 BM_CLICK 切换 + 保存落盘（G4 读入态保持 / G7 点击翻转）

  Write-Host "== G2: 未接入时保存 → [失败] 状态，文件不动 =="
  $before = (Get-Item $test).LastWriteTimeUtc
  Click-Btn (Find-Button "保存并生效")
  Assert "状态含 配置节不存在失败" (Any-Text "方案内没有 llm_rerank")
  Assert "文件未改动" ((Get-Item $test).LastWriteTimeUtc -eq $before)

  Write-Host "== G3: 接入方案读参数（自定义值回填）=="
  @'
schema:
  schema_id: zz_test
engine:
  processors:
    - lua_processor@*llm_processor
    - ascii_composer
  filters:
    - simplifier
    - uniquifier
    - lua_filter@*llm_filter

llm_rerank:
  enabled: true
  com_context: false
  min_code_len: 3
  max_code_len: 0 # 0=不限制（旧键）
  min_tokens: 2
  code_pattern: '.{3,4}'
  max_tokens: 12
  max_candidates: 5
  cpu_cores: 6
  freq_beta: 2.25
  expected_length_weight: 0.35
  debug_fusion: true
  model_path: "d:/gguf_models/zz_test.gguf"
'@ | Out-File -FilePath $test -Encoding ascii
  Click-Btn (Find-Button "读取参数")
  Assert "状态含 已加载" (Any-Text "已加载")
  Assert "code_pattern = .{3,4}" ((Get-WText $e[0].h) -eq ".{3,4}")
  Assert "max_tokens = 12" ((Get-WText $e[1].h) -eq "12")
  Assert "cpu_cores = 6" ((Get-WText $e[3].h) -eq "6")
  Assert "freq_beta = 2.25" ((Get-WText $e[4].h) -eq "2.25")
  Assert "elw = 0.35" ((Get-WText $e[5].h) -eq "0.35")

  Write-Host "== G4: 保存（β→0.80、mode→[abcde]{4}；复选框按读入态原样落盘；旧键被剥）=="
  Set-Edit $e[4] "0.80"
  Set-Edit $e[0] "[abcde]{4}"
  Click-Btn (Find-Button "保存并生效")
  Assert "状态含 已保存并触发重新部署" (Any-Text "已保存并触发重新部署")
  $f = Get-Content $test -Encoding UTF8
  Assert "enabled: true（读入态保持）" (($f | Where-Object { $_ -match '^\s+enabled: true\s*$' }).Count -eq 1)
  Assert "debug_fusion: true（读入态保持）" (($f | Where-Object { $_ -match '^\s+debug_fusion: true\s*$' }).Count -eq 1)
  Assert "残留 com_context 行已剥（死键收敛）" (($f | Where-Object { $_ -match 'com_context' }).Count -eq 0)
  Assert "freq_beta: 0.80" (($f | Where-Object { $_ -match '^\s+freq_beta: 0\.80\s*$' }).Count -eq 1)
  Assert "残留 min_tokens 行已剥（死键收敛）" (($f | Where-Object { $_ -match 'min_tokens' }).Count -eq 0)
  Assert "残留 min_code_len 行已剥（死键收敛）" (($f | Where-Object { $_ -match 'min_code_len' }).Count -eq 0)
  Assert "残留 max_code_len 行已剥（死键收敛）" (($f | Where-Object { $_ -match 'max_code_len' }).Count -eq 0)
  Assert "code_pattern 落盘 [abcde]{4}（单引号）" (($f | Where-Object { $_ -match "^\s+code_pattern: '\[abcde\]\{4\}'\s*$" }).Count -eq 1)
  Assert "elw 保留 0.35" (($f | Where-Object { $_ -match '^\s+expected_length_weight: 0\.35\s*$' }).Count -eq 1)
  Assert "max_tokens 保留 12" (($f | Where-Object { $_ -match '^\s+max_tokens: 12\s*$' }).Count -eq 1)
  Assert "model_path 保留" (($f | Where-Object { $_ -match '^\s+model_path: d:/gguf_models/zz_test\.gguf\s*$' }).Count -eq 1)
  Assert "组件行未动" ((($f | Select-String "lua_processor@\*llm_processor").Count) -eq 1 -and
                      (($f | Select-String "lua_filter@\*llm_filter").Count) -eq 1)
  Assert "llm_rerank 节恰 1" ((($f | Where-Object { $_ -match '^llm_rerank:' }).Count) -eq 1)
  Show-File

  Write-Host "== G5: 幂等重存（逐字节一致）=="
  $h1 = (Get-FileHash $test -Algorithm MD5).Hash
  Click-Btn (Find-Button "保存并生效")
  $h2 = (Get-FileHash $test -Algorithm MD5).Hash
  Assert "文件逐字节一致" ($h1 -eq $h2)

  Write-Host "== G6: 非法输入 β=abc → 拒绝保存 =="
  Set-Edit $e[4] "abc"
  Click-Btn (Find-Button "保存并生效")
  Assert "状态含 不是有效数字" (Any-Text "不是有效数字")
  Assert "文件未改动" ((Get-FileHash $test -Algorithm MD5).Hash -eq $h2)
  Set-Edit $e[4] "0.80"   # 恢复合法值——G7 复选框相位要靠保存落盘验证

  Write-Host "== G7: 复选框 BM_CLICK 切换 + 保存落盘 =="
  [void][W]::SendMsg((Find-Check "启用 LLM 重排"), 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)  # true→false
  Start-Sleep -Milliseconds 300
  Click-Btn (Find-Button "保存并生效")
  $f = Get-Content $test -Encoding UTF8
  Assert "enabled: false（点击翻转）" (($f | Where-Object { $_ -match '^\s+enabled: false\s*$' }).Count -eq 1)
  Assert "debug_fusion: true（未动保持）" (($f | Where-Object { $_ -match '^\s+debug_fusion: true\s*$' }).Count -eq 1)
  Assert "freq_beta 仍 0.80" (($f | Where-Object { $_ -match '^\s+freq_beta: 0\.80\s*$' }).Count -eq 1)

  Write-Host "== G8: 重读回环（保存值回到界面）=="
  Click-Btn (Find-Button "读取参数")
  Assert "beta 字段 = 0.80" ((Get-WText $e[4].h) -eq "0.80")
  Assert "code_pattern 字段 = [abcde]{4}" ((Get-WText $e[0].h) -eq "[abcde]{4}")
}
finally {
  Get-Process pwsh, powershell -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -like "*LLM 重排安装器*" } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item Env:LLM_INSTALLER_NO_REDEPLOY -ErrorAction SilentlyContinue
  Remove-Item Env:LLM_INSTALLER_TAB2 -ErrorAction SilentlyContinue
  Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fail -eq 0) { Write-Host "`nALL PASS" } else { Write-Host "`nFAILED: $($script:fail)"; exit 1 }
