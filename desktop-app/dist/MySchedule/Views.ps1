# =============================================================================
#  My Schedule - 三视图渲染（月 / 周 / 列表）
#  本文件由 ScheduleWidget.ps1 dot-source，不要单独运行
# =============================================================================

# ---------------------------------------------------------------------------
#  通用控件工厂
# ---------------------------------------------------------------------------
function New-Bd { param([string]$Bg, [string]$Border, [int]$Radius = 7, [double]$Bw = 1.5)
    $b = New-Object System.Windows.Controls.Border
    if ($Bg)     { $b.Background = Brush $Bg }
    if ($Border) { $b.BorderBrush = Brush $Border; $b.BorderThickness = [System.Windows.Thickness]::new($Bw) }
    $b.CornerRadius = [System.Windows.CornerRadius]::new($Radius)
    return $b
}
function New-Txt {
    # 字号走全局倍率（第四轮）：调用方一律传"设计字号"，实际值由 Scale-Ui 换算。
    # 这是全项目字号的唯一收口点 —— 在别处手写 FontSize = N 就会漏掉倍率，
    # SyntaxCheck 里有一条静态规则专门拦这个（见 verification\SyntaxCheck.ps1）。
    param([string]$Text, [double]$Size = 12, [string]$Color = '', [string]$Weight = 'Normal')
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = (Scale-Ui $Size)
    if ($Color) { $t.Foreground = Brush $Color }
    switch ($Weight) {
        'Bold'   { $t.FontWeight = [System.Windows.FontWeights]::Bold }
        'Semi'   { $t.FontWeight = [System.Windows.FontWeights]::SemiBold }
        'Normal' { $t.FontWeight = [System.Windows.FontWeights]::Normal }
    }
    $t.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    return $t
}

# 带硬阴影的按钮（像素风）
function New-PixBtn {
    # W / H / FontSize 三个尺寸参数都走全局倍率：按钮的宽高必须跟文字一起长，
    # 否则放大字号后文字会溢出按钮（或者按钮大而字小，看着像没生效）。
    param([string]$Text, [string]$Bg, [string]$Fg, [double]$W = 0, [double]$H = 30,
          [double]$FontSize = 12, [int]$Radius = 7, [string]$Tag = '',
          [string]$BorderCol = '')
    if (-not $BorderCol) { $BorderCol = Get-Pal 'Border' }
    $btn = New-Object System.Windows.Controls.Button
    $btn.Tag = $Tag
    $btn.Height = (Scale-Ui $H)
    if ($W -gt 0) { $btn.Width = (Scale-Ui $W) }
    Set-PixBtnLook -Btn $btn -Bg $Bg -Fg $Fg -FontSize $FontSize -Radius $Radius -BorderCol $BorderCol
    $btn.Content = (New-Txt -Text $Text -Size $FontSize -Color $Fg -Weight 'Semi')
    return $btn
}

function Set-PixBtnLook {
    # 像素风按钮的模板工厂：把"一个 PixBtn 长什么样"这件事收在一处。
    #   目前只有 New-PixBtn 调用它（造新按钮）。
    #
    # ⚠ 为什么运行期换配色**不走这个函数**（曾经的写法，本轮已废弃）：
    #   New-PixBtn 把底色**烘进 ControlTemplate**（模板字符串里写死 Background="$Bg"），
    #   模板里的值优先于控件自身的 Background 属性 —— 所以想高亮一个已存在的按钮，
    #   重新生成整份模板是"大炮打蚊子"，还会顺手重置 IsMouseOver/IsPressed 等瞬时状态。
    #   更干净的做法是：ApplyTemplate 之后用 Template.FindName('bd', $btn) 取回
    #   模板里那个真正在画底色的 Border，改它自己的 Background。
    #   （见 Views2.ps1 的 SetTabsShow / Update-TagChipSelection，两处同一套做法。）
    param([System.Windows.Controls.Button]$Btn, [string]$Bg, [string]$Fg,
          [double]$FontSize = 11, [int]$Radius = 7, [string]$BorderCol = '')
    if ($null -eq $Btn) { return }
    if (-not $BorderCol) { $BorderCol = Get-Pal 'Border' }
    # 圆角跟着一起缩放：字号涨了、按钮大了，圆角还停在 7px 会显得"方"，
    # 失去像素风的圆润感。至少 4px，免得小倍率下退化成尖角。
    $rad = [int][math]::Round([double]$Radius * [double]$script:UiScale)
    if ($rad -lt 4) { $rad = 4 }
    $tpl = @"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                 TargetType="Button">
  <Grid>
    <Border x:Name="sh" Background="$(Get-Pal 'Shadow')" CornerRadius="$rad" Margin="1,1,0,0"/>
    <Border x:Name="bd" Background="$Bg" BorderBrush="$BorderCol" BorderThickness="2"
            CornerRadius="$rad">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="9,0"/>
    </Border>
  </Grid>
  <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True">
      <Setter TargetName="bd" Property="Opacity" Value="0.85"/>
    </Trigger>
    <Trigger Property="IsPressed" Value="True">
      <Setter TargetName="bd" Property="Margin" Value="1,1,0,0"/>
      <Setter TargetName="sh" Property="Opacity" Value="0"/>
    </Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
"@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$tpl)
    $Btn.Template = [System.Windows.Markup.XamlReader]::Load($reader)
    # 这里**不碰 $Btn.Content**：文字由 New-PixBtn 自己写（它才知道字体大小该用哪个值）。
    #   第六轮曾经在这里"回读文字再重建"，结果 New-PixBtn 造按钮时内容还是 $null，
    #   被填成一个空 TextBlock —— 全项目 PixBtn 文字集体消失。教训：内容归调用方管。
}

# ---------------------------------------------------------------------------
#  月视图
# ---------------------------------------------------------------------------
function Render-Month {
    $grid6 = New-Object System.Windows.Controls.Grid
    $shell = New-Bd -Bg (Get-Pal 'Card') -Border (Get-Pal 'Border') -Radius 8
    # 先算"这一页要几行"，因为行数不再是常数 6：
    #   1 号落在周几（$offset，周一=0）+ 本月天数 -> 需要几整周。
    #   2 月的某些年份只要 4 行，就把多出来的整行省掉（以前永远 6 行，末尾空一整行）。
    $first = [datetime]::new($script:Anchor.Year, $script:Anchor.Month, 1)
    $daysInMonth = [datetime]::DaysInMonth($first.Year, $first.Month)
    $offset = ([int]$first.DayOfWeek + 6) % 7
    $usedRows = [int][math]::Ceiling(($offset + $daysInMonth) / 7.0)
    if ($usedRows -lt 4) { $usedRows = 4 }
    for ($i = 0; $i -le $usedRows; $i++) {     # 第 0 行是星期表头
        $rd = New-Object System.Windows.Controls.RowDefinition
        if ($i -eq 0) { $rd.Height = [System.Windows.GridLength]::new(36, 'Pixel') }
        else { $rd.Height = [System.Windows.GridLength]::new(1, 'Star') }
        $grid6.RowDefinitions.Add($rd)
    }
    for ($i = 0; $i -lt 7; $i++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = [System.Windows.GridLength]::new(1, 'Star')
        $grid6.ColumnDefinitions.Add($cd)
    }

    # --- 星期表头 ---
    for ($c = 0; $c -lt 7; $c++) {
        $headCol = if ($c -ge 5) { Get-Pal 'Holiday' } else { Get-Pal 'InkSoft' }
        $hb = New-Object System.Windows.Controls.Border
        $hb.Background = Brush (Get-Pal 'CardAlt')
        $hb.BorderBrush = Brush (Get-Pal 'BorderSoft')
        $hb.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 2)
        $tb = New-Txt -Text $script:DowShort[$c] -Size 13 -Color $headCol -Weight 'Semi'
        $tb.HorizontalAlignment = 'Center'
        $tb.VerticalAlignment = 'Center'
        $hb.Child = $tb
        [System.Windows.Controls.Grid]::SetRow($hb, 0)
        [System.Windows.Controls.Grid]::SetColumn($hb, $c)
        [void]$grid6.Children.Add($hb)
    }

    # --- 日期格 ---
    # 每页只画本月：从 1 号开始、到当月最后一天结束。
    #   以前固定铺满 42 格，月初 / 月末会借用上月的尾巴和下月的开头（灰字 + 别人的日程
    #   混在本月里，一眼看不出哪些属于当月）。现在本月的格子照旧，非本月的位置改成
    #   "补位格"＝浅色日号（见 New-MonthPadCell）：网格不再缺块，但补位格不画任何日程，
    #   所以"本月内容"这条边界依然干净。
    $today = [datetime]::Today
    $month = $script:Anchor.Month
    $shown = New-Object System.Collections.ArrayList   # 审计用：按格子顺序记下"日"，空位记 0
    $pads = New-Object System.Collections.ArrayList    # 审计用：补位格的日期（'yyyy-MM-dd'）
    for ($r = 1; $r -le $usedRows; $r++) {
        for ($c = 0; $c -lt 7; $c++) {
            $dayNum = (($r - 1) * 7 + $c) - $offset + 1
            if ($dayNum -lt 1 -or $dayNum -gt $daysInMonth) {
                # 用 AddDays 而不是自己算月份边界：跨年（12 月 -> 次年 1 月）自动正确。
                $padDate = $first.AddDays($dayNum - 1)
                $cell = New-MonthPadCell -Date $padDate -Col $c
                [void]$shown.Add(0)
                [void]$pads.Add((Fmt-Date $padDate))
            } else {
                $cell = New-MonthCell -Date ([datetime]::new($first.Year, $first.Month, $dayNum)) `
                    -InMonth $true -Col $c
                [void]$shown.Add($dayNum)
            }
            [System.Windows.Controls.Grid]::SetRow($cell, $r)
            [System.Windows.Controls.Grid]::SetColumn($cell, $c)
            [void]$grid6.Children.Add($cell)
        }
    }
    # 审计锚点：既要能按格子顺序核对 1..月底，也要能扫"页面里有没有别月的日程"。
    # MonthDaysShown 保持原语义（本月的日号，补位格记 0）——上一轮的断言因此不用改；
    # 补位格的正确性单独用 MonthPadDates / MonthPadInfo 断言。
    $script:MonthGridRoot = $grid6
    $script:MonthDaysShown = @($shown.ToArray())
    $script:MonthPadDates = @($pads.ToArray())
    $script:MonthPageInfo = @{ Rows = $usedRows; Offset = $offset; Days = $daysInMonth; Pads = $pads.Count }

    # 底部状态条（与网页版原型一致）
    $foot = New-Object System.Windows.Controls.Border
    $foot.Background = Brush (Get-Pal 'CardAlt')
    $foot.BorderBrush = Brush (Get-Pal 'BorderSoft')
    $foot.BorderThickness = [System.Windows.Thickness]::new(0, 2, 0, 0)
    $foot.Height = 30
    $ft = New-Txt -Text ('{0} events · {1} tasks' -f @($script:Events).Count, @($script:Tasks).Count) `
        -Size 11 -Color (Get-Pal 'InkSoft')
    $ft.HorizontalAlignment = 'Center'
    $ft.VerticalAlignment = 'Center'
    $foot.Child = $ft

    # 停靠式布局：先加被停靠的，后加的吃掉剩余高度
    $dp = New-Object System.Windows.Controls.DockPanel
    [System.Windows.Controls.DockPanel]::SetDock($foot, 'Bottom')
    [void]$dp.Children.Add($foot)
    [void]$dp.Children.Add($grid6)
    $shell.Child = $dp
    return $shell
}

function New-MonthCell {
    param([datetime]$Date, [bool]$InMonth, [int]$Col)
    $today = [datetime]::Today
    $holi = Get-Holiday $Date
    $isToday = Same-Day $Date $today
    $isSel = Same-Day $Date $script:Selected
    $wknd = Is-Weekend $Date

    $bg = Get-Pal 'Card'
    if ($wknd)  { $bg = Get-Pal 'Weekend' }
    if ($holi)  { $bg = Get-Pal 'HolidayRib' }
    if ($isToday) { $bg = Get-Pal 'AccentFocus' }

    $outer = New-Object System.Windows.Controls.Grid
    # 硬阴影层（仅当月且非今天时给阴影，避免过密）
    if ($InMonth) {
        $sh = New-Bd -Bg (Get-Pal 'Shadow') -Radius 6
        $sh.Margin = [System.Windows.Thickness]::new(2, 2, 0, 0)
        $sh.Opacity = 0.30
        [void]$outer.Children.Add($sh)
    }

    $box = New-Object System.Windows.Controls.StackPanel
    $box.Margin = [System.Windows.Thickness]::new(7, 6, 5, 4)

    $numCol = Get-Pal 'Ink'
    if ($isToday) { $numCol = Get-Pal 'TodayInk' }
    elseif (-not $InMonth) { $numCol = Get-Pal 'InkFaint' }
    $evts = @(Events-On $Date)
    $numRow = New-Object System.Windows.Controls.Grid
    $num = New-Txt -Text ([string]$Date.Day) -Size 13 -Color $numCol -Weight 'Bold'
    [void]$numRow.Children.Add($num)
    if ($evts.Count -gt 0) {
        $cnt = New-Txt -Text ([string]$evts.Count) -Size 10 -Color (Get-Pal 'InkFaint') -Weight 'Semi'
        $cnt.HorizontalAlignment = 'Right'
        $cnt.VerticalAlignment = 'Top'
        [void]$numRow.Children.Add($cnt)
    }
    [void]$box.Children.Add($numRow)

    # 日程摘要
    $shown = 0
    foreach ($e in $evts) {
        if ($shown -ge 3) { break }
        $shown++
        if ($e.done) {
            $t = New-Txt -Text ([string]$e.title) -Size 10 -Color (Get-Pal 'Ink') -Weight 'Semi'
            $t.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
            $t.Opacity = 0.65
            [void]$box.Children.Add($t)
        } elseif ([string]$e.tag -eq 'focus' -or [string]$e.tag -eq 'life') {
            $bar = New-Bd -Bg (Get-Pal 'AccentFocus') -Radius 2
            $bar.Height = 8
            $bar.Width = 42
            $bar.HorizontalAlignment = 'Left'
            $bar.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
            [void]$box.Children.Add($bar)
        } else {
            $t = New-Txt -Text ([string]$e.title) -Size 10 -Color (Get-Pal 'Ink') -Weight 'Semi'
            [void]$box.Children.Add($t)
        }
    }
    if ($evts.Count -gt 3) {
        $more = New-Object System.Windows.Controls.Border
        $more.Background = Brush (Get-Pal 'CardAlt')
        $more.BorderBrush = Brush (Get-Pal 'BorderSoft')
        $more.BorderThickness = [System.Windows.Thickness]::new(1)
        $more.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $more.Padding = [System.Windows.Thickness]::new(5, 1, 5, 1)
        $more.HorizontalAlignment = 'Left'
        $more.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
        $more.Tag = @{ kind = 'day-more'; date = $Date }
        $more.Cursor = [System.Windows.Input.Cursors]::Hand
        $more.Child = (New-Txt -Text ("+" + ($evts.Count - 3) + " more") -Size 10 -Color (Get-Pal 'InkSoft'))
        [void]$box.Children.Add($more)
    }

    $bd = New-Bd -Bg $bg -Border (Get-Pal 'Border') -Radius 6 -Bw 1
    $bd.Child = $box
    if ($isSel) { $bd.BorderThickness = [System.Windows.Thickness]::new(2) }
    [void]$outer.Children.Add($bd)

    if ($isToday -or $isSel) {
        $mark = New-Object System.Windows.Controls.Border
        $mark.Height = 3
        $mark.CornerRadius = [System.Windows.CornerRadius]::new(2)
        $mark.Background = Brush $(if ($isSel) { Get-Pal 'AccentEvent' } else { Get-Pal 'AccentFocus' })
        $mark.VerticalAlignment = 'Top'
        $mark.Margin = [System.Windows.Thickness]::new(6, 1, 6, 0)
        $mark.IsHitTestVisible = $false
        [void]$outer.Children.Add($mark)
    }

    # 节假日角标
    if ($holi) {
        $rib = New-Bd -Bg (Get-Pal 'Holiday') -Radius 3
        $rib.Width = 14; $rib.Height = 14
        $rib.HorizontalAlignment = 'Right'
        $rib.VerticalAlignment = 'Top'
        $rib.Margin = [System.Windows.Thickness]::new(0, 4, 4, 0)
        $rib.ToolTip = $holi
        [void]$outer.Children.Add($rib)
    }

    $outer.Tag = @{ kind = 'day'; date = $Date }
    $outer.Cursor = [System.Windows.Input.Cursors]::Hand
    # 月视图密度（第六轮）：给日期格一个**最小高度**。
    #   行本身仍是 1*（按剩余空间均分），所以"窗口拉高时格子跟着高"这条不变；
    #   密度只在窗口矮、格子会被压扁时兜底 —— 否则事件条会被压成一条线看不清。
    #   为什么不做成"固定行高"：那会让窗口变大时下方留一片空白，
    #   与"月视图要铺满"的观感相冲突。下限 + 均分是两边都照顾到的唯一做法。
    $monthMin = [double]$script:Settings['MonthDensity'] * [double]$script:UiScale
    if ($monthMin -gt 0) { $outer.MinHeight = $monthMin }
    return $outer
}

function New-MonthPadCell {
    # 相邻月份的"补位格"：只画一个浅色日号，不画阴影、不显示日程、不带今天/节假日角标。
    #
    # 为什么要有它：月视图每页只画本月（上一轮的硬要求），月初 / 月末必然多出几格空位。
    # 把空位画成"和背景同色的洞"很扎眼——整页网格里突然缺几块。补上相邻月份的浅色日号，
    # 网格就完整了，同时"本页内容只属于本月"这条不变量不受影响（补位格不画任何日程）。
    #
    # 为什么不复用 New-MonthCell：那个会带日程摘要、条数角标、今天高亮、节假日角标、
    # 选中态描边。补位格一旦沾上这些，"相邻月份事件不泄漏进本月"的审计就会红。
    param([datetime]$Date, [int]$Col)
    $bd = New-Bd -Bg (Get-Pal 'Panel') -Border (Get-Pal 'BorderSoft') -Radius 6 -Bw 1
    $bd.Opacity = 0.75
    $num = New-Txt -Text ([string]$Date.Day) -Size 11 -Color (Get-Pal 'InkFaint')
    $num.Margin = [System.Windows.Thickness]::new(8, 5, 0, 0)
    $num.HorizontalAlignment = 'Left'
    $num.VerticalAlignment = 'Top'
    $bd.Child = $num
    # 可点：跳到那一格所在的周（和点本月的日期格同一行为），但仍然不算"本页的内容"。
    # 用单独的 kind，别复用 'day'：右键 'day' 会打开"该日期的日程编辑窗"，
    # 在 9 月的页面上右键 8/31 弹出 8/31 的新建窗会让人以为点错了。
    $bd.Tag = @{ kind = 'day-pad'; date = $Date }
    $bd.Cursor = [System.Windows.Input.Cursors]::Hand
    $bd.ToolTip = ('{0:yyyy-MM-dd} · not in this month' -f $Date)
    return $bd
}

# ---------------------------------------------------------------------------
#  周视图
# ---------------------------------------------------------------------------
$script:HourHeight = 40.0
$script:WeekGutter = 54.0

# ---- 时段范围（只画 Start..End 这几个整点，Y=0 落在 Start 那一刻）----
# 为什么按"整点"存而不是按分钟存：刻度文案、整点横线、背景列都是按整点排的，
# 只要 Start/End 恒为整数小时，三者就永远对得齐（不需要再处理半点偏移）。
# 默认值取自设置文件；Day 视图的映射函数全部以这两个数为基准。
$script:WeekRangePresets = @(
    @{ Start = 0;  End = 24; Label = '全天 All day (00:00 - 24:00)' },
    @{ Start = 8;  End = 20; Label = '常用时间 Common (08:00 - 20:00)' },
    @{ Start = 9;  End = 18; Label = '工作时间 Work (09:00 - 18:00)' },
    @{ Start = 6;  End = 12; Label = '上午 Morning (06:00 - 12:00)' },
    @{ Start = 12; End = 18; Label = '下午 Afternoon (12:00 - 18:00)' },
    @{ Start = 18; End = 24; Label = '晚间 Evening (18:00 - 24:00)' }
)
$script:WeekRangeCustomLabel = '自定义 Custom...'
$script:WeekStartHour = 0
$script:WeekEndHour   = 24
if ($script:Settings.Contains('WeekStartHour')) { $script:WeekStartHour = [int]$script:Settings['WeekStartHour'] }
if ($script:Settings.Contains('WeekEndHour'))   { $script:WeekEndHour   = [int]$script:Settings['WeekEndHour'] }
if ($script:WeekStartHour -lt 0 -or $script:WeekEndHour -gt 24 -or $script:WeekEndHour -le $script:WeekStartHour) {
    $script:WeekStartHour = 0; $script:WeekEndHour = 24
}
# 范围控件的句柄与重入锁：ComboBox 的 SelectionChanged 会在"程序自己回填选中项"
# 时也被触发，不加锁会自激成死循环。处理器回调里只能看见 $script:，见 Care.ps1 顶部说明。
$script:WkRangeBox = $null
$script:WkStartBox = $null
$script:WkEndBox   = $null
$script:WeekAxis   = $null
$script:WkSuppress = $false

function Week-RangeRows {
    return ([int]$script:WeekEndHour - [int]$script:WeekStartHour)
}

# ---- 自适应高度：让周视图填满窗口，而不是在底部留一条空白 ----
# 为什么需要：HourHeight 以前是常数 40，窗口拉高时时间轴尺寸不变（08:00–20:00 就只有 480px），
# 底部空出一大片；窗口压矮时又要滚动。现在按"可视高度 / 时段小时数"反算。
#   下限 = 密度档位（HourHeightBase，默认 40）：**永远不会比选的密度更挤**。
#     窗口不高时算出来的值小于基准，直接退回基准，维持"内容比视口高 → 滚动"的老行为。
#   上限 = 220：防"极短的自定义时段（比如 3 小时）把一行拉成一整屏"。
# 另外这也保证了 1080x720 这个回归基准尺寸下行为基本不变（算出来约等于 40）。
#
# 第五轮：HourHeightBase 不再是常量 40，而是由设置里的"周视图密度"驱动
#   （紧凑 28 / 标准 40 / 宽松 56，见 Set-WeekDensity）。
#   同时新增一个**放大上限倍率**：不然选"紧凑"也没用 —— 窗口一高，
#   Reflow 会把 28 一路放大到 220，紧凑档形同虚设。
#   规则：最多放大到 base 的 1.6 倍。这样"紧凑"是"更矮、更容易滚动"，
#   而不是"在矮窗口里紧凑、在高窗口里又散开"。
$script:HourHeightBase = 40.0
$script:HourHeightMax  = 220.0
$script:DensityGrowMax = 1.6

function Fit-WeekAxisHeight {
    # 反算并写回 $script:HourHeight。返回 $true = "值变了，调用方要重画"。
    if ($null -eq $script:WeekScroll) { return $false }
    $h = [double]$script:WeekScroll.ViewportHeight
    if ($h -le 1.0) { $h = [double]$script:WeekScroll.ActualHeight }
    if ($h -le 1.0) { return $false }          # 还没布局，等下一次（Loaded / SizeChanged）
    $hours = [double](Week-RangeRows)
    if ($hours -le 0.0) { return $false }
    # 减 2px：让"内容高度 == 视口高度"时不至于因取整冒出一条多余的滚动条
    $want = ($h - 2.0) / $hours
    # 下限 = 当前密度档位（保证不会比用户选的更挤）
    if ($want -lt [double]$script:HourHeightBase) { $want = [double]$script:HourHeightBase }
    # 放大上限 = min(绝对上限 220, base × 1.6) —— 后者保证"紧凑档不会在高窗口里散开"
    $growCap = [double]$script:HourHeightBase * [double]$script:DensityGrowMax
    $cap = [double]$script:HourHeightMax
    if ($growCap -lt $cap) { $cap = $growCap }
    if ($want -gt $cap) { $want = $cap }
    $want = [math]::Round($want * 2.0) / 2.0   # 0.5px 精度，免得浮点抖动导致反复重画
    if ([math]::Abs($want - [double]$script:HourHeight) -lt 0.25) { return $false }
    $script:HourHeight = $want
    return $true
}

function Reflow-WeekHeight {
    # 返回 $true = 已重画轴与事件层（Update-WeekAxis 内部会顺带滚到"现在"）。
    # 调用时机只有两处：周视图 Loaded（首次布局之后）与窗口 SizeChanged。
    if ($script:View -ne 'week') { return $false }
    if ($null -eq $script:WeekAxis -or $null -eq $script:WeekScroll) { return $false }
    try { $script:MainWindow.UpdateLayout() } catch { }   # ViewportHeight 要布局完才有效
    if (-not (Fit-WeekAxisHeight)) { return $false }
    Update-WeekAxis
    return $true
}

# 分钟 -> 轴内像素 Y（可为负 / 超出轴高，调用方自行裁剪）
function Week-MinuteToY {
    param([int]$Min)
    return (([double]$Min / 60.0) - [double]$script:WeekStartHour) * [double]$script:HourHeight
}

# 轴内像素 Y -> 分钟（未吸附，可为区间外）
function Week-YToMinute {
    param([double]$Y)
    if ([double]$script:HourHeight -le 0.0) { return [int]$script:WeekStartHour * 60 }
    return [int](([double]$script:WeekStartHour + $Y / [double]$script:HourHeight) * 60.0)
}

# 把当前范围同步回控件（不回写、不触发重算）
function Update-WeekRangeControls {
    if ($null -eq $script:WkRangeBox) { return }
    $was = [bool]$script:WkSuppress
    $script:WkSuppress = $true
    try {
        $idx = -1
        $presets = @($script:WeekRangePresets)
        for ($i = 0; $i -lt $presets.Count; $i++) {
            if (([int]$presets[$i].Start -eq [int]$script:WeekStartHour) -and
                ([int]$presets[$i].End -eq [int]$script:WeekEndHour)) { $idx = $i; break }
        }
        if ($idx -ge 0) { $script:WkRangeBox.SelectedIndex = $idx }
        else { $script:WkRangeBox.SelectedIndex = $presets.Count }   # Custom...
        if ($null -ne $script:WkStartBox) { $script:WkStartBox.SelectedIndex = [int]$script:WeekStartHour }
        if ($null -ne $script:WkEndBox)   { $script:WkEndBox.SelectedIndex = [int]$script:WeekEndHour - 1 }
    } catch { Write-ErrLog ('Update-WeekRangeControls: ' + $_.Exception.Message) }
    finally { $script:WkSuppress = $was }
}

function Set-WeekRange {
    param([int]$StartHour, [int]$EndHour)
    if ($StartHour -lt 0) { $StartHour = 0 }
    if ($EndHour -gt 24) { $EndHour = 24 }
    if ($EndHour -le $StartHour) { return $false }
    $script:WeekStartHour = $StartHour
    $script:WeekEndHour = $EndHour
    $script:Settings['WeekStartHour'] = $StartHour
    $script:Settings['WeekEndHour'] = $EndHour
    Save-Settings
    Update-WeekAxis
    return $true
}

function Set-WeekDensity {
    # 设置周视图密度（每小时像素高）。返回 $true = 已生效。
    #
    # 为什么改的是 HourHeightBase 而不是 HourHeight：
    #   Fit-WeekAxisHeight 会用"可视高度 / 小时数"反算，但**下限是 HourHeightBase**。
    #   只改 HourHeight 的话，下一次 Reflow（窗口一缩放）就会被 base 顶回去 ——
    #   表现是"设成紧凑，拖一下窗口又变回标准"。所以必须改 base 本身。
    #
    # 为什么不重建整个周视图：和 Set-WeekRange 同理，控件正开着下拉弹层，
    #   重建会撕掉弹层。这里只改尺寸 + 重画轴层 + 让事件层重新贴位。
    param([int]$Px)
    if ($Px -lt 20 -or $Px -gt 80) { return $false }
    $script:HourHeightBase = [double]$Px
    $script:HourHeight     = [double]$Px
    $script:Settings['WeekDensity'] = $Px
    Save-Settings
    # Update-WeekAxis 会把轴层按新 HourHeight 重画，并让事件层重新贴回原位。
    Update-WeekAxis
    # 紧凑模式下内容可能比视口矮了，此时 Reflow 会把密度向上补一点（上限 220）。
    # 这是有意的：紧凑是"下限更低"，不是"锁死不变"。
    try { [void](Reflow-WeekHeight) } catch { }
    return $true
}

# 重画时间轴层（刻度 / 列底色 / 整点横线），并让事件层重新贴回原位。
# 为什么只重画"轴"而不整棵视图重建：范围由 ComboBox 切换，而 ComboBox 正开着
# 下拉弹层；把整棵视图（连同这个 ComboBox）拆掉重建，弹层会变成没人管的孤儿窗口。
function Update-WeekAxis {
    if ($null -eq $script:WeekAxis -or $null -eq $script:WeekOverlay) { return }
    New-WeekAxis $script:WeekAxis $script:WeekDays ([datetime]::Today)
    $w = [double]$script:WeekOverlay.ActualWidth
    if ($w -le 1.0 -and $null -ne $script:WeekAxis) {
        $w = [double]$script:WeekAxis.ActualWidth - [double]$script:WeekGutter
    }
    Draw-WeekEvents -Width $w
    Update-WeekRangeControls
    try { if ($null -ne $script:MainWindow) { $script:MainWindow.UpdateLayout() } } catch { }
    Scroll-WeekToNow
}

# 把视口滚到"现在"附近（仅当本周含今天且当前时刻落在所选时段内）
function Scroll-WeekToNow {
    if ($null -eq $script:WeekScroll) { return }
    $hasToday = $false
    foreach ($d in @($script:WeekDays)) { if (Same-Day $d ([datetime]::Today)) { $hasToday = $true; break } }
    if (-not $hasToday) { return }
    $nowMin = [datetime]::Now.Hour * 60 + [datetime]::Now.Minute
    $offset = (Week-MinuteToY $nowMin) - [double]$script:HourHeight
    if ($offset -lt 0.0) { $offset = 0.0 }
    try { $script:WeekScroll.ScrollToVerticalOffset($offset) } catch { }
}

# 时间轴层：小时刻度 + 每日列底色 + 整点横线。
# 单独一层（而不是和事件层混在同一个 Grid 里）是为了"换范围时只动这一层"。
function New-WeekAxis {
    param([System.Windows.Controls.Grid]$Axis, $Days, [datetime]$Today)
    if ($null -eq $Axis) { return }
    $Axis.Children.Clear()
    $Axis.RowDefinitions.Clear()
    $h0 = [int]$script:WeekStartHour
    $rows = Week-RangeRows
    for ($i = 0; $i -lt $rows; $i++) {
        $rd = New-Object System.Windows.Controls.RowDefinition
        $rd.Height = [System.Windows.GridLength]::new($script:HourHeight, 'Pixel')
        $Axis.RowDefinitions.Add($rd)
    }
    # 小时刻度
    for ($i = 0; $i -lt $rows; $i++) {
        $t = New-Txt -Text ('{0:00}:00' -f ($h0 + $i)) -Size 11 -Color (Get-Pal 'InkFaint')
        $t.HorizontalAlignment = 'Right'
        $t.VerticalAlignment = 'Top'
        $t.Margin = [System.Windows.Thickness]::new(0, -1, 6, 0)
        $t.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
        [System.Windows.Controls.Grid]::SetRow($t, $i)
        [System.Windows.Controls.Grid]::SetColumn($t, 0)
        [void]$Axis.Children.Add($t)
    }
    # 每日列底色（整列单元格色块，宽高都交给布局 -> 必然铺满）
    for ($c = 0; $c -lt 7; $c++) {
        $d = $Days[$c]
        $colBg = New-Object System.Windows.Controls.Border
        $isToday = Same-Day $d $Today
        $bg = Get-Pal 'Card'
        if (Is-Weekend $d) { $bg = Get-Pal 'Weekend' }
        if ($isToday)      { $bg = Get-Pal 'AccentFocus' }
        $colBg.Background = Brush $bg
        if ($isToday) { $colBg.Opacity = 0.45 }
        $colBg.BorderBrush = Brush (Get-Pal 'BorderSoft')
        $colBg.BorderThickness = [System.Windows.Thickness]::new(1, 0, 0, 0)
        [System.Windows.Controls.Grid]::SetRow($colBg, 0)
        [System.Windows.Controls.Grid]::SetRowSpan($colBg, [math]::Max(1, $rows))
        [System.Windows.Controls.Grid]::SetColumn($colBg, $c + 1)
        [void]$Axis.Children.Add($colBg)
    }
    # 整点横线（在列底之后加 -> 画在列底之上）
    for ($i = 1; $i -lt $rows; $i++) {
        $ln = New-Object System.Windows.Controls.Border
        $ln.BorderBrush = Brush (Get-Pal 'BorderSoft')
        $ln.BorderThickness = [System.Windows.Thickness]::new(0, 1, 0, 0)
        $ln.Opacity = 0.55
        [System.Windows.Controls.Grid]::SetRow($ln, $i)
        [System.Windows.Controls.Grid]::SetColumn($ln, 0)
        [System.Windows.Controls.Grid]::SetColumnSpan($ln, 8)
        [void]$Axis.Children.Add($ln)
    }
}

# 时段范围选择条（只出现在周视图里）
function New-WeekRangeBar {
    $bar = New-Object System.Windows.Controls.Border
    $bar.Background = Brush (Get-Pal 'CardAlt')
    $bar.BorderBrush = Brush (Get-Pal 'BorderSoft')
    $bar.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.VerticalAlignment = 'Center'
    $row.Margin = [System.Windows.Thickness]::new(10, 0, 10, 0)

    $cap = New-Txt -Text 'Time range' -Size 11 -Color (Get-Pal 'InkFaint')
    $cap.VerticalAlignment = 'Center'
    $cap.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [void]$row.Children.Add($cap)

    $box = New-Object System.Windows.Controls.ComboBox
    $box.Width = 196
    $box.Height = 26
    $box.FontSize = 11
    $box.Background = Brush (Get-Pal 'Card')
    $box.Foreground = Brush (Get-Pal 'Ink')
    $box.BorderBrush = Brush (Get-Pal 'Border')
    $box.BorderThickness = [System.Windows.Thickness]::new(2)
    $box.Padding = [System.Windows.Thickness]::new(6, 1, 6, 1)
    $box.VerticalContentAlignment = 'Center'
    foreach ($p in @($script:WeekRangePresets)) { [void]$box.Items.Add([string]$p.Label) }
    [void]$box.Items.Add([string]$script:WeekRangeCustomLabel)
    $box.ToolTip = 'Pick how many hours the week grid shows'
    [void]$row.Children.Add($box)

    $from = New-Object System.Windows.Controls.ComboBox
    $from.Width = 74
    $from.Height = 26
    $from.FontSize = 11
    $from.Background = Brush (Get-Pal 'Card')
    $from.Foreground = Brush (Get-Pal 'Ink')
    $from.BorderBrush = Brush (Get-Pal 'Border')
    $from.BorderThickness = [System.Windows.Thickness]::new(2)
    $from.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $from.VerticalContentAlignment = 'Center'
    for ($h = 0; $h -lt 24; $h++) { [void]$from.Items.Add(('{0:00}:00' -f $h)) }

    $dash = New-Txt -Text '-' -Size 12 -Color (Get-Pal 'InkFaint')
    $dash.VerticalAlignment = 'Center'
    $dash.Margin = [System.Windows.Thickness]::new(4, 0, 4, 0)

    $to = New-Object System.Windows.Controls.ComboBox
    $to.Width = 74
    $to.Height = 26
    $to.FontSize = 11
    $to.Background = Brush (Get-Pal 'Card')
    $to.Foreground = Brush (Get-Pal 'Ink')
    $to.BorderBrush = Brush (Get-Pal 'Border')
    $to.BorderThickness = [System.Windows.Thickness]::new(2)
    $to.VerticalContentAlignment = 'Center'
    for ($h = 1; $h -le 24; $h++) { [void]$to.Items.Add(('{0:00}:00' -f $h)) }

    [void]$row.Children.Add($from)
    [void]$row.Children.Add($dash)
    [void]$row.Children.Add($to)

    $bar.Child = $row

    $script:WkRangeBox = $box
    $script:WkStartBox = $from
    $script:WkEndBox   = $to
    Update-WeekRangeControls

    $box.Add_SelectionChanged({
        param($s, $e)
        try {
            if ($script:WkSuppress) { return }
            $presets = @($script:WeekRangePresets)
            $i = [int]$s.SelectedIndex
            if ($i -lt 0) { return }
            if ($i -lt $presets.Count) {
                [void](Set-WeekRange ([int]$presets[$i].Start) ([int]$presets[$i].End))
            } else {
                Apply-WeekCustomRange
            }
        } catch { Write-ErrLog ('Week range box: ' + $_.Exception.Message) }
    })
    $from.Add_SelectionChanged({
        param($s, $e)
        try { if (-not $script:WkSuppress) { Apply-WeekCustomRange } } catch { Write-ErrLog ('Week start box: ' + $_.Exception.Message) }
    })
    $to.Add_SelectionChanged({
        param($s, $e)
        try { if (-not $script:WkSuppress) { Apply-WeekCustomRange } } catch { Write-ErrLog ('Week end box: ' + $_.Exception.Message) }
    })
    return $bar
}

# 自定义时段：起止都从两个下拉里读。"起 >= 止"时不动数据、只把起止拉回上一个合法值。
function Apply-WeekCustomRange {
    if ($null -eq $script:WkStartBox -or $null -eq $script:WkEndBox) { return }
    $sHr = [int]$script:WkStartBox.SelectedIndex
    $eHr = [int]$script:WkEndBox.SelectedIndex + 1
    if ($sHr -lt 0) { $sHr = 0 }
    if ($eHr -lt 1) { $eHr = 1 }
    if ($eHr -le $sHr) {
        # 非法组合：把"止"抬到"起"+1，再回填控件（回填走 Suppress，不会自激）
        $eHr = $sHr + 1
        if ($eHr -gt 24) { $eHr = 24; $sHr = 23 }
        [void](Set-WeekRange $sHr $eHr)
        return
    }
    # 先切到 Custom...（Suppress 防止再次触发本函数）
    $was = [bool]$script:WkSuppress
    $script:WkSuppress = $true
    try { if ($null -ne $script:WkRangeBox) { $script:WkRangeBox.SelectedIndex = @($script:WeekRangePresets).Count } }
    finally { $script:WkSuppress = $was }
    [void](Set-WeekRange $sHr $eHr)
}

function Render-Week {
    $shell = New-Bd -Bg (Get-Pal 'Card') -Border (Get-Pal 'Border') -Radius 8
    $shell.ClipToBounds = $true

    $root = New-Object System.Windows.Controls.Grid
    # 0 = 时段范围选择条（只在周视图里出现），1 = 星期表头，2 = 可滚动的时间网格
    foreach ($h in @(38.0, 54.0)) {
        $rd = New-Object System.Windows.Controls.RowDefinition
        $rd.Height = [System.Windows.GridLength]::new($h, 'Pixel')
        $root.RowDefinitions.Add($rd)
    }
    $rdStar = New-Object System.Windows.Controls.RowDefinition
    $rdStar.Height = [System.Windows.GridLength]::new(1, 'Star')
    $root.RowDefinitions.Add($rdStar)

    $rangeBar = New-WeekRangeBar
    [System.Windows.Controls.Grid]::SetRow($rangeBar, 0)
    [void]$root.Children.Add($rangeBar)

    $days = Week-Days $script:Anchor
    $today = [datetime]::Today

    # --- 表头 ---
    $head = New-Object System.Windows.Controls.Grid
    # 表头和滚动内容共享同一可视宽度；预留系统滚动条，避免竖线错位。
    $head.Margin = [System.Windows.Thickness]::new(0, 0, [System.Windows.SystemParameters]::VerticalScrollBarWidth, 0)
    $cd0 = New-Object System.Windows.Controls.ColumnDefinition
    $cd0.Width = [System.Windows.GridLength]::new($script:WeekGutter, 'Pixel')
    $head.ColumnDefinitions.Add($cd0)
    for ($c = 0; $c -lt 7; $c++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = [System.Windows.GridLength]::new(1, 'Star')
        $head.ColumnDefinitions.Add($cd)
    }
    for ($c = 0; $c -lt 7; $c++) {
        $d = $days[$c]
        $hb = New-Object System.Windows.Controls.Border
        $bg = Get-Pal 'CardAlt'
        if (Is-Weekend $d)      { $bg = Get-Pal 'Weekend' }
        if (Same-Day $d $today) { $bg = Get-Pal 'AccentFocus' }
        $hb.Background = Brush $bg
        $hb.BorderBrush = Brush (Get-Pal 'BorderSoft')
        $hb.BorderThickness = [System.Windows.Thickness]::new(1, 0, 0, 2)
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.VerticalAlignment = 'Center'
        $sp.HorizontalAlignment = 'Center'
        $inkCol = Get-Pal 'InkSoft'
        if (Same-Day $d $today) { $inkCol = Get-Pal 'TodayInk' }
        $t1 = New-Txt -Text $script:DowShort[$c] -Size 12 -Color $inkCol -Weight 'Semi'
        $t1.HorizontalAlignment = 'Center'
        $t2 = New-Txt -Text ('{0}/{1}' -f $d.Month, $d.Day) -Size 14 -Color $inkCol -Weight 'Bold'
        $t2.HorizontalAlignment = 'Center'
        [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2)
        $holi = Get-Holiday $d
        if ($holi) {
            $rt = New-Txt -Text '休' -Size 9 -Color (Get-Pal 'AccentEvent') -Weight 'Bold'
            $rt.HorizontalAlignment = 'Center'
            [void]$sp.Children.Add($rt)
        }
        $hb.Child = $sp
        [System.Windows.Controls.Grid]::SetColumn($hb, $c + 1)
        [void]$head.Children.Add($hb)
    }
    # 表头贴在"星期表头"那一行；范围条与表头各自成行，互不挤压
    [System.Windows.Controls.Grid]::SetRow($head, 1)
    [void]$root.Children.Add($head)

    # --- 时间网格 ---
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Visible'
    $sv.HorizontalScrollBarVisibility = 'Disabled'

    # 外层 Grid 只有一行（行高由轴层的内容撑开），轴层与事件层共用同一套列定义。
    $canvas = New-Object System.Windows.Controls.Grid
    $rdOnly = New-Object System.Windows.Controls.RowDefinition
    $rdOnly.Height = [System.Windows.GridLength]::new(1, 'Star')
    $canvas.RowDefinitions.Add($rdOnly)
    $cd0b = New-Object System.Windows.Controls.ColumnDefinition
    $cd0b.Width = [System.Windows.GridLength]::new($script:WeekGutter, 'Pixel')
    $canvas.ColumnDefinitions.Add($cd0b)
    for ($c = 0; $c -lt 7; $c++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = [System.Windows.GridLength]::new(1, 'Star')
        $canvas.ColumnDefinitions.Add($cd)
    }

    # 轴层：小时刻度 / 每日列底 / 整点横线。单独一层的原因见 Update-WeekAxis。
    $axis = New-Object System.Windows.Controls.Grid
    $cdAx0 = New-Object System.Windows.Controls.ColumnDefinition
    $cdAx0.Width = [System.Windows.GridLength]::new($script:WeekGutter, 'Pixel')
    $axis.ColumnDefinitions.Add($cdAx0)
    for ($c = 0; $c -lt 7; $c++) {
        $cdAx = New-Object System.Windows.Controls.ColumnDefinition
        $cdAx.Width = [System.Windows.GridLength]::new(1, 'Star')
        $axis.ColumnDefinitions.Add($cdAx)
    }
    $script:WeekAxis = $axis
    New-WeekAxis $axis $days $today
    [System.Windows.Controls.Grid]::SetRow($axis, 0)
    [System.Windows.Controls.Grid]::SetColumn($axis, 0)
    [System.Windows.Controls.Grid]::SetColumnSpan($axis, 8)
    [void]$canvas.Children.Add($axis)

    # 事件卡（Canvas 覆盖层做绝对定位；最后加 -> 永远压在列底与格线之上）
    $overlay = New-Object System.Windows.Controls.Canvas
    [System.Windows.Controls.Grid]::SetRow($overlay, 0)
    [System.Windows.Controls.Grid]::SetColumn($overlay, 1)
    [System.Windows.Controls.Grid]::SetColumnSpan($overlay, 7)
    $overlay.ClipToBounds = $true
    $overlay.Background = [System.Windows.Media.Brushes]::Transparent
    $overlay.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($script:OverlayOpen -or $script:WeekDrag) { return }
        try { Start-WeekCreate ($e.GetPosition($script:WeekOverlay)); $e.Handled = $true } catch { Write-ErrLog ('Week create down: ' + $_.Exception.Message) }
    })
    $overlay.Add_MouseMove({
        param($s, $e)
        try { if ($null -ne $script:WeekCreate) { Update-WeekCreate ($e.GetPosition($script:WeekOverlay)) } } catch { Write-ErrLog ('Week create move: ' + $_.Exception.Message) }
    })
    $overlay.Add_MouseLeftButtonUp({
        param($s, $e)
        try { if ($null -ne $script:WeekCreate) { Finish-WeekCreate; $e.Handled = $true } } catch { Write-ErrLog ('Week create up: ' + $_.Exception.Message) }
    })
    $overlay.Add_LostMouseCapture({
        param($s, $e)
        try {
            if ($null -ne $script:WeekCreate) {
                if ($null -ne $script:WeekCreate.Rect) { [void]$script:WeekOverlay.Children.Remove($script:WeekCreate.Rect) }
                $script:WeekCreate = $null
            }
        } catch { }
    })

    $eventsForWeek = @()
    for ($c = 0; $c -lt 7; $c++) {
        foreach ($e in @(Events-On $days[$c])) {
            $eventsForWeek += [pscustomobject]@{ Ev = $e; Col = $c }
        }
    }
    $script:WeekOverlay = $overlay
    $script:WeekDays = $days
    $script:WeekEvents = $eventsForWeek
    $script:WeekCanvas = $canvas
    $script:WeekScroll = $sv

    # 宽度变化就重画（用 e.NewSize，不依赖 ActualWidth 的更新时机）
    $overlay.Add_SizeChanged({
        param($s, $e)
        Draw-WeekEvents -Width ([double]$e.NewSize.Width)
    })
    # 首次布局：此刻 ActualWidth 还是 0，先 Measure 探一次
    $overlay.Add_Loaded({
        try {
            if ($null -ne $script:WeekOverlay) {
                $script:WeekOverlay.Measure(
                    [System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
                Draw-WeekEvents -Width ([double]$script:WeekOverlay.DesiredSize.Width)
                # 高度自适应要在这里做：Loaded 时窗口刚跑完一次布局，ViewportHeight 才不是 0。
                [void](Reflow-WeekHeight)
                # 再无条件滚到"现在"一次：Reflow 内部只有在 HourHeight 真的变了的时候
                # 才会走到 Scroll-WeekToNow，而"打开就定位在当下"是每次进周视图都要的行为。
                Scroll-WeekToNow
            }
        } catch { Write-ErrLog ('WeekOverlay.Loaded: ' + $_.Exception.Message) }
    })

    [void]$canvas.Children.Add($overlay)

    $sv.Content = $canvas
    [System.Windows.Controls.Grid]::SetRow($sv, 2)
    [void]$root.Children.Add($sv)

    $shell.Child = $root
    return $shell
}

function Draw-WeekEvents {
    param([double]$Width = 0.0)
    if ($null -eq $script:WeekOverlay) { return }
    $ov = $script:WeekOverlay
    if ($ov.Children.Count -gt 0) { $ov.Children.Clear() }
    $w = $Width
    if ($w -le 1.0) { $w = [double]$ov.ActualWidth }
    if ($w -le 1.0) { return }
    $colW = $w / 7.0

    # 当前所选时段（分钟）。完全落在时段之外的日程不画 —— 它们的位置在轴外，
    # 画了也是被 ClipToBounds 裁掉的隐形卡片，白占渲染时间。
    $rangeMin = [int]$script:WeekStartHour * 60
    $rangeMax = [int]$script:WeekEndHour * 60

    # 按列分组，做重叠分道
    for ($c = 0; $c -lt 7; $c++) {
        $items = @($script:WeekEvents | Where-Object {
            ($_.Col -eq $c) -and ([int]$_.Ev.end -gt $rangeMin) -and ([int]$_.Ev.start -lt $rangeMax)
        } | ForEach-Object { $_.Ev })
        if ($items.Count -eq 0) { continue }
        $sorted = @($items | Sort-Object -Property @{E={[int]$_.start}}, @{E={[int]$_.end}})
        # 分道
        $laneEnds = New-Object System.Collections.ArrayList
        $placed = New-Object System.Collections.ArrayList
        foreach ($e in $sorted) {
            $lane = -1
            for ($i = 0; $i -lt $laneEnds.Count; $i++) {
                if ([int]$laneEnds[$i] -le [int]$e.start) { $lane = $i; break }
            }
            if ($lane -lt 0) { $lane = $laneEnds.Count; [void]$laneEnds.Add(0) }
            $laneEnds[$lane] = [int]$e.end
            [void]$placed.Add([pscustomobject]@{ Ev = $e; Lane = $lane })
        }
        $lanes = [math]::Max(1, $laneEnds.Count)

        foreach ($p in $placed) {
            $e = $p.Ev
            $tag = [string]$e.tag
            $bg = Get-Pal 'AccentTask'
            $fg = '#1E3323'
            if ($tag -eq 'focus' -or $tag -eq 'life') { $bg = Get-Pal 'AccentFocus'; $fg = '#4A2F16' }
            if ($tag -eq 'work') { $bg = Get-Pal 'AccentEvent'; $fg = '#FFFFFF' }

            $card = New-Bd -Bg $bg -Border (Get-Pal 'Border') -Radius 6 -Bw 1
            $card.Tag = @{ kind = 'event'; id = [string]$e.id; col = $c }

            $cardGrid = New-Object System.Windows.Controls.Grid
            $accent = New-Object System.Windows.Controls.Border
            $accent.Width = 4; $accent.HorizontalAlignment = 'Left'
            $accent.Background = Brush (Get-Pal 'Border')
            $accent.CornerRadius = [System.Windows.CornerRadius]::new(4,0,0,4)
            $accent.IsHitTestVisible = $false
            [void]$cardGrid.Children.Add($accent)
            $handleTop = New-Bd -Bg (Get-Pal 'Border') -Radius 2
            $handleTop.Height = 3; $handleTop.Margin = [System.Windows.Thickness]::new(7, 3, 7, 0)
            $handleTop.VerticalAlignment = 'Top'; $handleTop.Opacity = 0.55
            $handleBottom = New-Bd -Bg (Get-Pal 'Border') -Radius 2
            $handleBottom.Height = 3; $handleBottom.Margin = [System.Windows.Thickness]::new(7, 0, 7, 3)
            $handleBottom.VerticalAlignment = 'Bottom'; $handleBottom.Opacity = 0.55
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Margin = [System.Windows.Thickness]::new(7, 6, 5, 6)
            $tm = New-Txt -Text (('{0}-{1}' -f (Min-To-HHMM ([int]$e.start)), (Min-To-HHMM ([int]$e.end)))) `
                          -Size 10 -Color $fg -Weight 'Semi'
            $tm.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
            $tm.Opacity = 0.88
            [void]$sp.Children.Add($tm)
            $tt = New-Txt -Text ([string]$e.title) -Size 12 -Color $fg -Weight 'Semi'
            if ([bool]$e.done) { $tt.TextDecorations = [System.Windows.TextDecorations]::Strikethrough }
            [void]$sp.Children.Add($tt)
            [void]$cardGrid.Children.Add($sp)
            [void]$cardGrid.Children.Add($handleTop)
            [void]$cardGrid.Children.Add($handleBottom)
            $card.Child = $cardGrid
            $card.Tag['timeText'] = $tm
            $card.Cursor = [System.Windows.Input.Cursors]::SizeAll
            $card.ToolTip = '拖动改日期/时间；上、下边缘调整时长；双击编辑'
            $card.Add_MouseLeftButtonDown({
                param($s, $e)
                if ($script:OverlayOpen) { return }
                try {
                    if ((Get-MouseClickCount $e) -ge 2) {
                        $id = [string]$s.Tag['id']
                        $script:WeekDrag = $null
                        Open-EventEditor -Id $id
                        $e.Handled = $true
                        return
                    }
                    $pos = $e.GetPosition($script:WeekOverlay)
                    if (Start-WeekDrag $s $pos) { $e.Handled = $true }
                } catch { Write-ErrLog ('Week card mouse down: ' + $_.Exception.Message) }
            })
            $card.Add_MouseMove({
                param($s, $e)
                try {
                    if ($null -eq $script:WeekDrag) {
                        $pos = $e.GetPosition($s)
                        if ($pos.Y -le 9.0 -or $pos.Y -ge ($s.ActualHeight - 9.0)) {
                            $s.Cursor = [System.Windows.Input.Cursors]::SizeNS
                        } else {
                            $s.Cursor = [System.Windows.Input.Cursors]::SizeAll
                        }
                        return
                    }
                    Update-WeekDrag $s ($e.GetPosition($script:WeekOverlay))
                } catch { Write-ErrLog ('Week card mouse move: ' + $_.Exception.Message) }
            })
            $card.Add_MouseLeftButtonUp({
                param($s, $e)
                try {
                    if ($null -ne $script:WeekDrag -and [string]$script:WeekDrag.Card.Tag['id'] -eq [string]$s.Tag['id']) {
                        Finish-WeekDrag $s ($e.GetPosition($script:WeekOverlay))
                        $e.Handled = $true
                    }
                } catch { Write-ErrLog ('Week card mouse up: ' + $_.Exception.Message) }
            })
            $card.Add_LostMouseCapture({
                param($s, $e)
                try {
                    if ($null -ne $script:WeekDrag -and [string]$script:WeekDrag.Card.Tag['id'] -eq [string]$s.Tag['id']) {
                        $script:WeekDrag = $null
                        Refresh-All
                    }
                } catch { }
            })
            $cm = New-Object System.Windows.Controls.ContextMenu
            $cm.Background = Brush (Get-Pal 'Card'); $cm.Foreground = Brush (Get-Pal 'Ink')
            $cm.BorderBrush = Brush (Get-Pal 'Border'); $cm.BorderThickness = [System.Windows.Thickness]::new(1)
            $miEdit = New-Object System.Windows.Controls.MenuItem
            $miEdit.Header = 'Edit'; $miEdit.Tag = [string]$e.id
            $miDup = New-Object System.Windows.Controls.MenuItem
            $miDup.Header = 'Duplicate'; $miDup.Tag = [string]$e.id
            $miDel = New-Object System.Windows.Controls.MenuItem
            $miDel.Header = 'Delete'; $miDel.Tag = [string]$e.id
            $miEdit.Add_Click({ param($s,$ev) try { Open-EventEditor -Id ([string]$s.Tag) } catch { } })
            $miDup.Add_Click({ param($s,$ev) try { Duplicate-Event -Id ([string]$s.Tag) } catch { } })
            $miDel.Add_Click({ param($s,$ev) try { Remove-Event -Id ([string]$s.Tag) } catch { } })
            [void]$cm.Items.Add($miEdit); [void]$cm.Items.Add($miDup); [void]$cm.Items.Add($miDel)
            $card.ContextMenu = $cm

            $topPx = Week-MinuteToY ([int]$e.start)
            $durMin = [math]::Max(15, [int]$e.end - [int]$e.start)
            $hPx = [math]::Max(19.0, ($durMin / 60.0) * $script:HourHeight)
            $laneW = $colW / [double]$lanes

            $cw = $laneW - 8.0
            if ($cw -lt 20.0) { $cw = 20.0 }
            $card.Width = $cw
            $card.Height = $hPx
            $card.HorizontalAlignment = 'Left'
            $card.VerticalAlignment = 'Top'
            [System.Windows.Controls.Canvas]::SetLeft($card, [double]($c * $colW + $p.Lane * $laneW + 4.0))
            [System.Windows.Controls.Canvas]::SetTop($card, [double]$topPx)
            [void]$ov.Children.Add($card)
        }
    }

    # 当前时刻线（仅当本周含今天）
    $todayCol = -1
    for ($c = 0; $c -lt 7; $c++) {
        if (Same-Day $script:WeekDays[$c] ([datetime]::Today)) { $todayCol = $c; break }
    }
    if ($todayCol -ge 0) {
        $mins = [datetime]::Now.Hour * 60 + [datetime]::Now.Minute
        # 当前时刻落在所选时段之外时不画（否则会是一根贴在轴外的线）
        if ($mins -ge $rangeMin -and $mins -le $rangeMax) {
            $ln = New-Object System.Windows.Controls.Border
            $ln.Background = Brush (Get-Pal 'AccentEvent')
            $ln.Height = 2
            $ln.Width = $w
            [System.Windows.Controls.Canvas]::SetLeft($ln, 0.0)
            [System.Windows.Controls.Canvas]::SetTop($ln, [double](Week-MinuteToY $mins))
            [void]$ov.Children.Add($ln)
        }
    }
}

# ---------------------------------------------------------------------------
#  周视图空白区：按住拖动直接创建日程
# ---------------------------------------------------------------------------
function Get-WeekMinuteFromY {
    param([double]$Y)
    # 轴内 Y -> 绝对分钟：要先加上时段起点（Y=0 是 $script:WeekStartHour 那一刻）
    $lo = [int]$script:WeekStartHour * 60
    $hi = [int]$script:WeekEndHour * 60
    if ([double]$script:HourHeight -le 0.0) { return $lo }
    $m = [int]([math]::Round((([double]$script:WeekStartHour + $Y / [double]$script:HourHeight) * 60.0) / 15.0) * 15)
    if ($m -lt $lo) { $m = $lo }
    if ($m -gt $hi) { $m = $hi }
    if ($m -gt 1439) { $m = 1439 }
    return $m
}

function Ensure-WeekCreateRect {
    param($State)
    if ($null -ne $State.Rect) { return }
    $rect = New-Bd -Bg (Get-Pal 'AccentFocus') -Border (Get-Pal 'AccentEvent') -Radius 6 -Bw 2
    $rect.Opacity = 0.62
    $rect.IsHitTestVisible = $false
    $label = New-Txt -Text '' -Size 10 -Color (Get-Pal 'TodayInk') -Weight 'Bold'
    $label.Margin = [System.Windows.Thickness]::new(7, 4, 7, 4)
    $rect.Child = $label
    [void]$script:WeekOverlay.Children.Add($rect)
    $State.Rect = $rect
    $State.Label = $label
}

function Start-WeekCreate {
    param([System.Windows.Point]$Pos)
    if ($null -eq $script:WeekOverlay) { return }
    $w = [double]$script:WeekOverlay.ActualWidth
    if ($w -le 1.0) { return }
    $colW = $w / 7.0
    $col = [int][math]::Floor($Pos.X / $colW)
    if ($col -lt 0) { $col = 0 }
    if ($col -gt 6) { $col = 6 }
    $mins = Get-WeekMinuteFromY $Pos.Y
    $weekStart = Start-Of-Week $script:Anchor
    $script:WeekCreate = @{
        Col = $col
        Date = $weekStart.AddDays($col)
        StartMin = $mins
        CurrentMin = $mins
        Rect = $null
        Label = $null
        ColW = $colW
    }
    [void]$script:WeekOverlay.CaptureMouse()
}

function Update-WeekCreate {
    param([System.Windows.Point]$Pos)
    $st = $script:WeekCreate
    if ($null -eq $st) { return }
    $st.CurrentMin = Get-WeekMinuteFromY $Pos.Y
    Ensure-WeekCreateRect $st
    $a = [int]$st.StartMin
    $b = [int]$st.CurrentMin
    $down = ($b -ge $a)
    $start = [math]::Min($a, $b)
    $end = [math]::Max($a, $b)
    $end = [math]::Min(1439, $end)
    if (($end - $start) -lt 15) { $end = [math]::Min(1439, $start + 15) }
    $top = ($start / 60.0) * [double]$script:HourHeight
    $height = (($end - $start) / 60.0) * [double]$script:HourHeight
    if ($height -lt 18.0) { $height = 18.0 }
    $st.Rect.Width = [math]::Max(24.0, [double]$st.ColW - 8.0)
    $st.Rect.Height = $height
    [System.Windows.Controls.Canvas]::SetLeft($st.Rect, [double]($st.Col * $st.ColW + 4.0))
    [System.Windows.Controls.Canvas]::SetTop($st.Rect, [double]$top)
    $st.Label.Text = ((Min-To-HHMM $start) + '-' + (Min-To-HHMM $end))
}

function Finish-WeekCreate {
    $st = $script:WeekCreate
    if ($null -eq $st) { return }
    $a = [int]$st.StartMin
    $b = [int]$st.CurrentMin
    $start = [math]::Min($a, $b)
    $end = [math]::Max($a, $b)
    if (($end - $start) -lt 15) { $end = [math]::Min(1439, $start + 15) }
    if ($null -ne $st.Rect) { try { [void]$script:WeekOverlay.Children.Remove($st.Rect) } catch { } }
    $mouseMoved = ([math]::Abs($b - $a) -ge 15)
    $script:WeekCreate = $null
    try { $script:WeekOverlay.ReleaseMouseCapture() } catch { }
    if ($mouseMoved) {
        Open-EventEditor -PrefillDate (Fmt-Date $st.Date) -PrefillStart $start -PrefillEnd $end
    }
}

# ---------------------------------------------------------------------------
#  周视图交互：拖动改日期/时间，上/下边缘改时长，双击编辑
# ---------------------------------------------------------------------------
function Get-WeekSnapMinutes {
    param([double]$DeltaPx)
    if ($script:HourHeight -le 0) { return 0 }
    $raw = $DeltaPx / [double]$script:HourHeight * 60.0
    return [int]([math]::Round($raw / 15.0) * 15)
}

function Ensure-WeekGuide {
    param($State)
    if ($null -eq $State -or $null -ne $State.GuideLine) { return }
    $line = New-Object System.Windows.Shapes.Line
    $line.Stroke = Brush (Get-Pal 'AccentEvent')
    $line.StrokeThickness = 1.5
    $dash = New-Object System.Windows.Media.DoubleCollection
    [void]$dash.Add(5); [void]$dash.Add(3)
    $line.StrokeDashArray = $dash
    $line.X1 = 0.0
    $line.X2 = [double]$script:WeekOverlay.ActualWidth
    $line.IsHitTestVisible = $false
    [void]$script:WeekOverlay.Children.Add($line)

    $box = New-Bd -Bg (Get-Pal 'Card') -Border (Get-Pal 'Border') -Radius 4 -Bw 1
    $box.Padding = [System.Windows.Thickness]::new(6, 2, 6, 2)
    $box.Opacity = 0.96
    $box.IsHitTestVisible = $false
    $label = New-Txt -Text '' -Size 10 -Color (Get-Pal 'AccentEvent') -Weight 'Bold'
    $box.Child = $label
    [void]$script:WeekOverlay.Children.Add($box)

    $State.GuideLine = $line
    $State.GuideBox = $box
    $State.GuideLabel = $label
}

function Set-WeekGuide {
    param($State, [double]$Y, [string]$Text)
    if ($null -eq $State) { return }
    Ensure-WeekGuide $State
    if ($null -eq $State.GuideLine) { return }
    $State.GuideLine.X2 = [double]$script:WeekOverlay.ActualWidth
    $State.GuideLine.Y1 = $Y
    $State.GuideLine.Y2 = $Y
    $State.GuideLabel.Text = $Text
    [System.Windows.Controls.Canvas]::SetLeft($State.GuideBox, 6.0)
    $boxTop = $Y - 26.0
    if ($boxTop -lt 0.0) { $boxTop = $Y + 4.0 }
    [System.Windows.Controls.Canvas]::SetTop($State.GuideBox, $boxTop)
}

function Remove-WeekGuide {
    param($State)
    if ($null -eq $State) { return }
    if ($null -ne $State.GuideLine) {
        try { [void]$script:WeekOverlay.Children.Remove($State.GuideLine) } catch { }
    }
    if ($null -ne $State.GuideBox) {
        try { [void]$script:WeekOverlay.Children.Remove($State.GuideBox) } catch { }
    }
}

function Set-WeekDragTimeText {
    param($State, [int]$StartMin, [int]$EndMin)
    if ($null -eq $State -or $null -eq $State.TimeText) { return }
    $State.TimeText.Text = ('{0}-{1}' -f (Min-To-HHMM $StartMin), (Min-To-HHMM $EndMin))
}

function Start-WeekDrag {
    param($Card, [System.Windows.Point]$Pos)
    if ($null -eq $Card -or $null -eq $Card.Tag) { return $false }
    $id = [string]$Card.Tag['id']
    $hits = @($script:Events | Where-Object { [string]$_.id -eq $id })
    if ($hits.Count -eq 0) { return $false }
    $top = [System.Windows.Controls.Canvas]::GetTop($Card)
    $left = [System.Windows.Controls.Canvas]::GetLeft($Card)
    if ([double]::IsNaN($top) -or [double]::IsNaN($left)) { return $false }
    $localY = $Pos.Y - $top
    $phase = 'move'
    if ($localY -le 8.0) { $phase = 'resize-top' }
    elseif ($localY -ge ($Card.Height - 8.0)) { $phase = 'resize-bottom' }
    $script:WeekDrag = @{
        Event = $hits[0]
        Card = $Card
        Phase = $phase
        StartX = $Pos.X
        StartY = $Pos.Y
        Left = $left
        Top = $top
        Width = $Card.Width
        Height = $Card.Height
        StartMin = [int]$hits[0].start
        EndMin = [int]$hits[0].end
        Col = [int]$Card.Tag['col']
        TimeText = $Card.Tag['timeText']
        ColW = [double]$script:WeekOverlay.ActualWidth / 7.0
        GuideLine = $null
        GuideBox = $null
        GuideLabel = $null
    }
    [void]$Card.CaptureMouse()
    return $true
}

function Update-WeekDrag {
    param($Card, [System.Windows.Point]$Pos)
    $d = $script:WeekDrag
    if ($null -eq $d -or [string]$d.Card.Tag['id'] -ne [string]$Card.Tag['id']) { return }
    $dx = $Pos.X - [double]$d.StartX
    $dy = $Pos.Y - [double]$d.StartY
    $snapPx = 15.0 / 60.0 * [double]$script:HourHeight
    if ($d.Phase -eq 'resize-top') {
        $newTop = [double]$d.Top + [math]::Round($dy / $snapPx) * $snapPx
        $maxTop = [double]$d.Top + [double]$d.Height - 19.0
        if ($newTop -lt 0.0) { $newTop = 0.0 }
        if ($newTop -gt $maxTop) { $newTop = $maxTop }
        [System.Windows.Controls.Canvas]::SetTop($Card, $newTop)
        $Card.Height = ([double]$d.Top + [double]$d.Height) - $newTop
        $newStart = [int]$d.StartMin + (Get-WeekSnapMinutes ($newTop - [double]$d.Top))
        if ($newStart -gt ([int]$d.EndMin - 15)) { $newStart = [int]$d.EndMin - 15 }
        if ($newStart -lt 0) { $newStart = 0 }
        Set-WeekDragTimeText $d $newStart ([int]$d.EndMin)
        Set-WeekGuide $d $newTop (Min-To-HHMM $newStart)
        $Card.Cursor = [System.Windows.Input.Cursors]::SizeNS
    } elseif ($d.Phase -eq 'resize-bottom') {
        $newH = [double]$d.Height + [math]::Round($dy / $snapPx) * $snapPx
        $maxH = (([double]$script:WeekEndHour - [double]$script:WeekStartHour) * [double]$script:HourHeight) - [double]$d.Top
        if ($newH -lt 19.0) { $newH = 19.0 }
        if ($newH -gt $maxH) { $newH = $maxH }
        $Card.Height = $newH
        $newEnd = [int]$d.EndMin + (Get-WeekSnapMinutes ($newH - [double]$d.Height))
        if ($newEnd -lt ([int]$d.StartMin + 15)) { $newEnd = [int]$d.StartMin + 15 }
        if ($newEnd -gt 1439) { $newEnd = 1439 }
        Set-WeekDragTimeText $d ([int]$d.StartMin) $newEnd
        Set-WeekGuide $d ([double]($d.Top + $newH)) (Min-To-HHMM $newEnd)
        $Card.Cursor = [System.Windows.Input.Cursors]::SizeNS
    } else {
        $newLeft = [double]$d.Left + $dx
        $newTop = [double]$d.Top + [math]::Round($dy / $snapPx) * $snapPx
        $maxLeft = [double]$script:WeekOverlay.ActualWidth - [double]$d.Width - 3.0
        if ($newLeft -lt 3.0) { $newLeft = 3.0 }
        if ($newLeft -gt $maxLeft) { $newLeft = $maxLeft }
        $maxTop = (([double]$script:WeekEndHour - [double]$script:WeekStartHour) * [double]$script:HourHeight) - [double]$d.Height
        if ($newTop -lt 0.0) { $newTop = 0.0 }
        if ($newTop -gt $maxTop) { $newTop = $maxTop }
        [System.Windows.Controls.Canvas]::SetLeft($Card, $newLeft)
        [System.Windows.Controls.Canvas]::SetTop($Card, $newTop)
        $newStart = [int]$d.StartMin + (Get-WeekSnapMinutes ($newTop - [double]$d.Top))
        $duration = [int]$d.EndMin - [int]$d.StartMin
        if ($newStart -lt 0) { $newStart = 0 }
        if ($newStart -gt (1439 - $duration)) { $newStart = 1439 - $duration }
        Set-WeekDragTimeText $d $newStart ($newStart + $duration)
        Set-WeekGuide $d $newTop (Min-To-HHMM $newStart)
        $Card.Cursor = [System.Windows.Input.Cursors]::SizeAll
    }
}

function Finish-WeekDrag {
    param($Card, [System.Windows.Point]$Pos)
    $d = $script:WeekDrag
    if ($null -eq $d -or [string]$d.Card.Tag['id'] -ne [string]$Card.Tag['id']) { return }
    $dx = $Pos.X - [double]$d.StartX
    $dy = $Pos.Y - [double]$d.StartY
    if ([math]::Abs($dx) -lt 2.0 -and [math]::Abs($dy) -lt 2.0) {
        Remove-WeekGuide $d
        $script:WeekDrag = $null
        try { $Card.ReleaseMouseCapture() } catch { }
        return
    }
    $deltaMin = Get-WeekSnapMinutes $dy
    # 落值必须和拖动时的视觉钳制一致：卡片位置被钳在轴内（[0, 轴高-块高]），
    # 时间也只能落在所选时段内。少了这对钳制，把卡片拖到轴顶之上会写成
    # 08:00 之前的时间 —— 在"只显示 8:00-20:00"的时段里，这条日程会当场消失。
    $rangeMin = [int]$script:WeekStartHour * 60
    $rangeMax = [int]$script:WeekEndHour * 60
    $ev = $d.Event
    # 第七轮（第六轮第二十七节第 1 条）：把"拖动改时间"纳入撤销栈。
    #   必须在**任何时间字段被改写之前**存快照；存改后就没有"改前时间"可回了。
    #   只在真的发生了位移时才压栈（上面已提前 return 掉"没动"的情况）。
    #   Copy-Record 而不是直接存引用：否则快照会跟着 $ev 一起变，撤销成了空操作。
    #   也不能用 .Clone()：数据由 ConvertFrom-Json 反序列化而来，PSCustomObject 没有该方法。
    try {
        Push-Undo -Kind 'drag-event' -Id ([string]$ev.id) -Snapshot (Copy-Record $ev) -Label ([string]$ev.title)
    } catch { Write-ErrLog ('Push-Undo drag-event: ' + $_.Exception.Message) }
    if ($d.Phase -eq 'resize-top') {
        $newStart = [int]$d.StartMin + $deltaMin
        if ($newStart -lt $rangeMin) { $newStart = $rangeMin }
        if ($newStart -gt ([int]$d.EndMin - 15)) { $newStart = [int]$d.EndMin - 15 }
        $ev.start = $newStart
    } elseif ($d.Phase -eq 'resize-bottom') {
        $newEnd = [int]$d.EndMin + $deltaMin
        if ($newEnd -lt ([int]$d.StartMin + 15)) { $newEnd = [int]$d.StartMin + 15 }
        if ($newEnd -gt $rangeMax) { $newEnd = $rangeMax }
        if ($newEnd -gt 1439) { $newEnd = 1439 }
        $ev.end = $newEnd
    } else {
        $duration = [int]$d.EndMin - [int]$d.StartMin
        $newStart = [int]$d.StartMin + $deltaMin
        if ($newStart -lt $rangeMin) { $newStart = $rangeMin }
        if ($newStart -gt ($rangeMax - $duration)) { $newStart = $rangeMax - $duration }
        if ($newStart -gt (1439 - $duration)) { $newStart = 1439 - $duration }
        $colShift = 0
        if ([double]$d.ColW -gt 0) { $colShift = [int][math]::Round($dx / [double]$d.ColW) }
        $newCol = [int]$d.Col + $colShift
        if ($newCol -lt 0) { $newCol = 0 }
        if ($newCol -gt 6) { $newCol = 6 }
        if ($newCol -ne [int]$d.Col) {
            $weekStart = Start-Of-Week $script:Anchor
            $ev.date = Fmt-Date ($weekStart.AddDays($newCol))
        }
        $ev.start = $newStart
        $ev.end = $newStart + $duration
    }
    try { $Card.ReleaseMouseCapture() } catch { }
    $script:WeekDrag = $null
    Save-Data
    Refresh-All
}

# ---------------------------------------------------------------------------
#  列表视图
# ---------------------------------------------------------------------------
function Render-List {
    $shell = New-Bd -Bg (Get-Pal 'Card') -Border (Get-Pal 'Border') -Radius 8
    $outer = New-Object System.Windows.Controls.Grid
    # 单列。任务面板已搬到侧栏 Tasks 按钮对应的独立视图（Render-Tasks）：
    # 侧栏那个 Tasks 按钮以前点了只是跳回本页，等于没有自己的位置。
    # 拆开之后列表页整宽显示"时间流"，长标题不再被 316px 的侧栏挤着。
    $cd1 = New-Object System.Windows.Controls.ColumnDefinition
    $cd1.Width = [System.Windows.GridLength]::new(1, 'Star')
    $outer.ColumnDefinitions.Add($cd1)

    # --- 左：事件流 ---
    $left = New-Object System.Windows.Controls.DockPanel
    $filter = New-Object System.Windows.Controls.Border
    $filter.Background = Brush (Get-Pal 'CardAlt')
    $filter.BorderBrush = Brush (Get-Pal 'BorderSoft')
    $filter.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 2)
    $fp = New-Object System.Windows.Controls.WrapPanel
    # 用 WrapPanel 而不是横向 StackPanel：窗口压窄时，第三个下拉会换到第二行，
    # 而不是被右边界裁掉（旧版 820 宽时"All tasks"只剩半截）。
    $fp.Margin = [System.Windows.Thickness]::new(9, 8, 9, 8)
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Width = 190
    $tb.Height = 27
    $tb.FontSize = 12
    $tb.Text = ''
    $tb.ToolTip = '搜索日程标题'
    $tb.VerticalContentAlignment = 'Center'
    $tb.Background = Brush (Get-Pal 'Card')
    $tb.Foreground = Brush (Get-Pal 'Ink')
    $tb.BorderBrush = Brush (Get-Pal 'Border')
    $tb.BorderThickness = [System.Windows.Thickness]::new(2)
    $tb.Padding = [System.Windows.Thickness]::new(6, 0, 6, 0)
    $script:ListSearch = $tb
    $hintL = New-SearchHint -Box $tb -Text '搜索日程标题…'
    $script:ListSearchHint = $hintL.Hint
    [void]$fp.Children.Add($hintL.Wrap)

    $cbo = New-Object System.Windows.Controls.ComboBox
    $cbo.Width = 104; $cbo.Height = 27; $cbo.FontSize = 11
    $cbo.Margin = [System.Windows.Thickness]::new(7, 0, 0, 0)
    foreach ($it in @(
        [pscustomobject]@{ Tag='all';   Text='All tags' },
        [pscustomobject]@{ Tag='work';  Text='Work' },
        [pscustomobject]@{ Tag='focus'; Text='Focus' },
        [pscustomobject]@{ Tag='life';  Text='Life' })) {
        $ci = New-Object System.Windows.Controls.ComboBoxItem
        $ci.Tag = $it.Tag; $ci.Content = $it.Text
        [void]$cbo.Items.Add($ci)
    }
    $cbo.SelectedIndex = 0
    $script:ListTagBox = $cbo
    [void]$fp.Children.Add($cbo)

    $cbo2 = New-Object System.Windows.Controls.ComboBox
    $cbo2.Width = 108; $cbo2.Height = 27; $cbo2.FontSize = 11
    $cbo2.Margin = [System.Windows.Thickness]::new(7, 0, 0, 0)
    foreach ($it in @(
        [pscustomobject]@{ Tag='all';      Text='All tasks' },
        [pscustomobject]@{ Tag='today';    Text='Today' },
        [pscustomobject]@{ Tag='week';     Text='This week' },
        [pscustomobject]@{ Tag='overdue';  Text='Overdue' },
        [pscustomobject]@{ Tag='nodate';   Text='No date' })) {
        $ci = New-Object System.Windows.Controls.ComboBoxItem
        $ci.Tag = $it.Tag; $ci.Content = $it.Text
        [void]$cbo2.Items.Add($ci)
    }
    $cbo2.SelectedIndex = 0
    $script:ListScopeBox = $cbo2
    [void]$fp.Children.Add($cbo2)

    $filter.Child = $fp
    [System.Windows.Controls.DockPanel]::SetDock($filter, 'Top')
    [void]$left.Children.Add($filter)

    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sv.HorizontalScrollBarVisibility = 'Disabled'
    $stack = New-Object System.Windows.Controls.StackPanel
    $sv.Content = $stack
    $script:ListStack = $stack
    [void]$left.Children.Add($sv)

    $leftBd = New-Object System.Windows.Controls.Border
    $leftBd.Child = $left
    [System.Windows.Controls.Grid]::SetColumn($leftBd, 0)
    [void]$outer.Children.Add($leftBd)

    $shell.Child = $outer
    return $shell
}

function Fill-ListRows {
    if ($null -eq $script:ListStack) { return }
    $script:ListStack.Children.Clear()

    $q = ''
    if ($null -ne $script:ListSearch) { $q = ([string]$script:ListSearch.Text).Trim().ToLower() }
    $tagF = 'all'
    if ($null -ne $script:ListTagBox -and $script:ListTagBox.SelectedItem) {
        $tagF = [string]$script:ListTagBox.SelectedItem.Tag
    }
    $scope = 'all'
    if ($null -ne $script:ListScopeBox -and $script:ListScopeBox.SelectedItem) {
        $scope = [string]$script:ListScopeBox.SelectedItem.Tag
    }

    if ($scope -eq 'week') {
        $weekStart = Start-Of-Week $script:Anchor
        $list = @(Occurrences-Between $weekStart $weekStart.AddDays(6))
    } elseif ($scope -eq 'month') {
        $monthStart = [datetime]::new($script:Anchor.Year, $script:Anchor.Month, 1)
        $monthEnd = $monthStart.AddMonths(1).AddDays(-1)
        $list = @(Occurrences-Between $monthStart $monthEnd)
    } else {
        $list = @($script:Events | Where-Object { ([string]$_.repeat -eq '' -or [string]$_.repeat -eq 'none') })
        $repeatItems = @(Occurrences-Between $script:Anchor.AddMonths(-3) $script:Anchor.AddMonths(6) |
            Where-Object { [string]$_.repeat -ne 'none' })
        $list = @($list + $repeatItems)
    }
    if ($q) { $list = @($list | Where-Object { ([string]$_.title).ToLower().Contains($q) }) }
    if ($tagF -ne 'all') { $list = @($list | Where-Object { [string]$_.tag -eq $tagF }) }
    $list = @($list | Sort-Object -Property @{E={[string]$_.date}}, @{E={[int]$_.start}})

    if ($list.Count -eq 0) {
        # 第 5 条外观建议：空状态不能是纯空白（"看起来像界面坏了"）。
        # 分两种空：① 本来就没安排 → 给"新建日程"入口；
        #           ② 有安排但被筛选滤没了 → 给"清除筛选"，否则用户会以为日程丢了。
        $filtered = (-not [string]::IsNullOrWhiteSpace($q)) -or ($tagF -ne 'all')
        $wrap = New-Object System.Windows.Controls.StackPanel
        $wrap.HorizontalAlignment = 'Center'
        $wrap.Margin = [System.Windows.Thickness]::new(0, 34, 0, 0)
        $em = New-Txt -Text (Get-LangText $(if ($filtered) { 'empty.filtered' } else { 'empty.list' })) `
                      -Size 12 -Color (Get-Pal 'InkFaint')
        $em.HorizontalAlignment = 'Center'
        [void]$wrap.Children.Add($em)
        $cta = New-PixBtn -Text (Get-LangText $(if ($filtered) { 'empty.clear' } else { 'empty.cta' })) `
                          -Bg (Get-Pal 'CardAlt') -Fg (Get-Pal 'Ink') -H 30 -FontSize 12 `
                          -Radius 7 -BorderCol (Get-Pal 'Border')
        $cta.HorizontalAlignment = 'Center'
        $cta.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
        if ($filtered) {
            $cta.Add_Click({
                try {
                    if ($null -ne $script:ListSearch) { $script:ListSearch.Text = '' }
                    if ($null -ne $script:ListTagBox) { $script:ListTagBox.SelectedIndex = 0 }
                    Fill-ListRows
                } catch { Write-ErrLog ('Empty clear filter: ' + $_.Exception.Message) }
            })
        } else {
            $cta.Add_Click({
                try {
                    $d = [datetime]::Today
                    if ($null -ne $script:Anchor) { $d = $script:Anchor }
                    Open-EventEditor -Date $d
                } catch { Write-ErrLog ('Empty new event: ' + $_.Exception.Message) }
            })
        }
        [void]$wrap.Children.Add($cta)
        [void]$script:ListStack.Children.Add($wrap)
        return
    }

    $lastDate = ''
    foreach ($e in $list) {
        $dateKey = [string]$e.date
        if ($dateKey -ne $lastDate) {
            $lastDate = $dateKey
            $d = Parse-Date $dateKey
            $gb = New-Object System.Windows.Controls.Border
            $gb.Background = Brush (Get-Pal 'Weekend')
            $gb.BorderBrush = Brush (Get-Pal 'BorderSoft')
            $gb.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
            $gt = New-Txt -Text ('{0} · {1}月{2}日' -f $script:DowZh[([int]$d.DayOfWeek + 6) % 7], $d.Month, $d.Day) `
                          -Size 11 -Color (Get-Pal 'Border') -Weight 'Bold'
            $gt.Margin = [System.Windows.Thickness]::new(11, 5, 11, 5)
            $gb.Child = $gt
            [void]$script:ListStack.Children.Add($gb)
        }
        [void]$script:ListStack.Children.Add((New-ListRow $e))
    }
}

function New-ListRow {
    param($E)
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = [System.Windows.Thickness]::new(0)
    $row.Tag = @{ kind = 'event'; id = [string]$E.id }
    $row.Cursor = [System.Windows.Input.Cursors]::Hand
    for ($i = 0; $i -lt 3; $i++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        if ($i -eq 0) { $cd.Width = [System.Windows.GridLength]::new(96, 'Pixel') }
        elseif ($i -eq 1) { $cd.Width = [System.Windows.GridLength]::new(1, 'Star') }
        else { $cd.Width = [System.Windows.GridLength]::new(88, 'Pixel') }
        $row.ColumnDefinitions.Add($cd)
    }
    $tm = New-Txt -Text (('{0}-{1}' -f (Min-To-HHMM ([int]$E.start)), (Min-To-HHMM ([int]$E.end)))) `
                  -Size 11 -Color (Get-Pal 'InkSoft') -Weight 'Semi'
    $tm.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $tm.VerticalAlignment = 'Center'
    $tm.Margin = [System.Windows.Thickness]::new(11, 0, 0, 0)
    [System.Windows.Controls.Grid]::SetColumn($tm, 0)
    [void]$row.Children.Add($tm)

    $tt = New-Txt -Text ([string]$E.title) -Size 13 -Color (Get-Pal 'Ink') -Weight 'Semi'
    $tt.VerticalAlignment = 'Center'
    if ([bool]$E.done) { $tt.TextDecorations = [System.Windows.TextDecorations]::Strikethrough; $tt.Opacity = 0.6 }
    [System.Windows.Controls.Grid]::SetColumn($tt, 1)
    [void]$row.Children.Add($tt)

    $tag = [string]$E.tag
    $label = 'Life'
    if ($tag -eq 'work')  { $label = 'Work' }
    if ($tag -eq 'focus') { $label = 'Focus' }
    $tb = New-Bd -Bg (Get-Pal 'AccentFocus') -Radius 9 -Bw 1.5
    $tb.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2)
    $tb.HorizontalAlignment = 'Right'
    $tb.VerticalAlignment = 'Center'
    $tb.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
    $tb.Child = (New-Txt -Text $label -Size 10 -Color (Get-Pal 'TodayInk') -Weight 'Bold')
    [System.Windows.Controls.Grid]::SetColumn($tb, 2)
    [void]$row.Children.Add($tb)

    $wrap = New-Object System.Windows.Controls.Border
    $wrap.Padding = [System.Windows.Thickness]::new(0, 8, 0, 8)
    $wrap.BorderBrush = Brush (Get-Pal 'BorderSoft')
    $wrap.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
    $wrap.Child = $row
    $wrap.Tag = @{ kind = 'event'; id = [string]$E.id }
    $wrap.Cursor = [System.Windows.Input.Cursors]::Hand
    return $wrap
}

function New-SearchHint {
    # 给搜索框加"占位提示"。WPF 的 TextBox 到 .NET Framework 4.x 都没有原生 Placeholder，
    # 只有一个 Hint 属性（.NET Core 才有），所以用"底色铺在 wrapper 上 + 提示文字垫在
    # 输入框下面"的土办法顶替。三个必须注意的点，少一个就出毛病：
    #   ① 输入框自身必须变透明，否则它那层不透明底色会把提示整块盖住；
    #   ② 提示要 IsHitTestVisible=False，否则鼠标点在提示文字上时聚焦不到输入框；
    #   ③ 提示控件由调用方存到 $script: 上（StrictMode 下事件处理器看不到函数局部变量）。
    param([System.Windows.Controls.TextBox]$Box, [string]$Text = 'Search…')
    $ph = New-Txt -Text $Text -Size 12 -Color (Get-Pal 'InkFaint')
    $ph.IsHitTestVisible = $false
    $ph.VerticalAlignment = 'Center'
    $ph.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $wrap = New-Object System.Windows.Controls.Grid
    $wrap.Width = [double]$Box.Width
    $wrap.Height = [double]$Box.Height
    $wrap.Margin = $Box.Margin
    $wrap.Background = $Box.Background          # 底色挪到 wrapper 上
    $Box.Margin = [System.Windows.Thickness]::new(0)
    $Box.Background = [System.Windows.Media.Brushes]::Transparent
    $Box.HorizontalAlignment = 'Stretch'
    [void]$wrap.Children.Add($ph)               # 先加提示（在下层）
    [void]$wrap.Children.Add($Box)              # 后加输入框（上层，接收点击）
    return [pscustomobject]@{ Wrap = $wrap; Hint = $ph }
}

function Sync-SearchHint {
    # 输入框内容为空时显示占位提示，否则隐藏。纯空白也算"空"。
    # 单独抽出来是为了列表页与任务页共用一份可见性规则，不各写一遍。
    param([System.Windows.Controls.TextBox]$Box, [System.Windows.Controls.TextBlock]$Hint)
    if ($null -eq $Box -or $null -eq $Hint) { return }
    if ([string]::IsNullOrWhiteSpace([string]$Box.Text)) { $Hint.Visibility = 'Visible' }
    else { $Hint.Visibility = 'Collapsed' }
}

function New-TaskFilterCombo {
    # 任务视图工具栏上的筛选下拉。尺寸 / 字号 / 选项构造集中在这里，
    # 免得像旧版那样每个下拉各写一遍 Width/Height/FontSize（改一处忘一处就会歪）。
    param([string]$Name, [double]$Width, [object[]]$Options)
    $cbo = New-Object System.Windows.Controls.ComboBox
    $cbo.Name = $Name
    $cbo.Width = $Width; $cbo.Height = 28; $cbo.FontSize = 11
    foreach ($o in $Options) {
        $ci = New-Object System.Windows.Controls.ComboBoxItem
        $ci.Tag = [string]$o.Tag
        $ci.Content = [string]$o.Text
        [void]$cbo.Items.Add($ci)
    }
    $cbo.SelectedIndex = 0
    return $cbo
}

function Set-TaskPanelCollapsed {
    # 旧的"展开/收起任务侧栏"已经随任务面板一起退休：任务面板现在有自己的整页视图
    # （Render-Tasks），没有"折叠成 52px"这个状态了。函数保留成空壳，
    # 是因为换皮重建（Build-Window → Refresh-All）与旧审计脚本仍在调它，
    # 直接删掉会让"换了主题后任务列表没了"变成难查的静默问题。
    param([bool]$Collapsed)
    $script:TaskPanelCollapsed = $Collapsed
}

# ---------------------------------------------------------------------------
#  任务视图（侧栏 "Tasks" 按钮）
# ---------------------------------------------------------------------------
# 为什么单独开一个视图：侧栏那个 Tasks 按钮以前点了只是 Set-View 'list'，
# 而列表页只是"右边挂了个 316px 的小栏"，点了等于没反应。现在：
#   · 列表页＝时间流（整宽）
#   · 任务页＝任务（整宽，卡片宽版式，动作按钮独占最右一列）
# 功能按键也随之重排：搜索 / 项目 / 状态 / 时间范围 / 排序 五个筛选，
# 计数从"3 open"变成"3 open · 2 done · showing 4/5"（筛完能看出是过滤还是删了）。
function Render-Tasks {
    $script:TaskCardWide = $true
    $shell = New-Bd -Bg (Get-Pal 'Card') -Border (Get-Pal 'Border') -Radius 8
    $root = New-Object System.Windows.Controls.DockPanel

    # --- 头部：[计数] + [+New task]（第二行）---
    # 第七轮（item 4）：
    #   ① 删掉 "Tasks" 大标题 —— 左栏导航已经高亮了 Tasks，视图里再写一遍是重复信息，
    #      而且它跟下面的筛选栏挤在同一行，视觉上没起到"分节"的作用。
    #   ② "+ Add task" 改名为 "+New task"（与需求文案一致），并**挪到下一行**：
    #      原来它 Dock 在最右、与计数同一行，在窄窗下会和筛选栏抢宽度。
    #      现在头部是两行：第一行放计数（左对齐），第二行放新建按钮（左对齐）。
    $head = New-Object System.Windows.Controls.Border
    $head.Background = Brush (Get-Pal 'CardAlt')
    $head.BorderBrush = Brush (Get-Pal 'BorderSoft')
    $head.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 2)
    $hp = New-Object System.Windows.Controls.StackPanel
    $hp.Margin = [System.Windows.Thickness]::new(14, 10, 14, 10)

    $t2 = New-Txt -Text '' -Size 11 -Color (Get-Pal 'InkFaint')
    $t2.VerticalAlignment = 'Center'
    $script:TaskOpenText = $t2
    [void]$hp.Children.Add($t2)

    $bAdd = New-PixBtn -Text '+New task' -Bg (Get-Pal 'AccentTask') -Fg (Get-Pal 'Ink') -W 96 -H 30 -FontSize 10
    $bAdd.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    $bAdd.HorizontalAlignment = 'Left'
    $script:TaskAddButton = $bAdd
    $bAdd.Add_Click({ try { Open-TaskEditor } catch { Write-ErrLog ('Add task: ' + $_.Exception.Message) } })
    [void]$hp.Children.Add($bAdd)

    $head.Child = $hp
    [System.Windows.Controls.DockPanel]::SetDock($head, 'Top')
    [void]$root.Children.Add($head)

    # --- 工具栏：五个筛选 ---
    # 用 WrapPanel：820px 窄窗下这一排会折到第二行，而不是被右边界裁掉
    # （列表页的筛选栏就是踩了这个坑才从 StackPanel 换成 WrapPanel）。
    $bar = New-Object System.Windows.Controls.Border
    $bar.Background = Brush (Get-Pal 'CardAlt')
    $bar.BorderBrush = Brush (Get-Pal 'BorderSoft')
    $bar.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 2)
    $fp = New-Object System.Windows.Controls.WrapPanel
    $fp.Margin = [System.Windows.Thickness]::new(10, 8, 10, 8)

    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Width = 200; $tb.Height = 28; $tb.FontSize = 12
    $tb.ToolTip = 'Search task titles'
    $tb.VerticalContentAlignment = 'Center'
    $tb.Background = Brush (Get-Pal 'Card')
    $tb.Foreground = Brush (Get-Pal 'Ink')
    $tb.BorderBrush = Brush (Get-Pal 'Border')
    $tb.BorderThickness = [System.Windows.Thickness]::new(2)
    $tb.Padding = [System.Windows.Thickness]::new(6, 0, 6, 0)
    $script:TaskSearch = $tb
    $hint = New-SearchHint -Box $tb -Text 'Search task titles…'
    $script:TaskSearchHint = $hint.Hint
    [void]$fp.Children.Add($hint.Wrap)

    $projOpts = @([pscustomobject]@{ Tag = 'all'; Text = 'All projects' })
    foreach ($proj in @($script:Tasks | ForEach-Object { [string]$_.project } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)) {
        $projOpts += [pscustomobject]@{ Tag = $proj; Text = $proj }
    }
    $script:TaskProjectBox = New-TaskFilterCombo -Name 'TaskProjectBox' -Width 150 -Options $projOpts
    [void]$fp.Children.Add($script:TaskProjectBox)

    $script:TaskStatusBox = New-TaskFilterCombo -Name 'TaskStatusBox' -Width 108 -Options @(
        [pscustomobject]@{ Tag = 'all';  Text = 'All status' },
        [pscustomobject]@{ Tag = 'open'; Text = 'Open' },
        [pscustomobject]@{ Tag = 'done'; Text = 'Done' })
    [void]$fp.Children.Add($script:TaskStatusBox)

    $script:TaskScopeBox = New-TaskFilterCombo -Name 'TaskScopeBox' -Width 128 -Options @(
        [pscustomobject]@{ Tag = 'all';     Text = 'All dates' },
        [pscustomobject]@{ Tag = 'today';   Text = 'Today' },
        [pscustomobject]@{ Tag = 'week';    Text = 'This week' },
        [pscustomobject]@{ Tag = 'overdue'; Text = 'Overdue' },
        [pscustomobject]@{ Tag = 'nodate';  Text = 'No date' })
    [void]$fp.Children.Add($script:TaskScopeBox)

    $script:TaskSortBox = New-TaskFilterCombo -Name 'TaskSortBox' -Width 138 -Options @(
        [pscustomobject]@{ Tag = 'due';      Text = 'Sort: Due date' },
        [pscustomobject]@{ Tag = 'priority'; Text = 'Sort: Priority' },
        [pscustomobject]@{ Tag = 'title';    Text = 'Sort: Title' })
    [void]$fp.Children.Add($script:TaskSortBox)

    $bar.Child = $fp
    $script:TaskFilterRow = $bar
    [System.Windows.Controls.DockPanel]::SetDock($bar, 'Top')
    [void]$root.Children.Add($bar)

    # --- 卡片列表 ---
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sv.HorizontalScrollBarVisibility = 'Disabled'
    $stack = New-Object System.Windows.Controls.StackPanel
    $sv.Content = $stack
    $script:TaskScroll = $sv
    $script:TaskStack = $stack
    [void]$root.Children.Add($sv)

    $shell.Child = $root
    return $shell
}

function New-TaskChip {
    # 任务卡上的小胶囊（截止 / 项目 / 用时 / 子任务）。统一圆角、内边距、字号，
    # 免得每个 chip 各写一遍 Thickness —— 之前那版就是每处都手写，最后挤成一片。
    param([string]$Text, [string]$Bg, [string]$Fg = '', [string]$Border = '')
    if (-not $Fg) { $Fg = Get-Pal 'InkSoft' }
    if (-not $Border) { $Border = Get-Pal 'BorderSoft' }
    $b = New-Bd -Bg $Bg -Border $Border -Radius 4 -Bw 1
    $b.Padding = [System.Windows.Thickness]::new(5, 1, 5, 2)
    $b.Margin = [System.Windows.Thickness]::new(0, 0, 4, 3)
    $b.Child = (New-Txt -Text $Text -Size 9 -Color $Fg -Weight 'Semi')
    return $b
}

function Get-TaskField {
    # 任务对象上的"可选字段"一律走这里读。
    # 为什么：本程序开着 Set-StrictMode，任务对象有三个来源 —— 演示数据、从
    # schedule.json 反序列化、审计里临时造的探针 —— 字段集合并不完全一致（老数据、
    # 探针、以及将来新增字段都会缺）。直接写 $t.due，缺字段时抛出去的异常会一路
    # 冒到 Refresh-All，界面上就是"点了 Tasks 什么都没发生"，非常难查。
    param($Task, [string]$Name, $Default = $null)
    if ($null -eq $Task) { return $Default }
    try {
        if (@($Task.PSObject.Properties.Name) -contains $Name) {
            $v = $Task.$Name
            if ($null -ne $v) { return $v }
        }
    } catch { }
    return $Default
}

function Get-TaskDueKey {
    # 排序用的截止键：没截止的排到最后（'9999-99-99' 这个哨兵和排序逻辑是绑定的）
    param($Task)
    $d = [string](Get-TaskField $Task 'due' '')
    if ([string]::IsNullOrWhiteSpace($d)) { return '9999-99-99' }
    return $d
}

function Get-TaskRank {
    # 优先级排序键：高 0 / 中 1 / 低 2
    param($Task)
    $p = [string](Get-TaskField $Task 'priority' 'medium')
    if ($p -eq 'high') { return 0 }
    if ($p -eq 'low') { return 2 }
    return 1
}

function Test-TaskHasDue {
    param($Task)
    return (-not [string]::IsNullOrWhiteSpace([string](Get-TaskField $Task 'due' '')))
}

function Start-InlineTaskEdit {
    # 第八轮（第三十节第 6 条）：双击任务标题"原位改标题"，不弹编辑器。
    #
    # 为什么：改标题是任务列表里最高频的微调，为了它开一整个编辑窗口（七字段）很重。
    #   现在双击标题直接进入行内编辑框：Enter 提交 / Esc 取消 / 失焦提交。
    #   其它字段（截止、优先级、子任务）仍走原来的编辑窗口（双击卡片空白处）。
    #
    # 作用域铁律：本函数把要改的东西都挂 $script:（InlineTaskId / InlineTaskBox /
    #   InlineTaskText），因为 TextBox 的 KeyDown / LostFocus 处理器是 WPF 回调，
    #   触发时本函数作用域早没了。回调里只读 $script: 与事件源 $s。
    param($TitleBlock, [string]$Id)
    try {
        if ($null -eq $TitleBlock) { return }
        $tId = [string]$Id
        $orig = [string](Get-TaskField (@($script:Tasks | Where-Object { [string]$_.id -eq $tId })[0]) 'text' '')
        # 已有内联编辑框在用时先退出（幂等，防双击连点叠两个框）
        try { Stop-InlineTaskEdit $true } catch { }

        $grid = [System.Windows.Controls.Grid]::GetParent($TitleBlock)
        $col = [System.Windows.Controls.Grid]::GetColumn($TitleBlock)
        # 标题 TextBlock 隐藏，编辑框放在同一列
        $TitleBlock.Visibility = 'Collapsed'

        $tb = New-Object System.Windows.Controls.TextBox
        $tb.Text = $orig
        $tb.FontSize = (Scale-Ui 12)
        $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
        $tb.Padding = [System.Windows.Thickness]::new(3, 2, 3, 2)
        $tb.VerticalAlignment = 'Center'
        $tb.TextWrapping = 'Wrap'
        $tb.AcceptsReturn = $false
        $tb.BorderBrush = Brush (Get-Pal 'AccentFocus')
        $tb.BorderThickness = [System.Windows.Thickness]::new(1)
        $tb.Background = Brush (Get-Pal 'Card')
        $tb.Foreground = Brush (Get-Pal 'Ink')
        $tb.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
        [System.Windows.Controls.Grid]::SetColumn($tb, $col)
        [void]$grid.Children.Add($tb)

        # 挂状态，供回调读取
        $script:InlineTaskId   = $tId
        $script:InlineTaskText = $TitleBlock
        $script:InlineTaskBox  = $tb
        $tb.Tag = @{ kind = 'inline-task-edit'; id = $tId; orig = $orig }

        $tb.Add_KeyDown({
            param($s, $e)
            try {
                if ($e.Key -eq 'Enter') { $e.Handled = $true; Commit-InlineTaskEdit $s }
                elseif ($e.Key -eq 'Escape') { $e.Handled = $true; Stop-InlineTaskEdit $false }
            } catch { Write-ErrLog ('InlineTaskEdit key: ' + $_.Exception.Message) }
        })
        $tb.Add_LostFocus({
            param($s, $e)
            try { Commit-InlineTaskEdit $s } catch { }
        })

        $tb.Focus() | Out-Null
        $tb.SelectAll()
    } catch { Write-ErrLog ('Start-InlineTaskEdit: ' + $_.Exception.Message) }
}

function Commit-InlineTaskEdit {
    # 提交内联编辑：标题非空且与原文不同才写回（并进撤销栈）。
    param($Box)
    try {
        if ($null -eq $Box -or $null -eq $Box.Tag) { return }
        $tId = [string]$Box.Tag['id']
        $orig = [string]$Box.Tag['orig']
        $newText = [string]$Box.Text
        $isActive = ($null -ne $script:InlineTaskBox -and $script:InlineTaskBox -eq $Box)
        if (-not $isActive) { return }   # 已经处理过（幂等），避免 Enter 后又触发 LostFocus 重复提交
        Stop-InlineTaskEdit $false
        $newText = $newText.Trim()
        if ([string]::IsNullOrWhiteSpace($newText)) { return }   # 空标题不写回
        if ($newText -eq $orig) { return }                        # 没改不写回
        $hit = @($script:Tasks | Where-Object { [string]$_.id -eq $tId })
        if ($hit.Count -eq 0) { return }
        # 压撤销栈（改前整份快照）再改
        try {
            Push-Undo -Kind 'edit-task' -Id $tId -Snapshot (Copy-Record $hit[0]) -Label $newText
        } catch { Write-ErrLog ('InlineTaskEdit undo: ' + $_.Exception.Message) }
        $hit[0].text = $newText
        Save-Data
        Fill-Tasks
        Show-UndoActionToast -Kind 'edit-task' -LabelText 'undo.editTask' -Title $newText
    } catch { Write-ErrLog ('Commit-InlineTaskEdit: ' + $_.Exception.Message) }
}

function Stop-InlineTaskEdit {
    # 退出内联编辑：恢复标题 TextBlock、移除编辑框、清状态。
    #   $Commit：$true 时先把当前编辑框文本提交再清理（用于"另一个编辑要开始"时的让位）。
    param([bool]$Commit)
    try {
        if ($Commit -and $null -ne $script:InlineTaskBox) {
            Commit-InlineTaskEdit $script:InlineTaskBox
        }
        $box = $script:InlineTaskBox
        $tt  = $script:InlineTaskText
        $script:InlineTaskId   = $null
        $script:InlineTaskBox  = $null
        $script:InlineTaskText = $null
        if ($null -ne $tt) { $tt.Visibility = 'Visible' }
        if ($null -ne $box) {
            $grid = [System.Windows.Controls.Grid]::GetParent($box)
            if ($null -ne $grid) { try { $grid.Children.Remove($box) } catch { } }
        }
    } catch { Write-ErrLog ('Stop-InlineTaskEdit: ' + $_.Exception.Message) }
}

function Fill-Tasks {
    if ($null -eq $script:TaskStack) { return }
    # 这里**不**立刻 Clear：新卡片先全部建到一个本地列表里，等整轮渲染无异常地跑完，
    # 再一次性换上去（见函数末尾的 Swap）。
    # 为什么：以前是"先 Clear 再逐张 Add"，中间任何一张卡片抛异常都会留下一个
    # 空列表 —— 界面上就是"点一下任务，整列任务全没了"。这不是假想：
    # 双击展开面板里的 .GetNewClosure() 就是把 Get-Pal 打成 CommandNotFound、
    # 在 Clear 之后抛出去，用户看到的现象正是"双击没反应 + 整列任务消失"。
    # 换成原子替换后，最坏情况只是画面停留在上一帧（旧数据但可读），
    # 而不是一片空白 —— 崩溃点照旧进 errors.log。
    $built = New-Object System.Collections.ArrayList
    $tasks = @($script:Tasks)
    $total = $tasks.Count
    $openN = @($tasks | Where-Object { -not [bool]$_.done }).Count
    $doneN = $total - $openN

    # 筛选条件全部来自**任务视图自己的工具栏**。
    # 以前任务面板嵌在列表页右侧，范围筛选借的是列表页的 $script:ListScopeBox ——
    # 搬成独立视图后那个下拉属于"事件流"，再共用会出现"在任务页动了筛选，
    # 列表页的事件流也跟着变"这种互相改状态的问题。所以这里一律读 Task* 系列。
    $status = 'all'
    if ($null -ne $script:TaskStatusBox -and $null -ne $script:TaskStatusBox.SelectedItem) {
        $status = [string]$script:TaskStatusBox.SelectedItem.Tag
    }
    $sortKey = 'due'
    if ($null -ne $script:TaskSortBox -and $null -ne $script:TaskSortBox.SelectedItem) {
        $sortKey = [string]$script:TaskSortBox.SelectedItem.Tag
    }
    $scope = 'all'
    if ($null -ne $script:TaskScopeBox -and $null -ne $script:TaskScopeBox.SelectedItem) {
        $scope = [string]$script:TaskScopeBox.SelectedItem.Tag
    }
    $q = ''
    if ($null -ne $script:TaskSearch) { $q = ([string]$script:TaskSearch.Text).Trim().ToLower() }

    $today = [datetime]::Today
    $weekEnd = (Start-Of-Week $today).AddDays(6)
    if ($null -ne $script:TaskProjectBox -and $script:TaskProjectBox.SelectedIndex -gt 0) {
        $projectFilter = [string]$script:TaskProjectBox.SelectedItem
        $tasks = @($tasks | Where-Object { [string]$_.project -eq $projectFilter })
    }
    if ($status -eq 'open') {
        $tasks = @($tasks | Where-Object { -not [bool](Get-TaskField $_ 'done' $false) })
    } elseif ($status -eq 'done') {
        $tasks = @($tasks | Where-Object { [bool](Get-TaskField $_ 'done' $false) })
    }
    if ($scope -eq 'today') {
        $tasks = @($tasks | Where-Object { (Test-TaskHasDue $_) -and ((Parse-Date (Get-TaskDueKey $_)).Date -eq $today) })
    } elseif ($scope -eq 'week') {
        $tasks = @($tasks | Where-Object {
            if (-not (Test-TaskHasDue $_)) { return $false }
            $dd = (Parse-Date (Get-TaskDueKey $_)).Date
            return (($dd -ge $today) -and ($dd -le $weekEnd))
        })
    } elseif ($scope -eq 'overdue') {
        $tasks = @($tasks | Where-Object {
            if ([bool](Get-TaskField $_ 'done' $false)) { return $false }
            if (-not (Test-TaskHasDue $_)) { return $false }
            return ((Parse-Date (Get-TaskDueKey $_)).Date -lt $today)
        })
    } elseif ($scope -eq 'nodate') {
        $tasks = @($tasks | Where-Object { -not (Test-TaskHasDue $_) })
    }
    if (-not [string]::IsNullOrWhiteSpace($q)) {
        $tasks = @($tasks | Where-Object { ([string](Get-TaskField $_ 'text' '')).ToLower().Contains($q) })
    }
    # 排序：三种键都先按"未完成在前"，再按所选的键；键内都有稳定的兜底，
    # 免得同键元素顺序随排序算法抖动（否则列表每次刷新都在自己换位）。
    # 表达式一律用 $_（自动变量），**不要写 param($t)**：Sort-Object 的 -Property
    # 表达式是按"管道当前对象"给的，写成具名参数在混合风格的属性表里拿不到对象，
    # StrictMode 下会抛"找不到属性"。
    $sortOk = $true
    try {
        if ($sortKey -eq 'priority') {
            $tasks = @($tasks | Sort-Object -Property @{E={[bool](Get-TaskField $_ 'done' $false)}}, @{E={Get-TaskRank $_}}, @{E={Get-TaskDueKey $_}}, @{E={[string](Get-TaskField $_ 'text' '')}})
        } elseif ($sortKey -eq 'title') {
            $tasks = @($tasks | Sort-Object -Property @{E={[bool](Get-TaskField $_ 'done' $false)}}, @{E={[string](Get-TaskField $_ 'text' '')}}, @{E={Get-TaskDueKey $_}})
        } else {
            $tasks = @($tasks | Sort-Object -Property @{E={[bool](Get-TaskField $_ 'done' $false)}}, @{E={Get-TaskDueKey $_}}, @{E={Get-TaskRank $_}}, @{E={[string](Get-TaskField $_ 'text' '')}})
        }
    } catch {
        # 排序只是"更好看"，绝不该让整个任务页渲染不出来：异常会一路冒到 Refresh-All，
        # 界面上表现成"点了 Tasks 什么都没发生"。退回未排序，并把坏对象记进日志。
        $sortOk = $false
        $script:TaskSortFailed = $true
        Write-ErrLog ('Fill-Tasks sort: ' + $_.Exception.Message)
        foreach ($bad in @($tasks)) {
            $names = ''
            try { $names = (@($bad.PSObject.Properties.Name) -join '|') } catch { $names = '<no props>' }
            Write-ErrLog ('  task obj type=' + $(try { $bad.GetType().Name } catch { '?' }) + ' props=' + $names)
        }
    }

    if ($null -ne $script:TaskOpenText) {
        # 统计口径＝"全量"，筛选生效时再补一句"当前显示几条"，
        # 否则筛完之后光看"N open"会以为任务被删了。
        $txt = [string]$openN + ' open · ' + [string]$doneN + ' done'
        if ($tasks.Count -ne $total) { $txt += '  ·  showing ' + [string]$tasks.Count + '/' + [string]$total }
        $script:TaskOpenText.Text = $txt
    }

    if ($tasks.Count -eq 0) {
        $empty = New-Txt -Text 'No tasks match this filter.' -Size 11 -Color (Get-Pal 'InkFaint')
        $empty.HorizontalAlignment = 'Center'
        $empty.Margin = [System.Windows.Thickness]::new(12, 26, 12, 0)
        [void]$built.Add($empty)
        $script:TaskStack.Children.Clear()
        foreach ($c in $built) { [void]$script:TaskStack.Children.Add($c) }
        return
    }
    foreach ($t in $tasks) {
        # 卡片里所有字段都经 Get-TaskField 读（见上面的说明：缺字段会在 StrictMode 下抛，
        # 而抛在渲染中间就是"整个任务页空白"）。
        $tDue      = [string](Get-TaskField $t 'due' '')
        $tDone     = [bool](Get-TaskField $t 'done' $false)
        $tPriority = [string](Get-TaskField $t 'priority' 'medium')
        $tText     = [string](Get-TaskField $t 'text' '')
        $tId       = [string](Get-TaskField $t 'id' '')
        # 行内详情面板的展开态：只允许一张卡片处于展开态，展开的是哪张记在
        # $script:TaskExpandedId 里。第四轮起入口是卡片右端的 ▾/▸ 按钮（不再是双击）。
        # 为什么不做成"多张同时展开"：侧栏纵向空间很紧，展开面板本身就有 ~120px，
        # 多张一起开会把下面的任务全推出视野，反而找不回来。
        $expanded = (-not [string]::IsNullOrWhiteSpace($script:TaskExpandedId)) -and ($script:TaskExpandedId -eq $tId)
        $expCaret = '>'
        if ($expanded) { $expCaret = 'v' }
        # 任务卡改成"三行"结构。旧版把一份信息拆进 4 个列里：
        #   [24 勾选][* 正文][52 截止][104 两个按钮×两行]
        # 侧栏总宽只有 316，正文列被压到 ~136px，标题稍长就折成三行；
        # 右侧 104px 里还要塞 4 个按钮，只能摞两行，整块看着很碎。
        # 现在：
        #   第 1 行 复选框 + 正文（占满整宽 ≈ 265px）
        #   第 2 行 元信息芯片（截止 / 项目 / 用时 / 子任务，放不下会自动换行）
        #   第 3 行 操作按钮（Focus / +1 / Edit / Del，一行放得下）
        # 优先级只由左侧 4px 色条表达（红=高 / 橙=中 / 绿=低），不再重复写一遍文字。
        # 空间够宽时（独立 Tasks 视图＝整页宽）多开一列专门放动作按钮：
        # 标题因此拿到一整行的宽度，按钮也不再"贴在标题正下方"。
        $wide = [bool]$script:TaskCardWide
        $row = New-Object System.Windows.Controls.Grid
        $cdStrip = New-Object System.Windows.Controls.ColumnDefinition
        $cdStrip.Width = [System.Windows.GridLength]::new(4, 'Pixel')
        $row.ColumnDefinitions.Add($cdStrip)
        $cdBody = New-Object System.Windows.Controls.ColumnDefinition
        $cdBody.Width = [System.Windows.GridLength]::new(1, 'Star')
        $row.ColumnDefinitions.Add($cdBody)
        if ($wide) {
            $cdAct = New-Object System.Windows.Controls.ColumnDefinition
            $cdAct.Width = [System.Windows.GridLength]::new(0, 'Auto')
            $row.ColumnDefinitions.Add($cdAct)
        }

        $stripCol = Get-Pal 'AccentFocus'
        $stripTip = 'Medium priority'
        if ($tPriority -eq 'high') { $stripCol = Get-Pal 'AccentEvent'; $stripTip = 'High priority' }
        elseif ($tPriority -eq 'low') { $stripCol = Get-Pal 'AccentTask'; $stripTip = 'Low priority' }
        $strip = New-Object System.Windows.Controls.Border
        $strip.Width = 4; $strip.Background = Brush $stripCol
        $strip.HorizontalAlignment = 'Left'; $strip.VerticalAlignment = 'Stretch'
        $strip.ToolTip = $stripTip
        [System.Windows.Controls.Grid]::SetColumn($strip, 0)
        [void]$row.Children.Add($strip)

        $body = New-Object System.Windows.Controls.StackPanel
        $body.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
        [System.Windows.Controls.Grid]::SetColumn($body, 1)
        [void]$row.Children.Add($body)

        # ---- 第 1 行：复选框 + 正文 ----
        $head = New-Object System.Windows.Controls.Grid
        $hc0 = New-Object System.Windows.Controls.ColumnDefinition
        $hc0.Width = [System.Windows.GridLength]::new(22, 'Pixel')
        $head.ColumnDefinitions.Add($hc0)
        $hc1 = New-Object System.Windows.Controls.ColumnDefinition
        $hc1.Width = [System.Windows.GridLength]::new(1, 'Star')
        $head.ColumnDefinitions.Add($hc1)

        $box = New-Object System.Windows.Controls.Button
        $box.Width = 15; $box.Height = 15
        $box.Tag = @{ kind = 'task'; id = $tId }
        $box.Cursor = [System.Windows.Input.Cursors]::Hand
        $box.HorizontalAlignment = 'Left'
        $box.VerticalAlignment = 'Top'
        $box.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
        $boxBg = Get-Pal 'Card'
        if ($tDone) { $boxBg = Get-Pal 'AccentTaskD' }
        $box.Template = (Get-CheckTemplate $boxBg)
        # 方块要能被"看出来可以点"：15px 的小方块没有文字，光靠形状不够明显。
        # 提示文字随当前状态给"点下去会发生什么"，这是最容易理解的写法。
        if ($tDone) { $box.ToolTip = (Get-LangText 'tip.checkboxDone') }
        else { $box.ToolTip = (Get-LangText 'tip.checkbox') }
        [System.Windows.Controls.Grid]::SetColumn($box, 0)
        # 点方块 = 立刻勾选/取消勾选（不走 260ms 的"等双击"延迟）。
        #
        # 为什么要给方块单独的处理器（用户反馈"点击前面的方块无反应"）：
        #   卡片上所有点按都走 Attach-TaskClick / 卡片自己的 Up 处理器，而它们**开头就
        #   有一道 `Test-BtnTag` 过滤**：凡是点在 kind 属于
        #   ('task-edit','task-delete','task-focus','task-postpone') 的 Button 上就 `return`。
        #   方块的 Tag.kind 是 'task'（为了 Test-AncestorTag 能把它认成任务卡），
        #   于是它没被那道过滤拦住 —— 但真正致命的是下一步：
        #   `Test-AncestorTag` 从事件源往上走，**第一个带 kind 的祖先就是方块自己**
        #   （Tag 在方块身上，而它是 Button），返回 {kind='task'}，
        #   和"点在卡片空白处"的结果**完全一样** —— 没有任何代码能区分这两者。
        #   结果就是"点方块"要么被 260ms 延迟吞掉（用户以为没反应），要么被拖拽阈值影响。
        #
        #   修法：给方块挂自己的 Click，并且设 $e.Handled = $true 把路由截断，
        #   让外层那些 Up 处理器彻底收不到这次点击（否则会叠加成"勾一次又排一次待勾选"）。
        #   代价是失去"单击方块 + 双击卡片正文 = 只编辑不勾选"这个组合 ——
        #   但方块本来就是独立的勾选控件，点它就该勾，这是更符合直觉的语义。
        $box.Add_Click({
            param($s, $e)
            try {
                $e.Handled = $true
                # 点方块代表"明确要勾选"，先撤销那次等着变双击的待勾选，
                # 免得落地成"勾了又被勾回去"的抖动。
                Cancel-PendingTaskToggle
                Toggle-TaskDone -Id ([string]$s.Tag['id'])
            } catch { Write-ErrLog ('Task checkbox: ' + $_.Exception.Message) }
        })
        [void]$head.Children.Add($box)

        $tt = New-Txt -Text $tText -Size 12 -Color (Get-Pal 'Ink')
        $tt.TextWrapping = 'Wrap'
        $tt.VerticalAlignment = 'Center'
        $tt.Tag = @{ kind = 'task-title'; id = $tId }
        if ($tDone) { $tt.TextDecorations = [System.Windows.TextDecorations]::Strikethrough; $tt.Opacity = 0.55 }
        [System.Windows.Controls.Grid]::SetColumn($tt, 1)
        # 第八轮（第三十节第 6 条）：双击标题 = 原位改标题（内联编辑），
        #   双击卡片其它空白处仍是打开完整编辑窗口。这里在 Up 事件上拦双击，
        #   并 $e.Handled = $true 截断路由，让外层 $wrap 的"双击开窗"别叠加触发。
        $tt.Add_MouseLeftButtonUp({
            param($s, $e)
            try {
                if ((Get-MouseClickCount $e) -lt 2) { return }
                $e.Handled = $true
                $hitId = [string]$s.Tag['id']
                Start-InlineTaskEdit $s $hitId
            } catch { Write-ErrLog ('Task title dblclick: ' + $_.Exception.Message) }
        })
        [void]$head.Children.Add($tt)
        [void]$body.Children.Add($head)

        # ---- 第 2 行：元信息芯片 ----
        $proj = [string](Get-TaskField $t 'project' '')
        $est = [int](Get-TaskField $t 'estimatedMin' 0)
        $actMin = [int](Get-TaskField $t 'actualMin' 0)

        $metaRow = New-Object System.Windows.Controls.WrapPanel
        $metaRow.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)

        # 截止：今天 / 逾期要能一眼看出来，所以用强调色底而不是灰字
        if (-not [string]::IsNullOrWhiteSpace($tDue)) {
            $dueTxt = $tDue.Substring(5)
            $dueBg = Get-Pal 'CardAlt'; $dueFg = Get-Pal 'InkSoft'
            if ($tDone) {
                $dueTxt = 'Done · ' + $dueTxt; $dueFg = Get-Pal 'InkFaint'
            } elseif ($tDue -eq (Fmt-Date ([datetime]::Today))) {
                $dueTxt = 'Today'; $dueBg = Get-Pal 'AccentFocus'; $dueFg = Get-Pal 'TodayInk'
            } elseif ((Parse-Date $tDue).Date -lt [datetime]::Today) {
                $dueTxt = 'Overdue · ' + $dueTxt; $dueBg = Get-Pal 'AccentEvent'; $dueFg = Get-Pal 'OnAccent'
            }
            $dueTime = [string](Get-TaskField $t 'dueTime' '')
            if (-not [string]::IsNullOrWhiteSpace($dueTime)) { $dueTxt += ' ' + $dueTime }
            [void]$metaRow.Children.Add((New-TaskChip -Text $dueTxt -Bg $dueBg -Fg $dueFg))
        }
        if (-not [string]::IsNullOrWhiteSpace($proj)) {
            $projChip = New-TaskChip -Text $proj -Bg (Get-Pal 'Card') -Fg (Get-Pal 'InkSoft')
            $projChip.Tag = $proj
            $projChip.Cursor = [System.Windows.Input.Cursors]::Hand
            $projChip.ToolTip = 'Filter by this project'
            $projChip.Add_MouseLeftButtonUp({
                param($s,$e)
                try {
                    for ($i=0; $i -lt $script:TaskProjectBox.Items.Count; $i++) {
                        if ([string]$script:TaskProjectBox.Items[$i] -eq [string]$s.Tag) { $script:TaskProjectBox.SelectedIndex = $i; break }
                    }
                    Fill-Tasks; $e.Handled = $true
                } catch { }
            })
            [void]$metaRow.Children.Add($projChip)
        }
        if ($est -gt 0 -or $actMin -gt 0) {
            [void]$metaRow.Children.Add((New-TaskChip -Text ('Time ' + [string]$actMin + '/' + [string]$est + 'm') -Bg (Get-Pal 'CardAlt')))
        }
        $subDone = 0; $subTotal = 0
        if ($t.PSObject.Properties.Name -contains 'subtasks' -and $null -ne $t.subtasks) {
            $subTotal = @($t.subtasks).Count
            $subDone = @($t.subtasks | Where-Object { [bool](Get-TaskField $_ 'done' $false) }).Count
        }
        if ($subTotal -gt 0) {
            [void]$metaRow.Children.Add((New-TaskChip -Text ('Sub ' + [string]$subDone + '/' + [string]$subTotal) -Bg (Get-Pal 'CardAlt')))
        }
        if ($metaRow.Children.Count -gt 0) { [void]$body.Children.Add($metaRow) }

        # ---- 第 3 行：动作区 ----
        # 第三轮改动（用户报"双击 task 没有唤醒修改菜单"）：
        #   以前 Edit / Del 直接摆在这行里，双击卡片没有任何反应。
        #   现在把 Edit / Del 收进"双击才展开"的行内详情面板，这行只留两个高频轻动作：
        #     Focus（开始专注）、+1（顺延一天）
        #   为什么不干脆一个都不留：Focus 是番茄钟的入口、+1 是拖延场景里点得最勤的一个，
        #   每次都要双击展开再点会明显变慢；而 Edit / Del 是低频且带破坏性的，
        #   藏进详情面板反而更安全（多一步确认感）。
        $actRow = New-Object System.Windows.Controls.StackPanel
        $actRow.Orientation = 'Horizontal'
        $actRow.HorizontalAlignment = 'Right'
        $actRow.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
        $bFocus = New-PixBtn -Text 'Focus' -Bg (Get-Pal 'AccentFocus') -Fg (Get-Pal 'TodayInk') -W 48 -H 23 -FontSize 8
        $bPost = New-PixBtn -Text '+1' -Bg (Get-Pal 'Card') -Fg (Get-Pal 'Ink') -W 38 -H 23 -FontSize 8
        $bFocus.Tag = @{ kind = 'task-focus'; id = $tId }
        $bPost.Tag = @{ kind = 'task-postpone'; id = $tId }
        $bFocus.Margin = [System.Windows.Thickness]::new(0, 0, 4, 0)
        $bFocus.ToolTip = 'Start focus for this task'
        $bPost.ToolTip = 'Postpone one day'
        $bFocus.Add_Click({ param($s,$e) try { Start-FocusForTask -Id ([string]$s.Tag['id']); $e.Handled = $true } catch { Write-ErrLog ('Focus task: ' + $_.Exception.Message) } })
        $bPost.Add_Click({ param($s,$e) try { Postpone-Task -Id ([string]$s.Tag['id']); $e.Handled = $true } catch { Write-ErrLog ('Postpone task: ' + $_.Exception.Message) } })
        [void]$actRow.Children.Add($bFocus)
        [void]$actRow.Children.Add($bPost)
        # 展开指示器（▾/▸）：第四轮起它不再只是"装饰 + 暗示双击"，
        # 而是一个**真正可点的按钮** —— 双击卡片现在去开编辑窗口了，
        # 行内详情面板必须另有一个显式入口，否则这个能力就变成"没人知道怎么用"。
        # 用 New-PixBtn 而不是 TextBlock：需要一个真正的可点命中区（8px 高的文字
        # 命中区太小，在卡片右边缘几乎点不到），而且按钮能自带 hover/按下反馈。
        $caret = New-PixBtn -Text $expCaret -Bg (Get-Pal 'Card') -Fg (Get-Pal 'InkFaint') -W 24 -H 23 -FontSize 9
        $caret.Tag = @{ kind = 'task-expand'; id = $tId }
        $caret.Margin = [System.Windows.Thickness]::new(4, 0, 0, 0)
        $caret.ToolTip = $(if ($expanded) { 'Hide details' } else { 'Show details' })
        $caret.Add_Click({
            param($s,$e)
            try {
                if ($null -eq $s.Tag) { return }
                $hitId = [string]$s.Tag['id']
                if ($script:TaskExpandedId -eq $hitId) { $script:TaskExpandedId = '' } else { $script:TaskExpandedId = $hitId }
                Fill-Tasks
                $e.Handled = $true
            } catch { Write-ErrLog ('Task expand: ' + $_.Exception.Message) }
        })
        [void]$actRow.Children.Add($caret)
        [void]$body.Children.Add($actRow)

        # ---- 行内详情面板（由卡片上的 ▾/▸ 按钮展开）：完整字段 + Edit / Del ----
        # 为什么把 Edit / Del 放这里而不是继续留在卡片上：
        #   用户在窄侧栏里点这两个按钮的误触率不低（Del 紧挨着 Edit），而它们本身是
        #   低频动作。收进"要显式展开才出现"的面板之后，既给删除动作加了一层护栏，
        #   也让卡片主行保持干净（只留 Focus / +1 / ▾）。
        # 为什么字段要在这里重复一遍（卡片上已经有芯片）：芯片为了省地方用了缩写
        #   （'09-30' / 'Time 25/60m' / 'Sub 1/3'），而展开面板是"我要看清楚"的场景，
        #   必须给全量原文。
        if ($expanded) {
            $detail = New-Object System.Windows.Controls.StackPanel
            $detail.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
            $detailBg = New-Bd -Bg (Get-Pal 'CardAlt') -Border (Get-Pal 'BorderSoft') -Radius 6
            $detailBg.Padding = [System.Windows.Thickness]::new(8, 7, 8, 7)
            $detailBg.Child = $detail

            # ⚠ 千万不要在这里写 .GetNewClosure()。
            #   GetNewClosure() 会把脚本块**复制进一个新的动态模块**，而动态模块的函数表
            #   只有 global 作用域 —— 本文件/主脚本作用域里的函数（Get-Pal / New-Txt）
            #   在那个模块里一律 CommandNotFoundException。症状极隐蔽：
            #     · 未展开时走不到这段，一切正常；只有双击展开才炸；
            #     · 抛出点又在 Fill-Tasks 的 Children.Clear() 之后，
            #       于是任务列被清空、又没重建回来 —— 界面表现就是
            #       "双击没反应，而且整列任务都消失了"（用户报的原话正是这个）。
            #   $addLine 只在本作用域里被同步 & 调用（下面几行），
            #   普通脚本块本来就能读到外层的 $detail / $ln，不需要闭包。
            $addLine = {
                param($Label, $Value)
                if ([string]::IsNullOrWhiteSpace([string]$Value)) { return }
                $ln = New-Object System.Windows.Controls.StackPanel
                $ln.Orientation = 'Horizontal'
                $ln.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
                $k = New-Txt -Text ([string]$Label) -Size 9 -Color (Get-Pal 'InkFaint')
                $k.Width = 66
                [void]$ln.Children.Add($k)
                $v = New-Txt -Text ([string]$Value) -Size 10 -Color (Get-Pal 'Ink')
                $v.TextWrapping = 'Wrap'
                $v.MaxWidth = 240
                [void]$ln.Children.Add($v)
                [void]$detail.Children.Add($ln)
            }

            $prioText = 'Medium'
            if ($tPriority -eq 'high') { $prioText = 'High' }
            elseif ($tPriority -eq 'low') { $prioText = 'Low' }
            & $addLine 'Title' $tText
            & $addLine 'Due' $tDue
            & $addLine 'Priority' $prioText
            & $addLine 'Project' $proj
            & $addLine 'Estimate' $(if ($est -gt 0) { [string]$est + ' min' } else { '' })
            & $addLine 'Logged' $(if ($actMin -gt 0) { [string]$actMin + ' min' } else { '' })
            $remMin = [int](Get-TaskField $t 'reminderMin' 0)
            & $addLine 'Reminder' $(if ($remMin -gt 0) { [string]$remMin + ' min before' } else { '' })
            $tagVal = [string](Get-TaskField $t 'tag' '')
            & $addLine 'Tag' $tagVal

            # 子任务：展开面板里直接可勾，省得再开编辑窗口
            if ($subTotal -gt 0) {
                $subTitle = New-Txt -Text ('Subtasks ' + [string]$subDone + '/' + [string]$subTotal) -Size 9 -Color (Get-Pal 'InkFaint')
                $subTitle.Margin = [System.Windows.Thickness]::new(0, 5, 0, 2)
                [void]$detail.Children.Add($subTitle)
                foreach ($st in @($t.subtasks)) {
                    if ($null -eq $st) { continue }
                    $stText = [string](Get-TaskField $st 'text' '')
                    if ([string]::IsNullOrWhiteSpace($stText)) { continue }
                    $stDone = [bool](Get-TaskField $st 'done' $false)
                    $sr = New-Object System.Windows.Controls.StackPanel
                    $sr.Orientation = 'Horizontal'
                    $mark = New-Txt -Text $(if ($stDone) { '[x]' } else { '[ ]' }) -Size 10 -Color (Get-Pal 'InkSoft')
                    $mark.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
                    [void]$sr.Children.Add($mark)
                    $sx = New-Txt -Text $stText -Size 10 -Color (Get-Pal 'Ink')
                    $sx.Margin = [System.Windows.Thickness]::new(5, 0, 0, 0)
                    $sx.TextWrapping = 'Wrap'
                    $sx.MaxWidth = 226
                    if ($stDone) { $sx.TextDecorations = [System.Windows.TextDecorations]::Strikethrough; $sx.Opacity = 0.6 }
                    [void]$sr.Children.Add($sx)
                    [void]$detail.Children.Add($sr)
                }
            }

            $btnRow2 = New-Object System.Windows.Controls.StackPanel
            $btnRow2.Orientation = 'Horizontal'
            $btnRow2.HorizontalAlignment = 'Right'
            $btnRow2.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
            $bEdit2 = New-PixBtn -Text 'Edit' -Bg (Get-Pal 'AccentFocus') -Fg (Get-Pal 'TodayInk') -W 58 -H 26 -FontSize 10
            $bDel2 = New-PixBtn -Text 'Delete' -Bg (Get-Pal 'Weekend') -Fg (Get-Pal 'AccentEvent') -W 62 -H 26 -FontSize 10
            $bEdit2.Tag = @{ kind = 'task-edit'; id = $tId }
            $bDel2.Tag = @{ kind = 'task-delete'; id = $tId }
            $bDel2.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
            $bEdit2.ToolTip = 'Edit task'
            $bDel2.ToolTip = 'Delete task'
            $bEdit2.Add_Click({
                param($s,$e)
                try {
                    # 先收面板再开编辑窗：编辑窗是全屏模态，留着展开态会让用户回来时
                    # 看到一张"不知道为什么开着"的卡片。
                    $script:TaskExpandedId = ''
                    Open-TaskEditor -Id ([string]$s.Tag['id'])
                    $e.Handled = $true
                } catch { Write-ErrLog ('Edit task: ' + $_.Exception.Message) }
            })
            $bDel2.Add_Click({ param($s,$e) try { Remove-Task -Id ([string]$s.Tag['id']); $e.Handled = $true } catch { Write-ErrLog ('Delete task: ' + $_.Exception.Message) } })
            [void]$btnRow2.Children.Add($bEdit2)
            [void]$btnRow2.Children.Add($bDel2)
            [void]$detail.Children.Add($btnRow2)

            # 详情面板挂在 $row 的第 1 列（body 下方），不是 $body 里：
            # body 在 $wide 时只有两行，颜色条要跟着整卡高度拉伸（挂在 body 里色条会短一截）。
            [System.Windows.Controls.Grid]::SetColumn($detailBg, 1)
            $detailHost = New-Object System.Windows.Controls.Grid
            $detailHost.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
            [void]$detailHost.Children.Add($detailBg)
            [void]$body.Children.Add($detailHost)
        }

        $wrap = New-Object System.Windows.Controls.Border
        # 左边只留 6px：优先级色条要贴边才有"书脊"感（留 11px 会飘在中间）。
        $wrap.Padding = [System.Windows.Thickness]::new(6, 8, 8, 8)
        $wrap.BorderBrush = Brush (Get-Pal 'BorderSoft')
        $wrap.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
        $wrap.Child = $row
        $wrap.Tag = @{ kind = 'task'; id = $tId }
        $wrap.Cursor = [System.Windows.Input.Cursors]::Hand
        $wrap.AllowDrop = $true
        if ($expanded) {
            $wrap.Background = Brush (Get-Pal 'Card')
            $wrap.BorderBrush = Brush (Get-Pal 'Border')
        }
        # 双击卡片 = 打开任务编辑窗口（第四轮改版）。
        #
        # 历史：
        #   第二轮把 Edit / Del 从卡片收进"双击展开"的行内面板，解决了"双击没反应"；
        #   但用户第三轮反馈的原话是"双击 task，不能调出修改界面" —— "展开一段只读
        #   详情 + 再点 Edit" 和 "直接进编辑界面" 是两件事，用户要的是后者。
        #
        # 现在：
        #   · 双击卡片（非按钮区域）-> Open-TaskEditor -Id  —— 直接进编辑窗口
        #   · 单击卡片上的 ▾/▸ 指示器  -> 切换行内详情面板（原来的展开能力不丢，
        #     而且从"隐藏的双击"变成"看得见的可点入口"，比原来更好发现）
        #   · Edit 按钮的处理器里先清 $script:TaskExpandedId 再开窗，
        #     这样关掉编辑窗口回到列表时不会留着一个展开的面板。
        #
        # 为什么仍然用 MouseLeftButtonUp + ClickCount（而不是 MouseDoubleClick）：
        #   卡片上任何一个按钮吃掉一个 click 都会让 MouseDoubleClick 不触发，
        #   而 Up 事件的 ClickCount 在托管的 WPF 路由里稳得多。
        # ClickCount 必须从 $e 上读 —— 写成局部变量在处理器里是看不到的（闭包规则）。
        $wrap.Add_MouseLeftButtonUp({
            param($s,$e)
            try {
                if ((Get-MouseClickCount $e) -lt 2) { return }
                # 第一下已经排了一次"待勾选完成"，双击的意思是"去编辑"，不是"勾掉它"。
                Cancel-PendingTaskToggle
                # 统一走 Get-EventSourceOf：手工造的事件 OriginalSource 可能读不到，
                # 裸读 $e.OriginalSource 在 StrictMode 下会直接抛，把双击彻底打哑。
                $bt = Test-BtnTag (Get-EventSourceOf $e $s)
                if ($null -ne $bt -and $null -ne $bt.kind -and (@('task-edit','task-delete','task-focus','task-postpone','task-expand') -contains [string]$bt.kind)) { return }
                # 双击后可能紧跟一次拖拽起点，清掉免得"开个窗口的功夫卡片飞了"
                $script:TaskDragId = ''
                $script:TaskDragPoint = $null
                # 若这张卡正展开着，先收起：不然编辑窗口关掉后回到列表，
                # 会看到一个"上次展开的面板"还挂在那里，像是没保存生效。
                $hitId = [string]$s.Tag['id']
                if ($script:TaskExpandedId -eq $hitId) { $script:TaskExpandedId = '' }
                Open-TaskEditor -Id $hitId
                $e.Handled = $true
            } catch {
                # 日志必须带出处。只写 Exception.Message 的话，从深层脚本块里炸出来的
                # CommandNotFoundException 只能看到"找不到某个函数"，定位不到是谁在调它 ——
                # 第三轮的双击展开面板就是靠 ScriptStackTrace 里的 Views.ps1:1999 钉死的。
                $where = ''
                try {
                    $fr = @(($_.ScriptStackTrace -split "`r?`n") | Where-Object { $_.Trim() })
                    if ($fr.Count -gt 0) { $where = ' | at ' + ($fr[0].Trim()) }
                } catch { }
                Write-ErrLog ('Task dblclick: ' + $_.Exception.Message + $where)
            }
        })
        $wrap.Add_MouseLeftButtonDown({
            param($s,$e)
            try {
                $bt = Test-BtnTag (Get-EventSourceOf $e $s)
                if ($null -ne $bt -and $null -ne $bt.kind -and (@('task-edit','task-delete','task-focus','task-postpone') -contains [string]$bt.kind)) { return }
                # 双击的第二下也会走到这里，别把它当成拖拽起点
                if ((Get-MouseClickCount $e) -ge 2) { return }
                $script:TaskDragId = [string]$s.Tag['id']
                $script:TaskDragPoint = $e.GetPosition($script:TaskStack)
            } catch { }
        })
        $wrap.Add_MouseMove({
            param($s,$e)
            try {
                if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed -or [string]::IsNullOrWhiteSpace([string]$script:TaskDragId)) { return }
                $pp = $e.GetPosition($script:TaskStack)
                if ($null -eq $script:TaskDragPoint) { return }
                if ([math]::Abs($pp.X - [double]$script:TaskDragPoint.X) + [math]::Abs($pp.Y - [double]$script:TaskDragPoint.Y) -lt 6) { return }
                [System.Windows.DragDrop]::DoDragDrop($s, [string]$script:TaskDragId, [System.Windows.DragDropEffects]::Move)
            } catch { }
        })
        $wrap.Add_DragOver({ param($s,$e) try { if ($e.Data.GetDataPresent([string])) { $e.Effects = [System.Windows.DragDropEffects]::Move; $e.Handled = $true } } catch { } })
        $wrap.Add_Drop({
            param($s,$e)
            try {
                if ($e.Data.GetDataPresent([string])) {
                    Move-Task -SourceId ([string]$e.Data.GetData([string])) -TargetId ([string]$s.Tag['id'])
                    $e.Handled = $true
                }
                $script:TaskDragId = ''; $script:TaskDragPoint = $null
            } catch { }
        })
        [void]$built.Add($wrap)
    }
    # Swap：整轮都没抛异常，才把旧卡片换成新的（原子替换，理由见函数开头）。
    $script:TaskStack.Children.Clear()
    foreach ($c in $built) { [void]$script:TaskStack.Children.Add($c) }
}

function Get-CheckTemplate {
    param([string]$Bg)
    $tpl = @"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                 TargetType="Button">
  <Border Background="$Bg" BorderBrush="$(Get-Pal 'Border')" BorderThickness="2"
          CornerRadius="4"/>
</ControlTemplate>
"@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$tpl)
    return [System.Windows.Markup.XamlReader]::Load($reader)
}

# ---------------------------------------------------------------------------
#  骨架屏（-Skeleton 用：只画布局占位，不建单元格，用于秒出结构截图）
# ---------------------------------------------------------------------------
function Render-Skeleton {
    param([string]$View)
    $shell = New-Bd -Bg (Get-Pal 'Card') -Border (Get-Pal 'Border') -Radius 8
    $g = New-Object System.Windows.Controls.Grid
    if ($View -eq 'month') {
        for ($i = 0; $i -lt 7; $i++) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = [System.Windows.GridLength]::new(1, 'Star'); $g.ColumnDefinitions.Add($cd)
        }
        for ($r = 0; $r -lt 6; $r++) {
            $rd = New-Object System.Windows.Controls.RowDefinition
            if ($r -eq 0) { $rd.Height = [System.Windows.GridLength]::new(30, 'Pixel') }
            else { $rd.Height = [System.Windows.GridLength]::new(1, 'Star') }
            $g.RowDefinitions.Add($rd)
        }
        for ($c = 0; $c -lt 7; $c++) {
            $b = New-Bd -Bg (Get-Pal 'CardAlt') -Border (Get-Pal 'BorderSoft') -Radius 5
            $b.BorderThickness = [System.Windows.Thickness]::new(1, 0, 0, 2)
            [System.Windows.Controls.Grid]::SetRow($b, 0)
            [System.Windows.Controls.Grid]::SetColumn($b, $c)
            [void]$g.Children.Add($b)
        }
        $sk = 0
        for ($r = 1; $r -le 6; $r++) {
            for ($c = 0; $c -lt 7; $c++) {
                $bg = Get-Pal 'Card'
                if ($c -ge 5) { $bg = Get-Pal 'Weekend' }
                if ($sk -eq 24) { $bg = Get-Pal 'AccentFocus' }
                $b = New-Bd -Bg $bg -Border (Get-Pal 'BorderSoft') -Radius 5
                [System.Windows.Controls.Grid]::SetRow($b, $r)
                [System.Windows.Controls.Grid]::SetColumn($b, $c)
                [void]$g.Children.Add($b)
                $sk++
            }
        }
    } elseif ($View -eq 'week') {
        for ($r = 0; $r -lt 25; $r++) {
            $rd = New-Object System.Windows.Controls.RowDefinition
            if ($r -eq 0) { $rd.Height = [System.Windows.GridLength]::new(46, 'Pixel') }
            else { $rd.Height = [System.Windows.GridLength]::new(1, 'Star') }
            $g.RowDefinitions.Add($rd)
        }
        $cd0 = New-Object System.Windows.Controls.ColumnDefinition
        $cd0.Width = [System.Windows.GridLength]::new($script:WeekGutter, 'Pixel')
        $g.ColumnDefinitions.Add($cd0)
        for ($i = 0; $i -lt 7; $i++) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = [System.Windows.GridLength]::new(1, 'Star'); $g.ColumnDefinitions.Add($cd)
        }
        for ($c = 0; $c -lt 7; $c++) {
            $bg = Get-Pal 'CardAlt'
            if ($c -ge 5) { $bg = Get-Pal 'Weekend' }
            $b = New-Bd -Bg $bg -Border (Get-Pal 'BorderSoft') -Radius 0 -Bw 1
            [System.Windows.Controls.Grid]::SetRow($b, 0)
            [System.Windows.Controls.Grid]::SetColumn($b, $c + 1)
            [void]$g.Children.Add($b)
            $col = New-Bd -Bg $(if ($c -ge 5) { Get-Pal 'Weekend' } else { Get-Pal 'Card' }) -Radius 0 -Bw 0
            [System.Windows.Controls.Grid]::SetRow($col, 1)
            [System.Windows.Controls.Grid]::SetRowSpan($col, 24)
            [System.Windows.Controls.Grid]::SetColumn($col, $c + 1)
            [void]$g.Children.Add($col)
        }
        # 两块示例日程卡
        foreach ($pair in @(@{ c = 1; t = 1; h = 5 }, @{ c = 3; t = 3; h = 4 })) {
            $card = New-Bd -Bg (Get-Pal 'AccentEvent') -Border (Get-Pal 'Border') -Radius 6 -Bw 1.5
            [System.Windows.Controls.Grid]::SetRow($card, $pair.t)
            [System.Windows.Controls.Grid]::SetRowSpan($card, $pair.h)
            [System.Windows.Controls.Grid]::SetColumn($card, $pair.c)
            $card.Margin = [System.Windows.Thickness]::new(3, 2, 3, 2)
            [void]$g.Children.Add($card)
        }
    } else {
        for ($i = 0; $i -lt 2; $i++) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            if ($i -eq 0) { $cd.Width = [System.Windows.GridLength]::new(1, 'Star') }
            else { $cd.Width = [System.Windows.GridLength]::new(272, 'Pixel') }
            $g.ColumnDefinitions.Add($cd)
        }
        $left = New-Bd -Bg (Get-Pal 'CardAlt') -Border (Get-Pal 'BorderSoft') -Radius 0
        $left.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 2)
        $left.Height = 44
        $left.VerticalAlignment = 'Top'
        [System.Windows.Controls.Grid]::SetColumn($left, 0)
        [void]$g.Children.Add($left)
        $right = New-Bd -Bg (Get-Pal 'CardAlt') -Border (Get-Pal 'BorderSoft') -Radius 0
        $right.BorderThickness = [System.Windows.Thickness]::new(2, 0, 0, 0)
        [System.Windows.Controls.Grid]::SetColumn($right, 1)
        $right.Margin = [System.Windows.Thickness]::new(0, 44, 0, 0)
        [void]$g.Children.Add($right)
        $rowsHost = New-Object System.Windows.Controls.StackPanel
        $rowsHost.Margin = [System.Windows.Thickness]::new(0, 44, 0, 0)
        for ($i = 0; $i -lt 6; $i++) {
            $rb = New-Bd -Bg (Get-Pal 'Card') -Border (Get-Pal 'BorderSoft') -Radius 4 -Bw 1
            $rb.Height = 38
            $rb.Margin = [System.Windows.Thickness]::new(8, 4, 8, 4)
            [void]$rowsHost.Children.Add($rb)
        }
        [System.Windows.Controls.Grid]::SetColumn($rowsHost, 0)
        [void]$g.Children.Add($rowsHost)
    }
    $shell.Child = $g
    return $shell
}

# ---------------------------------------------------------------------------
#  视图切换 / 整体刷新
# ---------------------------------------------------------------------------
function Set-View {
    param([string]$View)
    # 白名单：视图名写错一个字母（'taks'）会安静地落到 switch 的 default 分支去渲染月视图，
    # 表现成"点了按钮没反应"——这类静默回落比直接报错难查得多。宁可在这里挡住。
    if (@('month', 'week', 'list', 'tasks') -notcontains $View) { return }
    # 只有真换视图才收起展开的详情面板。放在这里而不是 Refresh-All：
    #   Refresh-All 在改筛选 / 改搜索 / 勾选完成时都会跑，
    #   在那里清会让"双击展开 -> 勾一个子任务"马上又收起来。
    if ($script:View -ne $View) { $script:TaskExpandedId = '' }
    $script:View = $View
    $script:Settings['View'] = $View
    Save-Settings
    Refresh-All
}

function New-ViewWrap {
    param($Inner, [string]$ViewId)
    $wrap = New-Object System.Windows.Controls.Grid
    $wrap.Tag = @{ kind = 'view'; view = $ViewId }
    [void]$wrap.Children.Add($Inner)
    return $wrap
}

function Refresh-All {
    if ($null -eq $script:NodeHost) { return }
    $script:NodeHost.Children.Clear()

    # 列表视图的引用必须先清空：它们指向上一轮渲染的元素，
    # 不清空会让 Add_TextChanged / Add_SelectionChanged 在每次刷新时重复挂到
    # 已经脱离可视树的旧控件上（处理器越挂越多），而且后续的判空也失去意义。
    # 下面 Render-List / Render-Tasks 跑完会重新赋值。
    $script:ListStack    = $null
    $script:TaskStack    = $null
    $script:ListSearch   = $null
    $script:ListTagBox   = $null
    $script:ListScopeBox = $null
    $script:TaskOpenText = $null
    $script:TaskScroll = $null
    $script:TaskAddButton = $null
    $script:TaskPanelTitle = $null
    $script:TaskProjectBox = $null
    $script:TaskStatusBox = $null
    $script:TaskScopeBox = $null
    $script:TaskSortBox = $null
    $script:TaskSearch = $null
    # 搜索框的占位提示控件：和搜索框同生共死，所以一起复位（提示归零后
    # Sync-SearchHint 的判空会直接返回，旧处理器不会去动一个已经脱离可视树的元素）。
    $script:ListSearchHint = $null
    $script:TaskSearchHint = $null
    # 卡片版式跟着视图走：只有 Tasks 视图是宽版（Render-Tasks 里置 $true）。
    # 不在这里复位的话，从 Tasks 切回别的视图后卡片会保持宽版式而挤在窄容器里。
    $script:TaskCardWide = $false
    $script:TaskFilterRow = $null
    # 周视图时段控件同理：旧引用指向已脱离可视树的元素，留着会让 Set-WeekRange
    # 去改一个看不见的控件（回填静默失败，用户以为"选了没反应"）。
    $script:WeekAxis   = $null
    $script:WkRangeBox = $null
    $script:WkStartBox = $null
    $script:WkEndBox   = $null

    # 视图切换时若覆盖层开着，先收起（避免覆盖层悬在旧位置上）
    if ($script:OverlayOpen -and $null -ne $script:UiOverlay) { Close-Overlay }

    $inner = $null
    switch ($script:View) {
        'month' { $inner = Render-Month }
        'week'  { $inner = Render-Week }
        'list'  { $inner = Render-List }
        'tasks' { $inner = Render-Tasks }
        default { $inner = Render-Month }
    }
    $wrap = New-ViewWrap -Inner $inner -ViewId $script:View
    $script:NodeHost.Children.Add($wrap) | Out-Null
    $script:ViewWrap = $wrap

    # 骨架屏 / 渲染开关：骨架屏时不建事件处理器与数据填充
    if (-not $script:Skeleton) {
        Attach-ViewHandlers $wrap
        if ($script:View -eq 'list') {
            Attach-EventClick $script:ListStack
        }
        if ($script:View -eq 'tasks') {
            Attach-TaskClick $script:TaskStack
        }
        if ($script:ListSearch)  { $script:ListSearch.Add_TextChanged({ Sync-SearchHint $script:ListSearch $script:ListSearchHint; Fill-ListRows }) }
        if ($script:ListTagBox)  { $script:ListTagBox.Add_SelectionChanged({ Fill-ListRows }) }
        if ($script:ListScopeBox){ $script:ListScopeBox.Add_SelectionChanged({ Fill-ListRows }) }
        # 任务视图的五个筛选：任何一个变动都重画卡片区（和列表页各自独立，不互相改状态）
        if ($script:TaskSearch)     { $script:TaskSearch.Add_TextChanged({ Sync-SearchHint $script:TaskSearch $script:TaskSearchHint; Fill-Tasks }) }
        if ($script:TaskProjectBox) { $script:TaskProjectBox.Add_SelectionChanged({ Fill-Tasks }) }
        if ($script:TaskStatusBox)  { $script:TaskStatusBox.Add_SelectionChanged({ Fill-Tasks }) }
        if ($script:TaskScopeBox)   { $script:TaskScopeBox.Add_SelectionChanged({ Fill-Tasks }) }
        if ($script:TaskSortBox)    { $script:TaskSortBox.Add_SelectionChanged({ Fill-Tasks }) }
        if ($script:View -eq 'list')  { Fill-ListRows }
        if ($script:View -eq 'tasks') { Fill-Tasks }
    }

    Update-Chrome
    Update-PomodoroVisual
    # 周视图的高度自适应：此时树已经进了可视树，UpdateLayout 后 ViewportHeight 才有效
    # （不是周视图的话 Reflow 自己会返回 $false）。
    try { [void](Reflow-WeekHeight) } catch { Write-ErrLog ('Reflow week: ' + $_.Exception.Message) }
}

function Update-Chrome {
    # 标题栏。第五轮：视图名走语言表（原来是写死的英文），
    #  这样切语言之后标题栏也跟着变，不会出现"侧栏中文 + 标题栏英文"的新混用。
    $names = @{
        month = (Get-LangText 'view.month'); week = (Get-LangText 'view.week')
        list  = (Get-LangText 'view.list');  tasks = (Get-LangText 'view.tasks')
    }
    if ($null -ne $script:WinTitle) {
        $script:WinTitle.Text = (Get-LangText 'sched') + ' - ' + $names[$script:View]
    }
    if ($null -ne $script:HeroTitle) { $script:HeroTitle.Text = (Get-LangText 'sched') }

    # 视图切换按钮选中态（Tasks 也在这一组里：它现在是一个真正的视图，
    # 以前点了跳 list、自身永远不高亮，看起来像"按了没用"）
    foreach ($pair in @(
        @{ B = $script:NavMonth; V = 'month' }, @{ B = $script:NavWeek; V = 'week' },
        @{ B = $script:NavList;  V = 'list' },  @{ B = $script:NavTask; V = 'tasks' })) {
        if ($null -eq $pair.B) { continue }
        if ($pair.V -eq $script:View) {
            $pair.B.Background = Brush (Get-Pal 'Panel')
            $pair.B.Foreground = Brush (Get-Pal 'Border')
        } else {
            $pair.B.Background = $null
            $pair.B.Foreground = Brush (Get-Pal 'InkSoft')
        }
    }
    foreach ($pair in @(
        @{ B = $script:BtnViewMonth; V = 'month' }, @{ B = $script:BtnViewWeek; V = 'week' },
        @{ B = $script:BtnViewList;  V = 'list' })) {
        if ($null -eq $pair.B) { continue }
        if ($pair.V -eq $script:View) {
            $pair.B.Background = $null
            $pair.B.BorderBrush = Brush (Get-Pal 'AccentEvent')
            $pair.B.Foreground = Brush (Get-Pal 'Border')
            $pair.B.FontWeight = [System.Windows.FontWeights]::SemiBold
        } else {
            $pair.B.Background = $null
            $pair.B.BorderBrush = $null
            $pair.B.Foreground = Brush (Get-Pal 'InkSoft')
            $pair.B.FontWeight = [System.Windows.FontWeights]::Normal
        }
    }

    # Pin 按钮状态
    if ($null -ne $script:BtnPin) {
        if ($script:TopmostOn) {
            $script:BtnPin.Background = Brush (Get-Pal 'AccentFocus')
            $script:BtnPin.Foreground = Brush (Get-Pal 'TodayInk')
        } else {
            $script:BtnPin.Background = Brush (Get-Pal 'Card')
            $script:BtnPin.Foreground = Brush (Get-Pal 'Border')
        }
    }
    if ($null -ne $script:BtnTheme) {
        if ($script:Theme -eq 'night') {
            $script:BtnTheme.Background = Brush (Get-Pal 'AccentFocus')
            $script:BtnTheme.Foreground = Brush (Get-Pal 'TodayInk')
        } else {
            $script:BtnTheme.Background = Brush (Get-Pal 'Card')
            $script:BtnTheme.Foreground = Brush (Get-Pal 'Border')
        }
    }

    # 信息头
    $now = [datetime]::Now
    if ($null -ne $script:HeroDate) {
        $script:HeroDate.Text = ('{0}, {1} {2} {3}  {4:00}:{5:00}' -f `
            $script:DowShort[([int]$now.DayOfWeek + 6) % 7],
            $script:MonShort[$now.Month - 1], $now.Day, $now.Year, $now.Hour, $now.Minute)
    }
    if ($null -ne $script:HeroStats) {
        $done = @($script:Events | Where-Object { [bool]$_.done }).Count
        $tot = @($script:Events).Count
        $pct = 0
        if ($tot -gt 0) { $pct = [int][math]::Round(($done / [double]$tot) * 100.0) }
        $fmin = [int]$script:Settings['FocusTodayMin']
        $script:HeroStats.Text = ("Done {0}/{1} ({2}%) · Focus today {3}h{4:00}m" -f `
            $done, $tot, $pct, [math]::Floor($fmin / 60), ($fmin % 60))
    }

    # 日历导航条
    $a = $script:Anchor
    if ($script:View -eq 'month') {
        if ($null -ne $script:CalLabel)  { $script:CalLabel.Text = 'This month' }
        if ($null -ne $script:CalPeriod) { $script:CalPeriod.Text = $script:MonNames[$a.Month - 1] + ' ' + $a.Year }
        $n = 0
        foreach ($d in @(Month-Grid $a)) {
            if ($d.Month -eq $a.Month -and (Get-Holiday $d)) { $n++ }
        }
        if ($null -ne $script:CalNote) {
            # 复数：1 天的时候要写 "1 holiday"，否则英文会露怯
            if ($n -gt 0) {
                $word = if ($n -eq 1) { 'holiday' } else { 'holidays' }
                $script:CalNote.Text = "$n $word this month"
            } else { $script:CalNote.Text = '' }
        }
    } elseif ($script:View -eq 'week') {
        $ws = Week-Days $a
        if ($null -ne $script:CalLabel)  { $script:CalLabel.Text = 'This week' }
        if ($null -ne $script:CalPeriod) {
            $script:CalPeriod.Text = ('{0} {1} - {2} {3}' -f
                $script:MonShort[$ws[0].Month - 1], $ws[0].Day,
                $script:MonShort[$ws[6].Month - 1], $ws[6].Day)
        }
        $notes = @()
        foreach ($d in $ws) { $h = Get-Holiday $d; if ($h) { $notes += ('{0}/{1} {2}' -f $d.Month, $d.Day, $h) } }
        if ($null -ne $script:CalNote) { $script:CalNote.Text = ($notes -join ' · ') }
    } else {
        if ($null -ne $script:CalLabel)  { $script:CalLabel.Text = 'All' }
        if ($null -ne $script:CalPeriod) { $script:CalPeriod.Text = $script:MonNames[$a.Month - 1] + ' ' + $a.Year }
        if ($null -ne $script:CalNote)   { $script:CalNote.Text = '' }
    }
}

