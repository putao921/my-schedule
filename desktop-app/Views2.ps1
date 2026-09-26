# =============================================================================
#  My Schedule - 独立编辑窗口（WPF 真窗口，可拖动/最小化，和主窗口同一套皮肤）
#  为什么不用覆盖层：编辑时用户常需要翻看主窗口的其它日期，
#  一个可以自由摆放的独立窗口比模态遮罩更顺手。
# =============================================================================

# ---------------------------------------------------------------------------
#  可自定义标签的单一真源（第十轮）
#
#  标签 -> 色板键 的映射存在 $script:Settings['TagColors'] 里。这个函数把它
#  规范化成有序字典返回，屏蔽"来源是 hashtable 还是 JSON 反序列化的 PSCustomObject"
#  这两种形态的差异，编辑器按钮组 / 任务分类下拉都从这里读，保证同一张表。
# ---------------------------------------------------------------------------
function Get-TagChoices {
    $out = [ordered]@{}
    try {
        $src = $script:Settings['TagColors']
        if ($null -eq $src) { return $out }
        if ($src -is [System.Collections.IDictionary]) {
            foreach ($k in @($src.Keys)) { $out[[string]$k] = [string]$src[$k] }
        } else {
            foreach ($p in @($src.PSObject.Properties)) { $out[[string]$p.Name] = [string]$p.Value }
        }
    } catch { Write-ErrLog ('Get-TagChoices: ' + $_.Exception.Message) }
    # 兜底：配置坏了/空了至少给回默认四键，编辑器不能因为没标签而建不起来。
    if ($out.Count -eq 0) {
        $out['work'] = 'AccentEvent'; $out['focus'] = 'AccentFocus'
        $out['life'] = 'AccentTask';  $out['task'] = 'AccentTask'
    }
    return $out
}

function Add-CustomTag {
    # 把"新标签名 + 颜色"写进 Settings['TagColors']，再刷新标签管理区。
    #   名字做 trim + 小写归一（避免 Study/study 两套），空名/重名直接忽略。
    $name = ([string]$script:TagNewName.Text).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $color = 'AccentFocus'
    if ($null -ne $script:TagNewColor -and $null -ne $script:TagNewColor.SelectedItem) {
        $color = [string]$script:TagNewColor.SelectedItem
    }
    $cur = Get-TagChoices
    if ($cur.Contains($name)) { $script:TagNewName.Text = ''; return }
    $cur[$name] = $color
    $script:Settings['TagColors'] = $cur
    Save-Settings
    $script:TagNewName.Text = ''
    Render-TagManagerRows
}

function Remove-CustomTag {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $cur = Get-TagChoices
    if (-not $cur.Contains($Name)) { return }
    $cur.Remove($Name)
    $script:Settings['TagColors'] = $cur
    Save-Settings
    Render-TagManagerRows
}

function Render-TagManagerRows {
    # 按 Settings['TagColors'] 重画标签管理区的 chips（色块 + 名字 + ×）。
    #   增删标签后调用，保证看到的和存的一致。
    if ($null -eq $script:TagManagerStack) { return }
    $script:TagManagerStack.Children.Clear()
    $allTags = Get-TagChoices
    foreach ($k in @($allTags.Keys)) {
        $col = [string]$allTags[$k]
        $chip = New-Object System.Windows.Controls.Border
        $chip.Background = Brush (Get-Pal 'CardAlt')
        $chip.BorderBrush = Brush (Get-Pal 'BorderSoft')
        $chip.BorderThickness = [System.Windows.Thickness]::new(1)
        $chip.CornerRadius = [System.Windows.CornerRadius]::new(5)
        $chip.Padding = [System.Windows.Thickness]::new(6, 3, 6, 3)
        $chip.Margin = [System.Windows.Thickness]::new(0, 0, 6, 6)
        $chipRow = New-Object System.Windows.Controls.StackPanel
        $chipRow.Orientation = 'Horizontal'
        $sw = New-Object System.Windows.Controls.Border
        $sw.Width = 12; $sw.Height = 12
        $sw.CornerRadius = [System.Windows.CornerRadius]::new(3)
        $sw.Background = Brush (Get-Pal $col)
        $sw.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        $sw.VerticalAlignment = 'Center'
        [void]$chipRow.Children.Add($sw)
        $lb = New-Txt -Text $k -Size 11 -Color (Get-Pal 'Ink')
        $lb.VerticalAlignment = 'Center'
        [void]$chipRow.Children.Add($lb)
        $del = New-PixBtn -Text '×' -Bg (Get-Pal 'Card') -Fg (Get-Pal 'AccentEvent') -W 22 -H 22 -FontSize 11 -Radius 4
        $del.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
        $del.ToolTip = (Get-LangText 'tip.tagRemove')
        $del.Tag = @{ kind = 'tag-remove'; name = $k }
        $del.Add_Click({
            param($s, $e)
            try { if ($null -ne $s -and $null -ne $s.Tag) { Remove-CustomTag ([string]$s.Tag['name']) } }
            catch { Write-ErrLog ('Tag remove: ' + $_.Exception.Message) }
        })
        [void]$chipRow.Children.Add($del)
        $chip.Child = $chipRow
        [void]$script:TagManagerStack.Children.Add($chip)
    }
}

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

function New-DigitWheelField {
    # 四位数字滚轮（第七轮 item 5）。
    #
    # 需求原话："音位（应为'因为'）时间都是四个数字，所以给每个数字都设置一个从 1-9
    #   可以滚动的功能。"  —— 即把 00:00 这样的时长拆成 4 个独立数字位，
    #   每一位都能用鼠标滚轮 / 上下键单独加减，替代原来那个只有十来档的下拉框。
    #
    # 设计：
    #   · 显示形如 25:00，冒号是分隔符不是可编辑位；
    #   · 4 个位各自是一个 TextBlock，外面套一个可点/可滚的 Border；
    #   · 滚轮向上 = 进位 +1，向下 = -1；越界按"该位 0-9 循环"处理（个位 9->0 时
    #     给十位 +1，方便"滚一滚凑够 90 分钟"）。
    #   · 整值夹在 0..5999 秒（= 99:59），因为计时器那行大字是 mm:ss，三位数分钟会撑破。
    #
    # 返回一个对象：{ Box; Set; Get; SetMin; GetMin } —— Get/Set 都拿"分钟"这个语义值。
    #   为什么返回对象而不是控件本身：控件是 4 个位 + 分隔符，调用方要的是"读/写分钟"，
    #   不该关心内部有几位。审计也直接调 .Get() / .Set()。
    param($Parent, [string]$LabelKey, [int]$Minutes = 25, [int]$MaxMin = 99)
    [void]$Parent.Children.Add((New-Txt -Text (Get-LangText $LabelKey) -Size 11 -Color (Get-Pal 'InkFaint')))
    $wrap = New-Object System.Windows.Controls.StackPanel
    $wrap.Orientation = 'Horizontal'
    $wrap.Margin = [System.Windows.Thickness]::new(0, 3, 0, 12)
    $wrap.HorizontalAlignment = 'Left'

    if ($Minutes -lt 0) { $Minutes = 0 }
    if ($Minutes -gt $MaxMin) { $Minutes = $MaxMin }

    $box = New-Bd -Bg (Get-Pal 'CardAlt') -Border (Get-Pal 'Border') -Radius 8 -Bw 2
    $box.Padding = [System.Windows.Thickness]::new(12, 4, 12, 6)
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.HorizontalAlignment = 'Center'

    # 四个位：每个位是一个 TextBlock，外面套一层可滚动的 Border（"格子"）
    $cells = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt 4; $i++) {
        $cell = New-Object System.Windows.Controls.Border
        $cell.Width = 26
        $cell.Height = 44
        $cell.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $cell.Background = Brush (Get-Pal 'Card')
        $cell.BorderBrush = Brush (Get-Pal 'BorderSoft')
        $cell.BorderThickness = [System.Windows.Thickness]::new(1)
        $cell.Margin = [System.Windows.Thickness]::new(2, 0, 2, 0)
        $cell.Cursor = [System.Windows.Input.Cursors]::Hand
        $tb = New-Txt -Text '0' -Size 26 -Color (Get-Pal 'Ink') -Weight 'Bold'
        $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
        $tb.HorizontalAlignment = 'Center'
        $tb.VerticalAlignment = 'Center'
        # 第九轮（混排基线）：Consolas 行高偏大，收紧到略小于字号，数字在格子里才真正居中。
        $tb.LineHeight = (Scale-Ui 26)
        $tb.IsHitTestVisible = $false     # 点击/滚轮都归外层 Border 收，避免子元素吃掉事件
        $cell.Child = $tb
        $cell.Tag = @{ kind = 'digit-wheel'; idx = $i }
        [void]$row.Children.Add($cell)
        [void]$cells.Add($cell)
        # 冒号分隔符（插在前两位与后两位之间）
        if ($i -eq 1) {
            $sep = New-Txt -Text ':' -Size 26 -Color (Get-Pal 'InkSoft') -Weight 'Bold'
            $sep.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
            $sep.VerticalAlignment = 'Center'
            $sep.Margin = [System.Windows.Thickness]::new(1, 0, 1, 0)
            [void]$row.Children.Add($sep)
        }
    }
    $box.Child = $row
    [void]$wrap.Children.Add($box)
    [void]$Parent.Children.Add($wrap)

    # ---- 分钟级快捷档（第八轮第三十节第 4 条）----
    # 滚轮自由了，但常用值（25 / 45 / 60）反而要一格一格滚。放三个 chip 一键设定。
    #   chip 点击处理器只读 $s.Tag（把分钟数挂上去），不捕获创建函数的局部变量 ——
    #   与四位滚轮同一条作用域铁律。
    $chipRow = New-Object System.Windows.Controls.StackPanel
    $chipRow.Orientation = 'Horizontal'
    $chipRow.HorizontalAlignment = 'Left'
    $chipRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    foreach ($cm in @(25, 45, 60)) {
        $chip = New-PixBtn -Text ([string]$cm) -Bg (Get-Pal 'CardAlt') -Fg (Get-Pal 'Ink') `
                           -H 26 -W 44 -FontSize 11 -Radius 6 -BorderCol (Get-Pal 'Border')
        $chip.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        $chip.Tag = @{ kind = 'focus-chip'; minutes = $cm }
        $chip.Add_Click({
            param($s, $e)
            try {
                if ($null -eq $s -or $null -eq $s.Tag) { return }
                $mins = [int]$s.Tag['minutes']
                $script:FoDurationMin = $mins * 60
                & $script:DwPaint
            } catch { Write-ErrLog ('Focus chip: ' + $_.Exception.Message) }
        })
        [void]$chipRow.Children.Add($chip)
    }
    [void]$Parent.Children.Add($chipRow)

    # 提示行：告诉用户这个控件怎么用（滚轮/上下键）
    $hintTxt = New-Txt -Text (Get-LangText 'fld.fo.wheelHint') -Size 10 -Color (Get-Pal 'InkFaint')
    $hintTxt.Margin = [System.Windows.Thickness]::new(0, -6, 0, 10)
    [void]$Parent.Children.Add($hintTxt)

    $script:FoDigitCells = $cells
    $script:FoDigitMaxMin = $MaxMin

    # 把"位数组"写回 TextBlock，并同步到 $script:FoDurationMin
    $script:DwSync = {
        try {
            $cs = @($script:FoDigitCells)
            if ($cs.Count -ne 4) { return }
            $mm = ([int]$cs[0].Child.Text) * 10 + [int]$cs[1].Child.Text
            $ss = ([int]$cs[2].Child.Text) * 10 + [int]$cs[3].Child.Text
            $script:FoDurationMin = ($mm * 60 + $ss)
        } catch { Write-ErrLog ('DigitWheel sync: ' + $_.Exception.Message) }
    }
    $script:DwPaint = {
        try {
            $cs = @($script:FoDigitCells)
            if ($cs.Count -ne 4) { return }
            $min = [int]$script:FoDurationMin
            if ($min -lt 0) { $min = 0 }
            if ($min -gt ([int]$script:FoDigitMaxMin * 60 + 59)) { $min = [int]$script:FoDigitMaxMin * 60 + 59 }
            $script:FoDurationMin = $min
            $mm = [int][math]::Floor($min / 60)
            $ss = [int]($min % 60)
            $cs[0].Child.Text = [string]([int][math]::Floor($mm / 10) % 10)
            $cs[1].Child.Text = [string]($mm % 10)
            $cs[2].Child.Text = [string]([int][math]::Floor($ss / 10) % 10)
            $cs[3].Child.Text = [string]($ss % 10)
        } catch { Write-ErrLog ('DigitWheel paint: ' + $_.Exception.Message) }
    }

    # 每一位的滚轮 / 点击
    for ($idx = 0; $idx -lt 4; $idx++) {
        $c = $cells[$idx]
        $c.Tag = @{ kind = 'digit-wheel'; idx = $idx }
        $c.Add_MouseWheel({
            param($s, $e)
            try {
                if ($null -eq $s -or $null -eq $s.Tag) { return }
                $i = [int]$s.Tag['idx']
                Step-FocusDigit $i $(if ($e.Delta -gt 0) { 1 } else { -1 })
                $e.Handled = $true
            } catch { Write-ErrLog ('DigitWheel wheel: ' + $_.Exception.Message) }
        })
        # 左键点上半 = +1，下半 = -1（滚轮不好使的设备用它）
        $c.Add_MouseLeftButtonDown({
            param($s, $e)
            try {
                if ($null -eq $s -or $null -eq $s.Tag) { return }
                $i = [int]$s.Tag['idx']
                $up = ($e.GetPosition($s).Y -lt ($s.ActualHeight / 2.0))
                Step-FocusDigit $i $(if ($up) { 1 } else { -1 })
                $e.Handled = $true
            } catch { Write-ErrLog ('DigitWheel click: ' + $_.Exception.Message) }
        })
    }

    $script:FoDurationMin = $Minutes * 60
    & $script:DwPaint
    return [pscustomobject]@{
        Box = $box
        Set = { param([int]$m) $script:FoDurationMin = $m * 60; & $script:DwPaint }
        Get = { return [int][math]::Floor([int]$script:FoDurationMin / 60) }
        GetSeconds = { return [int]$script:FoDurationMin }
    }
}

function Step-FocusDigit {
    # 把 Focus 时长控件的第 $Idx 位加/减 1，并按"时分秒进位"规则重算总时长。
    #   进位规则（让"滚轮凑时长"符合直觉）：
    #     · 十位分 / 个位分 / 十位秒 / 个位秒 四个位各自是十进制；
    #     · 任一位越界就整体 ±1 秒（或 ±10 秒）地借位，而不是"该位 0-9 空转"。
    #   例：00:59 时滚个位秒 +1 -> 01:00（而不是 00:50）。
    #   整值夹在 [0, MaxMin*60+59]。
    param([int]$Idx, [int]$Delta)
    try {
        $cs = @($script:FoDigitCells)
        if ($cs.Count -ne 4) { return }
        $cur = [int]$script:FoDurationMin
        # 该位在"总秒数"里的权重：十位分=600s，个位分=60s，十位秒=10s，个位秒=1s
        $weight = @(600, 60, 10, 1)[$Idx]
        $cur = $cur + ($weight * $Delta)
        $max = [int]$script:FoDigitMaxMin * 60 + 59
        if ($cur -lt 0) { $cur = 0 }
        if ($cur -gt $max) { $cur = $max }
        $script:FoDurationMin = $cur
        & $script:DwPaint
    } catch { Write-ErrLog ('Step-FocusDigit: ' + $_.Exception.Message) }
}

function New-ChoiceField {
    # 下拉框的"可本地化"版本（第六轮第二项建议：弹窗字段名接进语言表）。
    #
    # 为什么不能在 New-ComboField 里直接把选项文案换成中文：
    #   **下拉框的文案既是"显示"又是"取值"**。全项目回读处都长这样：
    #       ([string]$cb.Text).ToLowerInvariant()      # 'Daily' -> 'daily'
    #       if ($cb.Text -like '5*') { $reminderMin = 5 }
    #   一旦把 'High' 显示成'高'，那段解析逻辑立刻失效，而且**不报错**，
    #   只是"改了选项却不生效"—— 又是最难查的那一类。
    #
    # 做法：显示文案与语义取值**分开存**。
    #   · Items 里放本地化后的文案（用户看得懂）；
    #   · $cb.Tag 里放稳定的语义值（'daily' / '5' / 'high' ……永远英文小写）；
    #   · 每次选择变化就把选中文案反查回语义值写进 Tag；
    #   · 解析处一律读 $cb.Tag，不再读 .Text。
    #   · $cb.ToolTip 存一个 "值→文案" 的映射表，供反查用。
    #
    # $Pairs：有序的 @( @{ V='daily'; K='opt.rep.daily' }, ... )，V 是语义值、K 是语言键。
    param($Parent, [string]$LabelKey, [string]$Value, $Pairs)
    [void]$Parent.Children.Add((New-Txt -Text (Get-LangText $LabelKey) -Size 11 -Color (Get-Pal 'InkFaint')))
    $cb = New-Object System.Windows.Controls.ComboBox
    $cb.IsEditable = $false          # 只能选，不能手打 —— 手打会造出 Tag 对不上的野值
    $cb.Height = 36
    $cb.FontSize = (Scale-Ui 13)     # 走 Scale-Ui：新控件必须跟全局字号倍率走
    $cb.Margin = [System.Windows.Thickness]::new(0, 3, 0, 12)
    $cb.Background = Brush (Get-Pal 'CardAlt')
    $cb.Foreground = Brush (Get-Pal 'Ink')
    $cb.BorderBrush = Brush (Get-Pal 'Border')
    $cb.BorderThickness = [System.Windows.Thickness]::new(2)
    $cb.Padding = [System.Windows.Thickness]::new(7, 3, 7, 3)
    # 值 <-> 文案 双向表
    $v2t = @{}
    $t2v = @{}
    $ordered = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($Pairs)) {
        $v = [string]$p['V']
        $t = Get-LangText ([string]$p['K'])
        $v2t[$v] = $t
        $t2v[$t] = $v
        [void]$ordered.Add($v)
        [void]$cb.Items.Add($t)
    }
    $cb.ToolTip = $t2v            # 只用于反查；不去显示（ComboBox 的 ToolTip 不弹）
    $cb.Tag = $Value              # 语义值，永远是这个（解析处读它）
    if ($v2t.ContainsKey($Value)) { $cb.SelectedItem = $v2t[$Value] }
    elseif ($ordered.Count -gt 0) { $cb.SelectedIndex = 0; $cb.Tag = $ordered[0] }
    # 选择变化 -> 把语义值同步回 Tag。处理器读不到局部变量，所以 $t2v 走 Tag。
    $cb.Add_SelectionChanged({
        param($s, $e)
        try {
            $m = $s.ToolTip
            $sel = [string]$s.SelectedItem
            if ($null -ne $m -and $m -is [hashtable] -and $m.ContainsKey($sel)) { $s.Tag = [string]$m[$sel] }
        } catch { }
    })
    Apply-SharedComboStyle $cb
    [void]$Parent.Children.Add($cb)
    return $cb
}

function Set-ChoiceFieldValue {
    # 把一个 New-ChoiceField 拨到指定语义值（打开编辑窗、切语言重建时用）。
    #   注意：不能只设 $cb.Tag —— 界面上显示的还是旧文案，用户会以为没生效。
    #   也不能只设 SelectedItem —— SelectionChanged 是异步派发的，Tag 不一定跟得上，
    #   所以两个都设，Tag 手工再写一次兜底。
    param([System.Windows.Controls.ComboBox]$Cb, [string]$Value)
    if ($null -eq $Cb) { return }
    $m = $Cb.ToolTip
    if ($null -ne $m -and $m -is [hashtable]) {
        foreach ($k in @($m.Keys)) {
            if ([string]$m[$k] -eq $Value) {
                $Cb.SelectedItem = $k
                $Cb.Tag = $Value
                return
            }
        }
    }
    $Cb.Tag = $Value
}

function New-SettingsSection {
    # 设置窗口里的分组小标题（第四轮：设置项从 1 项涨到 7 项，必须分组，
    # 否则一长条全是控件、找不到自己要改的那一项在哪）。
    # 上面留一条细分隔线，视觉上把"上一组"和"这一组"切开。
    #
    # 第六轮补一句：分组还在，但**同屏只留一组**了 —— 见 New-SettingsTabs。
    # 这条函数没被废弃，因为"当前页"内部仍需要它做小标题（例如 Window 页里
    # 没有子分组时它就是页面头顶那行说明）。
    param($Parent, [string]$Text)
    $line = New-Bd -Bg (Get-Pal 'BorderSoft') -Border '' -Radius 0
    $line.Height = 1.5
    $line.Margin = [System.Windows.Thickness]::new(0, 14, 0, 8)
    [void]$Parent.Children.Add($line)
    [void]$Parent.Children.Add((New-Txt -Text $Text -Size 11 -Color (Get-Pal 'Ink') -Weight 'Semi'))
}

function New-SettingsTabs {
    # 设置窗口分页（第六轮，用户第 1 条 "按照你说的建议全部修改"）。
    #
    # 为什么必须做：第五轮之后设置项涨到 9 个，截图里设置窗已经要滚两屏。
    #   "找一项设置要滚半天"会让以后每加一项都变成负担 —— 分页的价值不在好看，
    #   而在于**它还允许继续加设置项**。
    #
    # 做法：一排页签 + 一个内容区，切页时只换内容区的 Child。
    #   为什么不用 WPF 自带 TabControl：它的默认模板样式与本项目风格（像素边框、
    #   无系统圆角、主题色板）差太多，改模板的成本高于自己搭 4 个按钮 + 1 个 Border。
    #   而且本项目所有弹窗都不吃系统样式 —— 保持一致比省几行代码重要。
    #
    # 返回 @{ Strip; Host; Buttons; Show } —— Show 是"按 key 切页"的函数（scriptblock），
    #   由调用方持有；用 scriptblock 而不是往 $script: 塞状态，是因为同一时刻只有一个
    #   设置窗，没必要把页签状态做成全局。
    #
    # ⚠ 硬规则：页签按钮的 Add_Click 里**不能捕获本函数的局部变量**
    #   （WPF 处理器跑的时候本函数的作用域早没了）。所以：
    #     · 页面容器 $host、按钮表 $btns 存到 $script: 一份（名字带前缀避免撞车）；
    #     · 每个按钮的 key 通过它自己的 Tag 带进处理器（Tag 是形参天然带入）。
    # ⚠ 变量名不能叫 $host：$Host 是 PowerShell 的只读自动变量（控制台宿主对象），
    #   赋值会抛"无法覆盖变量 Host，因为该变量为只读变量或常量"。
    #   而且因为它在函数体里才炸，整个 Show-SettingsWindow 一打开就崩 ——
    #   与 New-EditorField 里 $Host 那个坑是同一类（见该函数注释）。
    #   这里改用 $pageHost。
    param([string[]]$Keys, [string[]]$Labels)
    $strip = New-Object System.Windows.Controls.StackPanel
    $strip.Orientation = 'Horizontal'
    $strip.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)

    $pageHost = New-Object System.Windows.Controls.Border
    $pageHost.Background = Brush (Get-Pal 'Card')
    $pageHost.BorderBrush = Brush (Get-Pal 'BorderSoft')
    $pageHost.BorderThickness = [System.Windows.Thickness]::new(0, 2, 0, 0)
    $pageHost.Padding = [System.Windows.Thickness]::new(0)

    $btns = New-Object System.Collections.Generic.List[object]
    $n = [math]::Min($Keys.Count, $Labels.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $key = [string]$Keys[$i]
        $b = New-PixBtn -Text ([string]$Labels[$i]) -Bg (Get-Pal 'CardAlt') `
                        -Fg (Get-Pal 'InkSoft') -W 92 -H 32 -FontSize 11
        $b.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        # ⚠ Tag 必须在这里**另赋一个 hashtable**，不能走 New-PixBtn 的 -Tag 形参：
        #   那个形参声明成 [string]，传 hashtable 会被 PS 悄悄转成
        #   "System.Collections.Hashtable" 字符串，后面 $b.Tag['key'] 就是"给字符串
        #   下标"→ 抛"参数类型不匹配"。直接赋值绕开形参的类型转换。
        $b.Tag = @{ kind = 'settab'; key = $key }
        $b.Add_Click({
            param($s, $e)
            try {
                $e.Handled = $true
                # 切页：真实逻辑挂在 $script: 上（处理器读不到局部变量）
                if ($null -ne $script:SetTabsShow) { & $script:SetTabsShow ([string]$s.Tag['key']) }
            } catch { Write-ErrLog ('Settings tab: ' + $_.Exception.Message) }
        })
        [void]$btns.Add($b)
        [void]$strip.Children.Add($b)
    }

    return @{ Strip = $strip; Host = $pageHost; Buttons = $btns }
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
        Set-LineHeight $h 10
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
    # 第十轮语言收尾：按钮文字也走语言表（原来是硬编码 'Save'，中文界面下露英文）。
    param([string]$Text = '')
    if ([string]::IsNullOrWhiteSpace($Text)) { $Text = Get-LangText 'btn.save' }
    return (New-DialogBarButton -Text $Text -Name 'DlgSave' `
        -Bg (Get-Pal 'AccentEvent') -Fg (Get-Pal 'OnAccent') -W 64.0 `
        -Tip (Get-LangText 'tpl.save'))
}

function New-DialogCloseButton {
    # 不用 New-PixBtn：那个模板的 ContentPresenter 带 9px 水平内边距，
    # 26px 宽的按钮里塞不下 10px 的 ×（会被压成一条竖线）。
    # 也不用 New-Icon + ControlTemplate 混搭，直接把手写的 X 路径烘进模板，
    # 少一层对 $script:IconDefs 的依赖。
    #
    # 第五轮：底色从 Transparent 改成 CardAlt —— 原来 × 是无底色轻按钮，
    # 而它左边紧挨着的 Save / Cancel 都是"有底 + 圆角"，同一行里三种观感。
    # 现在三件套统一为"有底 + 1.5px 描边 + 圆角"，只是 × 不写字、只放一个叉。
    # 注意 hover/press 必须比底色更深，否则"有底色之后 hover 看不出来"。
    $ink = Get-Pal 'Ink'
    $bg = Get-Pal 'CardAlt'
    $hover = Get-Pal 'BorderSoft'
    $press = Get-Pal 'Border'
    $btn = New-Object System.Windows.Controls.Button
    $btn.Name = 'DlgClose'
    $btn.Width = 26
    $btn.Height = 24
    $btn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $btn.Cursor = [System.Windows.Input.Cursors]::Hand
    # × 的语义现在是**唯一**的"不保存并关闭"（Cancel 已删）—— 提示文字必须说清楚，
    # 否则用户会以为它还兼着保存（旧文案正是 'Save and close'）。
    $btn.ToolTip = (Get-LangText 'tpl.close')
    $tpl = @"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                 TargetType="Button">
  <Border x:Name="bd" Background="$bg" BorderBrush="$(Get-Pal 'Border')" BorderThickness="1.5"
          CornerRadius="6">
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
    # 把标题栏两件套接上：Save 与 × 走同一条保存路径。
    #
    # 第五轮（用户第 3 条反馈）：**Cancel 已删**。
    #   原来 Save / Cancel / × 三个按钮里，Cancel 与 × 都是"不保存并关闭"，
    #   同一行里两个同义按钮只会让人反复试。现在只留：
    #     · Save -> 保存并关闭（转发一次 Click 给 ×，复用它的处理器）
    #     · ×    -> 不保存并关闭（Esc 等价）
    #   所以这里只剩 Save 一个转发分支。函数名保留 Bind-DialogChromeButtons
    #   而不是改成 Bind-DialogSaveButton：调用点有 6 个弹窗，改名要动 6 处，
    #   而"标题栏按钮的绑定"这个职责没变。
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
    #   而异常会被下面的 catch 吞掉，表现成"点 Save 没反应"。
    #   所以引用一律走 $s.Tag（$s 就是被点的那个按钮，是形参天然带进来的）：
    #     · BtnSave.Tag = 同 chrome 里的 × 按钮
    param($Chrome, $Win)
    if ($null -eq $Chrome) { return }
    $save = $Chrome['BtnSave']
    $close = $Chrome['BtnClose']
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
}

function Get-EditorChrome {
    # 参数类型不能写 Control：StackPanel 继承自 Panel（Panel -> FrameworkElement -> UIElement），
    # 并不在 Control 这条继承链上，传 StackPanel 会在参数绑定阶段就抛
    # "无法将 StackPanel 转换为 Control"，整个窗口都建不起来。
    param([string]$Title, [System.Windows.FrameworkElement]$Content, [switch]$NoSave)
    $wrap = New-Object System.Windows.Controls.Grid
    # 第十轮（item 6）：Save 从标题栏**移到底部按钮行**，标题栏只留 [标题] + [×]。
    #   行结构：0=标题栏(38) / 1=内容(*) / 2=底部按钮行(仅当有 Save 时，Auto)。
    #   为什么标题栏不再放 Save：用户反馈"Save 放在 × 旁边容易误点 × 丢内容"，
    #   而 Save 是"提交"动作，落在底部和输入区隔开、更符合表单直觉。
    $rowDefs = 3
    for ($i = 0; $i -lt $rowDefs; $i++) {
        $rd = New-Object System.Windows.Controls.RowDefinition
        if ($i -eq 0) { $rd.Height = [System.Windows.GridLength]::new(38, 'Pixel') }
        elseif ($i -eq 1) { $rd.Height = [System.Windows.GridLength]::new(1, 'Star') }
        else { $rd.Height = [System.Windows.GridLength]::Auto }
        $wrap.RowDefinitions.Add($rd)
    }
    $bar = New-Object System.Windows.Controls.Border
    $bar.Background = Brush (Get-Pal 'Chrome')
    $bar.BorderBrush = Brush (Get-Pal 'Border')
    $bar.BorderThickness = [System.Windows.Thickness]::new(2, 2, 2, 0)
    $bar.CornerRadius = [System.Windows.CornerRadius]::new(10, 10, 0, 0)
    # 标题栏 = [标题(占满)] + [×]。Save 不再放这行（移到底部按钮区，见下方 footer）。
    $barGrid = New-Object System.Windows.Controls.Grid
    $cdTitle = New-Object System.Windows.Controls.ColumnDefinition
    $cdTitle.Width = [System.Windows.GridLength]::new(1, 'Star')
    $barGrid.ColumnDefinitions.Add($cdTitle)
    $cdClose = New-Object System.Windows.Controls.ColumnDefinition
    $cdClose.Width = [System.Windows.GridLength]::new(34.0, 'Pixel')
    $barGrid.ColumnDefinitions.Add($cdClose)

    $barTxt = New-Txt -Text $Title -Size 13 -Color (Get-Pal 'Ink') -Weight 'Semi'
    $barTxt.VerticalAlignment = 'Center'
    $barTxt.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
    [System.Windows.Controls.Grid]::SetColumn($barTxt, 0)
    [void]$barGrid.Children.Add($barTxt)

    # BtnSave 一并返回（哪怕没生成）：六个弹窗的调用点都写 `$chrome.BtnSave`。
    # 第十轮起 Save 按钮放在**底部按钮行**（footer），不再挂标题栏。
    $btnSave = $null
    if (-not $NoSave) { $btnSave = New-DialogSaveButton }

    $btnClose = New-DialogCloseButton
    $btnClose.VerticalAlignment = 'Center'
    $btnClose.HorizontalAlignment = 'Right'
    [System.Windows.Controls.Grid]::SetColumn($btnClose, 1)
    [void]$barGrid.Children.Add($btnClose)

    $bar.Child = $barGrid
    [System.Windows.Controls.Grid]::SetRow($bar, 0)
    [void]$wrap.Children.Add($bar)

    $body = New-Object System.Windows.Controls.Border
    $body.Background = Brush (Get-Pal 'Card')
    $body.BorderBrush = Brush (Get-Pal 'Border')
    $body.BorderThickness = [System.Windows.Thickness]::new(2, 0, 2, 0)
    $body.Child = $Content
    [System.Windows.Controls.Grid]::SetRow($body, 1)
    [void]$wrap.Children.Add($body)

    # 底部按钮行：Save 放这（右对齐）。没有 Save 语义的窗口（-NoSave）不生成这一行。
    if ($null -ne $btnSave) {
        $footer = New-Object System.Windows.Controls.Border
        $footer.Background = Brush (Get-Pal 'Card')
        $footer.BorderBrush = Brush (Get-Pal 'Border')
        $footer.BorderThickness = [System.Windows.Thickness]::new(2, 1, 2, 2)
        $footer.CornerRadius = [System.Windows.CornerRadius]::new(0, 0, 10, 10)
        $fp = New-Object System.Windows.Controls.StackPanel
        $fp.Orientation = 'Horizontal'
        $fp.HorizontalAlignment = 'Right'
        $fp.Margin = [System.Windows.Thickness]::new(0, 10, 12, 10)
        $btnSave.VerticalAlignment = 'Center'
        [void]$fp.Children.Add($btnSave)
        $footer.Child = $fp
        [System.Windows.Controls.Grid]::SetRow($footer, 2)
        [void]$wrap.Children.Add($footer)
    }

    $root = New-Object System.Windows.Controls.Border
    $root.Background = Brush (Get-Pal 'Backdrop')
    $root.CornerRadius = [System.Windows.CornerRadius]::new(12)
    $root.Padding = [System.Windows.Thickness]::new(0)
    $root.Child = $wrap
    return @{ Root = $root; Bar = $bar; BarText = $barTxt;
              BtnSave = $btnSave; BtnClose = $btnClose }
}

# ---------------------------------------------------------------------------
#  新建 / 编辑日程
# ---------------------------------------------------------------------------
function Test-EventEditorDirty {
    # 日程编辑窗"用户是否动过任何字段"。
    #   与 $script:EdSnapshot（开窗那一刻的快照）逐项比对；任意一项不同即算动过。
    #   只读 $script: 上的东西 —— 会被 WPF 处理器调用，抓局部变量会抛"检索不到变量"。
    #   返回 $true = 动过（要走校验）；$false = 原封未动（可以直接退出）。
    try {
        $now = (@(
            ([string]$script:EdTbTitle.Text).Trim()
            ([string]$script:EdTbDate.Text).Trim()
            ([string]$script:EdTbStart.Text).Trim()
            ([string]$script:EdTbEnd.Text).Trim()
            ([string]$script:EdEvery.Text).Trim()
            ([string]$script:EdUntil.Text).Trim()
            ([string]$script:EdRepeat.Tag)
            ([string]$script:EdReminder.Tag)
            ([string]$script:EdTag)
            [string]([bool]$script:EdMonthLast.IsChecked)
        ) -join [char]1)
        return ($now -ne [string]$script:EdSnapshot)
    } catch { return $true }   # 读不到就保守当成"动过"，宁可多校验一次也别丢用户输入
}

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
    # 下拉框的初值一律用**语义值**（英文小写 / 数字字符串），不再用英文文案：
    #   文案现在随语言变，'None'/'Daily' 这类字面量在中界面下根本不存在，
    #   拿它去 New-ChoiceField 会匹配不上而静默落到第一项。
    $repeatVal = 'none'; $everyVal = '1'; $untilVal = ''
    $monthLastVal = $false; $reminderVal = '0'
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
            $rp = ([string]$script:EdEv.repeat).ToLowerInvariant()
            if ($rp -eq 'daily' -or $rp -eq 'weekly' -or $rp -eq 'monthly') { $repeatVal = $rp }
        }
        if ($script:EdEv.PSObject.Properties.Name -contains 'repeatEvery') { $everyVal = [string]$script:EdEv.repeatEvery }
        if ($script:EdEv.PSObject.Properties.Name -contains 'repeatUntil') { $untilVal = [string]$script:EdEv.repeatUntil }
        if ($script:EdEv.PSObject.Properties.Name -contains 'repeatMonthMode') { $monthLastVal = ([string]$script:EdEv.repeatMonthMode -eq 'last') }
        if ($script:EdEv.PSObject.Properties.Name -contains 'reminderMin') {
            $rm = [int]$script:EdEv.reminderMin
            if ($rm -gt 0) { $reminderVal = [string]$rm }
        }
    }

    $script:EdWin = New-Object System.Windows.Window
    $script:EdWin.Title = (Get-LangText 'win.event')
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
    [void]$sp.Children.Add((New-Txt -Text (Get-LangText $(if ($script:EdEditing) { 'fld.ed.title' } else { 'fld.ed.new' })) `
        -Size 18 -Color (Get-Pal 'Ink') -Weight 'Bold'))

    $script:EdTbTitle = New-EditorField $sp (Get-LangText 'fld.ed.titleF') $tStr
    $script:EdTbDate  = New-EditorField $sp (Get-LangText 'fld.ed.date') $dStr

    $row = New-Object System.Windows.Controls.Grid
    $cdA = New-Object System.Windows.Controls.ColumnDefinition
    $cdA.Width = [System.Windows.GridLength]::new(1, 'Star'); $row.ColumnDefinitions.Add($cdA)
    $cdB = New-Object System.Windows.Controls.ColumnDefinition
    $cdB.Width = [System.Windows.GridLength]::new(10, 'Pixel'); $row.ColumnDefinitions.Add($cdB)
    $cdC = New-Object System.Windows.Controls.ColumnDefinition
    $cdC.Width = [System.Windows.GridLength]::new(1, 'Star'); $row.ColumnDefinitions.Add($cdC)

    $colA = New-Object System.Windows.Controls.StackPanel
    [void]$colA.Children.Add((New-Txt -Text (Get-LangText 'fld.ed.start') -Size 11 -Color (Get-Pal 'InkFaint')))
    $script:EdTbStart = New-Object System.Windows.Controls.TextBox
    $script:EdTbStart.Text = $sStr; $script:EdTbStart.Height = 32; $script:EdTbStart.FontSize = 13
    $script:EdTbStart.Background = Brush (Get-Pal 'CardAlt'); $script:EdTbStart.Foreground = Brush (Get-Pal 'Ink')
    $script:EdTbStart.BorderBrush = Brush (Get-Pal 'Border'); $script:EdTbStart.BorderThickness = [System.Windows.Thickness]::new(2)
    $script:EdTbStart.Padding = [System.Windows.Thickness]::new(6, 3, 6, 3)
    $script:EdTbStart.VerticalContentAlignment = 'Center'
    [void]$colA.Children.Add($script:EdTbStart)
    [System.Windows.Controls.Grid]::SetColumn($colA, 0); [void]$row.Children.Add($colA)

    $colB = New-Object System.Windows.Controls.StackPanel
    [void]$colB.Children.Add((New-Txt -Text (Get-LangText 'fld.ed.end') -Size 11 -Color (Get-Pal 'InkFaint')))
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
    $script:EdRepeat = New-ChoiceField $sp 'fld.ed.repeat' $repeatVal @(
        @{ V = 'none'; K = 'opt.rep.none' }, @{ V = 'daily'; K = 'opt.rep.daily' },
        @{ V = 'weekly'; K = 'opt.rep.weekly' }, @{ V = 'monthly'; K = 'opt.rep.monthly' })
    $script:EdEvery = New-EditorField $sp (Get-LangText 'fld.ed.every') $everyVal
    $script:EdUntil = New-EditorField $sp (Get-LangText 'fld.ed.until') $untilVal
    $monthRow = New-Object System.Windows.Controls.StackPanel
    $monthRow.Orientation = 'Horizontal'
    $monthRow.Margin = [System.Windows.Thickness]::new(0, -5, 0, 10)
    $script:EdMonthLast = New-Object System.Windows.Controls.CheckBox
    $script:EdMonthLast.Content = (Get-LangText 'fld.ed.monthLast')
    $script:EdMonthLast.IsChecked = $monthLastVal
    $script:EdMonthLast.FontSize = 11
    $script:EdMonthLast.Foreground = Brush (Get-Pal 'InkSoft')
    [void]$monthRow.Children.Add($script:EdMonthLast)
    [void]$sp.Children.Add($monthRow)
    $script:EdReminder = New-ChoiceField $sp 'fld.ed.reminder' $reminderVal @(
        @{ V = '0'; K = 'opt.rem.no' }, @{ V = '5'; K = 'opt.rem.5' },
        @{ V = '10'; K = 'opt.rem.10' }, @{ V = '15'; K = 'opt.rem.15' })

    # 标签按钮组
    [void]$sp.Children.Add((New-Txt -Text (Get-LangText 'fld.ed.tag') -Size 10 -Color (Get-Pal 'InkFaint')))
    $tagRow = New-Object System.Windows.Controls.StackPanel
    $tagRow.Orientation = 'Horizontal'
    $tagRow.Margin = [System.Windows.Thickness]::new(0, 2, 0, 12)
    $script:EdTag = $tagStr
    # 第十轮：标签从 Settings['TagColors'] 动态生成（用户可在设置里增删改）。
    #   事件标签只展示 work/focus/life 三类（task 是任务的默认分类，不出现在事件里）。
    $allTags = Get-TagChoices
    $tagColors = [ordered]@{}
    foreach ($k in @($allTags.Keys)) {
        if ([string]$k -eq 'task') { continue }
        $tagColors[$k] = [string]$allTags[$k]
    }
    $tagBtns = @{}
    foreach ($k in $tagColors.Keys) {
        # 标签名是用户数据（第十轮起可自定义），原文显示，不做首字母大写——
        # 否则用户建的小写标签在编辑器里会变成另一个样子，跟设置页的标签管理对不上。
        $label = [string]$k
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
    $chrome = Get-EditorChrome (Get-LangText 'win.event') $scroll
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
        # Esc = 放弃关闭。第七轮起：没动过的空表单直接退（与 × 一致）；
        # 动过的表单也允许 Esc 放弃 —— Esc 的语义本来就是"不要了"，
        # 用户既然主动按了 Esc，就不该被校验拦住（× 才承担"保存并校验"）。
        if ($e.Key -eq 'Escape') { Close-DialogWindow $script:EdWin $false }
    })

    # × = 保存并关闭（原 Save 的全部逻辑原样搬过来）；Esc = 放弃（上面的 KeyDown）。
    #
    # 第七轮（item 3）：**没动过的空表单必须能直接退出**。
    #   用户报"有时候没有新建日程的想法，不小心点进去就出不来了"——
    #   原来 × 无条件走校验，标题为空就拦住，于是"误点进来"变成了"必须编一条出来"。
    #   现在的规则：
    #     · 表单与打开时一模一样（没动过任何字段）-> 直接放弃关闭，不校验；
    #     · 动过任何一个字段 -> 才进入校验（标题必填、日期/时间格式要对）。
    #   编辑既有日程时永远算"动过"，行为与本轮之前完全一致。
    #
    # 为什么用"开窗快照 + 关窗比对"而不是在每个控件上挂 TextChanged 打脏标记：
    #   ① 需要盯的控件有 8 个（标题/日期/起止/每/截止/勾选/三组下拉），
    #      逐个挂处理器既啰嗦又容易漏；
    #   ② 下拉框与勾选框是 New-ChoiceField / CheckBox，它们的"用户改过"
    #      不一定触发同一个事件（ComboBox 选固定项不触发 TextChanged）；
    #   ③ 快照比对是"以结果为准"，比"以事件为准"更不容易假阴性。
    #   比对放在关窗那一刻做一次，成本可以忽略。
    $script:EdSnapshot = (@(
        ([string]$script:EdTbTitle.Text).Trim()
        ([string]$script:EdTbDate.Text).Trim()
        ([string]$script:EdTbStart.Text).Trim()
        ([string]$script:EdTbEnd.Text).Trim()
        ([string]$script:EdEvery.Text).Trim()
        ([string]$script:EdUntil.Text).Trim()
        ([string]$script:EdRepeat.Tag)
        ([string]$script:EdReminder.Tag)
        ([string]$script:EdTag)
        [string]([bool]$script:EdMonthLast.IsChecked)
    ) -join [char]1)
    $script:EdIsNew = (-not [bool]$script:EdEditing)
    # × = 保存并关闭（原 Save 的全部逻辑原样搬过来）；Esc = 放弃（上面的 KeyDown）。
    $chrome.BtnClose.Add_Click({
        if ([bool]$script:EdIsNew -and -not (Test-EventEditorDirty)) {
            Close-DialogWindow $script:EdWin $false
            return
        }
        $title = ([string]$script:EdTbTitle.Text).Trim()
        if ([string]::IsNullOrWhiteSpace($title)) {
            $script:EdErr.Text = (Get-LangText 'err.titleRequired')
            $script:EdErr.Visibility = 'Visible'
            return
        }
        $dt = $null
        try { $dt = [datetime]::ParseExact(([string]$script:EdTbDate.Text).Trim(), 'yyyy-MM-dd', $null) } catch { }
        if ($null -eq $dt) {
            $script:EdErr.Text = (Get-LangText 'err.dateFormat')
            $script:EdErr.Visibility = 'Visible'
            return
        }
        $sMin = Parse-HHMM ([string]$script:EdTbStart.Text)
        $eMin = Parse-HHMM ([string]$script:EdTbEnd.Text)
        if ($sMin -lt 0 -or $eMin -lt 0) {
            $script:EdErr.Text = (Get-LangText 'err.timeFormat')
            $script:EdErr.Visibility = 'Visible'
            return
        }
        if ($eMin -le $sMin) { $eMin = [math]::Min(1439, $sMin + 30) }

        $every = 0
        if (-not [int]::TryParse(([string]$script:EdEvery.Text).Trim(), [ref]$every) -or $every -lt 1) {
            $script:EdErr.Text = (Get-LangText 'err.repeatInterval')
            $script:EdErr.Visibility = 'Visible'
            return
        }
        $until = ''
        $untilRaw = ([string]$script:EdUntil.Text).Trim()
        if (-not [string]::IsNullOrWhiteSpace($untilRaw)) {
            try { $until = Fmt-Date ([datetime]::ParseExact($untilRaw, 'yyyy-MM-dd', $null)) }
            catch {
                $script:EdErr.Text = (Get-LangText 'err.repeatUntil')
                $script:EdErr.Visibility = 'Visible'
                return
            }
        }
        # 读 .Tag（语义值），不读 .Text：文案现在随语言变，'Daily' 在中界面下不存在。
        $repeat = ([string]$script:EdRepeat.Tag).ToLowerInvariant()
        if (@('none','daily','weekly','monthly') -notcontains $repeat) { $repeat = 'none' }
        $monthMode = 'day'
        if ([bool]$script:EdMonthLast.IsChecked) { $monthMode = 'last' }
        $reminderMin = 0
        $remTag = [string]$script:EdReminder.Tag
        if ($remTag -match '^\d+$') { $reminderMin = [int]$remTag }
        if ($reminderMin -lt 0 -or $reminderMin -gt 99) { $reminderMin = 0 }

        if ($script:EdEditing) {
            # 第八轮（第三十节第 1 条）：编辑也进撤销栈。
            #   必须在**任何字段被改写之前**压栈 —— 压完再改，快照才是"改前"的。
            #   用 Copy-Record（不能用 .Clone()：JSON 反序列化出来的 PSCustomObject
            #   没有该方法，见第二十九节的坑）。
            try {
                Push-Undo -Kind 'edit-event' -Id ([string]$script:EdEv.id) `
                    -Snapshot (Copy-Record $script:EdEv) -Label $title
            } catch { Write-ErrLog ('Push-Undo edit-event: ' + $_.Exception.Message) }
            # 只改用户看得见的字段，其余（id / note / done）原样保留
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
        # 第八轮（第三十节第 1 条）：编辑后弹一条可撤销的提示条（与删除/勾选/拖动一致）。
        if ($script:EdEditing) {
            Show-UndoActionToast -Kind 'edit-event' -LabelText 'undo.editEvent' -Title $title
        }
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
        $script:SetErr.Text = (Get-LangText 'err.sessionLen')
        $script:SetErr.Visibility = 'Visible'
        return $false
    }

    # ---- 字号档位 ----
    # 第六轮起一律读 .Tag（语义值）：可选文案已经本地化了，读 .Text 在中文界面下
    # 必然匹配不上，然后静默回落 Normal —— 用户会觉得"选了大字号却没用"。
    $scaleVal = 1.0
    $scaleKey = ([string]$script:SetUiScale.Tag).ToLowerInvariant()
    if ($script:SetScaleChoices.Contains($scaleKey)) {
        $scaleVal = [double]$script:SetScaleChoices[$scaleKey]
    } else {
        $scaleVal = 1.0
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

    # ---- 语言（第五轮 / 第六轮改读 Tag） ----
    $langVal = ([string]$script:SetLangBox.Tag).ToLowerInvariant()
    if (@('zh','en') -notcontains $langVal) { $langVal = 'zh' }

    # ---- 视图密度（第五轮；第六轮拆成周/月两个键） ----
    $densityVal = 40
    $densityKey = ([string]$script:SetDensityBox.Tag).ToLowerInvariant()
    if ($script:SetDensityChoices.Contains($densityKey)) { $densityVal = [int]$script:SetDensityChoices[$densityKey] }
    $monthDensityVal = 40
    $monthDenKey = ([string]$script:SetMonthDensityBox.Tag).ToLowerInvariant()
    if ($script:SetDensityChoices.Contains($monthDenKey)) { $monthDensityVal = [int]$script:SetDensityChoices[$monthDenKey] }

    # ---- 落库 ----
    $oldTheme = [string]$script:Theme
    $oldScale = [double]$script:Settings['UiScale']
    $oldLang = [string]$script:Lang
    $oldDensity = [int]$script:Settings['WeekDensity']
    $oldMonthDensity = [int]$script:Settings['MonthDensity']
    $script:Settings['PomodoroMin'] = $m
    $script:Settings['UiScale'] = $scaleVal
    $script:Settings['UiAdaptive'] = [bool]$script:SetUiAdaptive.IsChecked
    $script:Settings['Topmost'] = [bool]$script:SetTopmost.IsChecked
    $script:Settings['CloseToTray'] = [bool]$script:SetCloseToTray.IsChecked
    $script:Settings['WeekViewRange'] = $weekRange
    $script:Settings['Language'] = $langVal
    $script:Settings['WeekDensity'] = $densityVal
    $script:Settings['MonthDensity'] = $monthDensityVal
    # 提示条角落（第六轮）：只影响下一次弹提示条的位置，不需要重建界面。
    $corner = ([string]$script:SetToastCorner.Tag).ToLowerInvariant()
    if (@('bl','br','tl','tr') -notcontains $corner) { $corner = 'br' }
    $script:Settings['ToastCorner'] = $corner
    # 提示条停留秒数（第七轮）：0 = 不自动关。非法值一律落回 5（与默认一致）。
    $toastSecs = 0
    if (-not [int]::TryParse(([string]$script:SetToastSeconds.Tag), [ref]$toastSecs)) { $toastSecs = 5 }
    if (@(0,3,5,8) -notcontains $toastSecs) { $toastSecs = 5 }
    $script:Settings['ToastSeconds'] = $toastSecs
    $newTheme = ([string]$script:SetThemeBox.Tag).ToLowerInvariant()
    if (@('light','night') -notcontains $newTheme) { $newTheme = 'light' }
    $script:Settings['Theme'] = $newTheme

    # 应用到运行时状态
    $script:UiScaleUser = $scaleVal
    [void](Update-UiScale)
    # 语言统一走 Set-Lang（设值 + 重建取词数组 + 刷 XAML 文案）。
    # 这里只改状态，不在这里刷界面 —— 下面的重建分支决定刷新时机。
    $script:Lang = $langVal
    Initialize-Lang
    $script:TopmostOn = [bool]$script:SetTopmost.IsChecked
    try { if ($null -ne $script:MainWindow) { $script:MainWindow.Topmost = [bool]$script:TopmostOn } } catch { }
    $script:CloseToTray = [bool]$script:Settings['CloseToTray']

    Save-Settings
    Reset-Pomodoro

    # ---- 需要重建界面的改动 ----
    # 字号变了：代码 new 出来的控件（New-Txt / New-PixBtn）字号在创建时就定死了，
    #   只有重建整棵树才会按新倍率重画。所以走 Build-Window（换皮不换窗，窗口对象不变）。
    # 主题变了：Set-Theme 本身就是重建路径，且它会带上新的 UiScale。
    # 语言变了：侧栏导航文字是 XAML 里写死的，改完词以后**还要重排一遍**才对齐
    #   （中文两个字比英文五个字母窄，但导航行高是按字号算的，不重建也能看；
    #    不过语言和字号一起变时只重建一次更省事）。
    # 三者都变时只走一次（Set-Theme -Sync 是最高优先的重建路径），避免重建多遍。
    $scaleChanged = ([math]::Abs([double]$oldScale - $scaleVal) -gt 0.001)
    $themeChanged = ($oldTheme -ne $newTheme)
    $langChanged = ($oldLang -ne $langVal)
    try {
        if ($themeChanged) {
            Set-Theme $newTheme -Sync
        } elseif ($scaleChanged) {
            Build-Window
            Refresh-All
        } else {
            if ($langChanged) { Apply-Lang }
            Apply-UiScale
            Refresh-All
        }
    } catch { Write-ErrLog ('Settings apply: ' + $_.Exception.Message) }

    # 周视图密度：只在当前就在周视图时才立刻重画（否则会白算一遍没有人看的轴）
    try {
        if ($densityVal -ne $oldDensity -and $script:View -eq 'week') { [void](Set-WeekDensity $densityVal) }
    } catch { Write-ErrLog ('Set week density: ' + $_.Exception.Message) }

    # 月视图密度（第六轮）：同理，只在当前就在月视图时重画。
    #   月视图没法"局部改尺寸"——日期格的最小高度是在建格子时烘上去的，
    #   所以这里只能整体重建月视图。好在月视图重建很轻（几十个格子）。
    try {
        if ($monthDensityVal -ne $oldMonthDensity -and $script:View -eq 'month') { Refresh-All }
    } catch { Write-ErrLog ('Set month density: ' + $_.Exception.Message) }

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
    $script:SetWin.Title = (Get-LangText 'win.settings')
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
    [void]$sp.Children.Add((New-Txt -Text (Get-LangText 'fld.st.title') -Size 18 -Color (Get-Pal 'Ink') -Weight 'Bold'))
    $who = ''
    try { $who = [string]$env:USERNAME } catch { }
    if ([string]::IsNullOrWhiteSpace($who)) { $who = 'unknown' }
    [void]$sp.Children.Add((New-Txt -Text ((Get-LangText 'fld.st.user') + $who) -Size 11 -Color (Get-Pal 'InkSoft')))
    # 数据目录这一段（第四节）第六轮挪到"数据"页了 —— 它是数据类信息，
    #   和字号/主题不在一个心智抽屉里。这里只留一行极简说明（谁在用哪份数据）。

    # ---- 设置项搜索（第八轮第三十节第 5 条）----
    # 设置已经四页二十多项，找"提示条停留多久"要翻页。给一个搜索框：
    #   输入时按**当前语言文案**对字段名做子串匹配，命中即切到对应页签并高亮该字段。
    #   实现：字段 key -> 页签 的索引建在 $script:SetSearchIndex（见下方各页构建完后），
    #   搜索处理器只读 $s.Text 和 $script: 索引，不捕获创建函数的局部变量。
    $script:SetSearchBox = New-Object System.Windows.Controls.TextBox
    $script:SetSearchBox.FontSize = (Scale-Ui 12)
    $script:SetSearchBox.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
    $script:SetSearchBox.Padding = [System.Windows.Thickness]::new(8, 5, 8, 5)
    $script:SetSearchBox.Margin = [System.Windows.Thickness]::new(0, 10, 0, 2)
    $script:SetSearchBox.Background = Brush (Get-Pal 'CardAlt')
    $script:SetSearchBox.Foreground = Brush (Get-Pal 'Ink')
    $script:SetSearchBox.BorderBrush = Brush (Get-Pal 'BorderSoft')
    $script:SetSearchBox.BorderThickness = [System.Windows.Thickness]::new(2)
    $script:SetSearchBox.ToolTip = (Get-LangText 'fld.st.searchHint')
    # 占位提示（无原生 Placeholder，用空字符串 + 下面一行小字提示即可，保持零依赖）
    [void]$sp.Children.Add($script:SetSearchBox)
    $script:SetSearchResult = New-Txt -Text '' -Size 10 -Color (Get-Pal 'InkFaint')
    $script:SetSearchResult.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    [void]$sp.Children.Add($script:SetSearchResult)
    $script:SetSearchBox.Add_TextChanged({
        param($s, $e)
        try {
            $q = [string]$s.Text
            if ([string]::IsNullOrWhiteSpace($q)) {
                if ($null -ne $script:SetSearchResult) { $script:SetSearchResult.Text = '' }
                return
            }
            $q = $q.Trim().ToLowerInvariant()
            # 在索引里找：字段 key 或它的当前语言文案包含输入词即命中。
            #   命中多个时取"第一个"（页签顺序），并在结果行列出命中数。
            $hits = @()
            foreach ($entry in @($script:SetSearchIndex)) {
                $key = [string]$entry.Key
                $page = [string]$entry.Page
                $label = ''
                try { $label = Get-LangText $key } catch { }
                $labelL = $label.ToLowerInvariant()
                if ($key.ToLowerInvariant().Contains($q) -or $labelL.Contains($q)) {
                    $hits += $entry
                }
            }
            if ($hits.Count -eq 0) {
                if ($null -ne $script:SetSearchResult) { $script:SetSearchResult.Text = (Get-LangText 'fld.st.searchNone') }
                return
            }
            $first = $hits[0]
            if ($null -ne $script:SetTabsShow) { & $script:SetTabsShow ([string]$first.Page) }
            if ($null -ne $script:SetSearchResult) {
                $script:SetSearchResult.Text = (Get-LangText 'fld.st.searchHit') -f $hits.Count
            }
        } catch { Write-ErrLog ('Settings search: ' + $_.Exception.Message) }
    })

    # ===========================================================================
    #  分页（第六轮，用户第 1 条）
    #  设置项涨到 9 个之后，一屏已经要滚两屏。分页的收益不在"好看"，在**它决定了
    #  以后还能不能继续加设置项**。四个页：
    #    外观 Appearance —— 字号、自适应、主题、语言、周密度
    #    窗口 Window     —— 置顶、关闭到托盘、周时段、番茄钟
    #    数据 Data       —— 数据目录、打开文件夹、近 7 天统计
    #    关于 About      —— 版本、快捷键
    #  做法：四个 StackPanel 各存一份引用（$script:SetPageAppear 等），切页只换
    #  $script:SetPageHost.Child。为什么不用 Visibility 切换：四个页面叠在一起时
    #  窗口高度会按"最高的那页"算，短页下方留一大片空白 —— 直接换 Child 更干净。
    #  注意：**所有控件都要在本次函数里全部建出来**（不论当前显示哪一页），
    #  因为 Save-SettingsDialogValues 会读它们中的每一个；分页只影响"看不看得见"。
    # ===========================================================================
    # 页签顺序的**唯一真源**：Ctrl+1..4 键盘导航按这个顺序映射，审计也读它。
    #   为什么单独抽一个变量：页签按钮、SetTabsShow 的 switch、键盘映射三处都依赖
    #   这个顺序，各自写一份字面量迟早会有一处漏改。
    $script:SetTabKeys = @('appear', 'window', 'data', 'about')
    $tabs = New-SettingsTabs $script:SetTabKeys `
        @((Get-LangText 'set.tab.appear'), (Get-LangText 'set.tab.window'), `
          (Get-LangText 'set.tab.data'), (Get-LangText 'set.tab.about'))
    [void]$sp.Children.Add($tabs.Strip)
    [void]$sp.Children.Add($tabs.Host)
    $script:SetPageHost = $tabs.Host

    $pa = New-Object System.Windows.Controls.StackPanel   # 外观
    $pw = New-Object System.Windows.Controls.StackPanel   # 窗口
    $pd = New-Object System.Windows.Controls.StackPanel   # 数据
    $pb = New-Object System.Windows.Controls.StackPanel   # 关于
    $script:SetPageAppear = $pa
    $script:SetPageWindow = $pw
    $script:SetPageData   = $pd
    $script:SetPageAbout  = $pb
    # 页签按钮表：切页时要改每个按钮的配色（选中态用强调色）
    $script:SetTabButtons = $tabs.Buttons
    # 切页函数体存在 $script: 上，供页签按钮的处理器调用。
    # 为什么不是普通函数：它要读四个页面引用与按钮表，做成函数就得把引用再传一遍；
    # 直接闭包成 scriptblock 读 $script: 更短，而且这里是"同一时刻只有一个设置窗"的场景。
    $script:SetTabsShow = {
        param([string]$Key)
        try {
            switch ($Key) {
                'appear' { $script:SetPageHost.Child = $script:SetPageAppear }
                'window' { $script:SetPageHost.Child = $script:SetPageWindow }
                'data'   { $script:SetPageHost.Child = $script:SetPageData }
                'about'  { $script:SetPageHost.Child = $script:SetPageAbout }
            }
            $script:SetTabActive = $Key
            foreach ($b in $script:SetTabButtons) {
                # ⚠⚠ 本函数最容易踩的一个坑：**PowerShell 变量名大小写不敏感**。
                #   页签的 key 存在 $b.Tag['key'] 里，如果循环里写
                #       $key = [string]$b.Tag['key']
                #   那它和上面的形参 `$Key` 是**同一个变量** —— 第一轮循环就把
                #   $Key 覆盖成了第一个页签的 key，之后所有比较都错位一格。
                #   表现极具迷惑性：只有"第一个页签（appear）"能高亮，
                #   其它页签永远不高亮；而且切页逻辑本身完全正常
                #   （switch 在循环之前就执行完了），审计里只看到 highlight=False。
                #   所以这里的局部变量**绝不能叫 $key**，一律用 $tabKey。
                $tabKey = [string]$b.Tag['key']
                $on = ($null -ne $b.Tag) -and ($b.Tag -is [hashtable]) -and ($tabKey -eq $Key)
                $bg = Get-Pal 'CardAlt'
                $fg = Get-Pal 'InkSoft'
                if ($on) { $bg = Get-Pal 'AccentFocus'; $fg = Get-Pal 'Ink' }
                # ⚠ 不能直接 $b.Background = ... ：New-PixBtn 把底色**烘进
                #   ControlTemplate**（模板字符串里写死 Background="$Bg"），模板优先于
                #   控件自身的 Background 属性，运行期改它视觉上毫无反应（不报错，
                #   最难查的那种）。正确做法是 ApplyTemplate 之后把模板里那个名为 bd
                #   的 Border 取回来，改它自己的 Background —— 与同文件
                #   Update-TagChipSelection 用的是同一套做法。
                try { [void]$b.ApplyTemplate() } catch { }
                $bd = $null
                try { $bd = $b.Template.FindName('bd', $b) } catch { }
                if ($null -ne $bd) { $bd.Background = Brush $bg }
                $txt = $b.Content
                if ($txt -is [System.Windows.Controls.TextBlock]) { $txt.Foreground = Brush $fg }
            }
        } catch { Write-ErrLog ('SetTabsShow: ' + $_.Exception.Message) }
    }

    # ================= 外观页 =================
    #  这一组是用户报的"在 setting 处增加修改字号、调整主题以及其他软件常用设置"。
    #  为什么字号用"档位下拉"而不是滑块：档位是离散的、可预期的（小/标准/大/特大），
    #  滑块会让人反复调、还调不出"和默认一样"的那个点。
    # 档位键做成"显示文字 -> 倍率"的映射表，存在 $script: 上：
    # 处理器里要用它做反查，而它是本函数的局部变量（处理器触发时已销毁）。
    $script:SetScaleChoices = [ordered]@{
        'small'  = 0.85
        'normal' = 1.00
        'medium' = 1.08
        'large'  = 1.15
        'huge'   = 1.35
    }
    # 反查当前档位：存的是倍率，配置被手改成一个"不在档位表里"的值时回落到 normal。
    $curScale = [double]$script:Settings['UiScale']
    $curScaleName = 'normal'
    foreach ($k in $script:SetScaleChoices.Keys) {
        if ([math]::Abs([double]$script:SetScaleChoices[$k] - $curScale) -lt 0.001) { $curScaleName = $k; break }
    }
    $script:SetUiScale = New-ChoiceField $pa 'fld.st.scale' $curScaleName @(
        @{ V = 'small'; K = 'opt.scale.small' }, @{ V = 'normal'; K = 'opt.scale.normal' },
        @{ V = 'medium'; K = 'opt.scale.medium' },
        @{ V = 'large'; K = 'opt.scale.large' }, @{ V = 'huge'; K = 'opt.scale.huge' })

    $script:SetUiAdaptive = New-ToggleRow $pa (Get-LangText 'fld.st.adaptive') `
        ([bool]$script:Settings['UiAdaptive']) `
        (Get-LangText 'hint.st.adaptive')

    $script:SetThemeBox = New-ChoiceField $pa 'fld.st.theme' ([string]$script:Settings['Theme']) @(
        @{ V = 'light'; K = 'opt.theme.light' }, @{ V = 'night'; K = 'opt.theme.night' })

    # 语言（第五轮）。放外观页里，因为它和主题/字号一样属于"整屏观感"。
    #   第六轮改成 New-ChoiceField：语义值 'zh'/'en' 存进 Tag，不再靠"显示名反查"。
    #   顺带解决一个隐患 —— 以前下拉里显示的是"中文/English"，切到英文界面后
    #   这两个词仍然是中文，看着像没生效；现在它是唯二不该被翻译的项（语言名本身），
    #   所以直接从语言表里取，双语下都显示"中文 / English"这组**固定**名称。
    $script:SetLangBox = New-ChoiceField $pa 'fld.st.lang' ([string]$script:Lang) @(
        @{ V = 'zh'; K = 'opt.lang.zh' }, @{ V = 'en'; K = 'opt.lang.en' })

    # 周视图密度（第五轮）。显示"紧凑/标准/宽松"，落库存像素高。
    #   第六轮两处改动：① 挪到外观页（它是"看起来多密"，不是"窗口怎么表现"）；
    #                  ② 拆成 WeekDensity / MonthDensity 两个键 —— 周视图要"紧密排满"、
    #                     月视图要"一格能看清"，同一个值满足不了两个诉求。
    $script:SetDensityChoices = [ordered]@{ 'compact' = 28; 'normal' = 40; 'roomy' = 56 }
    $curDensityName = 'normal'
    foreach ($k in $script:SetDensityChoices.Keys) {
        if ([int]$script:SetDensityChoices[$k] -eq [int]$script:Settings['WeekDensity']) { $curDensityName = $k; break }
    }
    $script:SetDensityBox = New-ChoiceField $pa 'fld.st.density' $curDensityName @(
        @{ V = 'compact'; K = 'opt.dens.compact' }, @{ V = 'normal'; K = 'opt.dens.normal' },
        @{ V = 'roomy'; K = 'opt.dens.roomy' })
    # 月视图密度（第六轮新增）。月视图的"一格"是日期格，行高含义与周视图不同。
    $curMonthDen = 'normal'
    foreach ($k in $script:SetDensityChoices.Keys) {
        if ([int]$script:SetDensityChoices[$k] -eq [int]$script:Settings['MonthDensity']) { $curMonthDen = $k; break }
    }
    $script:SetMonthDensityBox = New-ChoiceField $pa 'fld.st.densityMonth' $curMonthDen @(
        @{ V = 'compact'; K = 'opt.dens.compact' }, @{ V = 'normal'; K = 'opt.dens.normal' },
        @{ V = 'roomy'; K = 'opt.dens.roomy' })

    # ================= 窗口页 =================
    $script:SetTopmost = New-ToggleRow $pw (Get-LangText 'fld.st.topmost') `
        ([bool]$script:Settings['Topmost'])
    $script:SetCloseToTray = New-ToggleRow $pw (Get-LangText 'fld.st.tray') `
        ([bool]$script:Settings['CloseToTray']) `
        (Get-LangText 'fld.st.trayHint')
    $script:SetWeekRange = New-ComboField $pw (Get-LangText 'fld.st.weekRange') `
        ([string]$script:Settings['WeekViewRange']) @('0-24','8-20','6-22','9-18')
    $script:SetWeekRange.IsEditable = $false
    # 提示条角落（第六轮）：撤销条贴在屏幕哪个角。默认 br = 老版本的写死位置。
    $script:SetToastCorner = New-ChoiceField $pw 'fld.st.toastCorner' ([string]$script:Settings['ToastCorner']) @(
        @{ V = 'br'; K = 'opt.corner.br' }, @{ V = 'bl'; K = 'opt.corner.bl' },
        @{ V = 'tl'; K = 'opt.corner.tl' }, @{ V = 'tr'; K = 'opt.corner.tr' })
    # 提示条停留时长（第七轮）：3 / 5 / 8 秒，或 0 = 不自动关。
    #   值和角落放一起，因为它们回答的是同一个问题："这条提示条怎么出现、怎么消失"。
    $toastSecsInit = [string]([int]$script:Settings['ToastSeconds'])
    if (@('0','3','5','8') -notcontains $toastSecsInit) { $toastSecsInit = '5' }
    $script:SetToastSeconds = New-ChoiceField $pw 'fld.st.toastSeconds' $toastSecsInit @(
        @{ V = '3'; K = 'opt.toast.s3' }, @{ V = '5'; K = 'opt.toast.s5' },
        @{ V = '8'; K = 'opt.toast.s8' }, @{ V = '0'; K = 'opt.toast.hold' })
    # 番茄钟（第三轮就有）挪到窗口页：它算"运行期行为"，不是"长什么样"。
    $script:SetTbPomo = New-EditorField $pw (Get-LangText 'fld.st.pomo') ([string]$script:Settings['PomodoroMin'])

    # ================= 数据页 =================
    [void]$pd.Children.Add((New-Txt -Text ((Get-LangText 'fld.st.dir') + ' — ' + $script:DataDir) -Size 10 -Color (Get-Pal 'InkFaint')))
    [void]$pd.Children.Add((New-Txt -Text (Get-LangText 'fld.st.dirHint') -Size 10 -Color (Get-Pal 'InkFaint')))
    $dirBox2 = New-Object System.Windows.Controls.TextBox
    $dirBox2.Text = $script:DataDir
    $dirBox2.Height = 32; $dirBox2.FontSize = 12
    $dirBox2.IsReadOnly = $true
    $dirBox2.Margin = [System.Windows.Thickness]::new(0, 4, 0, 12)
    $dirBox2.Background = Brush (Get-Pal 'CardAlt'); $dirBox2.Foreground = Brush (Get-Pal 'InkSoft')
    $dirBox2.BorderBrush = Brush (Get-Pal 'BorderSoft'); $dirBox2.BorderThickness = [System.Windows.Thickness]::new(2)
    $dirBox2.Padding = [System.Windows.Thickness]::new(6, 3, 6, 3)
    $dirBox2.VerticalContentAlignment = 'Center'
    [void]$pd.Children.Add($dirBox2)

    # 近 7 天专注柱状
    [void]$pd.Children.Add((New-Txt -Text (Get-LangText 'fld.st.focus7') -Size 10 -Color (Get-Pal 'InkFaint')))
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
    [void]$pd.Children.Add($chart)

    $total = 0; foreach ($v in $vals) { $total += [int]$v }
    $pomoLen = [int]$script:Settings['PomodoroMin']
    if ($pomoLen -lt 1) { $pomoLen = 25 }
    $pomos = [int][math]::Floor($total / [double]$pomoLen)
    $doneN = @($script:Events | Where-Object { [bool]$_.done }).Count
    $allN = @($script:Events).Count
    $openN = @($script:Tasks | Where-Object { -not [bool]$_.done }).Count
    [void]$pd.Children.Add((New-Txt -Text ((Get-LangText 'fld.st.thisWeek') -f $total, $pomos) `
        -Size 12 -Color (Get-Pal 'Ink') -Weight 'Semi'))
    [void]$pd.Children.Add((New-Txt -Text ((Get-LangText 'fld.st.totals') -f $allN, $doneN, $openN) `
        -Size 11 -Color (Get-Pal 'InkSoft')))
    # Reset timer / Open folder 是"数据类"动作，跟着数据页走
    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'
    $btnRow.HorizontalAlignment = 'Right'
    $btnRow.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    # 只留两个"动作"按钮；保存/放弃统一走标题栏的 Save / ×（语义见 New-DialogSaveButton 注释）。
    $bReset = New-PixBtn -Text (Get-LangText 'fld.st.reset') -Bg (Get-Pal 'Card') -Fg (Get-Pal 'Ink') -W 110 -H 34 -FontSize 12
    $bOpen = New-PixBtn -Text (Get-LangText 'fld.st.openDir') -Bg (Get-Pal 'Card') -Fg (Get-Pal 'Ink') -W 106 -H 34 -FontSize 12
    $bReset.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [void]$btnRow.Children.Add($bReset)
    [void]$btnRow.Children.Add($bOpen)
    [void]$pd.Children.Add($btnRow)

    # ================= 标签管理（第十轮第 3 条）=================
    # 标签 -> 色板键 存 $script:Settings['TagColors']；这里提供增删改。
    #   · 已有标签渲染成 chips（色块 + 名字 + ×），点 × 删除；
    #   · 输入新名字 + 选颜色 + 点添加，即时写回 Settings 并刷新。
    #   为什么放数据页：标签是"数据结构"层的东西（决定卡片色条），不是外观。
    [void]$pd.Children.Add((New-Txt -Text (Get-LangText 'fld.st.tags') -Size 12 -Color (Get-Pal 'Ink') -Weight 'Semi'))
    $tagHintTxt = New-Txt -Text (Get-LangText 'fld.st.tagsHint') -Size 10 -Color (Get-Pal 'InkFaint')
    $tagHintTxt.TextWrapping = 'Wrap'
    [void]$pd.Children.Add($tagHintTxt)

    # 标签 chips 容器：增删后由 Render-TagManagerRows 重建
    $script:TagManagerStack = New-Object System.Windows.Controls.WrapPanel
    $script:TagManagerStack.Margin = [System.Windows.Thickness]::new(0, 6, 0, 8)

    # 添加行：名字输入 + 颜色下拉 + 添加按钮
    $addRow = New-Object System.Windows.Controls.StackPanel
    $addRow.Orientation = 'Horizontal'
    $script:TagNewName = New-Object System.Windows.Controls.TextBox
    $script:TagNewName.Height = 30; $script:TagNewName.Width = 150
    $script:TagNewName.FontSize = (Scale-Ui 12)
    $script:TagNewName.Background = Brush (Get-Pal 'CardAlt'); $script:TagNewName.Foreground = Brush (Get-Pal 'Ink')
    $script:TagNewName.BorderBrush = Brush (Get-Pal 'BorderSoft'); $script:TagNewName.BorderThickness = [System.Windows.Thickness]::new(1)
    $script:TagNewName.ToolTip = (Get-LangText 'fld.st.tagName')
    [void]$addRow.Children.Add($script:TagNewName)

    $script:TagNewColor = New-Object System.Windows.Controls.ComboBox
    $script:TagNewColor.Width = 96; $script:TagNewColor.Height = 30; $script:TagNewColor.FontSize = (Scale-Ui 12)
    $script:TagNewColor.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    foreach ($c in @('AccentEvent','AccentFocus','AccentTask','Holiday')) { [void]$script:TagNewColor.Items.Add($c) }
    $script:TagNewColor.SelectedIndex = 1
    [void]$addRow.Children.Add($script:TagNewColor)

    $bTagAdd = New-PixBtn -Text (Get-LangText 'btn.tagAdd') -Bg (Get-Pal 'AccentTask') -Fg (Get-Pal 'Ink') -W 104 -H 30 -FontSize 10
    $bTagAdd.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $bTagAdd.Add_Click({ try { Add-CustomTag } catch { Write-ErrLog ('Tag add: ' + $_.Exception.Message) } })
    [void]$addRow.Children.Add($bTagAdd)
    [void]$pd.Children.Add($script:TagManagerStack)
    [void]$pd.Children.Add($addRow)
    Render-TagManagerRows

    # ================= 关于页 =================
    [void]$pb.Children.Add((New-Txt -Text (Get-LangText 'about.appName') -Size 14 -Color (Get-Pal 'Ink') -Weight 'Bold'))
    [void]$pb.Children.Add((New-Txt -Text (Get-LangText 'about.tech') -Size 10 -Color (Get-Pal 'InkSoft')))
    $verTxt = 'v0.9'
    try { if ($null -ne $script:AppVersion) { $verTxt = [string]$script:AppVersion } } catch { }
    [void]$pb.Children.Add((New-Txt -Text ((Get-LangText 'fld.st.version') + $verTxt) -Size 11 -Color (Get-Pal 'Ink')))
    [void]$pb.Children.Add((New-Txt -Text (Get-LangText 'fld.st.shortcuts') -Size 11 -Color (Get-Pal 'Ink') -Weight 'Semi'))
    foreach ($k in @('sc.newEvent', 'sc.search', 'sc.undo', 'sc.esc', 'sc.tabs')) {
        [void]$pb.Children.Add((New-Txt -Text (Get-LangText $k) -Size 10 -Color (Get-Pal 'InkSoft')))
    }

    # 校验错误行：默认折叠，只有在 Save-SettingsDialogValues 返回 $false 时才显形。
    #  为什么放在页签区**下面**（$sp 而非某一页）：错误是"整窗级"的，跟着某一页走会在
    #  切页后消失，反而让人以为保存成功了。
    $script:SetErr = New-Txt -Text '' -Size 10 -Color (Get-Pal 'AccentEvent') -Weight 'Semi'
    $script:SetErr.Visibility = 'Collapsed'
    $script:SetErr.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    $script:SetErr.TextWrapping = 'Wrap'
    Set-LineHeight $script:SetErr 10
    [void]$sp.Children.Add($script:SetErr)

    # ---- 设置项搜索索引（第八轮第三十节第 5 条）----
    # 字段 key -> 页签 的映射。搜索框按"字段 key 或当前语言文案是否包含输入词"
    # 来匹配，命中即切到对应页签。索引必须**在建完所有字段之后**才建（此时各字段
    # 的文案已由 Get-LangText 生成），并挂到 $script: 供 TextChanged 处理器读取。
    $script:SetSearchIndex = @(
        # 外观页
        @{ Key = 'fld.st.scale';        Page = 'appear' },
        @{ Key = 'fld.st.adaptive';     Page = 'appear' },
        @{ Key = 'fld.st.theme';        Page = 'appear' },
        @{ Key = 'fld.st.lang';         Page = 'appear' },
        @{ Key = 'fld.st.density';      Page = 'appear' },
        @{ Key = 'fld.st.densityMonth'; Page = 'appear' },
        # 窗口页
        @{ Key = 'fld.st.topmost';      Page = 'window' },
        @{ Key = 'fld.st.tray';         Page = 'window' },
        @{ Key = 'fld.st.weekRange';    Page = 'window' },
        @{ Key = 'fld.st.pomo';         Page = 'window' },
        @{ Key = 'fld.st.toastCorner';  Page = 'window' },
        @{ Key = 'fld.st.toastSeconds'; Page = 'window' },
        # 数据页
        @{ Key = 'fld.st.dir';          Page = 'data' },
        @{ Key = 'fld.st.reset';        Page = 'data' },
        @{ Key = 'fld.st.openDir';      Page = 'data' },
        @{ Key = 'fld.st.thisWeek';     Page = 'data' },
        @{ Key = 'fld.st.totals';       Page = 'data' },
        # 关于页
        @{ Key = 'fld.st.version';      Page = 'about' },
        @{ Key = 'fld.st.shortcuts';    Page = 'about' }
    )

    # 默认停在外观页（用户最常改的那一页）
    & $script:SetTabsShow 'appear'

    $chrome = Get-EditorChrome (Get-LangText 'win.settings') $sp
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
        # 第七轮（第六轮第二十七节第 2 条）：设置窗页签支持 Ctrl+1..4 键盘导航。
        #   与"弹窗里 Esc 关闭"形成同一套键盘习惯：手不离开键盘就能翻页 + 退出。
        #   只在按着 Ctrl 时生效，免得普通数字键（将来若加数字输入框）被吞。
        if ($e.Key -eq 'Escape') { Close-DialogWindow $script:SetWin $false; return }
        try {
            if (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0) {
                # 键位表挂在 $script: 上（而不是本处理器局部）：审计要能读它验证映射，
                #   而且它跟 $script:SetTabKeys 的**页签顺序**必须一致，分散写迟早对不上。
                $map = @{}
                for ($ti = 0; $ti -lt 4; $ti++) {
                    $map['D' + ($ti + 1)] = [string]$script:SetTabKeys[$ti]
                    $map['NumPad' + ($ti + 1)] = [string]$script:SetTabKeys[$ti]
                }
                $k = [string]$e.Key
                if ($map.ContainsKey($k)) {
                    if ($null -ne $script:SetTabsShow) { & $script:SetTabsShow ([string]$map[$k]) }
                    $e.Handled = $true
                }
            }
        } catch { Write-ErrLog ('Settings tab key: ' + $_.Exception.Message) }
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
    $win.Title = (Get-LangText 'win.dayAgenda')
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
        [void]$sp.Children.Add((New-Txt -Text (Get-LangText 'fld.day.emptyDetail') -Size 12 -Color (Get-Pal 'InkFaint')))
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
    $chrome = Get-EditorChrome (Get-LangText 'win.dayAgenda') $sp
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
    $priorityVal = 'medium'      # 语义值（下拉框的文案随语言变，值不变）
    $projectVal = ''
    $estimatedVal = '0'
    $actualVal = '0'
    $dueTimeVal = '09:00'
    $reminderVal = '0'
    $subtaskLines = ''
    if ($script:TkEditing) {
        $textVal = [string]$script:TkTask.text
        if ($null -ne $script:TkTask.due) { $dueVal = [string]$script:TkTask.due }
        if (-not [string]::IsNullOrWhiteSpace([string]$script:TkTask.tag)) { $tagVal = [string]$script:TkTask.tag }
        $doneVal = [bool]$script:TkTask.done
        if ($script:TkTask.PSObject.Properties.Name -contains 'priority') { $priorityVal = ([string]$script:TkTask.priority).ToLowerInvariant() }
        if (@('high','medium','low') -notcontains $priorityVal) { $priorityVal = 'medium' }
        if ($script:TkTask.PSObject.Properties.Name -contains 'project') { $projectVal = [string]$script:TkTask.project }
        if ($script:TkTask.PSObject.Properties.Name -contains 'estimatedMin') { $estimatedVal = [string]$script:TkTask.estimatedMin }
        if ($script:TkTask.PSObject.Properties.Name -contains 'actualMin') { $actualVal = [string]$script:TkTask.actualMin }
        if ($script:TkTask.PSObject.Properties.Name -contains 'dueTime') { $dueTimeVal = [string]$script:TkTask.dueTime }
        if ($script:TkTask.PSObject.Properties.Name -contains 'reminderMin' -and [int]$script:TkTask.reminderMin -gt 0) {
            $reminderVal = [string]$script:TkTask.reminderMin
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
    $script:TkWin.Title = (Get-LangText 'win.task')
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
    [void]$sp.Children.Add((New-Txt -Text (Get-LangText $(if ($script:TkEditing) { 'fld.tk.title' } else { 'fld.tk.new' })) `
        -Size 18 -Color (Get-Pal 'Ink') -Weight 'Bold'))

    $script:TkText = New-EditorField $sp (Get-LangText 'fld.tk.text') $textVal
    $script:TkDue = New-EditorField $sp (Get-LangText 'fld.tk.due') $dueVal
    $script:TkDueTime = New-EditorField $sp (Get-LangText 'fld.tk.dueTime') $dueTimeVal
    $script:TkPriority = New-ChoiceField $sp 'fld.tk.priority' $priorityVal @(
        @{ V = 'high'; K = 'opt.pri.high' }, @{ V = 'medium'; K = 'opt.pri.mid' },
        @{ V = 'low'; K = 'opt.pri.low' })
    # 第十轮（第 3 条）：项目从自由文本改成"可编辑下拉"，列出已有项目。
    #   大小写不敏感去重：Study 与 study 视为同一个（保留先出现的大小写），
    #   避免"手误多写一个大小写变体"就裂成两个项目。
    $projList = New-Object System.Collections.ArrayList
    $projSeen = @{}
    foreach ($p in @($script:Tasks | ForEach-Object { [string]$_.project } |
                     Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $key = $p.ToLowerInvariant()
        if ($projSeen.ContainsKey($key)) { continue }
        $projSeen[$key] = $true
        [void]$projList.Add($p)
    }
    $script:TkProject = New-ComboField $sp (Get-LangText 'fld.tk.project') $projectVal @($projList)

    $metricRow = New-Object System.Windows.Controls.Grid
    for ($i = 0; $i -lt 3; $i++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        if ($i -eq 1) { $cd.Width = [System.Windows.GridLength]::new(10, 'Pixel') }
        else { $cd.Width = [System.Windows.GridLength]::new(1, 'Star') }
        [void]$metricRow.ColumnDefinitions.Add($cd)
    }
    $eCol = New-Object System.Windows.Controls.StackPanel
    [void]$eCol.Children.Add((New-Txt -Text (Get-LangText 'fld.tk.estimated') -Size 10 -Color (Get-Pal 'InkFaint')))
    $script:TkEstimated = New-Object System.Windows.Controls.TextBox
    $script:TkEstimated.Text = $estimatedVal; $script:TkEstimated.Height = 30; $script:TkEstimated.FontSize = 12
    $script:TkEstimated.Background = Brush (Get-Pal 'CardAlt'); $script:TkEstimated.Foreground = Brush (Get-Pal 'Ink')
    $script:TkEstimated.BorderBrush = Brush (Get-Pal 'Border'); $script:TkEstimated.BorderThickness = [System.Windows.Thickness]::new(2)
    [void]$eCol.Children.Add($script:TkEstimated)
    [System.Windows.Controls.Grid]::SetColumn($eCol, 0); [void]$metricRow.Children.Add($eCol)
    $aCol = New-Object System.Windows.Controls.StackPanel
    [void]$aCol.Children.Add((New-Txt -Text (Get-LangText 'fld.tk.actual') -Size 10 -Color (Get-Pal 'InkFaint')))
    $script:TkActual = New-Object System.Windows.Controls.TextBox
    $script:TkActual.Text = $actualVal; $script:TkActual.Height = 30; $script:TkActual.FontSize = 12
    $script:TkActual.Background = Brush (Get-Pal 'CardAlt'); $script:TkActual.Foreground = Brush (Get-Pal 'Ink')
    $script:TkActual.BorderBrush = Brush (Get-Pal 'Border'); $script:TkActual.BorderThickness = [System.Windows.Thickness]::new(2)
    [void]$aCol.Children.Add($script:TkActual)
    [System.Windows.Controls.Grid]::SetColumn($aCol, 2); [void]$metricRow.Children.Add($aCol)
    $metricRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    [void]$sp.Children.Add($metricRow)

    $script:TkReminder = New-ChoiceField $sp 'fld.ed.reminder' $reminderVal @(
        @{ V = '0'; K = 'opt.rem.no' }, @{ V = '5'; K = 'opt.rem.5' },
        @{ V = '10'; K = 'opt.rem.10' }, @{ V = '15'; K = 'opt.rem.15' },
        @{ V = '30'; K = 'opt.rem.30' })
    [void]$sp.Children.Add((New-Txt -Text (Get-LangText 'fld.tk.subtasks') -Size 11 -Color (Get-Pal 'InkFaint')))
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
    $bAddSub = New-PixBtn -Text (Get-LangText 'btn.add') -Bg (Get-Pal 'AccentTask') -Fg (Get-Pal 'Ink') -W 70 -H 30 -FontSize 10
    $bAddSub.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $bAddSub.Add_Click({ try { $txt = ([string]$script:TkNewSubtask.Text).Trim(); if ($txt) { New-TaskSubtaskRow -Stack $script:TkSubtaskStack -Text $txt -Done $false; $script:TkNewSubtask.Text = '' } } catch { } })
    [void]$subAddRow.Children.Add($bAddSub)
    [void]$sp.Children.Add($subAddRow)

    # 分类的值是**数据键**（写进 task.tag，还决定卡片竖条颜色），不进语言表。
    # 第十轮：标签从 Settings['TagColors'] 动态生成（用户可在设置里增删改）。
    $tagKeys = @((Get-TagChoices).Keys)
    $script:TkTag = New-ComboField $sp (Get-LangText 'fld.tk.tag') $tagVal $tagKeys
    $script:TkTag.IsEditable = $false
    $script:TkTag.SelectedItem = $tagVal

    $doneRow = New-Object System.Windows.Controls.StackPanel
    $doneRow.Orientation = 'Horizontal'
    $doneRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    $script:TkDone = New-Object System.Windows.Controls.CheckBox
    $script:TkDone.Content = (Get-LangText 'fld.tk.done')
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
    $chrome = Get-EditorChrome (Get-LangText 'win.task') $scroll
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
                $script:TkErr.Text = (Get-LangText 'err.taskRequired')
                $script:TkErr.Visibility = 'Visible'
                return
            }
            $dueRaw = ([string]$script:TkDue.Text).Trim()
            $due = $null
            if (-not [string]::IsNullOrWhiteSpace($dueRaw)) {
                try { $due = Fmt-Date ([datetime]::ParseExact($dueRaw, 'yyyy-MM-dd', $null)) }
                catch {
                    $script:TkErr.Text = (Get-LangText 'err.dueDate')
                    $script:TkErr.Visibility = 'Visible'
                    return
                }
            }
            $dueTime = ([string]$script:TkDueTime.Text).Trim()
            $dueMinCheck = Parse-HHMM $dueTime
            if ($dueMinCheck -lt 0) {
                $script:TkErr.Text = (Get-LangText 'err.dueTime')
                $script:TkErr.Visibility = 'Visible'
                return
            }
            # 分类是数据键（不翻译），但为了兼容"万一"被本地化过的旧值，仍然读 .Text 并原样落库。
            $tag = [string]$script:TkTag.Text
            if ([string]::IsNullOrWhiteSpace($tag)) { $tag = 'task' }
            # 优先级 / 提醒读 .Tag（语义值）：文案随语言变，读 .Text 在中文界面下必然失配。
            $priority = ([string]$script:TkPriority.Tag).ToLowerInvariant()
            if (@('high','medium','low') -notcontains $priority) { $priority = 'medium' }
            $project = ([string]$script:TkProject.Text).Trim()
            $estimated = 0; $actual = 0
            [void][int]::TryParse(([string]$script:TkEstimated.Text).Trim(), [ref]$estimated)
            [void][int]::TryParse(([string]$script:TkActual.Text).Trim(), [ref]$actual)
            if ($estimated -lt 0) { $estimated = 0 }
            if ($actual -lt 0) { $actual = 0 }
            $reminderMin = 0
            $remTag = [string]$script:TkReminder.Tag
            if ($remTag -match '^\d+$') { $reminderMin = [int]$remTag }
            if ($reminderMin -lt 0 -or $reminderMin -gt 99) { $reminderMin = 0 }
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
                # 第八轮（第三十节第 1 条）：任务编辑也进撤销栈。
                #   必须在**任何字段被改写之前**压栈。Copy-Record 而非 .Clone()。
                try {
                    Push-Undo -Kind 'edit-task' -Id ([string]$script:TkTask.id) `
                        -Snapshot (Copy-Record $script:TkTask) -Label $txt
                } catch { Write-ErrLog ('Push-Undo edit-task: ' + $_.Exception.Message) }
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
            # 第八轮（第三十节第 1 条）：编辑后弹可撤销提示条。
            if ($script:TkEditing) {
                Show-UndoActionToast -Kind 'edit-task' -LabelText 'undo.editTask' -Title $txt
            }
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
    if ($null -eq $script:FoDurationField) { return $false }
    # 时长范围：0-99 分钟（0 = 不计时，只当作"专注状态开关"）。
    # 第七轮起时长由四位滚轮维护。**注意单位**：$script:FoDurationMin 存的是**秒**
    #   （mm:ss 里那 4 位数字的合计），而落库的 PomodoroMin 是**分钟** ——
    #   这里做一次换算，不要再拿秒去和 99 比（那样 1 分钟的会话会被当成 60 而夹到 99）。
    #   先向下取整到分钟：走了 90 秒的会话 = 1 分钟（与 Get-FocusElapsedMin 同一口径）。
    $m = [int][math]::Floor([int]$script:FoDurationMin / 60)
    if ($m -lt 0) { $m = 0 }
    if ($m -gt 99) { $m = 99 }
    # 休息时长上界同步收到 99，跟会话同一套心智模型（也是 mm:ss）
    $breakMin = 0
    if (-not [int]::TryParse(([string]$script:FoBreakMin.Text).Trim(), [ref]$breakMin) -or $breakMin -lt 0 -or $breakMin -gt 99) {
        $script:FoErr.Text = (Get-LangText 'err.breakLen')
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
    $script:FoWin.Title = (Get-LangText 'win.focus')
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
    [void]$sp.Children.Add((New-Txt -Text (Get-LangText 'fld.fo.title') -Size 20 -Color (Get-Pal 'Ink') -Weight 'Bold'))
    [void]$sp.Children.Add((New-Txt -Text (Get-LangText 'fld.fo.sub') `
        -Size 11 -Color (Get-Pal 'InkSoft')))

    $enabledRow = New-Object System.Windows.Controls.StackPanel
    $enabledRow.Orientation = 'Horizontal'
    $enabledRow.Margin = [System.Windows.Thickness]::new(0, 14, 0, 6)
    $script:FoEnabled = New-Object System.Windows.Controls.CheckBox
    $script:FoEnabled.Content = (Get-LangText 'fld.fo.enable')
    $script:FoEnabled.IsChecked = [bool]$script:Settings['PomodoroEnabled']
    $script:FoEnabled.FontSize = 13
    $script:FoEnabled.Foreground = Brush (Get-Pal 'Ink')
    $script:FoEnabled.VerticalContentAlignment = 'Center'
    [void]$enabledRow.Children.Add($script:FoEnabled)
    [void]$sp.Children.Add($enabledRow)

    # 第七轮（item 5）：时长从"十来个档位的下拉"换成四位数字滚轮。
    #   用户的说法是"时间是四个数字，给每一位都做成 1-9 可滚动"。
    #   语义取值仍然是"分钟"（0-99），只是操作方式变了 ——
    #   Save-FocusWindowSettings 读的是 $script:FoDurationMin，不再是 .Text。
    #   0 = 不计时（只当专注状态开关）这个约定保持不变。
    $script:FoDurationField = New-DigitWheelField $sp 'fld.fo.duration' `
        ([int]$script:Settings['PomodoroMin']) 99

    $breakRow = New-Object System.Windows.Controls.StackPanel
    $breakRow.Orientation = 'Horizontal'
    $breakRow.Margin = [System.Windows.Thickness]::new(0, -4, 0, 8)
    $script:FoBreakEnabled = New-Object System.Windows.Controls.CheckBox
    $script:FoBreakEnabled.Content = (Get-LangText 'fld.fo.breakOn')
    $script:FoBreakEnabled.IsChecked = [bool]$script:Settings['BreakEnabled']
    $script:FoBreakEnabled.FontSize = 12
    $script:FoBreakEnabled.Foreground = Brush (Get-Pal 'Ink')
    [void]$breakRow.Children.Add($script:FoBreakEnabled)
    [void]$sp.Children.Add($breakRow)
    $script:FoBreakMin = New-ComboField $sp (Get-LangText 'fld.fo.break') `
        ([string]$script:Settings['BreakMin']) @('0','5','10','15','20','30','45','60')

    $taskChoices = @($script:Tasks | ForEach-Object { [string]$_.text } | Sort-Object -Unique)
    $script:FoTbTask = New-ComboField $sp (Get-LangText 'fld.fo.task') `
        ([string]$script:Settings['PomodoroTask']) $taskChoices

    $card = New-Bd -Bg (Get-Pal 'CardAlt') -Border (Get-Pal 'Border') -Radius 10
    $card.Padding = [System.Windows.Thickness]::new(18, 14, 18, 14)
    $card.Margin = [System.Windows.Thickness]::new(0, 2, 0, 10)
    # 这块大计时器卡片同时当"抓手"用：Focus 窗口整体是很轻的浮窗，
    # 只能从 38px 标题栏拖太别扭了（这正是"想要可拖动版本"的由来）。
    # 挑卡片而不是整块窗口：卡片里只有文字，不像表单区那样有输入框/下拉框，
    # 从这儿拖不会跟"选文字""开下拉"打架。
    $card.ToolTip = (Get-LangText 'fo.dragTip')
    $csp = New-Object System.Windows.Controls.StackPanel
    $script:FoTimeText = New-Txt -Text '25:00' -Size 46 -Color (Get-Pal 'Ink') -Weight 'Bold'
    $script:FoTimeText.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $script:FoTimeText.HorizontalAlignment = 'Center'
    # 第九轮（第三十二节第 4 条）：等宽 Consolas 的默认行高比微软雅黑大，
    #   46px 数字在盒子里会显得"顶格下沉"，跟下面那行中文状态标签的间距看着不齐。
    #   收紧行高（略小于字号本身），让数字基线贴紧、与中文标签的视觉间距更均匀。
    $script:FoTimeText.LineHeight = (Scale-Ui 44)
    $script:FoStatusText = New-Txt -Text (Get-LangText 'fo.ready') -Size 12 -Color (Get-Pal 'AccentEvent') -Weight 'Semi'
    $script:FoStatusText.HorizontalAlignment = 'Center'
    $script:FoTaskText = New-Txt -Text (Get-LangText 'fo.noTask') -Size 11 -Color (Get-Pal 'InkSoft')
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
    [void]$sp.Children.Add((New-Txt -Text ((Get-LangText 'fo.last7') -f $total) `
        -Size 11 -Color (Get-Pal 'InkFaint')))

    $script:FoErr = New-Txt -Text '' -Size 10 -Color (Get-Pal 'AccentEvent') -Weight 'Semi'
    $script:FoErr.Visibility = 'Collapsed'
    $script:FoErr.Margin = [System.Windows.Thickness]::new(0, 6, 0, 6)
    [void]$sp.Children.Add($script:FoErr)

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'
    $btnRow.HorizontalAlignment = 'Right'
    # 第七轮（item 6）：新增"结束并统计"。原来只有 Start/Pause 与 Reset ——
    #   用户走完一整个番茄钟才会自动计入统计；中途想收工（干完了/要走了）只有 Reset，
    #   而 Reset 是**清空**（把已走的分钟数丢掉），等于"这段白干了"。
    #   现在三件套语义：
    #     · Start / Pause —— 继续或暂停当前这段；
    #     · End & log    —— 把**本次已专注的分钟数**结算进今日统计（并计入关联任务），
    #                       弹提示条告知，计时器归零回到 Ready；
    #     · Reset        —— 放弃本次，不记录。
    #   为什么"结束"要能算出"本次已走多少"：剩余时长 = Total - Remaining，
    #   走完的部分就是 Total - Remaining（Reset 后 Remaining = Total，所以算出来 0）。
    $bStart = New-PixBtn -Text (Get-LangText 'btn.start') -Bg (Get-Pal 'AccentEvent') -Fg '#FFFFFF' -W 94 -H 36 -FontSize 12
    $bEnd = New-PixBtn -Text (Get-LangText 'btn.endLog') -Bg (Get-Pal 'AccentTask') -Fg (Get-Pal 'Ink') -W 104 -H 36 -FontSize 12
    $bReset = New-PixBtn -Text (Get-LangText 'btn.reset') -Bg (Get-Pal 'Card') -Fg (Get-Pal 'Ink') -W 88 -H 36 -FontSize 12
    $bStart.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $bEnd.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [void]$btnRow.Children.Add($bStart)
    [void]$btnRow.Children.Add($bEnd)
    [void]$btnRow.Children.Add($bReset)
    [void]$sp.Children.Add($btnRow)
    $script:FoStartText = $bStart.Content

    $chrome = Get-EditorChrome (Get-LangText 'win.focus') $sp
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
                    $script:FoErr.Text = (Get-LangText 'err.focusDisabled')
                    $script:FoErr.Visibility = 'Visible'
                }
            }
        } catch { Write-ErrLog ('Focus start: ' + $_.Exception.Message) }
    })
    $bReset.Add_Click({
        try { if (Save-FocusWindowSettings) { Reset-Pomodoro } } catch { Write-ErrLog ('Focus reset: ' + $_.Exception.Message) }
    })
    $bEnd.Add_Click({
        try { End-FocusSession } catch { Write-ErrLog ('Focus end: ' + $_.Exception.Message) }
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
    $script:AvWin.Title = (Get-LangText 'win.avatar')
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
    [void]$sp.Children.Add((New-Txt -Text (Get-LangText 'av.title2') -Size 20 -Color (Get-Pal 'Ink') -Weight 'Bold'))
    [void]$sp.Children.Add((New-Txt -Text (Get-LangText 'av.hint') `
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
    $script:AvPreviewHint = New-Txt -Text (Get-LangText 'av.default') -Size 10 -Color (Get-Pal 'InkSoft')
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
    $bChoose = New-PixBtn -Text (Get-LangText 'btn.chooseImg') -Bg (Get-Pal 'AccentFocus') -Fg (Get-Pal 'TodayInk') -W 126 -H 36 -FontSize 12
    $bDefault = New-PixBtn -Text (Get-LangText 'btn.restoreDef') -Bg (Get-Pal 'Card') -Fg (Get-Pal 'Ink') -W 126 -H 36 -FontSize 12
    $bChoose.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [void]$btnRow.Children.Add($bChoose)
    [void]$btnRow.Children.Add($bDefault)
    [void]$sp.Children.Add($btnRow)

    $chrome = Get-EditorChrome (Get-LangText 'win.avatar') $sp
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
            $dlg.Title = (Get-LangText 'dlg.chooseAvatar')
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
#  番茄钟完成提示 / 可撤销删除提示（不走 MessageBox，避免挡住截图与自动化）
#
#  -ActionText + -ActionScript 让同一个提示条变成"5 秒内可撤销"的 Undo 条
#  （第 5 条外观建议）：Windows 自己的"删除到回收站"就是这个模式。
#  二次确认挡不住"手比脑子快"，所以确认之后还要留一条退路。
#
#  作用域硬规则：-ActionScript 在点击时才被 WPF 回调，那时本函数的局部变量
#  （$w / $scripts）早已随作用域销毁。所以动作脚本一律挂在 $btn.Tag 上带过去，
#  处理器里只读 $s.Tag —— 绝不允许捕获创建函数的局部变量。
# ---------------------------------------------------------------------------
function Get-ToastWorkArea {
    # 提示条该贴哪块屏的工作区。优先"主窗口所在的那块屏"，读不到就退回主屏。
    #
    #  为什么不直接用 SystemParameters.WorkArea：那是**主屏**的工作区。用户把主窗口
    #  拖到副屏时，按主屏算边距会让提示条飞到主屏 —— 而提示条是给"当前窗口的操作"
    #  做反馈的，跑到另一块屏上等于没提示。这里尽量跟着主窗口走。
    #  WorkArea 是 DIP（与 WPF 的 Left/Top 同单位），不含任务栏，可直接用于贴边。
    param()
    try {
        if ($null -ne $script:MainWindow -and $script:MainWindow.IsLoaded) {
            $src = [System.Windows.PresentationSource]::FromVisual($script:MainWindow)
            if ($null -ne $src -and $null -ne $src.WorkingArea) { return $src.WorkingArea }
        }
    } catch { }
    return [System.Windows.SystemParameters]::WorkArea
}

function Show-Toast {
    param([string]$Title = 'Notification', [string]$Text = '',
          [string]$ActionText = '', [scriptblock]$ActionScript = $null,
          [int]$Seconds = 4)
    try {
        # 同一时刻只留一条提示条：否则连续删两项会叠成一片，且旧定时器会把新的关掉
        try {
            if ($null -ne $script:ToastTimer) { $script:ToastTimer.Stop() }
            if ($null -ne $script:ToastWindow) { $script:ToastWindow.Close() }
        } catch { }
        $script:ToastWindow = $null

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

        # ---- 停留时长（第七轮：ToastSeconds）提前算，好决定标题行要不要加关闭 × ----
        $secs = [int]$Seconds
        try {
            if ($null -ne $script:Settings -and $script:Settings.Contains('ToastSeconds')) {
                $secs = [int]$script:Settings['ToastSeconds']
            }
        } catch { }

        # 标题行：左边标题，右边（手动关闭模式时）一个 × 按钮。
        #   第八轮（第三十节第 3 条）：ToastSeconds=0 时不自动关，之前只能靠
        #   动作按钮或关主窗口让它消失，等于"粘"在屏幕上。给它一个显式出口。
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        $tTitle = New-Txt -Text $Title -Size 14 -Color (Get-Pal 'Ink') -Weight 'Bold'
        $tTitle.VerticalAlignment = 'Center'
        [void]$head.Children.Add($tTitle)
        if ($secs -le 0) {
            $bClose = New-PixBtn -Text '×' -Bg ([System.Windows.Media.BrushConverter]::new().ConvertFromString('#00000000')) `
                                 -Fg (Get-Pal 'InkSoft') -H 22 -W 24 -FontSize 14 -Radius 6
            $bClose.VerticalAlignment = 'Center'
            $bClose.HorizontalAlignment = 'Right'
            $bClose.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
            $bClose.ToolTip = (Get-LangText 'toast.close')
            $bClose.Add_Click({
                param($s, $e)
                try {
                    if ($null -ne $script:ToastTimer) { $script:ToastTimer.Stop() }
                    if ($null -ne $script:ToastWindow) {
                        $script:ToastWindow.Close()
                        $script:ToastWindow = $null
                    }
                } catch { }
            })
            [void]$head.Children.Add($bClose)
        }
        [void]$sp.Children.Add($head)

        if ($ActionText -and $null -ne $ActionScript) {
            # 两列：左边正文，右边动作按钮。正文用 StackPanel 包一层，
            # 这样长文本换行时不会把按钮挤到第二行。
            $row = New-Object System.Windows.Controls.StackPanel
            $row.Orientation = 'Horizontal'
            $tx = New-Txt -Text $Text -Size 11 -Color (Get-Pal 'InkSoft')
            $tx.VerticalAlignment = 'Center'
            $tx.Margin = [System.Windows.Thickness]::new(0, 8, 14, 0)
            [void]$row.Children.Add($tx)
            $btn = New-PixBtn -Text $ActionText -Bg (Get-Pal 'CardAlt') -Fg (Get-Pal 'Ink') `
                              -H 26 -FontSize 11 -Radius 6 -BorderCol (Get-Pal 'Border')
            $btn.VerticalAlignment = 'Center'
            $btn.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
            $btn.Tag = $ActionScript
            $btn.Add_Click({
                param($s, $e)
                $act = $s.Tag
                try {
                    if ($null -ne $script:ToastTimer) { $script:ToastTimer.Stop() }
                    if ($null -ne $script:ToastWindow) {
                        $script:ToastWindow.Close()
                        $script:ToastWindow = $null
                    }
                } catch { }
                if ($null -ne $act) {
                    try { & $act } catch { Write-ErrLog ('Toast action: ' + $_.Exception.Message) }
                }
            })
            [void]$row.Children.Add($btn)
            [void]$sp.Children.Add($row)
        } else {
            $t2 = New-Txt -Text $Text -Size 11 -Color (Get-Pal 'InkSoft')
            $t2.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
            [void]$sp.Children.Add($t2)
        }

        $bd.Child = $sp
        $w.Content = $bd
        # ---- 按设置的角落贴边（第六轮：ToastCorner）----
        # 老版本写死右下。提示条是独立 Topmost 窗口，右下角常与系统托盘/输入法候选框
        # 重叠，所以给一个"换角落"的开关。四个角都要考虑**多显示器**：
        #   SystemParameters.WorkArea 是**主屏**的工作区（不含任务栏）。若窗口被拖到
        #   副屏，按主屏 WorkArea 定位会让提示条跳到主屏上去 —— 但提示条本来就该
        #   贴在"用户当前看着的那块屏"。这里用一个折中：如果主窗口在某块屏上，
        #   就用那块屏的工作区；读不到就退回主屏 WorkArea。
        $wa = Get-ToastWorkArea
        # 先 Show 出来量一次实际尺寸：提示条是 SizeToContent，Show 之前 ActualWidth 恒为 0，
        # 直接按 0 算边距会让它贴在屏幕外（老代码用 320/150 两个魔数兜底，正是这个原因）。
        $w.Show()
        $w.UpdateLayout()
        $tw = $w.ActualWidth;  if (-not ($tw -gt 0)) { $tw = 320 }
        $th = $w.ActualHeight; if (-not ($th -gt 0)) { $th = 150 }
        $mx = 16; $my = 16
        $corner = 'br'
        try { if ($null -ne $script:Settings -and $script:Settings.Contains('ToastCorner')) { $corner = [string]$script:Settings['ToastCorner'] } } catch { }
        switch ($corner) {
            'bl' { $w.Left = $wa.Left + $mx;              $w.Top = $wa.Bottom - $th - $my }
            'tl' { $w.Left = $wa.Left + $mx;              $w.Top = $wa.Top + $my }
            'tr' { $w.Left = $wa.Right - $tw - $mx;       $w.Top = $wa.Top + $my }
            default { $w.Left = $wa.Right - $tw - $mx;    $w.Top = $wa.Bottom - $th - $my }
        }
        # 兜底：任何计算失误都不能让提示条跑出可视区（出屏 = 用户以为"没提示"）
        if ($w.Left -lt ($wa.Left - 4)) { $w.Left = $wa.Left + $mx }
        if ($w.Top  -lt ($wa.Top  - 4)) { $w.Top  = $wa.Top  + $my }
        # 注意：定时器与窗口必须挂到 $script: 上。
        # 事件处理器 scriptblock 真正被 WPF 回调时，函数局部变量（$t / $w）已经随作用域消失，
        # StrictMode 下会直接抛"检索不到变量"，被 catch 吞掉后就表现为"Toast 永不关闭"。
        $script:ToastWindow = $w
        # ---- 停留时长（第七轮：ToastSeconds）----
        # $secs 已在标题行之前算好（那里要据此决定是否给标题加关闭 ×）。
        #   0 = 不挂定时器 —— 提示条留在屏幕上，直到用户点标题行的 ×
        #   （或动作按钮 / 关主窗口）。
        #   为什么不让"0 = 立刻关"：那等于把提示条删掉了，语义上说不通。
        if ($secs -le 0) {
            # 手动关闭模式：不挂定时器。出口是标题行的 ×（第八轮补上），
            # 或带动作按钮的撤销条点动作按钮。
            $script:ToastTimer = $null
            return
        }
        $script:ToastTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:ToastTimer.Interval = [timespan]::FromSeconds($secs)
        $script:ToastTimer.Add_Tick({
            try {
                # 非动作按钮的普通提示条：点它就立即消失（手动关闭模式下这是唯一出口）。
                if ($null -ne $script:ToastTimer) { $script:ToastTimer.Stop() }
                if ($null -ne $script:ToastWindow) {
                    $script:ToastWindow.Close()
                    $script:ToastWindow = $null
                }
            } catch { Write-ErrLog ('Toast close: ' + $_.Exception.Message) }
        })
        $script:ToastTimer.Start()
    } catch { Write-ErrLog ('Toast: ' + $_.Exception.Message) }
}
