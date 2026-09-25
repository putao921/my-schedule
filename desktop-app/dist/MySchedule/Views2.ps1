# =============================================================================
#  My Schedule - 独立编辑窗口（WPF 真窗口，可拖动/最小化，和主窗口同一套皮肤）
#  为什么不用覆盖层：编辑时用户常需要翻看主窗口的其它日期，
#  一个可以自由摆放的独立窗口比模态遮罩更顺手。
# =============================================================================

# ---------------------------------------------------------------------------
#  标签芯片的选中态重绘
#
#  为什么不就地写个 $paintTags 脚本块：它会在按钮的 Click 处理器里被 & 调用，
#  而处理器真正触发时，创建它的那个函数作用域早就销毁了——脚本块和其中引用的
#  函数局部变量（$bb 等）全都取不到，StrictMode 下直接抛异常。
#  所以把按钮表和配色表挂到 $script:，用命名函数来读。
#
#  为什么不能直接改 $b.Background：New-PixBtn 的底色画在 ControlTemplate 里的
#  "bd" 边框上（$Bg 在构建时就拼进模板字符串了），Button.Background 根本没人读。
#  必须 ApplyTemplate 之后用 Template.FindName 取回那个边框改它的 Background；
#  文字色则改 Content（一个 TextBlock）的 Foreground。
# ---------------------------------------------------------------------------
function Update-TagChipSelection {
    param([string]$Key = '')
    if (-not [string]::IsNullOrWhiteSpace($Key)) { $script:EdTag = $Key }
    if ($null -eq $script:EdTagButtons) { return }
    foreach ($k in @($script:EdTagButtons.Keys)) {
        $b = $script:EdTagButtons[$k]
        if ($null -eq $b) { continue }
        $on = ([string]$k -eq [string]$script:EdTag)
        if ($on) { $bg = Get-Pal $script:EdTagColors[$k]; $fg = Get-Pal 'OnAccent' }
        else { $bg = Get-Pal 'Card'; $fg = Get-Pal 'Ink' }
        try { [void]$b.ApplyTemplate() } catch { }
        $bd = $null
        try { $bd = $b.Template.FindName('bd', $b) } catch { }
        if ($null -ne $bd) { $bd.Background = Brush $bg }
        $txt = $b.Content
        if ($null -ne $txt) { $txt.Foreground = Brush $fg }
    }
}

# ---------------------------------------------------------------------------
#  近 7 天专注统计（含今天，最后一个元素是今天）
#
#  口径：focus / life 两类日程的时长之和，再加上"今天"已完成的番茄钟累计
#  （$script:Settings['FocusTodayMin']）。月视图里这两类标签本来就画成橙色条，
#  和这里的口径是一致的。
# ---------------------------------------------------------------------------
function Get-FocusStats {
    $today = [datetime]::Today
    $acc = New-Object System.Collections.ArrayList
    for ($i = 6; $i -ge 0; $i--) {
        $day = $today.AddDays(-$i)
        $key = Fmt-Date $day
        $mins = 0
        foreach ($e in @(Events-On $day)) {
            $tg = [string]$e.tag
            if ($tg -ne 'focus' -and $tg -ne 'life') { continue }
            $d = [int]$e.end - [int]$e.start
            if ($d -gt 0) { $mins += $d }
        }
        if ($i -eq 0) { $mins += [int]$script:Settings['FocusTodayMin'] }
        [void]$acc.Add($mins)
    }
    return $acc.ToArray()
}

function New-EditorField {
    # 参数名不能叫 $Host：$Host 是 PowerShell 的只读自动变量，绑定参数时会抛
    # "无法覆盖变量 Host" ——而且因为延迟到调用时才炸，设置窗口一打开就报错。
    param($Parent, [string]$Label, [string]$Value, [double]$W = 0.0)
    [void]$Parent.Children.Add((New-Txt -Text $Label -Size 11 -Color (Get-Pal 'InkFaint')))
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Text = $Value
    $tb.Height = 32
    $tb.FontSize = 13
    $tb.Margin = [System.Windows.Thickness]::new(0, 3, 0, 12)
    if ($W -gt 0.0) { $tb.Width = $W }
    $tb.Background = Brush (Get-Pal 'CardAlt')
    $tb.Foreground = Brush (Get-Pal 'Ink')
    $tb.BorderBrush = Brush (Get-Pal 'Border')
    $tb.BorderThickness = [System.Windows.Thickness]::new(2)
    $tb.Padding = [System.Windows.Thickness]::new(6, 3, 6, 3)
    $tb.VerticalContentAlignment = 'Center'
    # 让窗口能跟着输入框滚动
    $tb.Add_GotKeyboardFocus({
        param($s, $e)
        try {
            $p = $s.Parent
            while ($null -ne $p -and $p -isnot [System.Windows.Controls.ScrollViewer]) { $p = $p.Parent }
            if ($null -ne $p) { $s.BringIntoView() }
        } catch { }
    })
    [void]$Parent.Children.Add($tb)
    return $tb
}

function Apply-SharedComboStyle {
    # 编辑器/设置这类对话框是独立 Window，资源是各自一套：主窗口 Window.Resources
    # 里那套隐式 ComboBox 样式它们拿不到，于是落到系统默认模板上 —— 默认模板的底色
    # 不听 Background 赋值，夜间模式就是"浅底 + 浅字"，控件等于隐形。
    # 这里直接把主窗口那套样式借过来显式贴上，省得再复制一份 XAML（两份迟早会漂移）。
    param([System.Windows.Controls.ComboBox]$Box)
    try {
        if ($null -eq $script:MainWindow) { return }
        $sc = $script:MainWindow.TryFindResource([System.Windows.Controls.ComboBox])
        if ($null -ne $sc) { $Box.Style = ($sc -as [System.Windows.Style]) }
        $si = $script:MainWindow.TryFindResource([System.Windows.Controls.ComboBoxItem])
        if ($null -ne $si) { $Box.ItemContainerStyle = ($si -as [System.Windows.Style]) }
    } catch { Write-ErrLog ('Apply-SharedComboStyle: ' + $_.Exception.Message) }
}

function New-ComboField {
    param($Parent, [string]$Label, [string]$Value, [string[]]$Choices = @())
    [void]$Parent.Children.Add((New-Txt -Text $Label -Size 11 -Color (Get-Pal 'InkFaint')))
    $cb = New-Object System.Windows.Controls.ComboBox
    $cb.IsEditable = $true
    $cb.Height = 36
    $cb.FontSize = 13
    $cb.Margin = [System.Windows.Thickness]::new(0, 3, 0, 12)
    $cb.Background = Brush (Get-Pal 'CardAlt')
    $cb.Foreground = Brush (Get-Pal 'Ink')
    $cb.BorderBrush = Brush (Get-Pal 'Border')
    $cb.BorderThickness = [System.Windows.Thickness]::new(2)
    $cb.Padding = [System.Windows.Thickness]::new(7, 3, 7, 3)
    $seen = @{}
    foreach ($choice in @($Choices)) {
        $txt = [string]$choice
        if ([string]::IsNullOrWhiteSpace($txt) -or $seen.ContainsKey($txt)) { continue }
        $seen[$txt] = $true
        [void]$cb.Items.Add($txt)
    }
    if (-not [string]::IsNullOrWhiteSpace($Value) -and -not $seen.ContainsKey($Value)) {
        [void]$cb.Items.Add($Value)
    }
    $cb.Text = $Value
    Apply-SharedComboStyle $cb
    [void]$Parent.Children.Add($cb)
    return $cb
}

function New-SettingsSection {
    # 设置窗口里的分组小标题（第四轮：设置项从 1 项涨到 7 项，必须分组，
    # 否则一长条全是控件、找不到自己要改的那一项在哪）。
    # 上面留一条细分隔线，视觉上把"上一组"和"这一组"切开。
    param($Parent, [string]$Text)
    $line = New-Bd -Bg (Get-Pal 'BorderSoft') -Border '' -Radius 0
    $line.Height = 1.5
    $line.Margin = [System.Windows.Thickness]::new(0, 14, 0, 8)
    [void]$Parent.Children.Add($line)
    [void]$Parent.Children.Add((New-Txt -Text $Text -Size 11 -Color (Get-Pal 'Ink') -Weight 'Semi'))
}

function New-ToggleRow {
    # 设置项里的复选框行。和 New-EditorField / New-ComboField 一样是"标签在上、
    # 控件在下"的纵向结构 —— 横向排会把 408px 宽的窗口挤得很乱。
    # 返回 CheckBox，调用方把它挂到 $script: 上（处理器里读不到局部变量）。
    param($Parent, [string]$Label, [bool]$Checked = $false, [string]$Hint = '')
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $Label
    $cb.IsChecked = $Checked
    $cb.FontSize = (Scale-Ui 12)
    $cb.Foreground = Brush (Get-Pal 'Ink')
    $cb.Margin = [System.Windows.Thickness]::new(0, 4, 0, 2)
    [void]$Parent.Children.Add($cb)
    if (-not [string]::IsNullOrWhiteSpace($Hint)) {
        $h = New-Txt -Text $Hint -Size 10 -Color (Get-Pal 'InkFaint')
        $h.Margin = [System.Windows.Thickness]::new(24, 0, 0, 6)
        $h.TextWrapping = 'Wrap'
        [void]$Parent.Children.Add($h)
    }
    return $cb
}

# ---------------------------------------------------------------------------
#  弹窗的"关闭"语义（第四轮改版）
#
#  第三轮把六个弹窗（日程编辑 / 设置 / 任务编辑 / 专注 / 头像 / 当日议程）压成
#  只留右上角一个 ×，结果用户反馈两条：
#    ① "无法直接不保存关闭" —— Esc 是个隐藏快捷键，界面上没有任何可见入口；
#    ② "也没有保存按钮"     —— × 到底会不会保存，用户只能猜。
#  "一个 × 兼三职"在设计上是省事，在使用上是把决策成本推给了用户。
#
#  第四轮改为标题栏三件套（六弹窗共用，位置固定在右上角）：
#    · Save    = 确认并保存关闭（校验失败不关，错误留在窗口里）
#    · Cancel  = 放弃修改直接关闭（= 原 Esc 行为，现在有可见按钮）
#    · ×       = 等同 Save（保持第三轮建立的肌肉记忆，不让老用户踩空）
#    · Esc     = 等同 Cancel（保留）
#  底部仍然不放按钮：动作入口全部集中在标题栏右端，正文区保持干净。
#
#  所以保存/放弃的处理器由各弹窗自己接（行为不同），这里只提供外观、
#  几何排布与"是否是按钮"的判定。
# ---------------------------------------------------------------------------
function Test-ClickOnButton {
    # 标题栏挂的是 DragMove。按钮内部的 MouseLeftButtonDown 理论上会被 ButtonBase
    # 自己标记 Handled 而不再冒泡上来，但"理论上"不够——一旦冒泡上来，点 × 会变成
    # 拖窗口（DragMove 是模态循环，窗口看起来就卡住了）。这里再从事件源往上走一遍
    # 可视树，只要碰到按钮就放行，让按钮自己处理。
    # ⚠ 参数名不能叫 $Args：与自动变量 $args 同名，绑定后会被覆盖成 @()
    #   （非 $null！），于是下面 `$null -eq $Args` 判空永远为假、$Args.Source 读不到，
    #   这个"点 × 别拖窗口"的护栏一直是空转的。
    param($Evt)
    if ($null -eq $Evt) { return $false }
    # 不要裸读 $Evt.OriginalSource：手工 RaiseEvent 的事件没有真实输入源，
    # 读它可能拿到 $null，在 Set-StrictMode 下甚至连读都抛（"找不到属性"）。
    # 走 Get-EventSourceOf 拿一个"尽力而为"的源；再退回 $Evt.Source。
    $node = Get-EventSourceOf $Evt
    if ($null -eq $node) {
        try { $node = $Evt.Source } catch { return $false }
    }
    if ($null -eq $node) { return $false }
    $guard = 0
    while ($null -ne $node -and $guard -lt 40) {
        $guard++
        if ($node -is [System.Windows.Controls.Primitives.ButtonBase]) { return $true }
        try { $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node) }
        catch { return $false }   # 走到非 Visual（如 Run）就到头了
    }
    return $false
}

function Close-DialogWindow {
    # 统一收口。为什么不直接写 $Win.DialogResult = $true：
    # DialogResult 只有"用 ShowDialog 打开的窗口"才允许赋值，否则抛
    # InvalidOperationException —— 而自动化测试里这些窗口是直接 new 出来、从不 Show 的，
    # 一旦抛在处理器中间，后面的 Close / Refresh-All 全被跳过（界面不刷新，
    # 而这个异常又会被 Invoke-Click 的 catch 吞掉，现场看不出任何痕迹）。
    param($Win, [bool]$Ok = $true)
    if ($null -eq $Win) { return }
    try { $Win.DialogResult = $Ok } catch { }   # 非模态窗口：忽略即可
    try { $Win.Close() } catch { }
}

function Get-SavedDialogPos {
    # 取出某个弹窗上次的位置；返回 $null = 没存过、或存的位置已经不可用（换过显示器）。
    # "还看得见"的判据故意宽松：只要窗口左上角落在虚拟屏幕范围内、且至少留 120x60
    # 的可见面积就接受。太严会让用户每次开机都发现窗口回到屏幕中央。
    param([string]$Key)
    if (-not $script:Settings.Contains($Key + 'Left')) { return $null }
    if (-not $script:Settings.Contains($Key + 'Top')) { return $null }
    try {
        $l = [double]$script:Settings[$Key + 'Left']
        $t = [double]$script:Settings[$Key + 'Top']
    } catch { return $null }
    if ($l -le -9999.0 -or $t -le -9999.0) { return $null }
    $vl = [double][System.Windows.SystemParameters]::VirtualScreenLeft
    $vt = [double][System.Windows.SystemParameters]::VirtualScreenTop
    $vw = [double][System.Windows.SystemParameters]::VirtualScreenWidth
    $vh = [double][System.Windows.SystemParameters]::VirtualScreenHeight
    if ($l -lt $vl -or $l -gt ($vl + $vw - 120.0)) { return $null }
    if ($t -lt $vt -or $t -gt ($vt + $vh - 60.0)) { return $null }
    return @{ Left = $l; Top = $t }
}

function Save-DialogPos {
    param($Win, [string]$Key)
    if ($null -eq $Win) { return }
    try {
        $script:Settings[$Key + 'Left'] = [math]::Round([double]$Win.Left)
        $script:Settings[$Key + 'Top'] = [math]::Round([double]$Win.Top)
        Save-Settings
    } catch { Write-ErrLog ('Save-DialogPos: ' + $_.Exception.Message) }
}

function Set-DialogStartPosition {
    # 弹窗落点：有记忆就用记忆，否则居中到主窗口。
    # 注意必须配 WindowStartupLocation = 'Manual' —— 设成 CenterOwner 时
    # WPF 会在 Show 的一刻按所有者重新定位，手动赋的 Left/Top 被无声盖掉。
    param($Win, [string]$Key)
    if ($null -eq $Win) { return }
    try { $Win.WindowStartupLocation = 'Manual' } catch { }
    # 居中前先把内容量一遍：SizeToContent 的弹窗在 Show 之前 Width/Height 是 NaN，
    # 拿它算偏移等于按"默认 460x460"估，实际位置会明显偏上偏左。
    $w = 460.0; $h = 460.0
    try {
        $root = Measure-DialogContent $Win
        if ($null -ne $root) {
            if ([double]$root.DesiredSize.Width  -gt 1.0) { $w = [double]$root.DesiredSize.Width }
            if ([double]$root.DesiredSize.Height -gt 1.0) { $h = [double]$root.DesiredSize.Height }
        }
    } catch { }
    $pos = Get-SavedDialogPos $Key
    if ($null -ne $pos) {
        $Win.Left = [double]$pos.Left
        $Win.Top = [double]$pos.Top
        return
    }
    $mw = $script:MainWindow
    if ($null -ne $mw) {
        try {
            $Win.Left = [double]($mw.Left + ([double]$mw.ActualWidth - $w) / 2.0)
            $Win.Top = [double]($mw.Top + ([double]$mw.ActualHeight - $h) / 2.0)
        } catch { }
    }
}

function Enable-DialogDrag {
    # 给一个元素挂"按住就能拖窗"，用来把拖动热区从 38px 的标题栏扩到整块窗口上。
    #
    # 为什么窗口句柄与记忆键要存进 $script:：WPF 回调触发时，创建函数的局部变量
    # 已经随作用域销毁了（本项目的老规矩，见 ClosureScan），处理器里**只能**看 $script:。
    # 所以这里不把 $Win / $Key 直接写进闭包，而是先落到两个 $script: 变量上。
    #
    # DragMove() 是模态消息循环，一直阻塞到松手才返回 —— 所以"存位置"写在它后面，
    # 刚好就是"拖完存一次"。
    param($Element, $Win, [string]$Key = '')
    if ($null -eq $Element -or $null -eq $Win) { return }
    $script:DragWin = $Win
    $script:DragPosKey = $Key
    $Element.Cursor = [System.Windows.Input.Cursors]::SizeAll
    $Element.Add_MouseLeftButtonDown({
        param($s, $e)
        # 点在按钮上的要放行：否则拖窗会吃掉"点按钮"，而 DragMove 一进去界面就像卡住
        if (Test-ClickOnButton $e) { return }
        try {
            $script:DragWin.DragMove()
            if (-not [string]::IsNullOrWhiteSpace([string]$script:DragPosKey)) {
                Save-DialogPos $script:DragWin ([string]$script:DragPosKey)
            }
        } catch { }
    })
}

function New-DialogBarButton {
    # 标题栏上的文字按钮（Save / Cancel）。与 × 一样是"手写模板 + 自带配色"，
    # 不走 New-PixBtn：那个模板的 ContentPresenter 带 9px 水平内边距，
    # 在 38px 高的标题栏里会把按钮撑得很高，且它的阴影边框在细标题栏里太重。
    # Name 由调用方给：审计要按 Name 精确定位（文字随语言/文案变动，Name 不会）。
    param([string]$Text, [string]$Name, [string]$Bg, [string]$Fg = '', [double]$W = 0.0, [string]$Tip = '')
    if (-not $Fg) { $Fg = Get-Pal 'Ink' }
    $hover = Get-Pal 'CardAlt'
    $press = Get-Pal 'BorderSoft'
    $btn = New-Object System.Windows.Controls.Button
    $btn.Name = $Name
    $btn.Height = 24
    if ($W -gt 0.0) { $btn.Width = $W }
    $btn.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
    $btn.Cursor = [System.Windows.Input.Cursors]::Hand
    if ($Tip) { $btn.ToolTip = $Tip }
    $pad = '8,0'
    $tpl = @"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                 TargetType="Button">
  <Border x:Name="bd" Background="$Bg" BorderBrush="$(Get-Pal 'Border')" BorderThickness="1.5"
          CornerRadius="6">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="$pad"/>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True">
      <Setter TargetName="bd" Property="Opacity" Value="0.85"/>
    </Trigger>
    <Trigger Property="IsPressed" Value="True">
      <Setter TargetName="bd" Property="Opacity" Value="0.7"/>
    </Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
"@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$tpl)
    $btn.Template = [System.Windows.Markup.XamlReader]::Load($reader)
    $btn.Content = (New-Txt -Text $Text -Size 11 -Color $Fg -Weight 'Semi')
    return $btn
}

function New-DialogSaveButton {
    # 主按钮：用当前主题的强调色，视觉上明确区分"保存"与"放弃"。
    param([string]$Text = 'Save')
    return (New-DialogBarButton -Text $Text -Name 'DlgSave' `
        -Bg (Get-Pal 'AccentEvent') -Fg (Get-Pal 'OnAccent') -W 64.0 `
        -Tip 'Save and close  (same as the x button)')
}

function New-DialogCancelButton {
    # 次按钮：走卡片底色，和标题栏同色系，表示"什么都不做直接走"。
    param([string]$Text = 'Cancel')
    return (New-DialogBarButton -Text $Text -Name 'DlgCancel' `
        -Bg (Get-Pal 'CardAlt') -Fg (Get-Pal 'Ink') -W 68.0 `
        -Tip 'Close without saving  (same as Esc)')
}

function New-DialogCloseButton {
    # 不用 New-PixBtn：那个模板的 ContentPresenter 带 9px 水平内边距，
    # 26px 宽的按钮里塞不下 10px 的 ×（会被压成一条竖线）。
    # 也不用 New-Icon + ControlTemplate 混搭，直接把手写的 X 路径烘进模板，
    # 少一层对 $script:IconDefs 的依赖。
    $ink = Get-Pal 'Ink'
    $hover = Get-Pal 'CardAlt'
    $press = Get-Pal 'BorderSoft'
    $btn = New-Object System.Windows.Controls.Button
    $btn.Name = 'DlgClose'
    $btn.Width = 26
    $btn.Height = 24
    $btn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $btn.Cursor = [System.Windows.Input.Cursors]::Hand
    $btn.ToolTip = 'Save and close  (Esc = discard changes)'
    $tpl = @"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                 TargetType="Button">
  <Border x:Name="bd" Background="Transparent" CornerRadius="5">
    <Path x:Name="gl" Data="M7 7 L17 17 M17 7 L7 17" Stroke="$ink" StrokeThickness="2.4"
          Width="24" Height="24" Stretch="None"
          StrokeStartLineCap="Round" StrokeEndLineCap="Round"
          HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True">
      <Setter TargetName="bd" Property="Background" Value="$hover"/>
    </Trigger>
    <Trigger Property="IsPressed" Value="True">
      <Setter TargetName="bd" Property="Background" Value="$press"/>
    </Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
"@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$tpl)
    $btn.Template = [System.Windows.Markup.XamlReader]::Load($reader)
    return $btn
}

function Bind-DialogChromeButtons {
    # 把标题栏三件套接上：Save 与 × 走同一条保存路径，Cancel 走"放弃修改"。
    #
    # 为什么必须放在各弹窗挂完 $chrome.BtnClose.Add_Click 之后再调：
    #   Save 的实现是 RaiseEvent(ClickEvent) 打到 × 上，复用它的处理器。
    #   如果在挂 BtnClose 之前就绑，Save 点下去什么也不会发生 —— 而按钮看上去
    #   一切正常，是最难查的一类"静默失效"。所以调用点必须紧跟 BtnClose 之后。
    #
    # 为什么 Save 用 RaiseEvent 而不是把保存逻辑抽成命名函数：
    #   各弹窗的保存逻辑都闭包着窗口局部状态（$script:EdWin / $script:TkWin …），
    #   抽函数要额外传一堆参数、还得把校验分支原样搬一遍，两份代码迟早漂移。
    #   打一个 Click 事件给 × 是零重复的方案：保存逻辑全世界只有一份。
    #
    # 作用域：处理器里只能读 $script: 和形参 —— 这个函数的局部变量（$close / $Win）
    #   在处理器真正触发时早已随作用域销毁，StrictMode 下直接抛"检索不到变量"，
    #   而异常会被下面的 catch 吞掉，表现成"点 Save / Cancel 没反应"。
    #   所以两个引用一律走 $s.Tag（$s 就是被点的那个按钮，是形参天然带进来的）：
    #     · BtnSave.Tag   = 同 chrome 里的 × 按钮
    #     · BtnCancel.Tag = 该弹窗的 Window
    param($Chrome, $Win)
    if ($null -eq $Chrome) { return }
    $save = $Chrome['BtnSave']
    $cancel = $Chrome['BtnCancel']
    $close = $Chrome['BtnClose']
    # Tag 上放窗体引用。注意 Button.Tag 默认是 $null，直接赋值即可。
    if ($null -ne $save -and $null -ne $close) {
        $save.Tag = @{ kind = 'dlg-save'; close = $close }
        $save.Add_Click({
            param($s, $e)
            try {
                $hit = $null
                if ($null -ne $s -and $null -ne $s.Tag -and ($s.Tag -is [hashtable])) { $hit = $s.Tag['close'] }
                if ($null -eq $hit) { return }
                $hit.RaiseEvent((New-Object System.Windows.RoutedEventArgs(
                    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
                $e.Handled = $true
            } catch { Write-ErrLog ('Dialog save: ' + $_.Exception.Message) }
        })
    }
    if ($null -ne $cancel) {
        $cancel.Tag = @{ kind = 'dlg-cancel'; win = $Win }
        $cancel.Add_Click({
            param($s, $e)
            try {
                $w = $null
                if ($null -ne $s -and $null -ne $s.Tag -and ($s.Tag -is [hashtable])) { $w = $s.Tag['win'] }
                Close-DialogWindow $w $false
                $e.Handled = $true
            } catch { Write-ErrLog ('Dialog cancel: ' + $_.Exception.Message) }
        })
    }
}

function Get-EditorChrome {
    # 参数类型不能写 Control：StackPanel 继承自 Panel（Panel -> FrameworkElement -> UIElement），
    # 并不在 Control 这条继承链上，传 StackPanel 会在参数绑定阶段就抛
    # "无法将 StackPanel 转换为 Control"，整个窗口都建不起来。
    param([string]$Title, [System.Windows.FrameworkElement]$Content)
    $wrap = New-Object System.Windows.Controls.Grid
    for ($i = 0; $i -lt 2; $i++) {
        $rd = New-Object System.Windows.Controls.RowDefinition
        if ($i -eq 0) { $rd.Height = [System.Windows.GridLength]::new(38, 'Pixel') }
        else { $rd.Height = [System.Windows.GridLength]::new(1, 'Star') }
        $wrap.RowDefinitions.Add($rd)
    }
    $bar = New-Object System.Windows.Controls.Border
    $bar.Background = Brush (Get-Pal 'Chrome')
    $bar.BorderBrush = Brush (Get-Pal 'Border')
    $bar.BorderThickness = [System.Windows.Thickness]::new(2, 2, 2, 0)
    $bar.CornerRadius = [System.Windows.CornerRadius]::new(10, 10, 0, 0)
    # 标题栏 = [标题(占满)] + [Save] + [Cancel] + [×]。用 Grid 而不是 DockPanel：
    # DockPanel 要先加的被停靠项，写反了标题会被按钮挤到中间。
    # 固定宽度列的尺寸必须在这里跟按钮的 Width + Margin 对齐，改一处要同步另一处，
    # 否则 Save 会被裁掉一半（Grid 不会因为内容超宽就撑开）。
    $barGrid = New-Object System.Windows.Controls.Grid
    $cdTitle = New-Object System.Windows.Controls.ColumnDefinition
    $cdTitle.Width = [System.Windows.GridLength]::new(1, 'Star')
    $barGrid.ColumnDefinitions.Add($cdTitle)
    foreach ($px in @(70.0, 74.0, 34.0)) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = [System.Windows.GridLength]::new($px, 'Pixel')
        $barGrid.ColumnDefinitions.Add($cd)
    }

    $barTxt = New-Txt -Text $Title -Size 12 -Color (Get-Pal 'Ink') -Weight 'Semi'
    $barTxt.VerticalAlignment = 'Center'
    $barTxt.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
    [System.Windows.Controls.Grid]::SetColumn($barTxt, 0)
    [void]$barGrid.Children.Add($barTxt)

    $btnSave = New-DialogSaveButton
    $btnSave.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($btnSave, 1)
    [void]$barGrid.Children.Add($btnSave)

    $btnCancel = New-DialogCancelButton
    $btnCancel.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($btnCancel, 2)
    [void]$barGrid.Children.Add($btnCancel)

    $btnClose = New-DialogCloseButton
    $btnClose.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($btnClose, 3)
    [void]$barGrid.Children.Add($btnClose)

    $bar.Child = $barGrid
    [System.Windows.Controls.Grid]::SetRow($bar, 0)
    [void]$wrap.Children.Add($bar)

    $body = New-Object System.Windows.Controls.Border
    $body.Background = Brush (Get-Pal 'Card')
    $body.BorderBrush = Brush (Get-Pal 'Border')
    $body.BorderThickness = [System.Windows.Thickness]::new(2, 0, 2, 2)
    $body.CornerRadius = [System.Windows.CornerRadius]::new(0, 0, 10, 10)
    $body.Child = $Content
    [System.Windows.Controls.Grid]::SetRow($body, 1)
    [void]$wrap.Children.Add($body)

    $root = New-Object System.Windows.Controls.Border
    $root.Background = Brush (Get-Pal 'Backdrop')
    $root.CornerRadius = [System.Windows.CornerRadius]::new(12)
    $root.Padding = [System.Windows.Thickness]::new(0)
    $root.Child = $wrap
    return @{ Root = $root; Bar = $bar; BarText = $barTxt;
              BtnSave = $btnSave; BtnCancel = $btnCancel; BtnClose = $btnClose }
}

# ---------------------------------------------------------------------------
#  新建 / 编辑日程
# ---------------------------------------------------------------------------
function Show-EventEditorWindow {
    param([string]$Id = '', [string]$PrefillDate = '', [int]$PrefillStart = -1, [int]$PrefillEnd = -1)

    $script:EdEditing = $false
    $script:EdEv = $null
    if ($Id) {
        $hit = @($script:Events | Where-Object { [string]$_.id -eq $Id })
        if ($hit.Count -gt 0) { $script:EdEv = $hit[0]; $script:EdEditing = $true }
    }

    $dStr = Fmt-Date $script:Selected
    $sStr = '09:00'; $eStr = '10:00'; $tStr = ''; $tagStr = 'work'
    $repeatVal = 'None'; $everyVal = '1'; $untilVal = ''
    $monthLastVal = $false; $reminderVal = 'No reminder'
    if (-not [string]::IsNullOrWhiteSpace($PrefillDate)) { $dStr = $PrefillDate }
    if ($PrefillStart -ge 0) { $sStr = Min-To-HHMM $PrefillStart }
    if ($PrefillEnd -gt $PrefillStart) { $eStr = Min-To-HHMM $PrefillEnd }
    if ($script:EdEditing) {
        $dStr = [string]$script:EdEv.date
        $sStr = Min-To-HHMM ([int]$script:EdEv.start)
        $eStr = Min-To-HHMM ([int]$script:EdEv.end)
        $tStr = [string]$script:EdEv.title
        $tagStr = [string]$script:EdEv.tag
        if (-not $tagStr) { $tagStr = 'work' }
        if ($script:EdEv.PSObject.Properties.Name -contains 'repeat') {
            $rp = [string]$script:EdEv.repeat
            if ($rp -eq 'daily') { $repeatVal = 'Daily' }
            elseif ($rp -eq 'weekly') { $repeatVal = 'Weekly' }
            elseif ($rp -eq 'monthly') { $repeatVal = 'Monthly' }
        }
        if ($script:EdEv.PSObject.Properties.Name -contains 'repeatEvery') { $everyVal = [string]$script:EdEv.repeatEvery }
        if ($script:EdEv.PSObject.Properties.Name -contains 'repeatUntil') { $untilVal = [string]$script:EdEv.repeatUntil }
        if ($script:EdEv.PSObject.Properties.Name -contains 'repeatMonthMode') { $monthLastVal = ([string]$script:EdEv.repeatMonthMode -eq 'last') }
        if ($script:EdEv.PSObject.Properties.Name -contains 'reminderMin') {
            $rm = [int]$script:EdEv.reminderMin
            if ($rm -gt 0) { $reminderVal = [string]$rm + ' min before' }
        }
    }

    $script:EdWin = New-Object System.Windows.Window
    $script:EdWin.Title = 'Event'
    $script:EdWin.WindowStyle = 'None'
    $script:EdWin.AllowsTransparency = $true
    $script:EdWin.Background = $null
    $script:EdWin.ResizeMode = 'NoResize'
    $script:EdWin.SizeToContent = 'WidthAndHeight'
    $script:EdWin.WindowStartupLocation = 'CenterOwner'
    $script:EdWin.ShowInTaskbar = $false
    $script:EdWin.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
    $sp.Width = 388
    [void]$sp.Children.Add((New-Txt -Text $(if ($script:EdEditing) { 'Edit event' } else { 'New event' }) `
        -Size 18 -Color (Get-Pal 'Ink') -Weight 'Bold'))

    $script:EdTbTitle = New-EditorField $sp 'Title' $tStr
    $script:EdTbDate  = New-EditorField $sp 'Date (yyyy-MM-dd)' $dStr

    $row = New-Object System.Windows.Controls.Grid
    $cdA = New-Object System.Windows.Controls.ColumnDefinition
    $cdA.Width = [System.Windows.GridLength]::new(1, 'Star'); $row.ColumnDefinitions.Add($cdA)
    $cdB = New-Object System.Windows.Controls.ColumnDefinition
    $cdB.Width = [System.Windows.GridLength]::new(10, 'Pixel'); $row.ColumnDefinitions.Add($cdB)
    $cdC = New-Object System.Windows.Controls.ColumnDefinition
    $cdC.Width = [System.Windows.GridLength]::new(1, 'Star'); $row.ColumnDefinitions.Add($cdC)

    $colA = New-Object System.Windows.Controls.StackPanel
    [void]$colA.Children.Add((New-Txt -Text 'Start (HH:mm)' -Size 11 -Color (Get-Pal 'InkFaint')))
    $script:EdTbStart = New-Object System.Windows.Controls.TextBox
    $script:EdTbStart.Text = $sStr; $script:EdTbStart.Height = 32; $script:EdTbStart.FontSize = 13
    $script:EdTbStart.Background = Brush (Get-Pal 'CardAlt'); $script:EdTbStart.Foreground = Brush (Get-Pal 'Ink')
    $script:EdTbStart.BorderBrush = Brush (Get-Pal 'Border'); $script:EdTbStart.BorderThickness = [System.Windows.Thickness]::new(2)
    $script:EdTbStart.Padding = [System.Windows.Thickness]::new(6, 3, 6, 3)
    $script:EdTbStart.VerticalContentAlignment = 'Center'
    [void]$colA.Children.Add($script:EdTbStart)
    [System.Windows.Controls.Grid]::SetColumn($colA, 0); [void]$row.Children.Add($colA)

    $colB = New-Object System.Windows.Controls.StackPanel
    [void]$colB.Children.Add((New-Txt -Text 'End (HH:mm)' -Size 11 -Color (Get-Pal 'InkFaint')))
    $script:EdTbEnd = New-Object System.Windows.Controls.TextBox
    $script:EdTbEnd.Text = $eStr; $script:EdTbEnd.Height = 32; $script:EdTbEnd.FontSize = 13
    $script:EdTbEnd.Background = Brush (Get-Pal 'CardAlt'); $script:EdTbEnd.Foreground = Brush (Get-Pal 'Ink')
    $script:EdTbEnd.BorderBrush = Brush (Get-Pal 'Border'); $script:EdTbEnd.BorderThickness = [System.Windows.Thickness]::new(2)
    $script:EdTbEnd.Padding = [System.Windows.Thickness]::new(6, 3, 6, 3)
    $script:EdTbEnd.VerticalContentAlignment = 'Center'
    [void]$colB.Children.Add($script:EdTbEnd)
    [System.Windows.Controls.Grid]::SetColumn($colB, 2); [void]$row.Children.Add($colB)

    $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 9)
    [void]$sp.Children.Add($row)

    # 重复与提醒
    $script:EdRepeat = New-ComboField $sp 'Repeat' $repeatVal @('None','Daily','Weekly','Monthly')
    $script:EdRepeat.IsEditable = $false
    $script:EdEvery = New-EditorField $sp 'Repeat every N days / weeks / months' $everyVal
    $script:EdUntil = New-EditorField $sp 'Repeat until (optional, yyyy-MM-dd)' $untilVal
    $monthRow = New-Object System.Windows.Controls.StackPanel
    $monthRow.Orientation = 'Horizontal'
    $monthRow.Margin = [System.Windows.Thickness]::new(0, -5, 0, 10)
    $script:EdMonthLast = New-Object System.Windows.Controls.CheckBox
    $script:EdMonthLast.Content = 'Monthly: use the last day of month'
    $script:EdMonthLast.IsChecked = $monthLastVal
    $script:EdMonthLast.FontSize = 11
    $script:EdMonthLast.Foreground = Brush (Get-Pal 'InkSoft')
    [void]$monthRow.Children.Add($script:EdMonthLast)
    [void]$sp.Children.Add($monthRow)
    $script:EdReminder = New-ComboField $sp 'Reminder' $reminderVal @('No reminder','5 min before','10 min before','15 min before')
    $script:EdReminder.IsEditable = $false

    # 标签按钮组
    [void]$sp.Children.Add((New-Txt -Text 'Tag' -Size 10 -Color (Get-Pal 'InkFaint')))
    $tagRow = New-Object System.Windows.Controls.StackPanel
    $tagRow.Orientation = 'Horizontal'
    $tagRow.Margin = [System.Windows.Thickness]::new(0, 2, 0, 12)
    $script:EdTag = $tagStr
    $tagColors = [ordered]@{ work = 'AccentEvent'; focus = 'AccentFocus'; life = 'AccentTask' }
    $tagBtns = @{}
    foreach ($k in $tagColors.Keys) {
        $label = $k.Substring(0, 1).ToUpper() + $k.Substring(1)
        # 注意：按钮没有 TagColorKey 这种属性（写上去会抛"在此对象上找不到属性"，
        # 而且整个编辑窗口都建不起来）。配色表统一放 $script:EdTagColors。
        $b = New-PixBtn -Text $label -Bg (Get-Pal 'Card') -Fg (Get-Pal 'Ink') -W 94 -H 26 -FontSize 11 -Tag $k
        $b.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
        $tagBtns[$k] = $b
        [void]$tagRow.Children.Add($b)
    }
    $script:EdTagButtons = $tagBtns
    $script:EdTagColors = $tagColors
    foreach ($k in $tagColors.Keys) {
        $bb = $tagBtns[$k]
        # 处理器里只能看见 $script: 和形参：$bb / $tagBtns / $paintTags 都是函数局部
        # 变量，回调触发时早已随作用域销毁。sender 从形参拿，重绘走命名函数。
        $bb.Add_Click({
            param($s, $e)
            if ($null -ne $s -and $null -ne $s.Tag) { Update-TagChipSelection ([string]$s.Tag) }
        })
    }
    Update-TagChipSelection
    [void]$sp.Children.Add($tagRow)

    $script:EdErr = New-Txt -Text '' -Size 10 -Color (Get-Pal 'AccentEvent') -Weight 'Semi'
    $script:EdErr.Visibility = 'Collapsed'
    $script:EdErr.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    [void]$sp.Children.Add($script:EdErr)

    # 底部不再放 Cancel / Save：保存动作挂到标题栏右上角的 × 上（见 Get-EditorChrome）。
    # 校验失败的提示留在 $script:EdErr 那一行，它就在输入区下方，比底部按钮更靠近出错的地方。

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.MaxHeight = 620
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $scroll.Content = $sp
    $chrome = Get-EditorChrome 'Event' $scroll
    $script:EdWin.Content = $chrome.Root
    $chrome.Bar.Add_MouseLeftButtonDown({
        param($s, $e)
        if (Test-ClickOnButton $e) { return }   # 点在 × 上：交给按钮，别拖窗口
        try { $script:EdWin.DragMove() } catch { }
    })
    try {
        if ($null -ne $script:MainWindow -and $script:MainWindow.IsVisible) {
            $script:EdWin.Owner = $script:MainWindow
            $script:EdWin.WindowStartupLocation = 'CenterOwner'
        } else {
            $script:EdWin.WindowStartupLocation = 'CenterScreen'
        }
    } catch { $script:EdWin.WindowStartupLocation = 'CenterScreen' }

    $script:EdWin.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') { Close-DialogWindow $script:EdWin $false }
    })

    # × = 保存并关闭（原 Save 的全部逻辑原样搬过来）；Esc = 放弃（上面的 KeyDown）。
    $chrome.BtnClose.Add_Click({
        $title = ([string]$script:EdTbTitle.Text).Trim()
        if ([string]::IsNullOrWhiteSpace($title)) {
            $script:EdErr.Text = 'Title is required.'
            $script:EdErr.Visibility = 'Visible'
            return
        }
        $dt = $null
        try { $dt = [datetime]::ParseExact(([string]$script:EdTbDate.Text).Trim(), 'yyyy-MM-dd', $null) } catch { }
        if ($null -eq $dt) {
            $script:EdErr.Text = 'Date must look like 2026-09-24.'
            $script:EdErr.Visibility = 'Visible'
            return
        }
        $sMin = Parse-HHMM ([string]$script:EdTbStart.Text)
        $eMin = Parse-HHMM ([string]$script:EdTbEnd.Text)
        if ($sMin -lt 0 -or $eMin -lt 0) {
            $script:EdErr.Text = 'Time must look like 09:30.'
            $script:EdErr.Visibility = 'Visible'
            return
        }
        if ($eMin -le $sMin) { $eMin = [math]::Min(1439, $sMin + 30) }

        $every = 0
        if (-not [int]::TryParse(([string]$script:EdEvery.Text).Trim(), [ref]$every) -or $every -lt 1) {
            $script:EdErr.Text = 'Repeat interval must be a positive number.'
            $script:EdErr.Visibility = 'Visible'
            return
        }
        $until = ''
        $untilRaw = ([string]$script:EdUntil.Text).Trim()
        if (-not [string]::IsNullOrWhiteSpace($untilRaw)) {
            try { $until = Fmt-Date ([datetime]::ParseExact($untilRaw, 'yyyy-MM-dd', $null)) }
            catch {
                $script:EdErr.Text = 'Repeat until must look like 2026-12-31.'
                $script:EdErr.Visibility = 'Visible'
                return
            }
        }
        $repeat = ([string]$script:EdRepeat.Text).ToLowerInvariant()
        if (@('none','daily','weekly','monthly') -notcontains $repeat) { $repeat = 'none' }
        $monthMode = 'day'
        if ([bool]$script:EdMonthLast.IsChecked) { $monthMode = 'last' }
        $reminderMin = 0
        if ([string]$script:EdReminder.Text -like '5*') { $reminderMin = 5 }
        elseif ([string]$script:EdReminder.Text -like '10*') { $reminderMin = 10 }
        elseif ([string]$script:EdReminder.Text -like '15*') { $reminderMin = 15 }

        if ($script:EdEditing) {
            # 只改用户看得见的四个字段，其余（id / note / done）原样保留
            $script:EdEv.date = Fmt-Date $dt
            $script:EdEv.start = $sMin
            $script:EdEv.end = $eMin
            $script:EdEv.title = $title
            $script:EdEv.tag = $script:EdTag
            $script:EdEv.repeat = $repeat
            $script:EdEv.repeatEvery = $every
            $script:EdEv.repeatUntil = $until
            $script:EdEv.repeatMonthMode = $monthMode
            $script:EdEv.reminderMin = $reminderMin
            $script:EdEv.reminderKey = ''
        } else {
            [void]$script:Events.Add([pscustomobject]@{
                id = (New-Id); date = Fmt-Date $dt
                start = $sMin; end = $eMin
                title = $title; tag = $script:EdTag; note = ''; done = $false
                repeat = $repeat; repeatEvery = $every; repeatUntil = $until
                repeatMonthMode = $monthMode; reminderMin = $reminderMin; reminderKey = ''
            })
        }
        Save-Data
        $script:Selected = $dt
        $script:Anchor = $dt
        Close-DialogWindow $script:EdWin $true
        Refresh-All
    })
    # 标题栏 Save / Cancel 接上（必须在 × 的处理器挂好之后调，见函数注释）
    Bind-DialogChromeButtons $chrome $script:EdWin
    $script:EdTbTitle.Focus() | Out-Null
    return $script:EdWin
}

# ---------------------------------------------------------------------------
#  设置 / 专注统计
# ---------------------------------------------------------------------------
function Save-SettingsDialogValues {
    # 把设置窗口里的所有控件读回 $script:Settings 并落盘。
    #
    # 为什么抽成命名函数而不是写在 × 的处理器里：
    #   第四轮设置项涨到 7 个，处理器里再堆这些分支会长得看不清；
    #   而且"字号 / 主题"这类改动需要在别处复用（例如将来加"恢复默认"按钮）。
    #   处理器只负责"调它、关窗、刷新"，逻辑在这儿。
    #
    # 返回值：$true = 全部接受；$false = 有校验失败（窗口不该关）。
    # 校验失败时错误显示在 $script:SetErr 那一行（新增），不弹 MessageBox ——
    # 与项目里其它弹窗一致：错误提示留在出错的地方附近。
    $script:SetErr.Visibility = 'Collapsed'

    # ---- 番茄钟时长（第三轮就有） ----
    $m = 0
    if (-not [int]::TryParse(([string]$script:SetTbPomo.Text).Trim(), [ref]$m) -or $m -lt 0 -or $m -gt 99) {
        $script:SetErr.Text = 'Session length must be a whole number from 0 to 99 minutes (0 = no countdown).'
        $script:SetErr.Visibility = 'Visible'
        return $false
    }

    # ---- 字号档位 ----
    $scaleVal = 1.0
    $scaleName = [string]$script:SetUiScale.Text
    if ($script:SetScaleChoices.Contains($scaleName)) {
        $scaleVal = [double]$script:SetScaleChoices[$scaleName]
    } else {
        # 用户手打了别的字（ComboBox 是可编辑的）：不报错，静默回落到 Normal，
        # 但把控件文字改回去 —— 否则用户会以为"我输入的值生效了"。
        $scaleVal = 1.0
        $scaleName = 'Normal'
        $script:SetUiScale.Text = 'Normal'
    }

    # ---- 周视图默认时段 ----
    $weekRange = ([string]$script:SetWeekRange.Text).Trim()
    $rangeOk = $false
    if ($weekRange -match '^(\d{1,2})-(\d{1,2})$') {
        $rh1 = [int]$Matches[1]; $rh2 = [int]$Matches[2]
        # 与 Set-WeekRange 同一套规则：起 0..23、止 1..24、起 < 止。
        # 两处不能各说各话，否则设置里存了个 Set-WeekRange 会拒绝的区间。
        if ($rh1 -ge 0 -and $rh1 -le 23 -and $rh2 -ge 1 -and $rh2 -le 24 -and $rh1 -lt $rh2) { $rangeOk = $true }
    }
    if (-not $rangeOk) { $weekRange = '0-24' }

    # ---- 落库 ----
    $oldTheme = [string]$script:Theme
    $oldScale = [double]$script:Settings['UiScale']
    $script:Settings['PomodoroMin'] = $m
    $script:Settings['UiScale'] = $scaleVal
    $script:Settings['UiAdaptive'] = [bool]$script:SetUiAdaptive.IsChecked
    $script:Settings['Topmost'] = [bool]$script:SetTopmost.IsChecked
    $script:Settings['CloseToTray'] = [bool]$script:SetCloseToTray.IsChecked
    $script:Settings['WeekViewRange'] = $weekRange
    $newTheme = ([string]$script:SetThemeBox.Text).ToLowerInvariant()
    if (@('light','night') -notcontains $newTheme) { $newTheme = 'light' }
    $script:Settings['Theme'] = $newTheme

    # 应用到运行时状态
    $script:UiScaleUser = $scaleVal
    [void](Update-UiScale)
    $script:TopmostOn = [bool]$script:SetTopmost.IsChecked
    try { if ($null -ne $script:MainWindow) { $script:MainWindow.Topmost = [bool]$script:TopmostOn } } catch { }
    $script:CloseToTray = [bool]$script:Settings['CloseToTray']

    Save-Settings
    Reset-Pomodoro

    # ---- 需要重建界面的改动 ----
    # 字号变了：代码 new 出来的控件（New-Txt / New-PixBtn）字号在创建时就定死了，
    #   只有重建整棵树才会按新倍率重画。所以走 Build-Window（换皮不换窗，窗口对象不变）。
    # 主题变了：Set-Theme 本身就是重建路径，且它会带上新的 UiScale。
    # 两者都变时只走一次（Set-Theme -Sync），避免重建两遍。
    $scaleChanged = ([math]::Abs([double]$oldScale - $scaleVal) -gt 0.001)
    $themeChanged = ($oldTheme -ne $newTheme)
    try {
        if ($themeChanged) {
            Set-Theme $newTheme -Sync
        } elseif ($scaleChanged) {
            Build-Window
            Refresh-All
        } else {
            Apply-UiScale
            Refresh-All
        }
    } catch { Write-ErrLog ('Settings apply: ' + $_.Exception.Message) }

    # 周视图时段：只在用户当前就在周视图时才立刻应用（否则会改掉"下次进周视图"的默认值）
    try {
        if ($weekRange -match '^(\d{1,2})-(\d{1,2})$') {
            if ($script:View -eq 'week') { [void](Set-WeekRange ([int]$Matches[1]) ([int]$Matches[2])) }
        }
    } catch { }

    return $true
}

function Show-SettingsWindow {
    $script:SetWin = New-Object System.Windows.Window
    $script:SetWin.Title = 'Settings'
    $script:SetWin.WindowStyle = 'None'
    $script:SetWin.AllowsTransparency = $true
    $script:SetWin.Background = $null
    $script:SetWin.ResizeMode = 'NoResize'
    $script:SetWin.SizeToContent = 'WidthAndHeight'
    $script:SetWin.WindowStartupLocation = 'CenterOwner'
    $script:SetWin.ShowInTaskbar = $false
    $script:SetWin.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
    $sp.Width = 408
    [void]$sp.Children.Add((New-Txt -Text 'Settings & focus stats' -Size 18 -Color (Get-Pal 'Ink') -Weight 'Bold'))
    $who = ''
    try { $who = [string]$env:USERNAME } catch { }
    if ([string]::IsNullOrWhiteSpace($who)) { $who = 'unknown' }
    [void]$sp.Children.Add((New-Txt -Text ('Windows user: ' + $who) -Size 11 -Color (Get-Pal 'InkSoft')))
    [void]$sp.Children.Add((New-Txt -Text '数据目录（每台电脑每个账户一份，互相隔离）' `
        -Size 10 -Color (Get-Pal 'InkFaint')))

    $dirBox = New-Object System.Windows.Controls.TextBox
    $dirBox.Text = $script:DataDir
    $dirBox.Height = 32; $dirBox.FontSize = 12
    $dirBox.IsReadOnly = $true
    $dirBox.Margin = [System.Windows.Thickness]::new(0, 2, 0, 12)
    $dirBox.Background = Brush (Get-Pal 'CardAlt'); $dirBox.Foreground = Brush (Get-Pal 'InkSoft')
    $dirBox.BorderBrush = Brush (Get-Pal 'BorderSoft'); $dirBox.BorderThickness = [System.Windows.Thickness]::new(2)
    $dirBox.Padding = [System.Windows.Thickness]::new(6, 3, 6, 3)
    $dirBox.VerticalContentAlignment = 'Center'
    [void]$sp.Children.Add($dirBox)

    $script:SetTbPomo = New-EditorField $sp 'Session length (0-99 minutes; 0 = no countdown)' ([string]$script:Settings['PomodoroMin'])

    # ================= 外观（第四轮新增） =================
    #  这一组是用户报的"在 setting 处增加修改字号、调整主题以及其他软件常用设置"。
    #  为什么字号用"档位下拉"而不是滑块：档位是离散的、可预期的（小/标准/大/特大），
    #  滑块会让人反复调、还调不出"和默认一样"的那个点。
    New-SettingsSection $sp 'Appearance'
    # 档位键做成"显示文字 -> 倍率"的映射表，存在 $script: 上：
    # 处理器里要用它做反查，而它是本函数的局部变量（处理器触发时已销毁）。
    $script:SetScaleChoices = [ordered]@{
        'Small'  = 0.85
        'Normal' = 1.00
        'Large'  = 1.15
        'Huge'   = 1.30
    }
    # 反查当前档位名：存的是倍率，配置被手改成一个"不在档位表里"的值时回落到 Normal。
    $curScale = [double]$script:Settings['UiScale']
    $curScaleName = 'Normal'
    foreach ($k in $script:SetScaleChoices.Keys) {
        if ([math]::Abs([double]$script:SetScaleChoices[$k] - $curScale) -lt 0.001) { $curScaleName = $k; break }
    }
    $script:SetUiScale = New-ComboField $sp 'Text size  (also follows the window width)' $curScaleName @('Small','Normal','Large','Huge')
    $script:SetUiScale.IsEditable = $false

    $script:SetUiAdaptive = New-ToggleRow $sp 'Let text size follow the window width' `
        ([bool]$script:Settings['UiAdaptive']) `
        'On: text grows a little in wide windows and shrinks in narrow ones. Off: text size only depends on the choice above.'

    $script:SetThemeBox = New-ComboField $sp 'Theme' $(if ($script:Theme -eq 'night') { 'Night' } else { 'Light' }) @('Light','Night')
    $script:SetThemeBox.IsEditable = $false

    # ================= Window（第四轮新增） =================
    New-SettingsSection $sp 'Window'
    $script:SetTopmost = New-ToggleRow $sp 'Keep the window on top of other windows' `
        ([bool]$script:Settings['Topmost'])
    $script:SetCloseToTray = New-ToggleRow $sp 'Closing the window hides it to the tray' `
        ([bool]$script:Settings['CloseToTray']) `
        'On: the x button hides the window and the app keeps running in the tray. Off: the x button asks whether to quit.'
    $script:SetWeekRange = New-ComboField $sp 'Hours shown in the week view by default' `
        ([string]$script:Settings['WeekViewRange']) @('0-24','8-20','6-22','9-18')
    $script:SetWeekRange.IsEditable = $false

    # 近 7 天专注柱状
    [void]$sp.Children.Add((New-Txt -Text 'Focus last 7 days (minutes)' -Size 10 -Color (Get-Pal 'InkFaint')))
    $vals = @(Get-FocusStats)
    $chart = New-Object System.Windows.Controls.Grid
    $chart.Height = 116
    $chart.Margin = [System.Windows.Thickness]::new(0, 4, 0, 10)
    for ($i = 0; $i -lt 7; $i++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = [System.Windows.GridLength]::new(1, 'Star')
        $chart.ColumnDefinitions.Add($cd)
    }
    $maxV = 1
    foreach ($v in $vals) { if ([int]$v -gt $maxV) { $maxV = [int]$v } }
    for ($i = 0; $i -lt 7; $i++) {
        $col = New-Object System.Windows.Controls.StackPanel
        $col.VerticalAlignment = 'Bottom'
        $col.HorizontalAlignment = 'Center'
        $v = [int]$vals[$i]
        $bh = 74.0 * ($v / [double]$maxV)
        if ($bh -lt 3.0) { $bh = 3.0 }
        $bar = New-Bd -Bg (Get-Pal 'AccentFocus') -Border (Get-Pal 'Border') -Radius 5 -Bw 2
        $bar.Height = $bh
        $bar.Width = 32
        $bar.HorizontalAlignment = 'Center'
        [void]$col.Children.Add($bar)
        $lb = New-Txt -Text ([string]$v) -Size 9 -Color (Get-Pal 'InkFaint')
        $lb.HorizontalAlignment = 'Center'
        [void]$col.Children.Add($lb)
        [System.Windows.Controls.Grid]::SetColumn($col, $i)
        [void]$chart.Children.Add($col)
    }
    [void]$sp.Children.Add($chart)

    $total = 0; foreach ($v in $vals) { $total += [int]$v }
    $pomoLen = [int]$script:Settings['PomodoroMin']
    if ($pomoLen -lt 1) { $pomoLen = 25 }
    $pomos = [int][math]::Floor($total / [double]$pomoLen)
    $doneN = @($script:Events | Where-Object { [bool]$_.done }).Count
    $allN = @($script:Events).Count
    $openN = @($script:Tasks | Where-Object { -not [bool]$_.done }).Count
    [void]$sp.Children.Add((New-Txt -Text ("This week {0} min · {1} pomodoros" -f $total, $pomos) `
        -Size 12 -Color (Get-Pal 'Ink') -Weight 'Semi'))
    [void]$sp.Children.Add((New-Txt -Text ("Events {0} (done {1}) · Open tasks {2}" -f $allN, $doneN, $openN) `
        -Size 11 -Color (Get-Pal 'InkSoft')))

    # 校验错误行：默认折叠，只有在 Save-SettingsDialogValues 返回 $false 时才显形。
    #  为什么放在按钮行上方而不是底部：底部按钮行已撤销，这里是唯一"离眼睛近"的地方；
    #  而且错误行出现/消失会推挤下面的按钮，反而更醒目。
    $script:SetErr = New-Txt -Text '' -Size 10 -Color (Get-Pal 'AccentEvent') -Weight 'Semi'
    $script:SetErr.Visibility = 'Collapsed'
    $script:SetErr.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    $script:SetErr.TextWrapping = 'Wrap'
    [void]$sp.Children.Add($script:SetErr)

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'
    $btnRow.HorizontalAlignment = 'Right'
    $btnRow.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    # 只留两个"动作"按钮；保存/放弃统一走标题栏的 Save / Cancel / ×（三者语义见 New-DialogSaveButton 注释）。
    $bReset = New-PixBtn -Text 'Reset timer' -Bg (Get-Pal 'Card') -Fg (Get-Pal 'Ink') -W 110 -H 34 -FontSize 12
    $bOpen = New-PixBtn -Text 'Open folder' -Bg (Get-Pal 'Card') -Fg (Get-Pal 'Ink') -W 106 -H 34 -FontSize 12
    $bReset.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [void]$btnRow.Children.Add($bReset)
    [void]$btnRow.Children.Add($bOpen)
    [void]$sp.Children.Add($btnRow)

    $chrome = Get-EditorChrome 'Settings' $sp
    $script:SetWin.Content = $chrome.Root
    $chrome.Bar.Add_MouseLeftButtonDown({
        param($s, $e)
        if (Test-ClickOnButton $e) { return }
        try { $script:SetWin.DragMove() } catch { }
    })
    try {
        if ($null -ne $script:MainWindow -and $script:MainWindow.IsVisible) { $script:SetWin.Owner = $script:MainWindow }
    } catch { }
    $script:SetWin.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') { Close-DialogWindow $script:SetWin $false }
    })
    $bReset.Add_Click({
        Reset-Pomodoro
        $script:SetTbPomo.Text = [string]$script:Settings['PomodoroMin']
        Close-DialogWindow $script:SetWin $true
    })
    $bOpen.Add_Click({ Open-DataFolder })
    # × / Save 都走 Save-SettingsDialogValues（统一落库入口），Cancel 走 Bind-DialogChromeButtons 的
    #   Close-DialogWindow $win $false —— 三者语义差异是这一轮的验收点，不能各自为政。
    #   这里仍然保留 × 的原生处理器（Bind-DialogChromeButtons 只是把 Save 转发到 ×，不覆盖 × 自身）。
    $chrome.BtnClose.Add_Click({
        try {
            if (Save-SettingsDialogValues) { Close-DialogWindow $script:SetWin $true }
        } catch {
            # 真正把异常露出来：静默吞掉会导致"点保存没反应"这种最难查的 bug。
            try {
                if ($null -ne $script:SetErr) {
                    $script:SetErr.Text = ('Could not save: ' + $_.Exception.Message)
                    $script:SetErr.Visibility = 'Visible'
                }
            } catch { }
            Write-ErrLog ('Settings save: ' + $_.Exception.Message)
        }
    })
    Bind-DialogChromeButtons $chrome $script:SetWin
    return $script:SetWin
}

# ---------------------------------------------------------------------------
#  日期详情窗口：展开月视图中的 +N 日程
# ---------------------------------------------------------------------------
function Show-DayAgendaWindow {
    param([datetime]$Date)
    $win = New-Object System.Windows.Window
    $script:DayAgendaWin = $win
    $script:DayAgendaDate = $Date
    $win.Title = 'Day agenda'
    $win.WindowStyle = 'None'
    $win.AllowsTransparency = $true
    $win.Background = $null
    $win.ResizeMode = 'NoResize'
    $win.SizeToContent = 'WidthAndHeight'
    $win.WindowStartupLocation = 'CenterOwner'
    $win.ShowInTaskbar = $false
    $win.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
    $sp.Width = 400
    [void]$sp.Children.Add((New-Txt -Text ($Date.ToString('yyyy-MM-dd') + ' agenda') -Size 18 -Color (Get-Pal 'Ink') -Weight 'Bold'))
    $events = @(Events-On $Date)
    if ($events.Count -eq 0) {
        [void]$sp.Children.Add((New-Txt -Text 'No events on this day.' -Size 12 -Color (Get-Pal 'InkFaint')))
    } else {
        foreach ($ev in $events) {
            $btn = New-PixBtn -Text (('{0}-{1}  {2}' -f (Min-To-HHMM ([int]$ev.start)), (Min-To-HHMM ([int]$ev.end)), [string]$ev.title)) `
                -Bg (Get-Pal 'CardAlt') -Fg (Get-Pal 'Ink') -W 360 -H 40 -FontSize 12
            $btn.Tag = @{ id = [string]$ev.id; win = $win }
            $btn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 7)
            $btn.Add_Click({
                param($s, $e)
                try { $script:DayAgendaWin.Close(); Open-EventEditor -Id ([string]$s.Tag['id']) } catch { }
            })
            [void]$sp.Children.Add($btn)
        }
    }
    $add = New-PixBtn -Text '+ New event' -Bg (Get-Pal 'AccentEvent') -Fg '#FFFFFF' -W 360 -H 36 -FontSize 12
    $add.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    $add.Add_Click({ try { $script:DayAgendaWin.Close(); Open-EventEditor -PrefillDate (Fmt-Date $script:DayAgendaDate) } catch { } })
    [void]$sp.Children.Add($add)
    $chrome = Get-EditorChrome 'Day agenda' $sp
    $win.Content = $chrome.Root
    # 处理器里必须走 $script:DayAgendaWin：$win 是本函数的局部变量，回调触发时
    # 那个作用域早就销毁了（StrictMode 下硬抛，又被 catch 吞成"拖不动/Esc 没反应"）。
    $chrome.Bar.Add_MouseLeftButtonDown({
        param($s, $e)
        if (Test-ClickOnButton $e) { return }
        try { $script:DayAgendaWin.DragMove() } catch { }
    })
    $chrome.BtnClose.Add_Click({ Close-DialogWindow $script:DayAgendaWin $true })
    # 当日议程是只读列表：Save 与 × 同义（都是"关掉"），Cancel 也是"关掉"。
    # 仍然接上，保证六个弹窗的标题栏按钮行为一致 —— 一个弹窗不响应 Save
    # 会让人以为程序卡了，比"这个按钮其实没意义"更糟。
    Bind-DialogChromeButtons $chrome $win
    try { if ($null -ne $script:MainWindow -and $script:MainWindow.IsVisible) { $win.Owner = $script:MainWindow } } catch { }
    $win.Add_KeyDown({ param($s,$e) if ($e.Key -eq 'Escape') { Close-DialogWindow $script:DayAgendaWin $false } })
    return $win
}

function New-TaskSubtaskRow {
    param($Stack, [string]$Text, [bool]$Done = $false)
    if ($null -eq $Stack) { return }
    $row = New-Object System.Windows.Controls.Grid
    for ($i = 0; $i -lt 3; $i++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        if ($i -eq 0) { $cd.Width = [System.Windows.GridLength]::new(28, 'Pixel') }
        elseif ($i -eq 1) { $cd.Width = [System.Windows.GridLength]::new(1, 'Star') }
        else { $cd.Width = [System.Windows.GridLength]::new(32, 'Pixel') }
        [void]$row.ColumnDefinitions.Add($cd)
    }
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.IsChecked = $Done; $cb.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($cb, 0); [void]$row.Children.Add($cb)
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Text = $Text; $tb.Height = 28; $tb.FontSize = 12
    $tb.Background = Brush (Get-Pal 'CardAlt'); $tb.Foreground = Brush (Get-Pal 'Ink')
    $tb.BorderBrush = Brush (Get-Pal 'BorderSoft'); $tb.BorderThickness = [System.Windows.Thickness]::new(1)
    [System.Windows.Controls.Grid]::SetColumn($tb, 1); [void]$row.Children.Add($tb)
    $del = New-PixBtn -Text 'x' -Bg (Get-Pal 'Card') -Fg (Get-Pal 'AccentEvent') -W 28 -H 26 -FontSize 10
    $del.Tag = @{ Row = $row; Stack = $Stack }
    $del.Margin = [System.Windows.Thickness]::new(4, 1, 0, 0)
    $del.Add_Click({ param($s,$e) try { [void]$s.Tag['Stack'].Children.Remove($s.Tag['Row']) } catch { } })
    [System.Windows.Controls.Grid]::SetColumn($del, 2); [void]$row.Children.Add($del)
    $row.Tag = @{ Text = $tb; Done = $cb }
    $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
    [void]$Stack.Children.Add($row)
}

# ---------------------------------------------------------------------------
#  任务编辑窗口：新建 / 修改
# ---------------------------------------------------------------------------
function Show-TaskEditorWindow {
    param([string]$Id = '')
    $script:TkEditing = $false
    $script:TkTask = $null
    if ($Id) {
        $hit = @($script:Tasks | Where-Object { [string]$_.id -eq $Id })
        if ($hit.Count -gt 0) {
            $script:TkTask = $hit[0]
            $script:TkEditing = $true
        }
    }
    $textVal = ''
    $dueVal = ''
    $tagVal = 'task'
    $doneVal = $false
    $priorityVal = 'Medium'
    $projectVal = ''
    $estimatedVal = '0'
    $actualVal = '0'
    $dueTimeVal = '09:00'
    $reminderVal = 'No reminder'
    $subtaskLines = ''
    if ($script:TkEditing) {
        $textVal = [string]$script:TkTask.text
        if ($null -ne $script:TkTask.due) { $dueVal = [string]$script:TkTask.due }
        if (-not [string]::IsNullOrWhiteSpace([string]$script:TkTask.tag)) { $tagVal = [string]$script:TkTask.tag }
        $doneVal = [bool]$script:TkTask.done
        if ($script:TkTask.PSObject.Properties.Name -contains 'priority') { $priorityVal = [string]$script:TkTask.priority }
        if ($script:TkTask.PSObject.Properties.Name -contains 'project') { $projectVal = [string]$script:TkTask.project }
        if ($script:TkTask.PSObject.Properties.Name -contains 'estimatedMin') { $estimatedVal = [string]$script:TkTask.estimatedMin }
        if ($script:TkTask.PSObject.Properties.Name -contains 'actualMin') { $actualVal = [string]$script:TkTask.actualMin }
        if ($script:TkTask.PSObject.Properties.Name -contains 'dueTime') { $dueTimeVal = [string]$script:TkTask.dueTime }
        if ($script:TkTask.PSObject.Properties.Name -contains 'reminderMin' -and [int]$script:TkTask.reminderMin -gt 0) {
            $reminderVal = [string]$script:TkTask.reminderMin + ' min before'
        }
        if ($script:TkTask.PSObject.Properties.Name -contains 'subtasks') {
            $ls = New-Object System.Collections.ArrayList
            foreach ($st in @($script:TkTask.subtasks)) {
                $prefix = $(if ([bool]$st.done) { '[x] ' } else { '[ ] ' })
                [void]$ls.Add($prefix + [string]$st.text)
            }
            $subtaskLines = ($ls.ToArray() -join [Environment]::NewLine)
        }
    }

    $script:TkWin = New-Object System.Windows.Window
    $script:TkWin.Title = 'Task'
    $script:TkWin.WindowStyle = 'None'
    $script:TkWin.AllowsTransparency = $true
    $script:TkWin.Background = $null
    $script:TkWin.ResizeMode = 'NoResize'
    $script:TkWin.SizeToContent = 'WidthAndHeight'
    $script:TkWin.WindowStartupLocation = 'CenterOwner'
    $script:TkWin.ShowInTaskbar = $false
    $script:TkWin.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
    $sp.Width = 390
    [void]$sp.Children.Add((New-Txt -Text $(if ($script:TkEditing) { 'Edit task' } else { 'New task' }) `
        -Size 18 -Color (Get-Pal 'Ink') -Weight 'Bold'))

    $script:TkText = New-EditorField $sp 'Task content' $textVal
    $script:TkDue = New-EditorField $sp 'Due date (optional, yyyy-MM-dd)' $dueVal
    $script:TkDueTime = New-EditorField $sp 'Due time (HH:mm)' $dueTimeVal
    $script:TkPriority = New-ComboField $sp 'Priority' $priorityVal @('High','Medium','Low')
    $script:TkPriority.IsEditable = $false
    $script:TkProject = New-EditorField $sp 'Project / list' $projectVal

    $metricRow = New-Object System.Windows.Controls.Grid
    for ($i = 0; $i -lt 3; $i++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        if ($i -eq 1) { $cd.Width = [System.Windows.GridLength]::new(10, 'Pixel') }
        else { $cd.Width = [System.Windows.GridLength]::new(1, 'Star') }
        [void]$metricRow.ColumnDefinitions.Add($cd)
    }
    $eCol = New-Object System.Windows.Controls.StackPanel
    [void]$eCol.Children.Add((New-Txt -Text 'Estimated minutes' -Size 10 -Color (Get-Pal 'InkFaint')))
    $script:TkEstimated = New-Object System.Windows.Controls.TextBox
    $script:TkEstimated.Text = $estimatedVal; $script:TkEstimated.Height = 30; $script:TkEstimated.FontSize = 12
    $script:TkEstimated.Background = Brush (Get-Pal 'CardAlt'); $script:TkEstimated.Foreground = Brush (Get-Pal 'Ink')
    $script:TkEstimated.BorderBrush = Brush (Get-Pal 'Border'); $script:TkEstimated.BorderThickness = [System.Windows.Thickness]::new(2)
    [void]$eCol.Children.Add($script:TkEstimated)
    [System.Windows.Controls.Grid]::SetColumn($eCol, 0); [void]$metricRow.Children.Add($eCol)
    $aCol = New-Object System.Windows.Controls.StackPanel
    [void]$aCol.Children.Add((New-Txt -Text 'Actual minutes' -Size 10 -Color (Get-Pal 'InkFaint')))
    $script:TkActual = New-Object System.Windows.Controls.TextBox
    $script:TkActual.Text = $actualVal; $script:TkActual.Height = 30; $script:TkActual.FontSize = 12
    $script:TkActual.Background = Brush (Get-Pal 'CardAlt'); $script:TkActual.Foreground = Brush (Get-Pal 'Ink')
    $script:TkActual.BorderBrush = Brush (Get-Pal 'Border'); $script:TkActual.BorderThickness = [System.Windows.Thickness]::new(2)
    [void]$aCol.Children.Add($script:TkActual)
    [System.Windows.Controls.Grid]::SetColumn($aCol, 2); [void]$metricRow.Children.Add($aCol)
    $metricRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    [void]$sp.Children.Add($metricRow)

    $script:TkReminder = New-ComboField $sp 'Reminder' $reminderVal @('No reminder','5 min before','10 min before','15 min before','30 min before')
    $script:TkReminder.IsEditable = $false
    [void]$sp.Children.Add((New-Txt -Text 'Subtasks' -Size 11 -Color (Get-Pal 'InkFaint')))
    $script:TkSubtaskStack = New-Object System.Windows.Controls.StackPanel
    $script:TkSubtaskStack.Margin = [System.Windows.Thickness]::new(0, 4, 0, 6)
    [void]$sp.Children.Add($script:TkSubtaskStack)
    if ($script:TkEditing -and $script:TkTask.PSObject.Properties.Name -contains 'subtasks') {
        foreach ($st in @($script:TkTask.subtasks)) {
            New-TaskSubtaskRow -Stack $script:TkSubtaskStack -Text ([string]$st.text) -Done ([bool]$st.done)
        }
    }
    $subAddRow = New-Object System.Windows.Controls.StackPanel
    $subAddRow.Orientation = 'Horizontal'; $subAddRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $script:TkNewSubtask = New-Object System.Windows.Controls.TextBox
    $script:TkNewSubtask.Height = 30; $script:TkNewSubtask.FontSize = 12; $script:TkNewSubtask.Width = 285
    $script:TkNewSubtask.Background = Brush (Get-Pal 'CardAlt'); $script:TkNewSubtask.Foreground = Brush (Get-Pal 'Ink')
    $script:TkNewSubtask.BorderBrush = Brush (Get-Pal 'BorderSoft'); $script:TkNewSubtask.BorderThickness = [System.Windows.Thickness]::new(1)
    [void]$subAddRow.Children.Add($script:TkNewSubtask)
    $bAddSub = New-PixBtn -Text '+ Add' -Bg (Get-Pal 'AccentTask') -Fg (Get-Pal 'Ink') -W 70 -H 30 -FontSize 10
    $bAddSub.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $bAddSub.Add_Click({ try { $txt = ([string]$script:TkNewSubtask.Text).Trim(); if ($txt) { New-TaskSubtaskRow -Stack $script:TkSubtaskStack -Text $txt -Done $false; $script:TkNewSubtask.Text = '' } } catch { } })
    [void]$subAddRow.Children.Add($bAddSub)
    [void]$sp.Children.Add($subAddRow)

    $script:TkTag = New-ComboField $sp 'Category' $tagVal @('task','work','focus','life')
    $script:TkTag.IsEditable = $false
    $script:TkTag.SelectedItem = $tagVal

    $doneRow = New-Object System.Windows.Controls.StackPanel
    $doneRow.Orientation = 'Horizontal'
    $doneRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    $script:TkDone = New-Object System.Windows.Controls.CheckBox
    $script:TkDone.Content = 'Completed'
    $script:TkDone.IsChecked = $doneVal
    $script:TkDone.FontSize = 13
    $script:TkDone.Foreground = Brush (Get-Pal 'Ink')
    [void]$doneRow.Children.Add($script:TkDone)
    [void]$sp.Children.Add($doneRow)

    $script:TkErr = New-Txt -Text '' -Size 10 -Color (Get-Pal 'AccentEvent') -Weight 'Semi'
    $script:TkErr.Visibility = 'Collapsed'
    $script:TkErr.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    [void]$sp.Children.Add($script:TkErr)

    # 底部不再放 Cancel / Save：保存动作挂到标题栏右上角的 × 上（见 Get-EditorChrome）。

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.MaxHeight = 610
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $scroll.Content = $sp
    $chrome = Get-EditorChrome 'Task' $scroll
    $script:TkWin.Content = $chrome.Root
    $chrome.Bar.Add_MouseLeftButtonDown({
        param($s, $e)
        if (Test-ClickOnButton $e) { return }
        try { $script:TkWin.DragMove() } catch { }
    })
    try {
        if ($null -ne $script:MainWindow -and $script:MainWindow.IsVisible) { $script:TkWin.Owner = $script:MainWindow }
    } catch { }
    $script:TkWin.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') { Close-DialogWindow $script:TkWin $false }
    })
    # × = 保存并关闭（原 Save 的逻辑原样保留）；Esc = 放弃。
    $chrome.BtnClose.Add_Click({
        try {
            $txt = ([string]$script:TkText.Text).Trim()
            if ([string]::IsNullOrWhiteSpace($txt)) {
                $script:TkErr.Text = 'Task content is required.'
                $script:TkErr.Visibility = 'Visible'
                return
            }
            $dueRaw = ([string]$script:TkDue.Text).Trim()
            $due = $null
            if (-not [string]::IsNullOrWhiteSpace($dueRaw)) {
                try { $due = Fmt-Date ([datetime]::ParseExact($dueRaw, 'yyyy-MM-dd', $null)) }
                catch {
                    $script:TkErr.Text = 'Due date must look like 2026-09-24.'
                    $script:TkErr.Visibility = 'Visible'
                    return
                }
            }
            $dueTime = ([string]$script:TkDueTime.Text).Trim()
            $dueMinCheck = Parse-HHMM $dueTime
            if ($dueMinCheck -lt 0) {
                $script:TkErr.Text = 'Due time must look like 09:30.'
                $script:TkErr.Visibility = 'Visible'
                return
            }
            $tag = [string]$script:TkTag.Text
            if ([string]::IsNullOrWhiteSpace($tag)) { $tag = 'task' }
            $priority = ([string]$script:TkPriority.Text).ToLowerInvariant()
            if (@('high','medium','low') -notcontains $priority) { $priority = 'medium' }
            $project = ([string]$script:TkProject.Text).Trim()
            $estimated = 0; $actual = 0
            [void][int]::TryParse(([string]$script:TkEstimated.Text).Trim(), [ref]$estimated)
            [void][int]::TryParse(([string]$script:TkActual.Text).Trim(), [ref]$actual)
            if ($estimated -lt 0) { $estimated = 0 }
            if ($actual -lt 0) { $actual = 0 }
            $reminderMin = 0
            if ([string]$script:TkReminder.Text -like '5*') { $reminderMin = 5 }
            elseif ([string]$script:TkReminder.Text -like '10*') { $reminderMin = 10 }
            elseif ([string]$script:TkReminder.Text -like '15*') { $reminderMin = 15 }
            elseif ([string]$script:TkReminder.Text -like '30*') { $reminderMin = 30 }
            $newSubtasks = New-Object System.Collections.ArrayList
            foreach ($row in @($script:TkSubtaskStack.Children)) {
                if ($null -eq $row -or $null -eq $row.Tag) { continue }
                $raw = ([string]$row.Tag['Text'].Text).Trim()
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                [void]$newSubtasks.Add([pscustomobject]@{
                    id = (New-Id); text = $raw; done = [bool]$row.Tag['Done'].IsChecked
                })
            }
            $subtasks = @($newSubtasks.ToArray())
            if ($script:TkEditing) {
                $script:TkTask.text = $txt
                $script:TkTask.due = $due
                $script:TkTask.dueTime = $dueTime
                $script:TkTask.tag = $tag
                $script:TkTask.done = [bool]$script:TkDone.IsChecked
                $script:TkTask.priority = $priority
                $script:TkTask.project = $project
                $script:TkTask.subtasks = $subtasks
                $script:TkTask.estimatedMin = $estimated
                $script:TkTask.actualMin = $actual
                $script:TkTask.reminderMin = $reminderMin
            } else {
                [void]$script:Tasks.Add([pscustomobject]@{
                    id = (New-Id); text = $txt; done = [bool]$script:TkDone.IsChecked
                    due = $due; dueTime = $dueTime; tag = $tag
                    priority = $priority; project = $project; subtasks = $subtasks
                    estimatedMin = $estimated; actualMin = $actual; reminderMin = $reminderMin
                })
            }
            Save-Data
            Fill-Tasks
            Close-DialogWindow $script:TkWin $true
        } catch { Write-ErrLog ('Task save: ' + $_.Exception.Message) }
    })
    Bind-DialogChromeButtons $chrome $script:TkWin
    $script:TkText.Focus() | Out-Null
    return $script:TkWin
}

# ---------------------------------------------------------------------------
#  专注设置窗口：启用状态 / 时长 / 任务内容 / 计时控制
# ---------------------------------------------------------------------------
function Save-FocusWindowSettings {
    if ($null -eq $script:FoTbDuration) { return $false }
    # 时长范围：0-99 分钟自由填（0 = 不计时，只当作"专注状态开关"）。
    # 上界从 180 收到 99 是刻意的：倒计时按 mm:ss 显示，三位数分钟会撑破浮窗那行 46pt 大字。
    $m = 0
    if (-not [int]::TryParse(([string]$script:FoTbDuration.Text).Trim(), [ref]$m) -or $m -lt 0 -or $m -gt 99) {
        $script:FoErr.Text = 'Session length must be a whole number from 0 to 99 minutes (0 = no countdown).'
        $script:FoErr.Visibility = 'Visible'
        return $false
    }
    # 休息时长上界同步收到 99，跟会话同一套心智模型（也是 mm:ss）
    $breakMin = 0
    if (-not [int]::TryParse(([string]$script:FoBreakMin.Text).Trim(), [ref]$breakMin) -or $breakMin -lt 0 -or $breakMin -gt 99) {
        $script:FoErr.Text = 'Break length must be a whole number from 0 to 99 minutes (0 = skip the break).'
        $script:FoErr.Visibility = 'Visible'
        return $false
    }
    $oldMin = [int]$script:Settings['PomodoroMin']
    $script:Settings['PomodoroMin'] = $m
    $script:Settings['PomodoroEnabled'] = [bool]$script:FoEnabled.IsChecked
    $script:Settings['BreakEnabled'] = [bool]$script:FoBreakEnabled.IsChecked
    $script:Settings['BreakMin'] = $breakMin
    $script:Settings['PomodoroTask'] = ([string]$script:FoTbTask.Text).Trim()
    $script:Pomo.Task = [string]$script:Settings['PomodoroTask']
    $script:FoErr.Visibility = 'Collapsed'
    if (-not [bool]$script:Settings['PomodoroEnabled'] -and [bool]$script:Pomo.Running) {
        $script:Pomo.Running = $false
        if ($null -ne $script:PomoTimer) { $script:PomoTimer.Stop() }
    }
    Save-Settings
    if (($oldMin -ne $m) -and -not [bool]$script:Pomo.Running) { Reset-Pomodoro }
    Update-PomodoroVisual
    return $true
}

function Show-FocusWindow {
    $script:FoWin = New-Object System.Windows.Window
    $script:FoWin.Title = 'Focus'
    $script:FoWin.WindowStyle = 'None'
    $script:FoWin.AllowsTransparency = $true
    $script:FoWin.Background = $null
    $script:FoWin.ResizeMode = 'NoResize'
    $script:FoWin.SizeToContent = 'WidthAndHeight'
    # 位置由 Set-DialogStartPosition 决定（记忆优先，否则居中）：
    # CenterOwner 会在 Show 的一刻覆盖手动赋的 Left/Top，所以不能再用它。
    $script:FoWin.WindowStartupLocation = 'Manual'
    $script:FoWin.ShowInTaskbar = $false
    $script:FoWin.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
    $sp.Width = 438
    [void]$sp.Children.Add((New-Txt -Text 'Focus session' -Size 20 -Color (Get-Pal 'Ink') -Weight 'Bold'))
    [void]$sp.Children.Add((New-Txt -Text 'Set whether focus is available, the session length and what you will work on.' `
        -Size 11 -Color (Get-Pal 'InkSoft')))

    $enabledRow = New-Object System.Windows.Controls.StackPanel
    $enabledRow.Orientation = 'Horizontal'
    $enabledRow.Margin = [System.Windows.Thickness]::new(0, 14, 0, 6)
    $script:FoEnabled = New-Object System.Windows.Controls.CheckBox
    $script:FoEnabled.Content = 'Enable focus timer'
    $script:FoEnabled.IsChecked = [bool]$script:Settings['PomodoroEnabled']
    $script:FoEnabled.FontSize = 13
    $script:FoEnabled.Foreground = Brush (Get-Pal 'Ink')
    $script:FoEnabled.VerticalContentAlignment = 'Center'
    [void]$enabledRow.Children.Add($script:FoEnabled)
    [void]$sp.Children.Add($enabledRow)

    # 0-99 自由填：预设把"常用档"和"边界档"都摆出来 —— 0（不计时）与 99 都在里面，
    # 用户一眼就知道上下界在哪，不用去猜输入框能填多少。
    $durationChoices = @('0','5','10','15','20','25','30','45','60','75','90','99')
    $script:FoTbDuration = New-ComboField $sp 'Session length (choose or type 0-99 minutes; 0 = no countdown)' `
        ([string]$script:Settings['PomodoroMin']) $durationChoices

    $breakRow = New-Object System.Windows.Controls.StackPanel
    $breakRow.Orientation = 'Horizontal'
    $breakRow.Margin = [System.Windows.Thickness]::new(0, -4, 0, 8)
    $script:FoBreakEnabled = New-Object System.Windows.Controls.CheckBox
    $script:FoBreakEnabled.Content = 'Start a break after focus'
    $script:FoBreakEnabled.IsChecked = [bool]$script:Settings['BreakEnabled']
    $script:FoBreakEnabled.FontSize = 12
    $script:FoBreakEnabled.Foreground = Brush (Get-Pal 'Ink')
    [void]$breakRow.Children.Add($script:FoBreakEnabled)
    [void]$sp.Children.Add($breakRow)
    $script:FoBreakMin = New-ComboField $sp 'Break length (choose or type 0-99 minutes; 0 = skip)' `
        ([string]$script:Settings['BreakMin']) @('0','5','10','15','20','30','45','60')

    $taskChoices = @($script:Tasks | ForEach-Object { [string]$_.text } | Sort-Object -Unique)
    $script:FoTbTask = New-ComboField $sp 'Task content (choose an existing task or type a new one)' `
        ([string]$script:Settings['PomodoroTask']) $taskChoices

    $card = New-Bd -Bg (Get-Pal 'CardAlt') -Border (Get-Pal 'Border') -Radius 10
    $card.Padding = [System.Windows.Thickness]::new(18, 14, 18, 14)
    $card.Margin = [System.Windows.Thickness]::new(0, 2, 0, 10)
    # 这块大计时器卡片同时当"抓手"用：Focus 窗口整体是很轻的浮窗，
    # 只能从 38px 标题栏拖太别扭了（这正是"想要可拖动版本"的由来）。
    # 挑卡片而不是整块窗口：卡片里只有文字，不像表单区那样有输入框/下拉框，
    # 从这儿拖不会跟"选文字""开下拉"打架。
    $card.ToolTip = 'Drag here to move this window'
    $csp = New-Object System.Windows.Controls.StackPanel
    $script:FoTimeText = New-Txt -Text '25:00' -Size 46 -Color (Get-Pal 'Ink') -Weight 'Bold'
    $script:FoTimeText.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $script:FoTimeText.HorizontalAlignment = 'Center'
    $script:FoStatusText = New-Txt -Text 'Ready' -Size 12 -Color (Get-Pal 'AccentEvent') -Weight 'Semi'
    $script:FoStatusText.HorizontalAlignment = 'Center'
    $script:FoTaskText = New-Txt -Text 'Task: No task selected' -Size 11 -Color (Get-Pal 'InkSoft')
    $script:FoTaskText.HorizontalAlignment = 'Center'
    $script:FoTaskText.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $script:FoTaskText.MaxWidth = 360
    [void]$csp.Children.Add($script:FoTimeText)
    [void]$csp.Children.Add($script:FoStatusText)
    [void]$csp.Children.Add($script:FoTaskText)
    $card.Child = $csp
    [void]$sp.Children.Add($card)

    $vals = @(Get-FocusStats)
    $total = 0; foreach ($v in $vals) { $total += [int]$v }
    [void]$sp.Children.Add((New-Txt -Text ("Focus last 7 days: {0} min" -f $total) `
        -Size 11 -Color (Get-Pal 'InkFaint')))

    $script:FoErr = New-Txt -Text '' -Size 10 -Color (Get-Pal 'AccentEvent') -Weight 'Semi'
    $script:FoErr.Visibility = 'Collapsed'
    $script:FoErr.Margin = [System.Windows.Thickness]::new(0, 6, 0, 6)
    [void]$sp.Children.Add($script:FoErr)

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'
    $btnRow.HorizontalAlignment = 'Right'
    # Start / Reset 是"动作"，留着；"Save & close" 由标题栏的 × 接管。
    $bStart = New-PixBtn -Text 'Start' -Bg (Get-Pal 'AccentEvent') -Fg '#FFFFFF' -W 94 -H 36 -FontSize 12
    $bReset = New-PixBtn -Text 'Reset' -Bg (Get-Pal 'Card') -Fg (Get-Pal 'Ink') -W 88 -H 36 -FontSize 12
    $bStart.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [void]$btnRow.Children.Add($bStart)
    [void]$btnRow.Children.Add($bReset)
    [void]$sp.Children.Add($btnRow)
    $script:FoStartText = $bStart.Content

    $chrome = Get-EditorChrome 'Focus' $sp
    $script:FoWin.Content = $chrome.Root
    # Content 就位后再定位：Set-DialogStartPosition 要靠内容量出真实尺寸才能居中。
    Set-DialogStartPosition $script:FoWin 'FocusWin'
    $chrome.Bar.Add_MouseLeftButtonDown({
        param($s, $e)
        if (Test-ClickOnButton $e) { return }
        # DragMove 返回＝松手，正好把新位置记下来
        try { $script:FoWin.DragMove(); Save-DialogPos $script:FoWin 'FocusWin' } catch { }
    })
    # 计时器卡片也是抓手（见上面 $card 处的说明）
    Enable-DialogDrag $card $script:FoWin 'FocusWin'
    # 兜底再存一次：位置也可能因为窗口被系统挪动而变，Closing 时读 Left/Top 仍然有效
    $script:FoWin.Add_Closing({
        try { Save-DialogPos $script:FoWin 'FocusWin' } catch { }
    })
    try {
        if ($null -ne $script:MainWindow -and $script:MainWindow.IsVisible) { $script:FoWin.Owner = $script:MainWindow }
    } catch { }
    $script:FoWin.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') { Close-DialogWindow $script:FoWin $false }
    })
    $bStart.Add_Click({
        try {
            if (Save-FocusWindowSettings) {
                if ([bool]$script:Settings['PomodoroEnabled']) {
                    Toggle-Pomodoro
                } else {
                    $script:FoErr.Text = 'Enable the focus timer before starting.'
                    $script:FoErr.Visibility = 'Visible'
                }
            }
        } catch { Write-ErrLog ('Focus start: ' + $_.Exception.Message) }
    })
    $bReset.Add_Click({
        try { if (Save-FocusWindowSettings) { Reset-Pomodoro } } catch { Write-ErrLog ('Focus reset: ' + $_.Exception.Message) }
    })
    # × = 保存设置并关闭；校验不通过就不关（错误提示留在窗口里）。
    $chrome.BtnClose.Add_Click({
        try { if (Save-FocusWindowSettings) { Close-DialogWindow $script:FoWin $true } } catch { Write-ErrLog ('Focus save: ' + $_.Exception.Message) }
    })
    Bind-DialogChromeButtons $chrome $script:FoWin
    Update-PomodoroVisual
    return $script:FoWin
}

# ---------------------------------------------------------------------------
#  头像更换窗口：选择图片、预览、恢复默认
# ---------------------------------------------------------------------------
function Show-AvatarWindow {
    $script:AvWin = New-Object System.Windows.Window
    $script:AvWin.Title = 'Avatar'
    $script:AvWin.WindowStyle = 'None'
    $script:AvWin.AllowsTransparency = $true
    $script:AvWin.Background = $null
    $script:AvWin.ResizeMode = 'NoResize'
    $script:AvWin.SizeToContent = 'WidthAndHeight'
    $script:AvWin.WindowStartupLocation = 'CenterOwner'
    $script:AvWin.ShowInTaskbar = $false
    $script:AvWin.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
    $sp.Width = 410
    [void]$sp.Children.Add((New-Txt -Text 'Your avatar' -Size 20 -Color (Get-Pal 'Ink') -Weight 'Bold'))
    [void]$sp.Children.Add((New-Txt -Text 'Choose a PNG, JPG, BMP or GIF image. It is copied into the app data folder.' `
        -Size 11 -Color (Get-Pal 'InkSoft')))

    $previewBorder = New-Bd -Bg (Get-Pal 'CardAlt') -Border (Get-Pal 'Border') -Radius 12
    $previewBorder.Width = 190; $previewBorder.Height = 190
    $previewBorder.HorizontalAlignment = 'Center'
    $previewBorder.Margin = [System.Windows.Thickness]::new(0, 16, 0, 14)
    $previewGrid = New-Object System.Windows.Controls.Grid
    $script:AvPreviewCanvas = New-Object System.Windows.Controls.Canvas
    $script:AvPreviewCanvas.Width = 190; $script:AvPreviewCanvas.Height = 190
    $script:AvPreviewCanvas.ClipToBounds = $true
    $script:AvPreviewImage = New-Object System.Windows.Controls.Image
    $script:AvPreviewImage.Stretch = 'UniformToFill'
    $script:AvPreviewImage.ClipToBounds = $true
    $script:AvPreviewHintBox = New-Object System.Windows.Controls.Border
    $script:AvPreviewHintBox.VerticalAlignment = 'Bottom'
    $script:AvPreviewHintBox.Background = Brush (Get-Pal 'Card')
    $script:AvPreviewHintBox.Opacity = 0.88
    $script:AvPreviewHint = New-Txt -Text 'Default' -Size 10 -Color (Get-Pal 'InkSoft')
    $script:AvPreviewHint.HorizontalAlignment = 'Center'
    $script:AvPreviewHintBox.Child = $script:AvPreviewHint
    [void]$previewGrid.Children.Add($script:AvPreviewCanvas)
    [void]$previewGrid.Children.Add($script:AvPreviewImage)
    [void]$previewGrid.Children.Add($script:AvPreviewHintBox)
    $previewBorder.Child = $previewGrid
    [void]$sp.Children.Add($previewBorder)

    $script:AvDraftPath = [string]$script:Settings['AvatarPath']
    Draw-Avatar $script:AvPreviewCanvas
    Set-AvatarElement -Image $script:AvPreviewImage -Canvas $script:AvPreviewCanvas `
        -Hint $script:AvPreviewHint -HintBox $script:AvPreviewHintBox -Path $script:AvDraftPath | Out-Null

    # 两个动作按钮居中；"Save & close" 由标题栏的 × 接管。
    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'
    $btnRow.HorizontalAlignment = 'Center'
    $bChoose = New-PixBtn -Text 'Choose image' -Bg (Get-Pal 'AccentFocus') -Fg (Get-Pal 'TodayInk') -W 126 -H 36 -FontSize 12
    $bDefault = New-PixBtn -Text 'Restore default' -Bg (Get-Pal 'Card') -Fg (Get-Pal 'Ink') -W 126 -H 36 -FontSize 12
    $bChoose.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [void]$btnRow.Children.Add($bChoose)
    [void]$btnRow.Children.Add($bDefault)
    [void]$sp.Children.Add($btnRow)

    $chrome = Get-EditorChrome 'Avatar' $sp
    $script:AvWin.Content = $chrome.Root
    $chrome.Bar.Add_MouseLeftButtonDown({
        param($s, $e)
        if (Test-ClickOnButton $e) { return }
        try { $script:AvWin.DragMove() } catch { }
    })
    try {
        if ($null -ne $script:MainWindow -and $script:MainWindow.IsVisible) { $script:AvWin.Owner = $script:MainWindow }
    } catch { }
    $script:AvWin.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') { Close-DialogWindow $script:AvWin $false }
    })
    $bChoose.Add_Click({
        try {
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = 'Choose avatar image'
            $dlg.Filter = 'Images (*.png;*.jpg;*.jpeg;*.bmp;*.gif)|*.png;*.jpg;*.jpeg;*.bmp;*.gif|All files (*.*)|*.*'
            if ($dlg.ShowDialog() -eq $true) {
                $script:AvDraftPath = [string]$dlg.FileName
                Set-AvatarElement -Image $script:AvPreviewImage -Canvas $script:AvPreviewCanvas `
                    -Hint $script:AvPreviewHint -HintBox $script:AvPreviewHintBox -Path $script:AvDraftPath | Out-Null
            }
        } catch { Write-ErrLog ('Avatar choose: ' + $_.Exception.Message) }
    })
    $bDefault.Add_Click({
        try {
            $script:AvDraftPath = ''
            Set-AvatarElement -Image $script:AvPreviewImage -Canvas $script:AvPreviewCanvas `
                -Hint $script:AvPreviewHint -HintBox $script:AvPreviewHintBox -Path '' | Out-Null
        } catch { Write-ErrLog ('Avatar default: ' + $_.Exception.Message) }
    })
    # × = 应用头像并关闭（原 Save & close 的逻辑原样保留）。
    $chrome.BtnClose.Add_Click({
        try {
            $target = Join-Path $script:DataDir 'avatar.dat'
            if ([string]::IsNullOrWhiteSpace([string]$script:AvDraftPath)) {
                if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
                $script:Settings['AvatarPath'] = ''
                Apply-AvatarImage -Path '' | Out-Null
            } else {
                $srcPath = [System.IO.Path]::GetFullPath([string]$script:AvDraftPath)
                if (-not (Test-Path -LiteralPath $srcPath)) { throw 'Selected image no longer exists.' }
                if (-not [string]::Equals($srcPath, $target, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Copy-Item -LiteralPath $srcPath -Destination $target -Force
                }
                $script:Settings['AvatarPath'] = $target
                Apply-AvatarImage -Path $target | Out-Null
            }
            Save-Settings
            Close-DialogWindow $script:AvWin $true
        } catch { Write-ErrLog ('Avatar save: ' + $_.Exception.Message) }
    })
    # 头像窗口的 Cancel 语义"撤销草稿"：选完图后 Cancel 必须把预览与草稿一起回退，
    # 否则用户点了 Cancel 却发现头像已经变了（Apply-AvatarImage 是立刻生效的）。
    Bind-DialogChromeButtons $chrome $script:AvWin
    return $script:AvWin
}

# ---------------------------------------------------------------------------
#  番茄钟完成提示（不走 MessageBox，避免挡住截图与自动化）
# ---------------------------------------------------------------------------
function Show-Toast {
    param([string]$Title = 'Notification', [string]$Text = '')
    try {
        $w = New-Object System.Windows.Window
        $w.WindowStyle = 'None'
        $w.AllowsTransparency = $true
        $w.Background = $null
        $w.ShowInTaskbar = $false
        $w.ResizeMode = 'NoResize'
        $w.SizeToContent = 'WidthAndHeight'
        $w.Topmost = $true
        $bd = New-Bd -Bg (Get-Pal 'Card') -Border (Get-Pal 'Border') -Radius 12
        $bd.Padding = [System.Windows.Thickness]::new(20, 14, 20, 14)
        $sp = New-Object System.Windows.Controls.StackPanel
        [void]$sp.Children.Add((New-Txt -Text $Title -Size 14 -Color (Get-Pal 'Ink') -Weight 'Bold'))
        [void]$sp.Children.Add((New-Txt -Text $Text -Size 11 -Color (Get-Pal 'InkSoft')))
        $bd.Child = $sp
        $w.Content = $bd
        $wa = [System.Windows.SystemParameters]::WorkArea
        $w.Left = $wa.Right - 300
        $w.Top = $wa.Bottom - 130
        $w.Show()
        # 注意：定时器与窗口必须挂到 $script: 上。
        # 事件处理器 scriptblock 真正被 WPF 回调时，函数局部变量（$t / $w）已经随作用域消失，
        # StrictMode 下会直接抛"检索不到变量"，被 catch 吞掉后就表现为"Toast 永不关闭"。
        $script:ToastWindow = $w
        $script:ToastTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:ToastTimer.Interval = [timespan]::FromSeconds(4)
        $script:ToastTimer.Add_Tick({
            try {
                $script:ToastTimer.Stop()
                if ($null -ne $script:ToastWindow) {
                    $script:ToastWindow.Close()
                    $script:ToastWindow = $null
                }
            } catch { Write-ErrLog ('Toast close: ' + $_.Exception.Message) }
        })
        $script:ToastTimer.Start()
    } catch { Write-ErrLog ('Toast: ' + $_.Exception.Message) }
}
