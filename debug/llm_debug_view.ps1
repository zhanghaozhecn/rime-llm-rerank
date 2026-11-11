<#
 llm_debug_view.ps1 — LLM 实时调试窗口（插件版）
 数据源：命名管道 \\.\pipe\rime_llm_live（rime_llm.dll 内的 live 管道服务，
 由 lua 在 llm_rerank/debug_fusion: true 时调用 llm.live_write 推送）。
 前置：方案开启 debug_fusion 并重新部署（否则管道不存在，本窗口等待连接）。

 行协议（| 分隔 UTF-8 文本行；自由文本字段已把 | 转全角｜、换行转空格）：
   V|rime-llm-live|1|plugin|<日期>                     连接后服务端立即推
   L|HH:MM:SS|input|cache|src|ctx|tick|ms|ready|n      每次触发评分的调用头
                                                       （ctx=完整上文；cache=HIT 时 ms=0；
                                                        src ∈ tsf/com/uia/rime）
   C|eng|word|s1|ce|fb|u1|fused|full|cerank|fin|win    逐候选按最终序（上限 20 行）：
                                                       eng=引擎原序 s1=层1分 ce=CE 分（空=无分）
                                                       fb=β·log1p(eff) u1=log(p1)
                                                       full=两码整句满长 cerank=CE 序名次
                                                       fin=最终位置 win=1 层2窗内/0 尾窗透传
   S|HH:MM:SS|reason|input|src                        跳过原因：pattern/ctx_empty/
                                                       not_ready/ctx_short/scores_nil/
                                                       score_failed/few_candidates
   E|HH:MM:SS|word|eff0|eff1|tick0|tick1              commit 落账
   R|HH:MM:SS|reason                                  上文重置（编辑键等）

 用法：
   pwsh -STA -File llm_debug_view.ps1            图形窗口（推荐用 open_debug_window.bat 启动）
   pwsh -File llm_debug_view.ps1 -Raw            控制台直打收到的行（自动化验证用）
 本文件必须保持 UTF-8 BOM（Windows PowerShell 5.1 无 BOM 会把中文按 ANSI 解析）。
#>
param([switch]$Raw)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$PipeName = 'rime_llm_live'

# ── 后台读取循环（独立 Runspace 里跑；跨线程通信只走线程安全的
#    ConcurrentQueue，UI 只在主线程 Timer 里取——不碰跨线程控件访问）───
$ReaderScript = {
  param($q, $pipeName)
  $enc = [System.Text.Encoding]::UTF8
  while ($true) {
    $pipe = $null
    try {
      $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
        '.', $pipeName, [System.IO.Pipes.PipeDirection]::In)
      $pipe.Connect(1500)
      $q.Enqueue('::CONNECTED')
      $sr = [System.IO.StreamReader]::new($pipe, $enc)
      while ($true) {
        $line = $sr.ReadLine()
        if ($null -eq $line) { break }
        if ($line.Length -gt 0) { $q.Enqueue($line) }
      }
    } catch {
      # 管道不存在（debug_fusion 未开 / 服务未启动）或对端断开——外层重连
    } finally {
      if ($pipe) { $pipe.Dispose() }
      $q.Enqueue('::DISCONNECTED')
    }
    Start-Sleep -Milliseconds 1000
  }
}

# ── -Raw：控制台直打行流（自动化验证）────────────────────────────────────
if ($Raw) {
  try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
  Write-Host "等待管道 \\.\pipe\$PipeName （在方案开启 llm_rerank/debug_fusion 并重新部署后，打字即出数据；Ctrl+C 退出）"
  $q = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
  $bg = [System.Management.Automation.PowerShell]::Create()
  $bg.AddScript($ReaderScript).AddArgument($q).AddArgument($PipeName) | Out-Null
  $h = $bg.BeginInvoke()
  try {
    while ($true) {
      $line = $null
      while ($q.TryDequeue([ref]$line)) { Write-Host $line }
      Start-Sleep -Milliseconds 100
    }
  } finally {
    $bg.Stop(); $bg.Dispose()
  }
  exit 0
}

# ── 数据状态 ─────────────────────────────────────────────────────────────
$script:queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:invList = [System.Collections.Generic.List[object]]::new()  # 最近 50 次调用
$script:events  = [System.Collections.Generic.List[string]]::new()  # 最近 200 条事件行
$script:viewIdx = -1          # 当前展示的调用下标（-1 = 无）
$script:paused  = $false
$script:connected = $false
$script:verInfo = ''

# ── 布局常量（96 DPI 设计值；DpiK≠1 时末尾统一 字体×k + Scale(k,k)）──────
$Y_STATUS = 8;  $H_STATUS = 22
$Y_INFO   = 34; $H_INFO = 20
$Y_CTX    = 58; $H_CTX = 42
$Y_GRID   = 104; $H_GRID = 298
$X_GRID   = 8;   $W_GRID = 728
$X_HIST   = 744; $W_HIST = 204
$Y_EVT    = 410; $H_EVT = 96
$Y_FOOT   = 512       # 公式 / 列义 / 数据源 三行灰注（各 +16）
$CW = 976       # ClientSize 宽（= X_HIST + W_HIST + 8）
$CH = 576       # ClientSize 高（2026-11-11 加公式两行）

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'LLM 实时调试 — rime-llm-rerank（插件版）'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::White
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9)
$form.ClientSize = [System.Drawing.Size]::new($CW, $CH)

function New-Lbl([int]$x, [int]$y, [int]$w, [int]$h) {
  $l = [System.Windows.Forms.Label]::new()
  $l.Location = [System.Drawing.Point]::new($x, $y)
  $l.Size = [System.Drawing.Size]::new($w, $h)
  $l.BackColor = [System.Drawing.Color]::White
  $l.AutoEllipsis = $true
  $form.Controls.Add($l)
  return $l
}
$lblStatus = New-Lbl 8 $Y_STATUS 700 $H_STATUS
$lblStatus.Text = '等待连接…（先在方案开启 llm_rerank/debug_fusion 并重新部署，然后打字）'
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray

$lblInfo = New-Lbl 8 $Y_INFO 944 $H_INFO
$lblInfo.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblInfo.Text = '—'

$lblCtx = New-Lbl 8 $Y_CTX 944 $H_CTX
$lblCtx.Text = '上文：—'

$btnPause = [System.Windows.Forms.Button]::new()
$btnPause.Location = [System.Drawing.Point]::new(704, $Y_STATUS - 2)
$btnPause.Size = [System.Drawing.Size]::new(64, 24)
$btnPause.Text = '暂停'
$btnPause.FlatStyle = 'Flat'
$btnPause.UseVisualStyleBackColor = $false
$form.Controls.Add($btnPause)

$chkTop = [System.Windows.Forms.CheckBox]::new()
$chkTop.Location = [System.Drawing.Point]::new(776, $Y_STATUS)
$chkTop.Size = [System.Drawing.Size]::new(52, 22)
$chkTop.Text = '置顶'
$chkTop.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($chkTop)

$btnClear = [System.Windows.Forms.Button]::new()
$btnClear.Location = [System.Drawing.Point]::new(836, $Y_STATUS - 2)
$btnClear.Size = [System.Drawing.Size]::new(52, 24)
$btnClear.Text = '清空'
$btnClear.FlatStyle = 'Flat'
$btnClear.UseVisualStyleBackColor = $false
$form.Controls.Add($btnClear)

$grid = [System.Windows.Forms.DataGridView]::new()
$grid.Location = [System.Drawing.Point]::new($X_GRID, $Y_GRID)
$grid.Size = [System.Drawing.Size]::new($W_GRID, $H_GRID)
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.BorderStyle = 'FixedSingle'
$grid.CellBorderStyle = 'SingleHorizontal'
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeColumnsMode = 'None'
# 列头禁换行 + 短文案：窄列两行表头会被默认行高裁掉下半行（2026-11-10 实测）
$grid.ColumnHeadersDefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::False
# 列（2026-11-11 协议 v2）：频两项 = 原始值（衰减频 = eff 衰减计数、
# 累计频 = 累计 unigram 原始计数，都未乘系数）；CE 列加宽容纳展开的
# CE1/CE2/CE3（点 CE 单元格切换，默认不展开）
# 方案 B / 计数-得分式命名（2026-11-11 用户定案）：CE 三子项常显；
# 词频得分/累计得分 = 真正进融合的项，括号内是原始证据
$cols = @(
  @('#', 24), @('词', 58), @('C1/C2/C3', 128), @('CE和', 58),
  @('词频得分', 88), @('累计得分', 88),
  @('用户频分', 66), @('融合分', 62), @('满', 26), @('CE→终', 58), @('窗', 30))
foreach ($c in $cols) {
  $i = $grid.Columns.Add($c[0], $c[0])
  $grid.Columns[$i].Width = $c[1]
}
$form.Controls.Add($grid)

$hist = [System.Windows.Forms.ListBox]::new()
$hist.Location = [System.Drawing.Point]::new($X_HIST, $Y_GRID)
$hist.Size = [System.Drawing.Size]::new($W_HIST, $H_GRID)
$hist.HorizontalScrollbar = $true
$form.Controls.Add($hist)

$evt = [System.Windows.Forms.ListBox]::new()
$evt.Location = [System.Drawing.Point]::new(8, $Y_EVT)
$evt.Size = [System.Drawing.Size]::new(944, $H_EVT)
$evt.HorizontalScrollbar = $true
$form.Controls.Add($evt)

# 公式与列义两行灰注（2026-11-11 用户定案：空白处显示融合公式 + 层1/满/
# 展开说明；点 CE 格展开 CE1/2/3，默认不展开）
$lblFx = New-Lbl 8 $Y_FOOT 944 16
$lblFx.ForeColor = [System.Drawing.Color]::Gray
$lblFx.Font = [System.Drawing.Font]::new('Segoe UI', 8)
$lblFx.Text = '融合分 = CE + 词频得分 + 累计得分；词频得分 = 12·log(1+衰减计数)；累计得分 = log((累计次数+1)/(全词数+2万))；用户频分 = 词频得分+累计得分'

$lblLeg = New-Lbl 8 ($Y_FOOT + 16) 944 16
$lblLeg.ForeColor = [System.Drawing.Color]::Gray
$lblLeg.Font = [System.Drawing.Font]::new('Segoe UI', 8)
$lblLeg.Text = '括号内为原始证据（衰减计数 / 累计次数）；用户频分 = 全体候选的预排分，按其降序取前5进 LLM；满 = 两码整句满长组；窗=0 = 尾窗未进 LLM（灰字）'

$lblFoot = New-Lbl 8 ($Y_FOOT + 32) 944 16
$lblFoot.ForeColor = [System.Drawing.Color]::Gray
$lblFoot.Font = [System.Drawing.Font]::new('Segoe UI', 8)
$lblFoot.Text = '数据源 \\.\pipe\' + $PipeName + ' · 开关 = 方案 llm_rerank/debug_fusion（改后重新部署）· 预解 = 上文 KV 预解码命中'

# ── 显示更新 ─────────────────────────────────────────────────────────────
function Update-Current {
  if ($script:viewIdx -lt 0 -or $script:viewIdx -ge $script:invList.Count) {
    $script:lblInfo.Text = '—'
    $script:lblCtx.Text = '上文：—'
    $script:grid.Rows.Clear()
    return
  }
  $inv = $script:invList[$script:viewIdx]
  $script:lblInfo.Text = ('{0}  输入 {1}   来源 {2}   预解 {3}   {4}ms   tick {5}   全词数 {6}   n={7}   就绪 {8}' -f
    $inv.t, $inv.input, $inv.src,
    $(if ($inv.prep) { $inv.prep } else { '-' }),
    $inv.ms, $inv.tick,
    $(if ($inv.nseen) { $inv.nseen } else { '-' }),
    $inv.n, $inv.ready)
  $script:lblCtx.Text = '上文：' + $(if ($inv.ctx) { $inv.ctx } else { '（空）' })
  $script:grid.Rows.Clear()
  $i = 0
  foreach ($r in $inv.rows) {
    $fbTxt = $r.fb
    if ($r.fb -and $r.eff) { $fbTxt = $r.fb + '(' + (Format-CeShort $r.eff) + ')' }
    elseif (-not $r.fb -and $r.eff) { $fbTxt = Format-CeShort $r.eff }
    $u1Txt = $r.u1
    if ($r.u1 -and $r.uni) { $u1Txt = $r.u1 + '(' + $r.uni + ')' }
    elseif (-not $r.u1 -and $r.uni) { $u1Txt = $r.uni }
    [void]$script:grid.Rows.Add(($i + 1), $r.word, (Get-CeText $r),
      $(if ($r.ce) { $r.ce } else { '·' }), $fbTxt, $u1Txt, $r.s1, $r.fused,
      $r.full, ($r.cerank + '→' + $r.fin), $r.win)
    if ($r.win -eq '0') {
      $script:grid.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
    }
    $i++
  }
}

# CE 单元格文本：收起 = CE 值（或 ·）；展开 = CE1/CE2/CE3 原始分量
#（未乘 kCeW 权重；缺分量位显示 ·）。展开态压成 2 位小数——3 位时三段
# 放不进列宽（2026-11-11 实测截断）
function Format-CeShort {
  param($v)
  if (-not $v) { return '·' }
  $s = [string]$v
  $dot = $s.IndexOf('.')
  if ($dot -lt 0 -or $dot + 2 -ge $s.Length) { return $s }
  return $s.Substring(0, $dot + 3)
}
function Get-CeText {
  param($r)
  if (-not ($r.ce1 -or $r.ce2 -or $r.ce3)) { return '·' }
  return ((Format-CeShort $r.ce1) + '/' + (Format-CeShort $r.ce2) + '/' +
          (Format-CeShort $r.ce3))
}

function Add-Event {
  param($text)
  $script:events.Insert(0, $text)
  while ($script:events.Count -gt 200) { $script:events.RemoveAt($script:events.Count - 1) }
  if (-not $script:paused) {
    $script:evt.Items.Clear()
    foreach ($e in $script:events) { [void]$script:evt.Items.Add($e) }
  }
}

function Rebuild-All {
  $script:evt.Items.Clear()
  foreach ($e in $script:events) { [void]$script:evt.Items.Add($e) }
  # 历史列表也要重建：暂停期间 invList 仍在追加/裁剪，ListBox 已陈旧
  $script:hist.Items.Clear()
  foreach ($inv in $script:invList) {
    $words = ($inv.rows | Select-Object -First 3 | ForEach-Object { $_.word }) -join ','
    [void]$script:hist.Items.Add(('{0} {1} {2}' -f $inv.t, $inv.input, $words))
  }
  Update-Current
}

# ── 协议行处理 ───────────────────────────────────────────────────────────
function Handle-Line {
  param($line)
  if ($line -eq '::CONNECTED') {
    $script:connected = $true
    if (-not $script:paused) {
      $script:lblStatus.Text = '已连接' + $(if ($script:verInfo) { ' · ' + $script:verInfo } else { '' })
      $script:lblStatus.ForeColor = [System.Drawing.Color]::Green
    }
    return
  }
  if ($line -eq '::DISCONNECTED') {
    $script:connected = $false
    if (-not $script:paused) {
      $script:lblStatus.Text = '连接断开，1 秒后重连…（管道不存在 = debug_fusion 未开或小狼毫服务未运行）'
      $script:lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    }
    return
  }
  $f = $line -split '\|'
  switch ($f[0]) {
    'V' {
      if ($f.Count -ge 5 -and $f[1] -eq 'rime-llm-live') {
        $script:verInfo = ('协议 v{0} · {1} 版 · {2}' -f $f[2], $f[3], $f[4])
        if ($script:connected -and -not $script:paused) {
          $script:lblStatus.Text = '已连接 · ' + $script:verInfo
        }
      }
    }
    'L' {
      if ($f.Count -lt 10) { return }
      $inv = @{ t = $f[1]; input = $f[2]; cache = $f[3]; src = $f[4]
                ctx = $f[5]; tick = $f[6]; ms = $f[7]; ready = $f[8]
                n = $f[9]
                prep = $(if ($f.Count -gt 10) { $f[10] } else { '' })
                nseen = $(if ($f.Count -gt 11) { $f[11] } else { '' })
                rows = [System.Collections.Generic.List[object]]::new() }
      $script:invList.Add($inv)
      while ($script:invList.Count -gt 50) { $script:invList.RemoveAt(0) }
      $script:viewIdx = $script:invList.Count - 1
      if (-not $script:paused) {
        [void]$script:hist.Items.Add(('{0} {1}' -f $inv.t, $inv.input))
        while ($script:hist.Items.Count -gt 50) { $script:hist.Items.RemoveAt(0) }
        Update-Current
      }
    }
    'C' {
      if ($f.Count -lt 12) { return }
      if ($script:invList.Count -eq 0) { return }
      $inv = $script:invList[$script:invList.Count - 1]
      # 协议 v2：第 5/6 字段 = 衰减频(eff)/累计频(uni) 原始值；12/13/14 =
      # CE 三分量原始值（旧服务端只有 12 个字段 → 三分量为空，退化为旧显示）
      $inv.rows.Add(@{ eng = $f[1]; word = $f[2]; s1 = $f[3]; ce = $f[4]
                       eff = $f[5]; uni = $f[6]; fused = $f[7]; full = $f[8]
                       cerank = $f[9]; fin = $f[10]; win = $f[11]
                       ce1 = $(if ($f.Count -gt 12) { $f[12] } else { '' })
                       ce2 = $(if ($f.Count -gt 13) { $f[13] } else { '' })
                       ce3 = $(if ($f.Count -gt 14) { $f[14] } else { '' })
                       fb = $(if ($f.Count -gt 15) { $f[15] } else { '' })
                       u1 = $(if ($f.Count -gt 16) { $f[16] } else { '' }) })
      if (-not $script:paused -and $script:viewIdx -eq ($script:invList.Count - 1)) {
        Update-Current
      }
      # 历史条目补前 3 个词（前几条 C 行到达时）
      if (-not $script:paused -and $inv.rows.Count -le 3) {
        $idx = $script:hist.Items.Count - 1
        if ($idx -ge 0) {
          $words = ($inv.rows | Select-Object -First 3 | ForEach-Object { $_.word }) -join ','
          $script:hist.Items[$idx] = ('{0} {1} {2}' -f $inv.t, $inv.input, $words)
        }
      }
    }
    'S' {
      if ($f.Count -lt 3) { return }
      Add-Event ('{0} 跳过 {1}（输入 {2} 来源 {3}）' -f $f[1], $f[2],
        $(if ($f.Count -gt 3) { $f[3] } else { '' }),
        $(if ($f.Count -gt 4) { $f[4] } else { '-' }))
    }
    'E' {
      if ($f.Count -lt 7) { return }
      Add-Event ('{0} 上屏 {1}  eff {2}→{3}  tick {4}→{5}' -f
        $f[1], $f[2], $f[3], $f[4], $f[5], $f[6])
    }
    'R' {
      if ($f.Count -lt 3) { return }
      Add-Event ('{0} 重置 {1}' -f $f[1], $f[2])
    }
  }
}

# ── 交互 ─────────────────────────────────────────────────────────────────
$btnPause.Add_Click({
  $script:paused = -not $script:paused
  $btnPause.Text = $(if ($script:paused) { '继续' } else { '暂停' })
  if (-not $script:paused) { Rebuild-All }
})
$chkTop.Add_CheckedChanged({ $form.TopMost = $chkTop.Checked })
$btnClear.Add_Click({
  $script:invList.Clear(); $script:events.Clear()
  $script:hist.Items.Clear(); $script:evt.Items.Clear()
  $script:viewIdx = -1
  Update-Current
})
$hist.Add_SelectedIndexChanged({
  if ($script:hist.SelectedIndex -ge 0) {
    # ListBox 与 invList 同步追加/裁剪到 50 → 下标换算：尾部对齐
    $script:viewIdx = $script:invList.Count - $script:hist.Items.Count +
                      $script:hist.SelectedIndex
    if ($script:viewIdx -lt 0) { $script:viewIdx = 0 }
    if ($script:viewIdx -ge $script:invList.Count) { $script:viewIdx = $script:invList.Count - 1 }
    Update-Current
  }
})
# CE 单元格点击 → 展开/收起 CE1/CE2/CE3（2026-11-11 用户定案：默认不展开）。
# 只改该单元格，不整表重建（保持选择与滚动位置）。
$grid.Add_CellClick({
  param($s, $e)
  if ($e.ColumnIndex -eq 2 -and $e.RowIndex -ge 0 -and
      $script:viewIdx -ge 0 -and $script:viewIdx -lt $script:invList.Count) {
    $rows = $script:invList[$script:viewIdx].rows
    if ($e.RowIndex -lt $rows.Count) {
      $r = $rows[$e.RowIndex]
      $r.ceExpanded = -not $r.ceExpanded
      $s.Rows[$e.RowIndex].Cells[2].Value = Get-CeText $r
    }
  }
})

# ── 后台 Runspace + UI Timer ─────────────────────────────────────────────
$script:bg = [System.Management.Automation.PowerShell]::Create()
$script:bg.AddScript($ReaderScript).AddArgument($script:queue).AddArgument($PipeName) | Out-Null
$script:bgHandle = $script:bg.BeginInvoke()

$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 100
$timer.Add_Tick({
  $line = $null
  while ($script:queue.TryDequeue([ref]$line)) { Handle-Line $line }
})
$timer.Start()

$form.Add_FormClosing({
  $timer.Stop()
  try { $script:bg.Stop(); $script:bg.Dispose() } catch {}
})

# ── 高 DPI（抄 install_plugin.ps1 定案模式）：96 DPI 设计值 → 字体×k +
#    Scale(k,k)；RIME_LLM_FAKE_DPI 可本机模拟核对 ─────────────────────────
$script:DpiK = 1.0
try {
  if ($env:RIME_LLM_FAKE_DPI) {
    $script:DpiK = [double]$env:RIME_LLM_FAKE_DPI / 96.0
  } else {
    $g = [System.Drawing.Graphics]::FromHwnd($form.Handle)
    $script:DpiK = [double]$g.DpiX / 96.0
    $g.Dispose()
  }
} catch { $script:DpiK = 1.0 }
if ($script:DpiK -le 0) { $script:DpiK = 1.0 }
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
if ([Math]::Abs($script:DpiK - 1.0) -gt 0.001) {
  $k = [single]$script:DpiK
  $form.Font = [System.Drawing.Font]::new('Segoe UI', [float](9 * $k))
  $lblInfo.Font = [System.Drawing.Font]::new('Segoe UI', [float](9 * $k), [System.Drawing.FontStyle]::Bold)
  $lblFoot.Font = [System.Drawing.Font]::new('Segoe UI', [float](8 * $k))
  $form.Scale([System.Drawing.SizeF]::new($k, $k))
}

[void]$form.ShowDialog()
