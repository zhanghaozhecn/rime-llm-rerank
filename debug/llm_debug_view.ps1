<#
 llm_debug_view.ps1 — LLM 实时调试窗口（插件版）
 数据源：命名管道 \\.\pipe\rime_llm_live（rime_llm.dll 内的 live 管道服务，
 由 lua 在 llm_rerank/debug_fusion: true 时调用 llm.live_write 推送）。
 前置：方案开启 debug_fusion 并重新部署（否则管道不存在，本窗口等待连接）。

 行协议（| 分隔 UTF-8 文本行；自由文本字段已把 | 转全角｜、换行转空格）：
   V|rime-llm-live|1|plugin|<日期>                     连接后服务端立即推
   L|HH:MM:SS|input|cache|src|ctx|tick|ms|ready|n|prep|n_seen|ctx_used
                                                       每次触发评分的调用头
                                                       （ctx=完整去空白上文；src ∈ tsf/com/uia/rime；
                                                        prep=KV 预解命中；n_seen=全词数（协议保留
                                                        不显示）；v4 尾字段 ctx_used=推理用尾部，
                                                        查看器灰显其余前缀——缺字段不灰显）
   C|eng|word|s1|ce|eff|uni|fused|full|cerank|fin|win|ce1|ce2|ce3|fb|u1
                                                       逐候选按最终序（上限 20 行）：
                                                       eng=引擎原序 s1=层1分(=fb+u1)
                                                       ce=加权 CE（空=无分）
                                                       eff=衰减计数 uni=累计次数
                                                       fused=融合分（无 CE 时 = fb+u1）
                                                       full=两码整句满长 cerank=CE 序名次
                                                       fin=最终位置 win=1 层2窗内/0 尾窗透传
                                                       ce1/2/3=各分位原始 CE（未乘权重）
                                                       fb=β·log1p(eff) u1=ln(uni+1)
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
$Y_GRID   = 104; $H_GRID = 314
$X_GRID   = 8;   $W_GRID = 836
$X_HIST   = 852; $W_HIST = 204
$Y_EVT    = 426; $H_EVT = 96
$Y_FOOT   = 528       # 数据源一行灰注（公式行已删——公式体现在分数格内）
$CW = 1068      # ClientSize 宽（= X_HIST + W_HIST + 12）
$CH = 548       # ClientSize 高

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

$lblInfo = New-Lbl 8 $Y_INFO 1048 $H_INFO
$lblInfo.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblInfo.Text = '—'

# 上文行 = RichTextBox（2026-11-12 灰显，协议 v4）：推理用尾部（ctx_used）
# 正常色、未用前缀灰色；ReadOnly 无边框仿 Label，竖滚动条承接长上文
$lblCtx = [System.Windows.Forms.RichTextBox]::new()
$lblCtx.Location = [System.Drawing.Point]::new(8, $Y_CTX)
$lblCtx.Size = [System.Drawing.Size]::new(1048, $H_CTX)
$lblCtx.Font = [System.Drawing.Font]::new('Segoe UI', 9)
$lblCtx.BackColor = [System.Drawing.Color]::White
$lblCtx.BorderStyle = 'None'
$lblCtx.ReadOnly = $true
$lblCtx.ScrollBars = 'Vertical'
$form.Controls.Add($lblCtx)
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
# 等宽字体：分数格内"得分=计算过程"的各成分才能逐位对齐（2026-11-11 用户定案）
$grid.Font = [System.Drawing.Font]::new('Consolas', 9)
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
# 分数部分四列（2026-11-11 用户定案"分数=计算过程"）：CE / 衰减词频分 /
# 累计词频 / 总分，格内 = 得分 + '=' + 具体计算（成分统一 3 位小数，
# 等宽字体逐位对齐），公式不再单独展示；其余列只剩 身份(#/词) 与 状态(满/窗)
# 列宽与源码版 WeaselLLMDebug 同值（GDI 实测取宽 + 对齐补空格的余量）；
# 总分置前 = 纯分值（三项已各自带过程，不重复连加式）
$cols = @(
  @('#', 26), @('词', 64), @('总分', 64), @('CE', 310), @('衰减词频分', 140),
  @('累计词频分', 112), @('匹配词长', 72), @('窗', 30))
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
$evt.Size = [System.Drawing.Size]::new(1048, $H_EVT)
$evt.HorizontalScrollbar = $true
$form.Controls.Add($evt)

# 公式行/列义行已删（2026-11-11 用户定案：计算过程直接写在分数格里，
# 无需再对照底部公式）；只剩数据源一行灰注
$lblFoot = New-Lbl 8 $Y_FOOT 1048 16
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
  $script:lblInfo.Text = ('{0}  输入 {1}   来源 {2}   预解 {3}   {4}ms   tick {5}   n={6}   就绪 {7}' -f
    $inv.t, $inv.input, $inv.src,
    $(if ($inv.prep) { $inv.prep } else { '-' }),
    $inv.ms, $inv.tick,
    $inv.n, $inv.ready)
  # 上文行灰显（协议 v4 ctx_used）：推理用尾部正常色、未用前缀灰色；
  # 缺字段/找不到子串（旧 DLL、空上文）= 全文正常色
  $lblCtx.Clear()
  $lblCtx.SelectionColor = [System.Drawing.Color]::Black
  $lblCtx.AppendText('上文：')
  if (-not $inv.ctx) {
    $lblCtx.AppendText('（空）')
  } else {
    $idx = -1
    if ($inv.ctxused) { $idx = $inv.ctx.LastIndexOf($inv.ctxused) }
    if ($idx -gt 0) {
      $lblCtx.SelectionColor = [System.Drawing.Color]::Gray
      $lblCtx.AppendText($inv.ctx.Substring(0, $idx))
      $lblCtx.SelectionColor = [System.Drawing.Color]::Black
      $lblCtx.AppendText($inv.ctx.Substring($idx))
    } else {
      $lblCtx.AppendText($inv.ctx)
    }
  }
  $script:grid.Rows.Clear()
  # 动态对齐（2026-11-11 用户定案）：本次调用内每个数值组向最宽者看齐、
  # 右对齐（补空格）——等宽字体下小数点逐位对齐，整数部分位数不同不再错位
  $wCeL = 0; $wCeC = 0; $wFbL = 0; $wFbE = 0; $wU1L = 0; $wUni = 0; $wFuL = 0
  foreach ($r in $inv.rows) {
    $v = Get-Num $r.ce;   if ($null -ne $v) { $wCeL = [Math]::Max($wCeL, (Format-F1 $v).Length) }
    foreach ($raw in @($r.ce1, $r.ce2, $r.ce3)) {
      $v = Get-Num $raw;  if ($null -ne $v) { $wCeC = [Math]::Max($wCeC, (Format-F1 $v).Length) }
    }
    $v = Get-Num $r.fb;   if ($null -ne $v) { $wFbL = [Math]::Max($wFbL, (Format-F1 $v).Length) }
    $v = Get-Num $r.eff;  if ($null -ne $v) { $wFbE = [Math]::Max($wFbE, (Format-F1 $v).Length) }
    $v = Get-Num $r.u1;   if ($null -ne $v) { $wU1L = [Math]::Max($wU1L, (Format-F1 $v).Length) }
    $v = Get-Num $r.uni;  if ($null -ne $v) { $wUni = [Math]::Max($wUni, ([string][int]$v).Length) }
    $v = Get-Num $r.fused; if ($null -ne $v) { $wFuL = [Math]::Max($wFuL, (Format-F1 $v).Length) }
  }
  $i = 0
  foreach ($r in $inv.rows) {
    [void]$script:grid.Rows.Add(($i + 1), $r.word, (Get-FusedProc $r $wFuL),
      (Get-CeProc $r $wCeL $wCeC), (Get-FbProc $r $wFbL $wFbE),
      (Get-U1Proc $r $wU1L $wUni), $r.full, $r.win)
    if ($r.win -eq '0') {
      $script:grid.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
    }
    $i++
  }
}

# ── 分数格 = "得分=计算过程"（2026-11-11 用户定案）─────────────────────────
# 数值字段解析：空串/NaN/非数 → $null（生产端 live_num/live_fmt3 对无分发空串）
function Get-Num([string]$s) {
  if (-not $s) { return $null }
  try {
    $d = [double]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture)
  } catch { return $null }
  if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
  return $d
}
function Format-F1([double]$v) { return '{0:F1}' -f $v }
# 左补空格到指定宽（右对齐）：小数位数一致时小数点即逐位对齐
function Pad-L([string]$s, [int]$w) {
  if ($s.Length -ge $w) { return $s }
  return (' ' * ($w - $s.Length)) + $s
}

# CE 格：加权 CE 与其三分量。生产语义 = ce = -(Σ kCeW·分量)（分量是原始
# 交叉熵、正值；分值取负号进融合），故等号右为带负号的括号和。
# ce2/ce3 带权重前缀（1.05/0.45 = 标定常数，原样显示不四舍五入）；ce1 权重
# 恒 1 → 前缀不显示（2026-11-12 用户定案）；数据浮点统一 1 位小数。
# $wL = 分数列内最宽值宽，$wC = 三分量列内最宽值宽
function Get-CeProc($r, $wL, $wC) {
  $ce = Get-Num $r.ce
  if ($null -eq $ce) { return '—' }
  $lead = Pad-L (Format-F1 $ce) $wL
  $t = $lead + '=-('
  $any = $false
  foreach ($pair in @(@($null, $r.ce1), @('1.05', $r.ce2), @('0.45', $r.ce3))) {
    $v = Get-Num $pair[1]
    if ($null -eq $v) { continue }
    if ($any) { $t += '+' }
    if ($pair[0]) { $t += $pair[0] + '·' }
    $t += Pad-L (Format-F1 $v) $wC
    $any = $true
  }
  if (-not $any) { return $lead }
  return $t + ')'
}

# 衰减词频分格：β·ln(1+eff)，β=12 内置常数（log/ln = 自然对数）；
# $wL=分数宽 $wE=eff 宽
function Get-FbProc($r, $wL, $wE) {
  $fb = Get-Num $r.fb
  if ($null -eq $fb) { return '—' }
  $lead = Pad-L (Format-F1 $fb) $wL
  $eff = Get-Num $r.eff
  if ($null -eq $eff) { return $lead }
  return $lead + '=12·ln(1+' + (Pad-L (Format-F1 $eff) $wE) + ')'
}

# 累计词频分格：ln(1+uni)（与衰减词频分格统一 1 在前；2026-11-11 公式
# 简化，分母为窗内常数已去除）；$wL=分数宽 $wU=累计次数（整数）宽
function Get-U1Proc($r, $wL, $wU) {
  $u1 = Get-Num $r.u1
  if ($null -eq $u1) { return '—' }
  $lead = Pad-L (Format-F1 $u1) $wL
  $uni = Get-Num $r.uni
  if ($null -eq $uni) { return $lead }
  return $lead + ('=ln(1+{0})' -f (Pad-L ([string][int]$uni) $wU))
}

# 总分格：融合分值（三项已各自带过程，不重复连加式；$wL=分数宽）
function Get-FusedProc($r, $wL) {
  $fu = Get-Num $r.fused
  if ($null -eq $fu) { return '—' }
  return Pad-L (Format-F1 $fu) $wL
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
                # 协议 L 行第 12 字段 n_seen（全词数）自 2026-11-12 不再显示
                # （公式简化后无消费方）——协议保留，查看器不解析不显示
                ctxused = $(if ($f.Count -gt 12) { $f[12] } else { '' })
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
# CE 子项 2026-11-11 起常驻 CE 格内（计算过程直显），点击展开交互已删

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
  # 显式设过字体的控件要跟着缩（表单字体不覆盖它们）
  $grid.Font = [System.Drawing.Font]::new('Consolas', [float](9 * $k))
  $form.Scale([System.Drawing.SizeF]::new($k, $k))
}

[void]$form.ShowDialog()
