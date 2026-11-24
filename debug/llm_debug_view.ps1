<#
 llm_debug_view.ps1 — LLM 实时调试窗口（插件版）
 数据源：命名管道 \\.\pipe\rime_llm_live（rime_llm.dll 内的 live 管道服务，
 由 lua 在 llm_rerank/debug_fusion: true 时调用 llm.live_write 推送）。
 前置：方案开启 debug_fusion 并重新部署（否则管道不存在，本窗口等待连接）。

 行协议（| 分隔 UTF-8 文本行；自由文本字段已把 | 转全角｜、换行转空格）：
   V|rime-llm-live|1|plugin|<日期>                     连接后服务端立即推
                                                       （协议握手保留；版本/日期徽章
                                                       自 2026-11-16 不再显示）
   L|HH:MM:SS|input|cache|src|ctx|tick|ms|ready|n|prep|ctx_used
                                                       每次触发评分的调用头
                                                       （ctx=完整去空白上文；src ∈ tsf/com/uia/rime；
                                                        prep=KV 预解命中；n=候选数（协议保留不显示）；
                                                        v4 尾字段 ctx_used=推理用尾部，查看器灰显
                                                        其余前缀——缺字段不灰显；n_seen 字段
                                                        2026-11-17 删除，按字段数兼容旧行）
   C|eng|word|s1|ce|eff|uni|fused|full|cerank|fin|win|ce1|ce2|ce3|fb|u1|pf|sdelta|seg
                                                       pf=旧修正分 λ（v5, 0=未命中）
                                                       sdelta=有符号分数（v6, +200/+100/-5/0）
                                                       seg=token 边界段显（v7, "词"列：
                                                       单 token 词原样、多 token 词段间
                                                       '/'；空=旧发送端显示原词）
                                                       逐候选按最终序（上限 20 行）：
                                                       eng=引擎原序 s1=层1分(=fb+u1)
                                                       ce=加权 CE（空=无分）
                                                       eff=衰减计数 uni=累计次数
                                                       fused=融合分（无 CE 时 = fb+u1）
                                                       full=两码整句满长 cerank=CE 序名次
                                                       fin=最终位置 win=1 层2窗内/0 尾窗透传
                                                       ce1/2/3=各分位原始 CE（未乘权重）
                                                       fb=β·log1p(eff) u1=ln(uni+1)
                                                       修正分无专属列（2026-11-21 v7：命中
                                                       时折进 CE 格数值 + 公式尾项）
   S|HH:MM:SS|reason|input|src                        跳过原因：pattern/ctx_empty/
                                                       not_ready/ctx_short/scores_nil/
                                                       score_failed/few_candidates；
                                                       freq_only = 无上文（非跳过）
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
# 合并流（2026-11-17 用户定案：原历史〔推理项列表，可点开详情〕与事件〔纯日志〕
# 两块合一）：@{kind='inv'|'evt'; text=; seq=} 按到达顺序排（旧在头新在尾），
# 推理行 ◆ 黑字可点开、日志行灰字不可点开——行为同前只是合到一起
$script:streamData = [System.Collections.Generic.List[object]]::new()  # 最近 200 行
$script:invSeq = 0            # 推理序号（inv.seq；流行经它关联回 invList）
$script:viewIdx = -1          # 当前展示的调用下标（-1 = 无）
$script:paused  = $false
$script:connected = $false
$script:suppressStreamSel = $false   # 程序化拨高亮时抑制 SelectedIndexChanged

# ── 布局常量（96 DPI 设计值；DpiK≠1 时末尾统一 字体×k + Scale(k,k)）──────
$Y_STATUS = 8;  $H_STATUS = 22
$Y_INFO   = 34; $H_INFO = 20
$Y_CTX    = 58; $H_CTX = 42
$Y_GRID   = 104; $H_GRID = 250
$X_GRID   = 8;   $W_GRID = 1072  # 2026-11-17 合并流后右列腾出 → 网格占满全宽
$Y_STREAM = 360; $H_STREAM = 188 # 合并流：网格下方（原 事件区 96 + 历史列并入）
$Y_TYPE   = 554; $H_TYPE = 64   # 打字测试框（2026-11-16：在此输入即走本机 IME，免切窗口测试）
$Y_FOOT   = 644       # 数据源一行灰注（公式行已删——公式体现在分数格内）
$CW = 1088      # ClientSize 宽
$CH = 664       # ClientSize 高（2026-11-17 流列表换得的高度：原 640 + 24）

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

$lblInfo = New-Lbl 8 $Y_INFO 1072 $H_INFO
$lblInfo.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblInfo.Text = '—'

# 上文行 = RichTextBox（2026-11-12 灰显，协议 v4）：推理用尾部（ctx_used）
# 正常色、未用前缀灰色；ReadOnly 无边框仿 Label，竖滚动条承接长上文
$lblCtx = [System.Windows.Forms.RichTextBox]::new()
$lblCtx.Location = [System.Drawing.Point]::new(8, $Y_CTX)
$lblCtx.Size = [System.Drawing.Size]::new(1072, $H_CTX)
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
# 累计词频 / 总分，格内 = 得分 + '=' + 具体计算（成分统一 1 位小数，
# 等宽字体逐位对齐），公式不再单独展示；身份列只剩 #/词
# 「窗」「匹配词长」列均已删（2026-11-16 用户定案：窗内/尾窗灰字区分、
# 满长准入优先下"有无 CE 分"即满长标志——列冗余）；
# 「修正分」列已删（2026-11-21 用户定案 v7：命中修正折进 CE 格数值 +
# 公式尾项，见 Get-CeProc——0 不显示，恒 0 的专属列无观察价值）
# 列宽与源码版 WeaselLLMDebug 同值（GDI 实测取宽 + 对齐补空格的余量；
# 词 100 = 字符段显带 '/'（4 字词 ≈77px，容 5 字词）；2026-11-21 公式空格
# （'='、'+' 两边各一空格）列宽重分配（合计 878 < 888 Studio 右列网格宽）：
# CE 380 = 352 + 空格余量 − 挪给分式列的 12；衰减词频分 168 = 140 + 空格
# 2 字符（真机实测 "=14·log1p(…)" 被截成 …）；累计词频分 140 = 112 + 容
# 5 位数累计次数）
$cols = @(
  @('#', 26), @('词', 100), @('总分', 64), @('CE', 380), @('衰减词频分', 168),
  @('累计词频分', 140))
foreach ($c in $cols) {
  $i = $grid.Columns.Add($c[0], $c[0])
  $grid.Columns[$i].Width = $c[1]
}
$form.Controls.Add($grid)

# 合并流（2026-11-17 用户定案）：原历史（推理项列表，可点开详情）与事件
# （纯日志）两块合一。owner-draw 只为分色：推理行 ◆ 黑字、日志行灰字
# （同尾窗灰约定）；选中高亮 = 详情区所示那条推理。
$stream = [System.Windows.Forms.ListBox]::new()
$stream.Location = [System.Drawing.Point]::new(8, $Y_STREAM)
$stream.Size = [System.Drawing.Size]::new(1072, $H_STREAM)
$stream.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
$stream.ItemHeight = 18
$stream.HorizontalScrollbar = $true
$form.Controls.Add($stream)
$stream.Add_DrawItem({
  param($s, $e)
  $sel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
  $text = ''
  $isInv = $false
  if ($e.Index -ge 0 -and $e.Index -lt $script:streamData.Count) {
    $text = $script:streamData[$e.Index].text
    $isInv = ($script:streamData[$e.Index].kind -eq 'inv')
  }
  $bg = [System.Drawing.Color]::White
  $fg = [System.Drawing.Color]::Gray
  # 选中高亮取 SystemColors（2026-11-21：pwsh 7.7 的 System.Drawing.Color
  # 来自精简版 System.Drawing.Primitives v11——KnownColor 系静态色
  # Highlight/HighlightText/Control 等不存在（静默返回 null，SolidBrush
  # 收到 null 即弹 .ctor 异常框）；基础色 White/Gray/Black/Green/DimGray
  # 仍在。WinForms 下 SystemColors.Highlight 同源可用）
  if ($sel) { $bg = [System.Drawing.SystemColors]::Highlight; $fg = [System.Drawing.Color]::White }
  elseif ($isInv) { $fg = [System.Drawing.Color]::Black }
  $b = [System.Drawing.SolidBrush]::new($bg)
  $e.Graphics.FillRectangle($b, $e.Bounds)
  $b.Dispose()
  $fb = [System.Drawing.SolidBrush]::new($fg)
  $e.Graphics.DrawString($text, $e.Font, $fb,
    (New-Object System.Drawing.PointF(($e.Bounds.X + 2), ($e.Bounds.Y + 1))))
  $fb.Dispose()
  $e.DrawFocusRectangle()
})

# 打字测试框（2026-11-16 用户定案）：在此输入即走本机 IME——组词/候选/
# 上屏全程在本窗口内完成，逐候选数据实时刷新，免切窗口测试。
# 标准多行 TextBox，TSF/IME 对其自动生效；事件栏下移腾位。
$lblType = New-Lbl 8 ($Y_TYPE - 2) 460 16
$lblType.ForeColor = [System.Drawing.Color]::Gray
$lblType.Font = [System.Drawing.Font]::new('Segoe UI', 8)
$lblType.Text = '打字测试（在此输入即走本机 IME，逐候选数据实时刷新）'
$form.Controls.Add($lblType)
$tbType = [System.Windows.Forms.TextBox]::new()
$tbType.Location = [System.Drawing.Point]::new(8, $Y_TYPE + 18)
$tbType.Size = [System.Drawing.Size]::new(1072, $H_TYPE)
$tbType.Multiline = $true
$tbType.ScrollBars = 'Vertical'
$form.Controls.Add($tbType)

# 公式行/列义行已删（2026-11-11 用户定案：计算过程直接写在分数格里，
# 无需再对照底部公式）；只剩数据源一行灰注
$lblFoot = New-Lbl 8 $Y_FOOT 1072 16
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
  $script:lblInfo.Text = ('{0}  输入 {1}   来源 {2}   预解 {3}   {4}ms   tick {5}   就绪 {6}' -f
    $inv.t, $inv.input, $inv.src,
    $(if ($inv.prep) { $inv.prep } else { '-' }),
    $inv.ms, $inv.tick,
    $inv.ready)
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
    # 词码对修正折叠（2026-11-21 v7）：CE 分数列量的是折叠后的值
    $sdV = Get-Corr $r
    $v = Get-Num $r.ce;   if ($null -ne $v) { $wCeL = [Math]::Max($wCeL, (Format-F1 ($v + $sdV)).Length) }
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
    [void]$script:grid.Rows.Add(($i + 1), (Get-WordText $r), (Get-FusedProc $r $wFuL),
      (Get-CeProc $r $wCeL $wCeC), (Get-FbProc $r $wFbL $wFbE),
      (Get-U1Proc $r $wU1L $wUni))
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

# 词列文本：token 边界段显（v7 seg，如 cm/ak；单 token 词服务端原样发）
# 优先，空（旧发送端/尾窗）回退原词。参数 = 行哈希表
function Get-WordText($r) {
  if ($r.seg) { return $r.seg }
  return $r.word
}

# 词码对修正值（显示端折叠用，2026-11-21）：sdelta 为准，旧发送端无
# 该字段时回退 v5 的 pf（-λ）。代码里 CE 与修正仍分离（发送端照发），仅
# 显示端折叠。返回标量（无修正 = 0.0）
function Get-Corr($r) {
  $sd = Get-Num $r.sdelta
  if ($null -ne $sd) { return $sd }
  $pf = Get-Num $r.pf
  if ($null -ne $pf -and $pf -gt 0) { return -$pf }
  return 0.0
}
# 修正项后缀（公式右侧）：负 -5.0 / 正 +5.0；0 = 不显示
function Get-CorrSuffix([double]$sd) {
  if ($sd -eq 0) { return '' }
  return ($(if ($sd -gt 0) { '+' } else { '-' })) + (Format-F1 ([Math]::Abs($sd)))
}

# CE 格：加权 CE 与其三分量 + 词码对修正折叠（2026-11-21 用户定案 v7：
# 修正分专属列删除——对几乎所有候选恒为 0 的独立列无观察价值；命中时
# 把修正值折进 CE 数值本身并在公式右侧追修正项，如
#   -34.7 = -(14.0 + 1.1·10.1 + 0.6·7.6) - 5.0
# 修正为 0 不追加任何显示。无 CE 分（尾窗/无法表示）→ 格保持 '—'
# （修正项只随融合分隐含）。公式排版（2026-11-21 用户定案）：'=' 与 '+'
# 两边各留一个空格。生产语义 = ce = -(Σ kCeW·分量)（分量是原始
# 交叉熵、正值；分值取负号进融合），故等号右为带负号的括号和。
# ce2/ce3 带权重前缀（系数 = 标定内置常数 1.10/0.60，显示 1.1/0.6——
# 第二位小数不显示，与数据 1 位小数一致；2026-11-14 随默认模型 0.5B
# 重标定，旧 1.05/0.45 为 0.8B v3 值）；ce1 权重
# 恒 1 → 前缀不显示（2026-11-12 用户定案）；数据浮点统一 1 位小数。
# $wL = 分数列内最宽值宽，$wC = 三分量列内最宽值宽
function Get-CeProc($r, $wL, $wC) {
  $sd = Get-Corr $r
  $ce = Get-Num $r.ce
  if ($null -eq $ce) { return '—' }
  if ($sd -ne 0) { $ce += $sd }
  $tail = Get-CorrSuffix $sd
  if ($tail) { $tail = ' ' + $tail }  # 修正项前空一格
  $lead = Pad-L (Format-F1 $ce) $wL
  $t = $lead + ' = -('
  $any = $false
  foreach ($pair in @(@($null, $r.ce1), @('1.1', $r.ce2), @('0.6', $r.ce3))) {
    $v = Get-Num $pair[1]
    if ($null -eq $v) { continue }
    if ($any) { $t += ' + ' }
    if ($pair[0]) { $t += $pair[0] + '·' }
    $t += Pad-L (Format-F1 $v) $wC
    $any = $true
  }
  if (-not $any) { return $lead + $tail }
  return $t + ')' + $tail
}

# 衰减词频分格：β·log1p(eff)，β=14 内置常数（2026-11-14
# 随默认模型 0.5B 重标定，旧 β=12 为 0.8B v3 值）；
# $wL=分数宽 $wE=eff 宽
function Get-FbProc($r, $wL, $wE) {
  $fb = Get-Num $r.fb
  if ($null -eq $fb) { return '—' }
  $lead = Pad-L (Format-F1 $fb) $wL
  $eff = Get-Num $r.eff
  if ($null -eq $eff) { return $lead }
  return $lead + ' = 14·log1p(' + (Pad-L (Format-F1 $eff) $wE) + ')'
}

# 累计词频分格：log1p(uni)（2026-11-11 公式简化，分母为窗内常数已去除；
# 2026-11-18 显示统一 log1p(n)）；$wL=分数宽 $wU=累计次数（整数）宽
function Get-U1Proc($r, $wL, $wU) {
  $u1 = Get-Num $r.u1
  if ($null -eq $u1) { return '—' }
  $lead = Pad-L (Format-F1 $u1) $wL
  $uni = Get-Num $r.uni
  if ($null -eq $uni) { return $lead }
  return $lead + (' = log1p({0})' -f (Pad-L ([string][int]$uni) $wU))
}

# 总分格：融合分纯分值（三项过程各在自带格内，词码对修正折进 CE 格见
# Get-CeProc；$wL=分数宽）
function Get-FusedProc($r, $wL) {
  $fu = Get-Num $r.fused
  if ($null -eq $fu) { return '—' }
  return Pad-L (Format-F1 $fu) $wL
}

# ── 合并流（2026-11-17：历史+事件两块合一）─────────────────────────────────
function Get-InvRowText($inv) {
  # 推理行：◆ 时间 输入 词1,词2,词3（前 3 词；C 行到达时补齐；有 token
  # 段显（v7 seg）用段显——与"词"列同口径）
  $words = ($inv.rows | Select-Object -First 3 |
    ForEach-Object { Get-WordText $_ }) -join ','
  if ($words) { return ('◆ {0} {1} {2}' -f $inv.t, $inv.input, $words) }
  return ('◆ {0} {1}' -f $inv.t, $inv.input)
}

function Add-Stream {
  # 追加一行到合并流（数据列表是唯一事实源；未暂停时同步 ListBox）。
  # kind='inv' 带 seq（关联回 invList，可点开详情）；'evt' seq=0 不可点开。
  param($kind, $text, $seq)
  $script:streamData.Add(@{ kind = $kind; text = $text; seq = $seq })
  while ($script:streamData.Count -gt 200) { $script:streamData.RemoveAt(0) }
  if ($script:paused) { return }
  [void]$script:stream.Items.Add($text)
  while ($script:stream.Items.Count -gt 200) { $script:stream.Items.RemoveAt(0) }
  if ($script:stream.Items.Count -gt 0) {
    $script:stream.TopIndex = $script:stream.Items.Count - 1   # 跟随最新
  }
}

function Select-Current-In-Stream {
  # 把高亮拨回详情区正在展示的那条推理（程序化拨选不触发递归：抑制标志）
  if ($script:viewIdx -lt 0 -or $script:viewIdx -ge $script:invList.Count) { return }
  $seq = $script:invList[$script:viewIdx].seq
  for ($i = $script:streamData.Count - 1; $i -ge 0; $i--) {
    if ($script:streamData[$i].kind -eq 'inv' -and $script:streamData[$i].seq -eq $seq) {
      $script:suppressStreamSel = $true
      try { $script:stream.SelectedIndex = $i } finally { $script:suppressStreamSel = $false }
      return
    }
  }
}

function Rebuild-All {
  # 合并流整列重建：streamData 是唯一事实源（暂停期间照常入队）
  $script:stream.Items.Clear()
  foreach ($e in $script:streamData) { [void]$script:stream.Items.Add($e.text) }
  if ($script:stream.Items.Count -gt 0) {
    $script:stream.TopIndex = $script:stream.Items.Count - 1
  }
  Select-Current-In-Stream
  Update-Current
}

# ── 协议行处理 ───────────────────────────────────────────────────────────
function Handle-Line {
  param($line)
  if ($line -eq '::CONNECTED') {
    $script:connected = $true
    if (-not $script:paused) {
      # 协议版本/日期徽章自 2026-11-16 不再显示（两版查看器同口径）
      $script:lblStatus.Text = '已连接'
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
      # 协议握手行仅作识别；版本/日期徽章自 2026-11-16 不再显示，
      # 行本身保留供协议升级判别
    }
    'L' {
      if ($f.Count -lt 10) { return }
      $script:invSeq++
      $inv = @{ t = $f[1]; input = $f[2]; cache = $f[3]; src = $f[4]
                ctx = $f[5]; tick = $f[6]; ms = $f[7]; ready = $f[8]
                prep = $(if ($f.Count -gt 10) { $f[10] } else { '' })
                # 协议 L 行第 10 字段 n（候选数，信息行 2026-11-16 起不再显示）
                # 协议保留、查看器不解析。n_seen 字段 2026-11-17 服务端删除：
                # 旧行 13 字段取第 13 字段，新行 12 字段取第 12 字段（ctx_used）。
                ctxused = $(if ($f.Count -gt 12) { $f[12] }
                            elseif ($f.Count -gt 11) { $f[11] } else { '' })
                seq = $script:invSeq
                rows = [System.Collections.Generic.List[object]]::new() }
      $script:invList.Add($inv)
      while ($script:invList.Count -gt 50) { $script:invList.RemoveAt(0) }
      $script:viewIdx = $script:invList.Count - 1
      if (-not $script:paused) {
        Add-Stream 'inv' (Get-InvRowText $inv) $inv.seq
        Select-Current-In-Stream   # 高亮跟随最新（网格同步切到最新）
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
                       u1 = $(if ($f.Count -gt 16) { $f[16] } else { '' })
                       # v5: 旧修正分 pf（负分幅度, 0=未命中）
                       pf = $(if ($f.Count -gt 17) { $f[17] } else { '' })
                       # v6: 有符号词码对分数（+200/+100/-5/0）
                       sdelta = $(if ($f.Count -gt 18) { $f[18] } else { '' })
                       # v7: token 边界段显（"词"列 cm/ak；空=显示原词）
                       seg = $(if ($f.Count -gt 19) { $f[19] } else { '' }) })
      if (-not $script:paused -and $script:viewIdx -eq ($script:invList.Count - 1)) {
        Update-Current
      }
      # 合并流最新推理行补前 3 个词（前几条 C 行到达时）
      if (-not $script:paused -and $inv.rows.Count -le 3) {
        for ($i = $script:streamData.Count - 1; $i -ge 0; $i--) {
          if ($script:streamData[$i].kind -eq 'inv' -and $script:streamData[$i].seq -eq $inv.seq) {
            $txt = Get-InvRowText $inv
            $script:streamData[$i].text = $txt
            $script:stream.Items[$i] = $txt
            break
          }
        }
      }
    }
    'S' {
      if ($f.Count -lt 3) { return }
      # 无上文（2026-11-24）：freq_only 不是"跳过"——本窗照常融合/前缀确认，
      # 只是不含 CE。用中性措辞，避免被读成"没触发重排"。
      if ($f[2] -eq 'freq_only') {
        Add-Stream 'evt' ('{0} 无上文：按词频融合（无 CE）（输入 {1} 来源 {2}）' -f
          $f[1], $(if ($f.Count -gt 3) { $f[3] } else { '' }),
          $(if ($f.Count -gt 4) { $f[4] } else { '-' })) 0
      } else {
        Add-Stream 'evt' ('{0} 跳过 {1}（输入 {2} 来源 {3}）' -f $f[1], $f[2],
          $(if ($f.Count -gt 3) { $f[3] } else { '' }),
          $(if ($f.Count -gt 4) { $f[4] } else { '-' })) 0
      }
    }
    'E' {
      if ($f.Count -lt 7) { return }
      Add-Stream 'evt' ('{0} 上屏 {1}  eff {2}→{3}  tick {4}→{5}' -f
        $f[1], $f[2], $f[3], $f[4], $f[5], $f[6]) 0
    }
    'R' {
      if ($f.Count -lt 3) { return }
      Add-Stream 'evt' ('{0} 重置 {1}' -f $f[1], $f[2]) 0
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
  $script:invList.Clear(); $script:streamData.Clear()
  $script:stream.Items.Clear()
  $script:viewIdx = -1
  Update-Current
})
$stream.Add_SelectedIndexChanged({
  if ($script:suppressStreamSel) { return }
  $i = $script:stream.SelectedIndex
  if ($i -lt 0 -or $i -ge $script:streamData.Count) { return }
  # 推理行（seq>0）→ 详情切到该条；纯日志行不可点开——高亮弹回当前推理
  #（行为同 2026-11-17 前的历史列表，只是行混进了日志行）
  $ent = $script:streamData[$i]
  if ($ent.kind -ne 'inv') { Select-Current-In-Stream; return }
  for ($j = $script:invList.Count - 1; $j -ge 0; $j--) {
    if ($script:invList[$j].seq -eq $ent.seq) {
      $script:viewIdx = $j
      Update-Current
      return
    }
  }
  Select-Current-In-Stream   # 推理行已滚出 50 条窗口 → 保持当前视图
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
  # 合并流 owner-draw 的行高 Scale 不会动，手动跟 k
  $stream.ItemHeight = [int][Math]::Ceiling(18 * $script:DpiK)
  $form.Scale([System.Drawing.SizeF]::new($k, $k))
}

[void]$form.ShowDialog()
