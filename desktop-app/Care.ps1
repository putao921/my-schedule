# =============================================================================
#  My Schedule - 窗口能力 / 交互 / 覆盖层
#  本文件由 ScheduleWidget.ps1 dot-source，不要单独运行
#
#  覆盖层设计（重要）：
#    界面根是一个 Grid（一个单元格），底层 NodeHost 承载三视图，
#    顶层 UiOverlay 是透明 Canvas，承载"新建日程"与"统计"两个面板。
#    两者同格叠放 -> 做成后加的（UiOverlay）在最后 -> 永远浮在最上面，
#    切换视图只重建 NodeHost，覆盖层不受影响。
#    好处：不需要 Popup（Popup 在独立可视树里，主题切换要额外照顾），
#          也不需要 Adorner（改可视树不好调）。
# =============================================================================

function Parse-HHMM {
    param([string]$S)
    $t = ([string]$S).Trim()
    if ($t -notmatch '^\d{1,2}:\d{2}$') { return -1 }
    $parts = $t.Split(':')
    $h = [int]$parts[0]; $m = [int]$parts[1]
    if ($h -lt 0 -or $h -gt 23 -or $m -lt 0 -or $m -gt 59) { return -1 }
    return $h * 60 + $m
}

# ---------------------------------------------------------------------------
#  C. 命中测试（WPF 没有 DOM 的 closest，自己从起点往上找带 Tag 的祖先）
# ---------------------------------------------------------------------------
function Test-AncestorTag {
    param($Start)
    $cur = $Start
    $hop = 0
    while ($null -ne $cur -and $hop -lt 24) {
        try {
            if ($null -ne $cur.Tag -and ($cur.Tag -is [hashtable])) {
                $t = $cur.Tag
                if ($t.ContainsKey('kind')) { return $t }
            }
        } catch { }
        $cur = $cur.Parent
        $hop++
    }
    return $null
}

function Test-BtnTag {
    # 从事件源往上找"最近的带 Tag 的 Button"，返回它的 Tag。
    #
    # 为什么要跳过 kind='task' 的按钮（第五轮新增）：
    #   任务卡最左边那个 15x15 的勾选方块**本身就是 Button，Tag 是 {kind='task'}**。
    #   它有自己的 Add_Click（点它立刻勾选并 Handled=true），所以本函数返回什么
    #   其实都无所谓了 —— 但那道 Handled 只在真实路由里生效；审计里的合成事件
    #   是直接打到卡片上的，方块的 Click 不会参与，于是 Test-BtnTag 会在这里
    #   返回方块的 {kind='task'}。把它当成"命中了任务卡"，外层的 Up 处理器
    #   就会把这个合成事件当成"点卡片正文"再走一遍 —— 语义重复、结果难预测。
    #   跳过它之后，返回值永远是"真正的功能按钮"（Edit/Delete/Focus/Postpone/Expand）
    #   或者 $null，语义干净。
    param($Start)
    $cur = $Start
    $hop = 0
    while ($null -ne $cur -and $hop -lt 24) {
        try {
            if ($cur -is [System.Windows.Controls.Button] -and $null -ne $cur.Tag) {
                $tg = $cur.Tag
                $isCardBody = ($tg -is [hashtable]) -and $tg.ContainsKey('kind') -and ([string]$tg['kind'] -eq 'task')
                if (-not $isCardBody) { return $tg }
            }
        } catch { }
        $cur = $cur.Parent
        $hop++
    }
    return $null
}

# ---------------------------------------------------------------------------
#  D. 各视图的点按 / 双击行为
# ---------------------------------------------------------------------------
function Attach-ViewHandlers {
    param($Root)
    if ($null -eq $Root) { return }
    $Root.Add_MouseLeftButtonUp({
        param($s, $e)
        # 覆盖层开着时，点底层不响应
        if ($script:OverlayOpen) { return }
        $t = Test-AncestorTag (Get-EventSourceOf $e $s)
        if ($null -eq $t) { return }
        if ($t.kind -eq 'day-more') {
            Open-DayAgenda -Date $t.date
            return
        }
        # 补位格（相邻月份的浅色日号）：点它就跳到那一格所在的周。
        # 和本月日期格同一个行为，但不改"本页只属于本月"——它本身不画任何日程。
        if ($t.kind -eq 'day-pad') {
            $d = $t.date
            $script:Anchor = $d.Date
            $script:Selected = $d.Date
            Set-View 'week'
            return
        }
        if ($t.kind -eq 'day') {
            $d = $t.date
            $script:Anchor = $d.Date
            $script:Selected = $d.Date
            if ($script:View -eq 'month') {
                Set-View 'week'
            } else {
                Refresh-All
            }
        }
    })
    $Root.Add_MouseRightButtonUp({
        param($s, $e)
        if ($script:OverlayOpen) { return }
        $t = Test-AncestorTag (Get-EventSourceOf $e $s)
        if ($null -eq $t) { return }
        # 右键只对本月日期格生效：在 9 月的页面上右键 8/31 的补位格会弹出
        # "8/31 新建日程"的窗口，看起来像点错了月份。
        if ($t.kind -eq 'day') {
            $script:Selected = $t.date
            Open-EventEditor
        }
    })
}

function Attach-EventClick {
    param($Root)
    $Root.Add_MouseLeftButtonUp({
        param($s, $e)
        if ($script:OverlayOpen) { return }
        $t = Test-AncestorTag (Get-EventSourceOf $e $s)
        if ($null -eq $t) { return }
        if ($t.kind -eq 'event') { Open-EventEditor -Id $t.id }
    })
}

function Cancel-PendingTaskToggle {
    # 双击的第二下来了 —— 撤销那次"待勾选"。
    param()
    $script:PendingTaskId = ''
    if ($null -ne $script:TaskClickTimer) { $script:TaskClickTimer.Stop() }
}

function Toggle-TaskDone {
    # 立刻把某个任务在"完成 / 未完成"之间翻转并存盘刷新。
    #
    # 与 Invoke-PendingTaskToggle 的关系：
    #   · Invoke-PendingTaskToggle 翻转的是"被延迟记在 $script:PendingTaskId 里的那一项"，
    #     服务于"单击卡片正文（等 260ms 确认不是双击）"这条路径。
    #   · 本函数按 **id 直接翻转**，服务于"点卡片前的方块"这条路径 ——
    #     方块是明确的勾选控件，不需要等双击判定，点了就该立刻生效。
    #   两者共用下面这段翻转动作用，避免"勾选逻辑"出现两份实现。
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    $hit = @($script:Tasks | Where-Object { [string]$_.id -eq [string]$Id })
    if ($hit.Count -eq 0) { return $false }
    # 第七轮（第六轮第二十七节第 1 条）：把"勾选完成"也纳入撤销栈。
    #   必须在**改动之前**存快照 —— 存改后的就没有"改前状态"可回了。
    #   Snapshot 用 Copy-Record：直接存 $hit[0] 存的是同一个引用，
    #   改完之后快照跟着一起变，撤销就成了空操作（静默失效的典型）。
    #   也不能用 .Clone()：PSCustomObject（JSON 反序列化的产物）没有该方法。
    try {
        Push-Undo -Kind 'toggle' -Id ([string]$Id) -Snapshot (Copy-Record $hit[0]) -Label ([string]$hit[0].text)
    } catch { Write-ErrLog ('Push-Undo toggle: ' + $_.Exception.Message) }
    $wasDone = [bool]$hit[0].done
    $hit[0].done = (-not $wasDone)
    Save-Data
    Fill-Tasks
    # 撤销提示条：告诉用户"刚做了什么"，顺带提示"可以 Ctrl+Z 回去"。
    #   只在主窗口可见且非测试/抑制模式下弹，避免审计里刷屏。
    if (-not $script:SuppressModal -and -not $TestMode) {
        try {
            $label = $(if (-not [string]::IsNullOrWhiteSpace([string]$hit[0].text)) { [string]$hit[0].text } else { 'Task' })
            $verb = $(if ($wasDone) { Get-LangText 'undo.toggleOff' } else { Get-LangText 'undo.toggleOn' })
            Show-Toast -Title (Get-LangText 'undo.task') -Text ($verb + (Shorten-Text $label 22)) `
                -ActionText (Get-LangText 'undo.btn') -Seconds 5 -ActionScript { Undo-Delete }
            Sync-UndoHint
        } catch { }
    }
    return $true
}

function Invoke-PendingTaskToggle {
    # 延时结束，把单击真的落地成"勾选 / 取消勾选"。
    # 单独抽成函数有两个用处：
    #   · 计时器回调只需要一行；
    #   · 无头审计里计时器不保证会被消息泵驱动，可以直接调用它拿到确定结果。
    param()
    $id = [string]$script:PendingTaskId
    $script:PendingTaskId = ''
    return (Toggle-TaskDone -Id $id)
}

function Attach-TaskClick {
    param($Root)
    # 第三轮：双击 = 展开详情面板，单击 = 勾选完成。两者都挂在 Up 事件上，
    # 所以这里必须显式分道 —— 否则一次双击会先勾一下、再展开，看起来像"抖了一下"。
    # MouseLeftButtonUp 的 ClickCount 在 WPF 里是靠双击时间/距离阈值算出来的，
    # 第二下的 Up 事件已经带着 ClickCount=2；第一下才是 1。
    $Root.Add_MouseLeftButtonUp({
        param($s, $e)
        if ($script:OverlayOpen) { return }
        $btnTag = Test-BtnTag (Get-EventSourceOf $e $s)
        if ($null -ne $btnTag -and $null -ne $btnTag.kind -and
            (@('task-edit','task-delete','task-focus','task-postpone') -contains [string]$btnTag.kind)) { return }
        # 双击交给卡片自己的处理器（Fill-Tasks 里挂的那个），这里只处理单击。
        if ((Get-MouseClickCount $e) -ge 2) { Cancel-PendingTaskToggle; return }
        $t = Test-AncestorTag (Get-EventSourceOf $e $s)
        if ($null -eq $t) { return }
        if ($t.kind -eq 'task') {
            # 推迟到"确认不是双击"之后再勾选（原因见 $script:PendingTaskId 的声明处）
            $script:PendingTaskId = [string]$t.id
            if ($null -eq $script:TaskClickTimer) {
                $script:TaskClickTimer = New-Object System.Windows.Threading.DispatcherTimer
                $script:TaskClickTimer.Interval = [TimeSpan]::FromMilliseconds(260)
                $script:TaskClickTimer.Add_Tick({
                    $script:TaskClickTimer.Stop()
                    [void](Invoke-PendingTaskToggle)
                })
            }
            $script:TaskClickTimer.Stop()
            $script:TaskClickTimer.Start()
        }
    })
}

# ---------------------------------------------------------------------------
#  E. 番茄钟
# ---------------------------------------------------------------------------
# 提醒：界面元素在 Build-Window 之前还不存在（FoTimeText 等），
# 所有会被提前调用的函数都必须用"先算数据、后刷界面"的写法。
#
function Set-RingArc {
    # 番茄钟进度环的**唯一**画法（第十四轮）。
    #   以前只有侧栏环用（后来侧栏删了只剩死代码），第十四轮悬浮窗加进度环，
    #   把这段几何抄过去就是第二份 —— 所以先收口成函数，两处都调它。
    #
    # 环的几何必须跟"构建时约定的尺寸"走，不去读 ActualWidth ——
    # 刷新可能发生在首次布局之前，那时 ActualWidth 还是 0。
    # $Size 是构建时的环外径，$Path.StrokeThickness 必须已经设好。
    param($Path, [double]$Size, [double]$Frac)
    if ($null -eq $Path) { return }
    if ($Frac -lt 0.0) { $Frac = 0.0 }
    if ($Frac -gt 1.0) { $Frac = 1.0 }
    $size = [double]$Size
    if ($size -le 8.0) { $size = 86.0 }
    $stroke = [double]$Path.StrokeThickness
    if ($stroke -le 0.0) { $stroke = 6.0 }
    $r = ($size / 2.0) - ($stroke / 2.0) - 3.0
    if ($r -le 2.0) { $r = 2.0 }
    $cx = $size / 2.0
    $cy = $size / 2.0
    $fig = New-Object System.Windows.Media.PathFigure
    $fig.StartPoint = [System.Windows.Point]::new([double]$cx, [double]($cy - $r))
    $fig.IsClosed = $false
    if ($Frac -le 0.0) {
        # 空环：只用极短一段，视觉上等于没有
        $seg0 = New-Object System.Windows.Media.LineSegment
        $seg0.Point = [System.Windows.Point]::new([double]($cx + 0.01), [double]($cy - $r))
        $fig.Segments.Add($seg0)
    } else {
        $sweep = $Frac * 360.0
        $rad = ($sweep - 90.0) * [math]::PI / 180.0
        $seg = New-Object System.Windows.Media.ArcSegment
        $seg.Point = [System.Windows.Point]::new(
            [double]($cx + $r * [math]::Cos($rad)),
            [double]($cy + $r * [math]::Sin($rad)))
        $seg.Size = [System.Windows.Size]::new([double]$r, [double]$r)
        $seg.SweepDirection = [System.Windows.Media.SweepDirection]::Clockwise
        $seg.IsLargeArc = ($sweep -gt 180.0)
        $fig.Segments.Add($seg)
    }
    $geo = New-Object System.Windows.Media.PathGeometry
    $geo.Figures.Add($fig)
    $Path.Data = $geo
}

# 第三轮改动：侧栏那块番茄钟（圆环 + 倒计时 + Start/Setup + Ready）整块删掉了，
# 于是本函数里 PomoArc / PomoText / PomoHint / PomoBox / PomoBtnText 这些
# $script: 变量永远是 $null。所有对它们的写入都必须先判空 —— 这里不是"防御性编程"，
# 而是删块之后的必经路径（StrictMode 下直接读 $null 的属性会抛异常）。
# 现在唯一还活着的显示面是 Focus 浮窗，所以判空分支全部保留、只由浮窗接管。
function Update-PomodoroVisual {
    $total = [int]$script:Pomo.Total
    $rem = [int]$script:Pomo.Remaining
    if ($total -le 0) { $total = 1 }
    if ($rem -lt 0) { $rem = 0 }

    if ($null -ne $script:PomoText) {
        $script:PomoText.Text = ('{0:00}:{1:00}' -f [math]::Floor($rem / 60), ($rem % 60))
    }

    # 进度：0 = 刚开始（空环），1 = 走完（满环）。
    # 只在圆环存在时才需要算 —— 侧栏圆环已删，这段默认不执行。
    if ($null -ne $script:PomoArc) {
        $frac = 1.0 - ($rem / [double]$total)
        # 第十四轮：几何画法收口到 Set-RingArc（悬浮窗也用环了，一份画法两处用）。
        # 原来这里的"环的几何必须跟控件实际尺寸走"说明移进 Set-RingArc 头注释。
        Set-RingArc -Path $script:PomoArc -Size ([double]$script:PomoRingSize) -Frac $frac
    }

    $enabled = [bool]$script:Settings['PomodoroEnabled']
    $mode = [string]$script:Pomo.Mode
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'focus' }
    if ($null -ne $script:PomoBtnText) {
        # 第十轮语言收尾：按钮/状态文字全部走语言表（原来是硬编码英文）。
        if (-not $enabled) { $script:PomoBtnText.Text = (Get-LangText 'pomo.setup') }
        elseif ([bool]$script:Pomo.Running) { $script:PomoBtnText.Text = (Get-LangText 'pomo.pause') }
        elseif ($mode -eq 'break') { $script:PomoBtnText.Text = (Get-LangText 'pomo.resume') }
        else { $script:PomoBtnText.Text = (Get-LangText 'btn.start') }
    }
    if ($null -ne $script:PomoHint) {
        if (-not $enabled) { $script:PomoHint.Text = (Get-LangText 'pomo.disabled') }
        elseif ($mode -eq 'break' -and [bool]$script:Pomo.Running) { $script:PomoHint.Text = (Get-LangText 'pomo.break') }
        elseif ($mode -eq 'break') { $script:PomoHint.Text = (Get-LangText 'pomo.breakPaused') }
        elseif ([bool]$script:Pomo.Running) { $script:PomoHint.Text = (Get-LangText 'pomo.focusing') }
        elseif ($rem -le 0) { $script:PomoHint.Text = (Get-LangText 'pomo.complete') }
        elseif ($rem -lt $total) { $script:PomoHint.Text = (Get-LangText 'pomo.paused') }
        else { $script:PomoHint.Text = (Get-LangText 'fo.ready') }
    }
    if ($null -ne $script:PomoBox) {
        if (-not $enabled) { $script:PomoBox.ToolTip = (Get-LangText 'fo.disabledTip') }
        elseif ([bool]$script:Pomo.Running) { $script:PomoBox.ToolTip = (Get-LangText 'fo.runningTip') }
        else { $script:PomoBox.ToolTip = (Get-LangText 'fo.startTip') }
    }
    if ($null -ne $script:FoTimeText) {
        $script:FoTimeText.Text = ('{0:00}:{1:00}' -f [math]::Floor($rem / 60), ($rem % 60))
        if (-not $enabled) { $script:FoStatusText.Text = (Get-LangText 'pomo.disabled') }
        elseif ($mode -eq 'break' -and [bool]$script:Pomo.Running) { $script:FoStatusText.Text = (Get-LangText 'pomo.break') }
        elseif ($mode -eq 'break') { $script:FoStatusText.Text = (Get-LangText 'pomo.breakPaused') }
        elseif ([bool]$script:Pomo.Running) { $script:FoStatusText.Text = (Get-LangText 'pomo.focusing') }
        elseif ($rem -le 0) { $script:FoStatusText.Text = (Get-LangText 'pomo.complete') }
        elseif ($rem -lt $total) { $script:FoStatusText.Text = (Get-LangText 'pomo.paused') }
        else { $script:FoStatusText.Text = (Get-LangText 'fo.ready') }
        $script:FoStartText.Text = $(if ([bool]$script:Pomo.Running) { Get-LangText 'pomo.pause' } elseif ($mode -eq 'break') { Get-LangText 'pomo.resume' } else { Get-LangText 'btn.start' })
        $task = [string]$script:Pomo.Task
        if ([string]::IsNullOrWhiteSpace($task)) { $task = (Get-LangText 'pomo.noTask') }
        $script:FoTaskText.Text = (Get-LangText 'pomo.taskPrefix') + $task
    }
    # 第十二轮（item 2）：迷你悬浮窗跟着同一条刷新走（每个 tick 都到这里）。
    Update-PomoMini
}

function Complete-PomodoroPhase {
if ([int]$script:Pomo.Remaining -le 0) {
    if ([string]$script:Pomo.Mode -eq 'break') {
        $script:Pomo.Mode = 'focus'
        $script:Pomo.Running = $false
        # 注意：$script:Settings 是 OrderedDictionary，判存在要用 Contains 而不是
        # ContainsKey（后者会抛"不包含名为 ContainsKey 的方法"）。
        $mins = 25
        if ($script:Settings.Contains('PomodoroMin')) {
            $parsed2 = 0
            if ([int]::TryParse(([string]$script:Settings['PomodoroMin']).Trim(), [ref]$parsed2)) { $mins = $parsed2 }
        }
        if ($mins -lt 0) { $mins = 0 }
        $script:Pomo.Total = $mins * 60
        $script:Pomo.Remaining = $mins * 60
        if ($null -ne $script:PomoTimer) { $script:PomoTimer.Stop() }
        try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
        Show-DesktopNotification (Get-LangText 'ntf.breakDone') (Get-LangText 'ntf.breakReady')
        Hide-PomoMini
    } else {
        $script:Settings['FocusTodayMin'] = [int]$script:Settings['FocusTodayMin'] + [int]$script:Pomo.Total
        if (-not [string]::IsNullOrWhiteSpace([string]$script:Pomo.TaskId)) {
            $taskHit = @($script:Tasks | Where-Object { [string]$_.id -eq [string]$script:Pomo.TaskId })
            if ($taskHit.Count -gt 0) {
                $oldActual = 0
                if ($taskHit[0].PSObject.Properties.Name -contains 'actualMin') { $oldActual = [int]$taskHit[0].actualMin }
                $taskHit[0].actualMin = $oldActual + [int]($script:Pomo.Total / 60)
                Save-Data
                Fill-Tasks
            }
        }
        Save-Settings
        $taskText = [string]$script:Pomo.Task
        if ([string]::IsNullOrWhiteSpace($taskText)) { $taskText = (Get-LangText 'pomo.session') }
        try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
        if ([bool]$script:Settings['BreakEnabled']) {
            # 休息时长为 0 = 不休息：直接跳过 break 阶段，别弹一条"break for 0 min"的提示。
            $bm = 5
            $parsedBm = 0
            if ($null -ne $script:Settings['BreakMin'] -and
                [int]::TryParse(([string]$script:Settings['BreakMin']).Trim(), [ref]$parsedBm)) { $bm = $parsedBm }
            if ($bm -gt 0) {
                Show-DesktopNotification (Get-LangText 'ntf.focusDone') ((Get-LangText 'ntf.focusBreak') -f $taskText, [string]$bm)
                $script:Pomo.Mode = 'break'
                $script:Pomo.Total = $bm * 60
                $script:Pomo.Remaining = $bm * 60
                $script:Pomo.Running = $true
                Save-Settings
            } else {
                # 休息时长填了 0 -> 本轮专注结束就直接收工，不进 break
                $script:Pomo.Running = $false
                $script:Pomo.Remaining = 0
                if ($null -ne $script:PomoTimer) { $script:PomoTimer.Stop() }
                Hide-PomoMini
            }
        } else {
            $script:Pomo.Running = $false
            $script:Pomo.Remaining = 0
            if ($null -ne $script:PomoTimer) { $script:PomoTimer.Stop() }
            Show-DesktopNotification (Get-LangText 'ntf.focusDone') ((Get-LangText 'ntf.focusAdd') -f $taskText, [string]$script:Pomo.Total)
            Hide-PomoMini
        }
        $script:Selected = [datetime]::Today
        # 第十四轮（item 2）：任务队列轮换 —— 专注段**自然走完**才算"消耗"一个名额，
        # 队头任务顶上来变成下一段专注的目标（暂停/提前收工不消耗，用户可能还想继续）。
        Advance-PomoQueue
        Refresh-All
    }
}
}

function Get-FocusElapsedMin {
    # 本次专注已经走了多少分钟（= Total - Remaining，把秒折算成分钟）。
    #   为什么用"总量减剩余"而不是另立一个"已走秒数"计数器：
    #     计时器只有 Remaining 一个会变的量；再加一个计数器就要在 Tick / 暂停 /
    #     跨阶段（focus->break）三处同步，迟早漂移。用差值算永远和显示一致。
    #   取整规则：向下取整。走了 89 秒算 1 分钟（对用户有利，也不虚报）。
    #   break 阶段的"已走"不算专注时长 —— 那是在休息。
    try {
        if ([string]$script:Pomo.Mode -eq 'break') { return 0 }
        $total = [int]$script:Pomo.Total
        $rem = [int]$script:Pomo.Remaining
        $elapsedSec = $total - $rem
        if ($elapsedSec -lt 0) { $elapsedSec = 0 }
        return [int][math]::Floor($elapsedSec / 60)
    } catch { return 0 }
}

function End-FocusSession {
    # 结束本次专注并**结算归档**（第七轮 item 6）。
    #
    # 与 Complete-PomodoroPhase（自然走完）的区别：
    #   · 自然走完记录的是 Total（整段时长）；
    #   · 这里记录的是"实际走了多少"（Get-FocusElapsedMin），因为用户可能提前收工。
    # 两者的落库口径一致：都加到 Settings['FocusTodayMin']，并且如果关联了任务，
    # 同步加到该任务的 actualMin 上。
    #
    # 边界：
    #   · 完全没走（elapsed = 0）-> 不记录、不提示"已记录 0 分钟"这种没意义的文案，
    #     但仍把计时器归零（等价于 Reset），并提示"本次没有可记录的时长"。
    #   · 正在跑 -> 先停表再结算，避免结算后 Tick 又把它减下去。
    try {
        $wasRunning = [bool]$script:Pomo.Running
        $elapsed = Get-FocusElapsedMin
        $taskText = [string]$script:Pomo.Task
        if ([string]::IsNullOrWhiteSpace($taskText)) { $taskText = '' }

        # 先停表：结算与"停表"之间不能再有一次 Tick 改动 Remaining。
        $script:Pomo.Running = $false
        if ($null -ne $script:PomoTimer) { $script:PomoTimer.Stop() }

        if ($elapsed -gt 0) {
            $script:Settings['FocusTodayMin'] = [int]$script:Settings['FocusTodayMin'] + $elapsed
            # 关联任务：把本次分钟数累加到 actualMin（和自然走完那条路径同一口径）
            if (-not [string]::IsNullOrWhiteSpace([string]$script:Pomo.TaskId)) {
                $taskHit = @($script:Tasks | Where-Object { [string]$_.id -eq [string]$script:Pomo.TaskId })
                if ($taskHit.Count -gt 0) {
                    $oldActual = 0
                    if ($taskHit[0].PSObject.Properties.Name -contains 'actualMin') { $oldActual = [int]$taskHit[0].actualMin }
                    $taskHit[0].actualMin = $oldActual + $elapsed
                }
            }
            Save-Settings
            Save-Data
            try { Fill-Tasks } catch { }
            $label = $(if ([string]::IsNullOrWhiteSpace($taskText)) { Get-LangText 'pomo.session' } else { $taskText })
            $ntfBody = (Get-LangText 'ntf.focusAdd') -f $label, [string]$elapsed
            Show-DesktopNotification (Get-LangText 'ntf.focusLogged') $ntfBody
            try { Show-Toast (Get-LangText 'ntf.focusLogged') $ntfBody } catch { }
            $script:LastFocusEndMin = $elapsed
        } else {
            try { Show-Toast (Get-LangText 'ntf.focus') (Get-LangText 'ntf.noLog') } catch { }
            $script:LastFocusEndMin = 0
        }

        # 归零：回到 Ready，剩余 = 当前设置的时长（等价于 Reset 之后的状态）
        Reset-Pomodoro
        Refresh-All
    } catch { Write-ErrLog ('End-FocusSession: ' + $_.Exception.Message) }
}

function Reset-Pomodoro {
    # 0 = 用户明确选择"不计时"。老代码把 <1 一律当"没设过"回落到 25，
    # 那样 0-99 自由选择里就永远选不出 0（存下去是 0，读回来变 25）。
    # 现在只在"键缺失/非数字"这种真·没设过的情况才回落到 25。
    # 判存在用 Contains 而不是 ContainsKey：Settings 是 OrderedDictionary。
    $mins = 25
    if ($script:Settings.Contains('PomodoroMin')) {
        $raw = $script:Settings['PomodoroMin']
        $parsed = 0
        if ($null -ne $raw -and [int]::TryParse(([string]$raw).Trim(), [ref]$parsed)) { $mins = $parsed }
    }
    if ($mins -lt 0) { $mins = 0 }
    if ($mins -gt 99) { $mins = 99 }
    $script:Pomo.Total = $mins * 60
    $script:Pomo.Remaining = $mins * 60
    $script:Pomo.Running = $false
    $script:Pomo.Mode = 'focus'
    $script:Pomo.Task = [string]$script:Settings['PomodoroTask']
    $taskMatch = @($script:Tasks | Where-Object { [string]$_.text -eq [string]$script:Pomo.Task })
    if ($taskMatch.Count -gt 0) { $script:Pomo.TaskId = [string]$taskMatch[0].id } else { $script:Pomo.TaskId = '' }
    if ($null -ne $script:PomoTimer) { $script:PomoTimer.Stop() }
    Update-PomodoroVisual
    # 第十四轮：常驻开着时归零**不收窗** —— 悬浮窗切回空闲小组件（时钟+待办数）；
    # 没常驻才按老行为整个藏起来。
    $pinnedNow = $false
    if ($script:Settings.Contains('MiniPinned')) { $pinnedNow = [bool]$script:Settings['MiniPinned'] }
    if ($pinnedNow) { Update-PomoMini } else { Hide-PomoMini }
}

function Toggle-Pomodoro {
    if (-not [bool]$script:Settings['PomodoroEnabled']) {
        Open-FocusPanel
        return
    }
    if ([bool]$script:Pomo.Running) {
        $script:Pomo.Running = $false
        if ($null -ne $script:PomoTimer) { $script:PomoTimer.Stop() }
    } else {
        if ([int]$script:Pomo.Remaining -le 0) { Reset-Pomodoro }
        $script:Pomo.Running = $true
        if ($null -eq $script:PomoTimer) {
            $script:PomoTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:PomoTimer.Interval = [timespan]::FromSeconds(1)
            $script:PomoTimer.Add_Tick({
                try {
                    if (-not [bool]$script:Pomo.Running) { return }
                    $script:Pomo.Remaining = [int]$script:Pomo.Remaining - 1
                    Complete-PomodoroPhase
                    Update-PomodoroVisual
                } catch { Write-ErrLog ('PomoTick: ' + $_.Exception.Message) }
            })
        }
        $script:PomoTimer.Start()
        # 第十三轮（item 1）：开始专注就把主窗最小化到托盘，只留迷你悬浮窗在桌面，
        # 避免大界面挡住屏幕。托盘图标仍在，点它可随时唤回主窗。
        # 守卫：审计（SuppressModal）环境下不最小化，否则会破坏后面"窗口宽度缩放"
        # 类断言的窗口尺寸测量。
        try {
            if (-not $script:SuppressModal -and $null -ne $script:MainWindow) {
                if ($script:MainWindow.WindowState -eq 'Normal') { $script:MainWindow.WindowState = 'Minimized' }
            }
        } catch { }
    }
    Update-PomodoroVisual
    # 第十二轮（item 2）：开始/暂停都同步迷你悬浮窗的可见性。
    if ([bool]$script:Pomo.Running) { Show-PomoMini } else { Update-PomoMini }
}

function Advance-PomoQueue {
    # 任务队列轮换（第十四轮 item 2）。
    #   队列存的是任务 id（Settings['PomoQueue']，逗号分隔、有序）。
    #   专注段**自然走完**后调用：队头任务顶上来变成当前专注任务，原队头挪到队尾，
    #   下一段"开始"就落在下一个任务上。队列为空 = 一切照旧（单任务老行为）。
    #   只保留仍存在的 id：任务可能在中途被删，坏 id 留在队列里会让轮换卡死。
    try {
        $raw = ''
        if ($script:Settings.Contains('PomoQueue')) { $raw = [string]$script:Settings['PomoQueue'] }
        $ids = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $alive = @($script:Tasks | ForEach-Object { [string]$_.id })
        $ids = @($ids | Where-Object { $alive -contains $_ })
        if ($ids.Count -eq 0) {
            if ($raw) { $script:Settings['PomoQueue'] = ''; Save-Settings }
            return
        }
        $head = [string]$ids[0]
        $hit = @($script:Tasks | Where-Object { [string]$_.id -eq $head })
        if ($hit.Count -gt 0) {
            $script:Pomo.Task = [string]$hit[0].text
            $script:Pomo.TaskId = $head
            $script:Settings['PomodoroTask'] = [string]$hit[0].text
        }
        $rot = @()
        for ($i = 1; $i -lt $ids.Count; $i++) { $rot += $ids[$i] }
        $rot += $head
        $script:Settings['PomoQueue'] = ($rot -join ',')
        Save-Settings
    } catch { Write-ErrLog ('Advance-PomoQueue: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------
#  番茄钟迷你悬浮窗（第十二轮 item 2 创建；第十四轮大改）
#
#  为什么要有它：专注浮窗（Show-FocusWindow）是完整的设置窗，字段多、占地方；
#  用户跑番茄钟时只想看到"还剩几分钟"，并且能最小化主窗、把计时留在桌面角落。
#
#  第十四轮改了四件事：
#    ① 常驻开关（MiniPinned）：不跑番茄钟也钉在角落当桌面小组件 ——
#       空闲时显示当前时钟 + 今日待办数，跑起来自动变回倒计时。
#    ② 倒计时进度环：时间数字嵌在环心，一眼看出"这一段走了多少"。
#    ③ 主题跟随：换肤时整窗按新色板重建（Refresh-PomoMiniTheme），
#       环色每个 tick 现取 Get-Pal，换肤立刻生效不等下一轮。
#    ④ 滚轮调透明度 + 位置记忆 + 崩溃自愈（构建失败重建一次并弹系统通知）。
#
#  ⚠ 修复过的 bug（就是用户报的"点击开始后按键不跟着变"）：
#    以前对 $script:PomoMiniBtn（Button）写 .Text —— Button 没有 Text 属性
#    （文字是包在 Content 里的 TextBlock），每秒抛"找不到属性"异常，
#    被 Update-PomoMini 的静默 catch 整个吞掉：按钮永远停在构建时的"暂停"，
#    暂停后不变"继续"，任务名也刷不出来。现在改持 Content 里的 TextBlock。
# ---------------------------------------------------------------------------
function New-PomoMiniWidget {
    if ($null -ne $script:PomoMiniWin) { return }
    $w = New-Object System.Windows.Window
    $w.WindowStyle = 'None'
    $w.AllowsTransparency = $true
    $w.Background = $null
    $w.ResizeMode = 'NoResize'
    $w.SizeToContent = 'WidthAndHeight'
    $w.ShowInTaskbar = $false
    $w.Topmost = $true
    $w.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
    # 透明度记忆（第十四轮 ④）：滚轮调节，重启保持。夹在 [0.35, 1]。
    $op = 1.0
    if ($script:Settings.Contains('MiniOpacity')) {
        $opTry = 0.0
        if ([double]::TryParse(([string]$script:Settings['MiniOpacity']).Trim(), [ref]$opTry)) { $op = $opTry }
    }
    if ($op -lt 0.35) { $op = 0.35 }
    if ($op -gt 1.0) { $op = 1.0 }
    $w.Opacity = $op
    $script:PomoMiniWin = $w

    $root = New-Bd -Bg (Get-Pal 'Card') -Border (Get-Pal 'Border') -Radius 12
    $root.Padding = [System.Windows.Thickness]::new(16, 12, 16, 12)
    # 滚轮调透明度就发生在"滚轮悬在窗上"这个动作里，提示写进 ToolTip。
    $root.ToolTip = (Get-LangText 'tip.miniWheel')
    $sp = New-Object System.Windows.Controls.StackPanel

    # ---- 进度环 + 居中倒计时（第十四轮 ②）----
    $ringSize = 118.0
    $script:PomoMiniRingSize = $ringSize
    $ringHost = New-Object System.Windows.Controls.Grid
    $ringHost.Width = $ringSize
    $ringHost.Height = $ringSize
    $ringHost.HorizontalAlignment = 'Center'
    $track = New-Object System.Windows.Shapes.Path
    # 轨道色用 BorderSoft：CardAlt 和卡片底色太接近，环会"看不见"（第十四轮截图实测）
    $track.Stroke = Brush (Get-Pal 'BorderSoft')
    $track.StrokeThickness = 7
    $track.StrokeStartLineCap = 'Round'
    $track.StrokeEndLineCap = 'Round'
    $trackR = ($ringSize / 2.0) - (7.0 / 2.0) - 3.0
    $track.Data = [System.Windows.Media.EllipseGeometry]::new(
        [System.Windows.Point]::new($ringSize / 2.0, $ringSize / 2.0), $trackR, $trackR)
    [void]$ringHost.Children.Add($track)
    $script:PomoMiniArc = New-Object System.Windows.Shapes.Path
    $script:PomoMiniArc.Stroke = Brush (Get-Pal 'AccentFocus')
    $script:PomoMiniArc.StrokeThickness = 7
    $script:PomoMiniArc.StrokeStartLineCap = 'Round'
    $script:PomoMiniArc.StrokeEndLineCap = 'Round'
    [void]$ringHost.Children.Add($script:PomoMiniArc)
    $script:PomoMiniTime = New-Txt -Text '25:00' -Size 26 -Color (Get-Pal 'Ink') -Weight 'Bold'
    $script:PomoMiniTime.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $script:PomoMiniTime.HorizontalAlignment = 'Center'
    $script:PomoMiniTime.VerticalAlignment = 'Center'
    [void]$ringHost.Children.Add($script:PomoMiniTime)
    [void]$sp.Children.Add($ringHost)

    $script:PomoMiniStatus = New-Txt -Text (Get-LangText 'pomo.focusing') -Size 11 -Color (Get-Pal 'AccentEvent') -Weight 'Semi'
    $script:PomoMiniStatus.HorizontalAlignment = 'Center'
    $script:PomoMiniStatus.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    [void]$sp.Children.Add($script:PomoMiniStatus)

    $script:PomoMiniTask = New-Txt -Text '' -Size 10 -Color (Get-Pal 'InkSoft')
    $script:PomoMiniTask.HorizontalAlignment = 'Center'
    $script:PomoMiniTask.MaxWidth = 210
    $script:PomoMiniTask.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    [void]$sp.Children.Add($script:PomoMiniTask)

    # 按钮行：暂停/继续 + 结束并统计 + 退出（第十三轮三键制）。
    # 常驻空闲态时"结束并统计"没有意义（没在计时），Update-PomoMini 会把它藏起来。
    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'
    $btnRow.HorizontalAlignment = 'Center'
    $btnRow.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    $script:PomoMiniBtn = New-PixBtn -Text (Get-LangText 'pomo.pause') -Bg (Get-Pal 'AccentFocus') -Fg (Get-Pal 'TodayInk') -W 62 -H 26 -FontSize 10
    # 修复"按钮文字不跟状态走"：持 Content 里的 TextBlock（Button 本身没有 .Text）。
    $script:PomoMiniBtnText = $script:PomoMiniBtn.Content
    $script:PomoMiniBtn.Add_Click({ param($s,$e) try { Toggle-Pomodoro; $e.Handled = $true } catch { Write-ErrLog ('PomoMini toggle: ' + $_.Exception.Message) } })
    [void]$btnRow.Children.Add($script:PomoMiniBtn)
    $script:PomoMiniEndBtn = New-PixBtn -Text (Get-LangText 'pomo.endStat') -Bg (Get-Pal 'AccentEvent') -Fg (Get-Pal 'OnAccent') -W 74 -H 26 -FontSize 10
    $script:PomoMiniEndBtn.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
    $script:PomoMiniEndBtn.ToolTip = (Get-LangText 'pomo.endStat')
    $script:PomoMiniEndBtn.Add_Click({ param($s,$e) try { End-FocusSession; $e.Handled = $true } catch { Write-ErrLog ('PomoMini end: ' + $_.Exception.Message) } })
    [void]$btnRow.Children.Add($script:PomoMiniEndBtn)
    $exitBtn = New-PixBtn -Text (Get-LangText 'pomo.exit') -Bg (Get-Pal 'CardAlt') -Fg (Get-Pal 'Ink') -W 46 -H 26 -FontSize 10
    $exitBtn.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
    $exitBtn.ToolTip = (Get-LangText 'pomo.exit')
    # 退出按钮的语义跟状态走（第十四轮 ①）：
    #   在计时/暂停中 -> 结束本次（Reset）并收窗；常驻空闲态 -> 取消常驻并收窗。
    $exitBtn.Add_Click({
        param($s,$e)
        try {
            $pinned = $false
            if ($script:Settings.Contains('MiniPinned')) { $pinned = [bool]$script:Settings['MiniPinned'] }
            $idle = ((-not [bool]$script:Pomo.Running) -and ([int]$script:Pomo.Remaining -ge [int]$script:Pomo.Total))
            if ($pinned -and $idle) {
                $script:Settings['MiniPinned'] = $false
                Save-Settings
            } else {
                Reset-Pomodoro
            }
            Hide-PomoMini
            $e.Handled = $true
        } catch { Write-ErrLog ('PomoMini exit: ' + $_.Exception.Message) }
    })
    [void]$btnRow.Children.Add($exitBtn)
    [void]$sp.Children.Add($btnRow)

    $root.Child = $sp
    $w.Content = $root
    # 拖动：整块都能拖（点在按钮上时不拖）；松手即记位置（第十四轮 ④ 位置记忆，
    # 常驻小组件重启后回原位，换肤重建也不跳回右下角）。
    $root.Add_MouseLeftButtonDown({
        param($s, $e)
        if (Test-ClickOnButton $e) { return }
        try {
            $script:PomoMiniWin.DragMove()
            Save-MiniPos
        } catch { }
    })
    # 滚轮调透明度（第十四轮 ④）：只改内存里的设置值，落盘交给 Hide/退出等节点，
    # 避免一秒几十次的滚轮事件各写一次 settings.json。
    $root.Add_MouseWheel({
        param($s, $e)
        try {
            $cur = [double]$script:PomoMiniWin.Opacity
            if ($e.Delta -gt 0) { $cur = $cur + 0.05 } else { $cur = $cur - 0.05 }
            if ($cur -lt 0.35) { $cur = 0.35 }
            if ($cur -gt 1.0) { $cur = 1.0 }
            $script:PomoMiniWin.Opacity = $cur
            $script:Settings['MiniOpacity'] = $cur
            $e.Handled = $true
        } catch { Write-ErrLog ('PomoMini wheel: ' + $_.Exception.Message) }
    })
}

function Save-MiniPos {
    # 记悬浮窗位置（第十四轮 ④）。读 Left/Top 在窗口最小化/关闭时可能抛，包住。
    if ($null -eq $script:PomoMiniWin) { return }
    try {
        $script:Settings['MiniLeft'] = [double]$script:PomoMiniWin.Left
        $script:Settings['MiniTop'] = [double]$script:PomoMiniWin.Top
        Save-Settings
    } catch { }
}

function Show-PomoMini {
    try { New-PomoMiniWidget } catch {
        # 崩溃兜底（第十四轮 ④）：构建失败就清掉半成品对象让下轮重试，
        # 并用系统通知告诉用户一声（只通知一次，别轰炸）。
        $script:PomoMiniWin = $null
        Write-ErrLog ('PomoMini build: ' + $_.Exception.Message)
        if (-not $script:PomoMiniFailNotified) {
            $script:PomoMiniFailNotified = $true
            try { Show-DesktopNotification (Get-LangText 'ntf.miniFail') '' } catch { }
        }
        return
    }
    if ($null -eq $script:PomoMiniWin) { return }
    try {
        if (-not $script:PomoMiniWin.IsVisible) { $script:PomoMiniWin.Show() }
        $script:PomoMiniWin.UpdateLayout()
        # 位置：优先用上次记住的（且还在屏幕工作区内），没有才贴右下角。
        $wa = [System.Windows.SystemParameters]::WorkArea
        $stL = -1.0; $stT = -1.0
        if ($script:Settings.Contains('MiniLeft')) { $stL = [double]$script:Settings['MiniLeft'] }
        if ($script:Settings.Contains('MiniTop'))  { $stT = [double]$script:Settings['MiniTop'] }
        if (($stL -gt -1000) -and ($stT -gt -1000) -and
            ($stL -lt $wa.Right - 40) -and ($stT -lt $wa.Bottom - 40)) {
            $script:PomoMiniWin.Left = $stL
            $script:PomoMiniWin.Top = $stT
        } else {
            $script:PomoMiniWin.Left = [double]$wa.Right - [double]$script:PomoMiniWin.ActualWidth - 20.0
            $script:PomoMiniWin.Top  = [double]$wa.Bottom - [double]$script:PomoMiniWin.ActualHeight - 20.0
        }
    } catch { }
    Update-PomoMini
}

function Hide-PomoMini {
    if ($null -eq $script:PomoMiniWin) { return }
    try {
        Save-MiniPos
        $script:PomoMiniWin.Hide()
    } catch { }
}

function Refresh-PomoMiniTheme {
    # 主题跟随（第十四轮 ③）：换肤后整窗按新色板重建。
    # 颜色都是构建时烘进控件的，逐元素回放容易漏（主窗当年就是因此走整树重建）；
    # 悬浮窗又小，重建成本可以忽略。没显示也没常驻就直接跳过。
    $wasVisible = ($null -ne $script:PomoMiniWin -and $script:PomoMiniWin.IsVisible)
    $pinned = $false
    if ($script:Settings.Contains('MiniPinned')) { $pinned = [bool]$script:Settings['MiniPinned'] }
    if (-not $wasVisible -and -not $pinned) { return }
    if ($null -ne $script:PomoMiniWin) { try { $script:PomoMiniWin.Hide() } catch { } }
    $script:PomoMiniWin = $null
    Show-PomoMini
}

function Toggle-MiniPinned {
    # 常驻开关（第十四轮 ①）：主菜单「…」里切换。开着 = 不跑番茄钟也钉在角落，
    # 空闲时显示时钟 + 待办数；跑起来自动变回倒计时。
    if ($script:Settings.Contains('MiniPinned') -and [bool]$script:Settings['MiniPinned']) {
        $script:Settings['MiniPinned'] = $false
        Save-Settings
        Hide-PomoMini
    } else {
        $script:Settings['MiniPinned'] = $true
        Save-Settings
        Show-PomoMini
    }
}

function Update-PomoMini {
    # 崩溃自愈（第十四轮 ④）：窗口对象被兜底清空了但番茄钟还在跑 -> 尝试重建。
    if ($null -eq $script:PomoMiniWin) {
        if ([bool]$script:Pomo.Running -and -not $script:SuppressModal) { Show-PomoMini }
        return
    }
    if (-not $script:PomoMiniWin.IsVisible) { return }
    try {
        $rem = [int]$script:Pomo.Remaining
        if ($rem -lt 0) { $rem = 0 }
        $total = [int]$script:Pomo.Total
        if ($total -le 0) { $total = 1 }
        # 空闲 = 没在跑且没走过（Ready）。常驻时空闲态就是"桌面小组件"。
        $pinned = $false
        if ($script:Settings.Contains('MiniPinned')) { $pinned = [bool]$script:Settings['MiniPinned'] }
        $idle = ((-not [bool]$script:Pomo.Running) -and ($rem -ge $total))
        if ($idle -and $pinned) {
            # ---- 常驻空闲模式（第十四轮 ①）：时钟 + 待办数 + 日期 ----
            $now = [datetime]::Now
            $script:PomoMiniTime.Text = ('{0:00}:{1:00}' -f $now.Hour, $now.Minute)
            $openN = @($script:Tasks | Where-Object { -not [bool](Get-TaskField $_ 'done' $false) }).Count
            $script:PomoMiniStatus.Text = ((Get-LangText 'hud.tasks') -f [string]$openN)
            $script:PomoMiniTask.Text = ('{0} {1}-{2:00}-{3:00}' -f `
                $script:DowShort[([int]$now.DayOfWeek + 6) % 7], $now.Year, $now.Month, $now.Day)
            $script:PomoMiniBtnText.Text = Get-LangText 'btn.start'
            if ($null -ne $script:PomoMiniEndBtn) { $script:PomoMiniEndBtn.Visibility = 'Collapsed' }
            if ($null -ne $script:PomoMiniArc) {
                # 空闲态环上那个"接近 0 的弧"看着像个 bug（实测截图里是个小橙点），
                # 直接把弧藏起来，只留一圈轨道。
                $script:PomoMiniArc.Opacity = 0
                Set-RingArc -Path $script:PomoMiniArc -Size ([double]$script:PomoMiniRingSize) -Frac 0.0
            }
        } else {
            $mode = [string]$script:Pomo.Mode
            if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'focus' }
            # ⚠ 倒计时赋值在 else 分支里：空闲分支写的是时钟，两态各写各的，
            #   不写这行的话从空闲切回计时时数字会停在时钟上（首轮截图抓到过）。
            $script:PomoMiniTime.Text = ('{0:00}:{1:00}' -f [math]::Floor($rem / 60), ($rem % 60))
            if ([bool]$script:Pomo.Running) {
                $script:PomoMiniStatus.Text = $(if ($mode -eq 'break') { Get-LangText 'pomo.break' } else { Get-LangText 'pomo.focusing' })
                $script:PomoMiniBtnText.Text = Get-LangText 'pomo.pause'
            } else {
                $script:PomoMiniStatus.Text = Get-LangText 'pomo.paused'
                $script:PomoMiniBtnText.Text = Get-LangText 'pomo.resume'
            }
            if ($null -ne $script:PomoMiniEndBtn) { $script:PomoMiniEndBtn.Visibility = 'Visible' }
            $task = [string]$script:Pomo.Task
            if ([string]::IsNullOrWhiteSpace($task)) { $task = Get-LangText 'pomo.noTask' }
            $script:PomoMiniTask.Text = $task
            if ($null -ne $script:PomoMiniArc) {
                $frac = 1.0 - ($rem / [double]$total)
                # 休息阶段换绿色环，跟"专注中"一眼区分开；空闲态藏掉的弧在这里恢复
                if ($mode -eq 'break') { $script:PomoMiniArc.Stroke = Brush (Get-Pal 'AccentTask') }
                else { $script:PomoMiniArc.Stroke = Brush (Get-Pal 'AccentFocus') }
                $script:PomoMiniArc.Opacity = 1
                Set-RingArc -Path $script:PomoMiniArc -Size ([double]$script:PomoMiniRingSize) -Frac $frac
            }
        }
    } catch {
        # 第十四轮兜底：以前这里是静默 catch，"对 Button 写 .Text"这类属性异常
        # 每秒抛一次没人知道。现在至少进 errors.log，构建期的自愈在 Show 里做。
        Write-ErrLog ('PomoMini update: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
#  F. 托盘图标
# ---------------------------------------------------------------------------
function New-AppIcon {
    # 托盘图标（第十四轮）：从内嵌默认头像生成 32x32 Icon。
    # 之前用 SystemIcons.Application（灰色通用图标）辨识度差，换成小女孩。
    try {
        $bytes = [System.Convert]::FromBase64String($script:DefaultAvatarB64)
        $ms = New-Object System.IO.MemoryStream -ArgumentList (, $bytes)
        $src = New-Object System.Drawing.Bitmap($ms)
        $bmp = New-Object System.Drawing.Bitmap($src, 32, 32)
        # 保活：HICON 依赖 bitmap，别让 GC 提前回收导致托盘图标变白。
        $script:AppIconBitmap = $bmp
        $script:AppIcon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        $src.Dispose()
        $ms.Dispose()
        return $script:AppIcon
    } catch {
        Write-ErrLog ('New-AppIcon: ' + $_.Exception.Message)
        return $null
    }
}

function New-TrayIcon {
    $ni = New-Object System.Windows.Forms.NotifyIcon
    try {
        $ni.Icon = New-AppIcon
        if ($null -eq $ni.Icon) { $ni.Icon = [System.Drawing.SystemIcons]::Application }
    } catch {
        $ni.Icon = [System.Drawing.SystemIcons]::Application
    }
    $ni.Text = (Get-LangText 'tray.name')
    $ni.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miShow = $menu.Items.Add('显示 / Show')
    $miHide = $menu.Items.Add('隐藏到托盘 / Hide')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miMonth = $menu.Items.Add('月视图 / Month')
    $miWeek = $menu.Items.Add('周视图 / Week')
    $miList = $menu.Items.Add('列表视图 / List')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miExit = $menu.Items.Add('退出 / Exit')

    $miShow.Add_Click({ $script:MainWindow.Show(); $script:MainWindow.WindowState = 'Normal'; $script:MainWindow.Activate() })
    $miHide.Add_Click({ $script:MainWindow.Hide() })
    $miMonth.Add_Click({ Show-FromTray; Set-View 'month' })
    $miWeek.Add_Click({ Show-FromTray; Set-View 'week' })
    $miList.Add_Click({ Show-FromTray; Set-View 'list' })
    $miExit.Add_Click({ $script:AllowClose = $true; $script:MainWindow.Close() })

    $ni.ContextMenuStrip = $menu
    $ni.Add_MouseDoubleClick({ Show-FromTray })
    $ni.Add_MouseClick({
        param($s, $e)
        try {
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-FromTray }
        } catch { }
    })
    return $ni
}

function Show-FromTray {
    $script:MainWindow.Show()
    $script:MainWindow.WindowState = 'Normal'
    $script:MainWindow.Activate()
    $script:MainWindow.Topmost = $script:TopmostOn
}

# ---------------------------------------------------------------------------
#  G. 关闭确认
# ---------------------------------------------------------------------------
function Confirm-Close {
    if ($script:AllowClose -or $TestMode) { return $true }
    $r = [System.Windows.MessageBox]::Show(
        '关闭窗口还是最小化到托盘？' + [Environment]::NewLine + [Environment]::NewLine +
        '是(Y) = 最小化到托盘（推荐）' + [Environment]::NewLine + '否(N) = 直接退出',
        'Schedule',
        [System.Windows.MessageBoxButton]::YesNoCancel,
        [System.Windows.MessageBoxImage]::Question)
    if ($r -eq [System.Windows.MessageBoxResult]::Yes) {
        $script:MainWindow.Hide()
        return $false
    } elseif ($r -eq [System.Windows.MessageBoxResult]::No) {
        $script:AllowClose = $true
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
#  H. 构建窗口（把 XAML 变成活界面 + 接好所有事件）
# ---------------------------------------------------------------------------
# 在资源管理器里打开本用户的数据目录。
# 多用户场景下这是必要的：数据按 Windows 账户隔离，用户得能找到属于自己的那份。
function Open-DataFolder {
    try {
        if (-not (Test-Path -LiteralPath $script:DataDir)) {
            New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
        }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:DataDir + '"')
    } catch { Write-ErrLog ('Open-DataFolder: ' + $_.Exception.Message) }
}

function Show-DesktopNotification {
    param([string]$Title, [string]$Text)
    try {
        $script:LastNotification = $Title + ': ' + $Text
        if ($TestMode) { return }
        if ($null -ne $script:TrayIcon -and -not $TestMode) {
            $script:TrayIcon.BalloonTipTitle = $Title
            $script:TrayIcon.BalloonTipText = $Text
            $script:TrayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            $script:TrayIcon.ShowBalloonTip(8000)
        } else {
            Show-Toast -Title $Title -Text $Text
        }
    } catch { Write-ErrLog ('Notification: ' + $_.Exception.Message) }
}

function Check-Reminders {
    try {
        $now = [datetime]::Now
        foreach ($day in @([datetime]::Today, [datetime]::Today.AddDays(1))) {
            foreach ($ev in @(Events-On $day)) {
                $rm = 0
                if ($ev.PSObject.Properties.Name -contains 'reminderMin') { $rm = [int]$ev.reminderMin }
                if ($rm -le 0) { continue }
                $startAt = (Parse-Date ([string]$ev.date)).AddMinutes([int]$ev.start)
                $notifyAt = $startAt.AddMinutes(-$rm)
                if ($now -ge $notifyAt -and $now -lt $notifyAt.AddMinutes(1)) {
                    $key = 'event:' + [string]$ev.id + ':' + [string]$ev.date
                    if (-not $script:NotifiedKeys.ContainsKey($key)) {
                        $script:NotifiedKeys[$key] = $true
                        Show-DesktopNotification ((Get-LangText 'ntf.inMin') -f [string]$rm) ([string]$ev.title + ' · ' + (Min-To-HHMM ([int]$ev.start)))
                    }
                }
            }
        }
        foreach ($t in @($script:Tasks)) {
            if ([bool]$t.done -or [string]::IsNullOrWhiteSpace([string]$t.due)) { continue }
            $rm = 0
            if ($t.PSObject.Properties.Name -contains 'reminderMin') { $rm = [int]$t.reminderMin }
            if ($rm -lt 0) { continue }
            $dueTime = '09:00'
            if ($t.PSObject.Properties.Name -contains 'dueTime' -and -not [string]::IsNullOrWhiteSpace([string]$t.dueTime)) { $dueTime = [string]$t.dueTime }
            $dueMin = Parse-HHMM $dueTime
            if ($dueMin -lt 0) { $dueMin = 540 }
            $dueAt = (Parse-Date ([string]$t.due)).AddMinutes($dueMin)
            $notifyAt = $dueAt.AddMinutes(-$rm)
            $window = 1
            if ($rm -eq 0) { $window = 2 }
            if ($now -ge $notifyAt -and $now -lt $notifyAt.AddMinutes($window)) {
                $key = 'task:' + [string]$t.id + ':' + (Fmt-Date $dueAt)
                if (-not $script:NotifiedKeys.ContainsKey($key)) {
                    $script:NotifiedKeys[$key] = $true
                    $when = $(if ($rm -gt 0) { (Get-LangText 'ntf.dueIn') -f [string]$rm } else { Get-LangText 'ntf.taskDue' })
                    Show-DesktopNotification $when ([string]$t.text)
                }
            }
        }
    } catch { Write-ErrLog ('Check-Reminders: ' + $_.Exception.Message) }
}

function Start-ReminderTimer {
    if ($null -ne $script:ReminderTimer) { return }
    $script:ReminderTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ReminderTimer.Interval = [timespan]::FromSeconds(30)
    $script:ReminderTimer.Add_Tick({
        try { Check-Reminders } catch { Write-ErrLog ('Reminder tick: ' + $_.Exception.Message) }
        # 第十四轮：常驻空闲模式的悬浮窗靠这个 30s 节拍刷时钟/待办数。
        # 番茄钟在跑时有自己的 1s PomoTimer；这里只补"没在跑也常驻"的空档。
        # Update-PomoMini 开头就会对"窗口没显示"直接 return，空转成本可以忽略。
        try { Update-PomoMini } catch { }
    })
    $script:ReminderTimer.Start()
}

function Set-NavCollapsed {
    param([bool]$Collapsed)
    if ($null -eq $script:NavCol -or $null -eq $script:NavPanel) { return }
    if ($Collapsed) {
        $script:NavCol.Width = [System.Windows.GridLength]::new(0, 'Pixel')
        $script:NavPanel.Visibility = 'Collapsed'
    } else {
        # 宽度取"字号缩放值 × 窗口自适应因子"算好的结果（Apply-ResponsiveLayout 维护）。
        # 优先级：NavColWidthResponsive（含窗口宽度因子）> NavColWidthScaled（只含字号）> 142。
        # 以前写死 142，字号放大之后导航文字会被这个固定宽度挤成两行；
        # 第七轮又加了"窗口越宽侧栏越宽"这一层，所以这里要读最新的那个值。
        $w = 142.0
        try {
            if ($null -ne $script:NavColWidthResponsive) { $w = [double]$script:NavColWidthResponsive }
            elseif ($null -ne $script:NavColWidthScaled) { $w = [double]$script:NavColWidthScaled }
        } catch { }
        $script:NavCol.Width = [System.Windows.GridLength]::new($w, 'Pixel')
        $script:NavPanel.Visibility = 'Visible'
    }
}

function Collect-XamlFontNodes {
    # 采集 Ui.ps1 内嵌 XAML 里所有带硬编码 FontSize 的元素，把"设计字号"记下来。
    #
    # 为什么需要这一步：那些 FontSize 是 XAML 解析时就烘进对象里的字面量，
    # New-Txt 工厂管不到它们（它们根本不是 New-Txt 造出来的）。要让字号倍率对
    # 标题栏 / HeroDate / CalPeriod / 侧栏导航文字也生效，只能事后遍历一遍。
    #
    # 为什么现在采、而不是每次 Apply-UiScale 都采：
    #   采到的"基础值"必须永远是设计值。如果每次都重新采，第二次采到的就已经是
    #   被乘过的值，再乘一遍 -> 0.85 → 0.72 → 0.61 指数塌陷。
    #   所以只在 Build-Window 里采一次，之后 Apply-UiScale 一律按这份基线赋值。
    param($Root)
    $script:XamlFontNodes = New-Object System.Collections.ArrayList
    if ($null -eq $Root) { return }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    $guard = 0
    while ($stack.Count -gt 0 -and $guard -lt 60000) {
        $guard++
        $n = $stack.Pop()
        if ($null -eq $n) { continue }
        $tb = $n -as [System.Windows.Controls.TextBlock]
        if ($null -ne $tb) {
            # 只采 XAML 里显式写了 FontSize 的（继承来的默认值不该被我们改写）。
            # TextBlock 的 FontSize 没有"是否本地赋值"的公开 API，用 LocalValue
            # 与 DependencyProperty 比对来判断：显式写了才会有 LocalValue。
            try {
                $lv = $tb.ReadLocalValue([System.Windows.Controls.TextBlock]::FontSizeProperty)
                if ($null -ne $lv -and $lv -isnot [System.Windows.DependencyProperty]) {
                    $base = [double]$tb.FontSize
                    if ($base -gt 0.0) {
                        [void]$script:XamlFontNodes.Add(@{ node = $tb; base = $base })
                    }
                }
            } catch { }
        }
        $kids = @()
        if ($n -is [System.Windows.Controls.Panel]) { $kids = $n.Children }
        elseif ($n -is [System.Windows.Controls.Decorator]) { $kids = @($n.Child) }
        elseif ($n -is [System.Windows.Controls.ContentControl]) { $kids = @($n.Content) }
        foreach ($k in $kids) { $stack.Push($k) }
    }
    Write-Trace ('xaml font nodes = ' + @($script:XamlFontNodes).Count)
}

function Set-NavLabel {
    # 把某个导航按钮里的文字改掉。
    # 为什么"按按钮 Name 找 TextBlock"而不是给每个 TextBlock 起 x:Name：
    #   起了新 Name 就要在 Build-Window 的 $n[] 里接走（项目有静态规则查这个），
    #   为了改 7 个文字而新增 7 个 x:Name + 7 行赋值，不划算。
    #   导航按钮的结构是固定的（图标 + 一行文字），取其中唯一的 TextBlock 即可。
    #
    # 为什么不复用 Find-AllOfType：
    #   它定义在 ScheduleWidget.ps1 第 1170 行，而 Build-Window 在 1126 行就被调用 ——
    #   本项目的分片是"整段按顺序执行"的，调用点在前、定义在后会直接抛
    #   CommandNotFoundException。所以这里用一个自带的极小遍历，不跨文件依赖。
    #   （教训：Build-Window 路径上只能用"定义在它之前"的函数。）
    param($Btn, [string]$Text)
    if ($null -eq $Btn -or [string]::IsNullOrWhiteSpace($Text)) { return }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Btn)
    $guard = 0
    while ($stack.Count -gt 0 -and $guard -lt 200) {
        $guard++
        $n = $stack.Pop()
        if ($null -eq $n) { continue }
        $tb = $n -as [System.Windows.Controls.TextBlock]
        if ($null -ne $tb) {
            # 图标是 Path 不是 TextBlock，所以这里找到的就是那行文字。
            $tb.Text = $Text
            return
        }
        $kids = @()
        if ($n -is [System.Windows.Controls.Panel]) { $kids = $n.Children }
        elseif ($n -is [System.Windows.Controls.Decorator]) { $kids = @($n.Child) }
        elseif ($n -is [System.Windows.Controls.ContentControl]) { $kids = @($n.Content) }
        foreach ($k in $kids) { $stack.Push($k) }
    }
}

function Apply-Lang {
    # 把当前语言刷到界面上"XAML 里写死的那批固定文案"上。
    # 与 Apply-UiScale 同族：都是"代码 new 出来的控件管不到的那部分"。
    #
    # 覆盖范围（有意只做框架词，不做全量 i18n）：
    #   侧栏 7 个导航文字 / 视图标题栏 / Hero 标题 / DAILY NOTE
    # 不覆盖：各弹窗里的字段名、提示、Tooltip —— 那些是英文且量大，
    #   全量抽调属于另一个量级的工作，硬塞进这一轮只会做出一半。
    if ($null -eq $script:MainWindow) { return }
    Set-NavLabel $script:NavMonth    (Get-LangText 'nav.month')
    Set-NavLabel $script:NavWeek     (Get-LangText 'nav.week')
    Set-NavLabel $script:NavList     (Get-LangText 'nav.list')
    Set-NavLabel $script:NavTask     (Get-LangText 'nav.tasks')
    Set-NavLabel $script:NavFocus    (Get-LangText 'nav.focus')
    Set-NavLabel $script:NavSettings (Get-LangText 'nav.settings')
    Set-NavLabel $script:NavProfile  (Get-LangText 'nav.profile')
    # 第十二轮（item 3）：侧栏底部"每日一句"改成 作者 + 最新更新时间。
    if ($null -ne $script:AuthorLabel) { $script:AuthorLabel.Text = (Get-LangText 'about.author') }
    if ($null -ne $script:UpdateLabel) { $script:UpdateLabel.Text = ((Get-LangText 'about.updated') -f $script:AppUpdated) }
    # 第十一轮：侧栏「+ New event」按钮、头像「Change」文字与头像 ToolTip
    #   也是 XAML 里写死的英文，一并收口。
    if ($null -ne $script:BtnAdd)      { Set-NavLabel $script:BtnAdd (Get-LangText 'nav.newEvent') }
    if ($null -ne $script:AvatarHint)  { $script:AvatarHint.Text = (Get-LangText 'av.change') }
    if ($null -ne $script:AvatarBox)   { $script:AvatarBox.ToolTip = (Get-LangText 'av.tip') }
    # 标题栏 / Hero 标题在 Update-Chrome 里按语言表刷新（那里本来就在做这件事）
    try { Update-Chrome } catch { }
}

function Apply-UiScale {
    # 把当前倍率正式落到界面上。三件事：
    #   ① 重算 $script:UiScale（User × Auto）
    #   ② XAML 那批硬编码字号按基线 × 倍率重设
    #   ③ 侧栏宽度这类"跟字号一起长"的固定像素量同步调整
    #
    # 注意：代码 new 出来的控件（New-Txt / New-PixBtn）**不需要**在这里处理 ——
    # 它们的字号在创建时就已经按当时的倍率算好了。改了倍率要重建才会生效，
    # 所以改设置的入口那边走的是 Refresh-All / Build-Window 重建路径。
    param()
    [void](Update-UiScale)
    $s = [double]$script:UiScale
    foreach ($e in @($script:XamlFontNodes)) {
        try {
            $node = $e['node']
            if ($null -eq $node) { continue }
            $v = [double]$e['base'] * $s
            $node.FontSize = [math]::Round($v * 2.0) / 2.0
        } catch { }
    }
    # 侧栏宽度：导航文字放大后 142px 会挤，跟着倍率一起放。
    # 夹在 [120, 210]：太窄文字换行，太宽把内容区吃掉。
    if ($null -ne $script:NavCol) {
        $w = [math]::Round(142.0 * $s)
        if ($w -lt 120.0) { $w = 120.0 }
        if ($w -gt 210.0) { $w = 210.0 }
        $script:NavColWidthScaled = $w
        try { Set-NavCollapsed ([bool]$script:NavUserCollapsed) } catch { }
    }
}

function Apply-ResponsiveLayout {
    if ($null -eq $script:MainWindow -or $null -eq $script:NavCol) { return }
    $width = [double]$script:MainWindow.ActualWidth
    if ($width -le 1.0) { $width = [double]$script:MainWindow.Width }
    # 侧栏折叠只由用户决定（... 菜单里的 Hide / Show sidebar）。
    # 曾经在窗口 < 980px 时自动折叠，问题是：用户缩小窗口只是想看看别的东西，
    # 侧栏却自己没了，再放大也不会自己回来（NavUserCollapsed 被写成了"用户选的"）。
    Set-NavCollapsed ([bool]$script:NavUserCollapsed)

    # --- 第七轮（item 7）：侧栏宽度也要"跟着窗口大小走" ---
    #   用户报"左侧栏大小不会跟着界面大小自适应"。
    #   根因：侧栏宽度只在 Apply-UiScale 里按**字号倍率**算过一次
    #   （142 × UiScale），而 UiScale 只跟"用户选的档位"和"窗口宽/窄三档"有关；
    #   同在三档之内时窗口从 900 拉到 1500，侧栏一动不动。
    #   修法：在字号倍率之外，再叠一个**仅作用于内容区宽度**的自适应因子，
    #   让 142px 这个"设计宽度"在宽窗口下适当变宽、窄窗口下适当收窄。
    #   夹在 [118, 196]：比原来 [120,210] 略紧，避免宽窗口下侧栏吃掉太多内容区。
    #   注意只改宽度、不改字号 —— 字号已经由 Apply-UiScale 管了，
    #   这里再动字号会让"用户选的档位"看起来没生效。
    if ($null -ne $script:NavCol) {
        $navBase = 142.0
        if ($null -ne $script:NavColWidthScaled) { $navBase = [double]$script:NavColWidthScaled }
        $navFactor = 1.0
        if ($width -lt 900.0) { $navFactor = 0.92 }
        elseif ($width -ge 1280.0) { $navFactor = 1.10 }
        elseif ($width -ge 1100.0) { $navFactor = 1.05 }
        $navW = [math]::Round($navBase * $navFactor)
        if ($navW -lt 118.0) { $navW = 118.0 }
        if ($navW -gt 196.0) { $navW = 196.0 }
        $script:NavColWidthResponsive = $navW
        try { Set-NavCollapsed ([bool]$script:NavUserCollapsed) } catch { }
    }

    # --- 字号自适应（第四轮）：按窗口宽度给一个 0.9 / 1.0 / 1.08 的自适应因子 ---
    # 为什么宽窗口要"更大"而不只是"不变"：宽窗口下内容区很空，同样的字号看着更小；
    # 稍微放大能保持视觉密度一致。窄窗口则缩一点，给内容腾地方（否则按钮会互相挤）。
    # 开关关掉时固定为 1.0，让"我就想字号永远不变"的用户得到完全稳定的结果。
    if ([bool]$script:Settings['UiAdaptive']) {
        if ($width -lt 900.0) { $script:UiScaleAuto = 0.90 }
        elseif ($width -ge 1280.0) { $script:UiScaleAuto = 1.08 }
        else { $script:UiScaleAuto = 1.00 }
    } else {
        $script:UiScaleAuto = 1.00
    }
    $scaleChanged = ([math]::Abs([double]$script:UiScale -
        ([double]$script:UiScaleUser * [double]$script:UiScaleAuto)) -gt 0.0001)
    if ($scaleChanged) { Apply-UiScale }

    # HeroTitle 以前是硬编码 24/28 的特例，现在并进倍率体系：
    # 它的设计字号是 28，窄窗口靠自适应因子（0.90）自然缩到 25。
    # 保留一条更狠的"极窄"分支：< 760px 时额外降到 0.85，否则标题会换行。
    if ($null -ne $script:HeroTitle) {
        $heroDesign = 28.0
        $heroFactor = [double]$script:UiScale
        if ($width -lt 760.0) { $heroFactor = $heroFactor * 0.85 }
        $script:HeroTitle.FontSize = [math]::Round($heroDesign * $heroFactor * 2.0) / 2.0
    }
    # 下面两条按宽度隐藏次要文字：这是"空间不够就别硬塞"，不是字号问题，保留原逻辑。
    if ($null -ne $script:HeroStats) {
        if ($width -lt 820.0) { $script:HeroStats.Visibility = 'Collapsed' }
        else { $script:HeroStats.Visibility = 'Visible' }
    }
    if ($null -ne $script:CalNote) {
        if ($width -lt 900.0) { $script:CalNote.Visibility = 'Collapsed' }
        else { $script:CalNote.Visibility = 'Visible' }
    }
    # --- 高度方向也要"自动匹配"，不只是宽度 ---
    # 周视图以前只有宽度自适应：窗口拉高、时间轴还是常数 40px/小时，底部留一大片空白。
    # Reflow-WeekHeight 会按可视高度重算 HourHeight（下限＝原设计密度，见 Views.ps1），
    # 非周视图或还没布局时它自己返回 $false，这里不用再判。
    try { [void](Reflow-WeekHeight) } catch { Write-ErrLog ('Reflow week: ' + $_.Exception.Message) }
}

function Toggle-Topmost {
    $script:TopmostOn = (-not $script:TopmostOn)
    $script:MainWindow.Topmost = $script:TopmostOn
    $script:Settings['Topmost'] = $script:TopmostOn
    Save-Settings
}

function Toggle-ThemeMode {
    if ($script:Theme -eq 'night') { Set-Theme 'light' } else { Set-Theme 'night' }
}

function Toggle-Sidebar {
    $script:NavUserCollapsed = ($script:NavCol.Width.Value -gt 0)
    Set-NavCollapsed $script:NavUserCollapsed
}

function Export-Data {
    # 导出日程/任务数据（第十五轮，分享 PC）。
    # 只导 schedule.json（纯数据）：settings 里存着窗口位置这类本机信息，
    # 带到别的电脑反而是负担。未来跨端（Web 版）也直接认这份 JSON。
    try {
        Save-Data   # 先落盘，导出的是"此刻"的数据
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.FileName = ('myschedule-data-' + (Get-Date).ToString('yyyyMMdd') + '.json')
        $dlg.Filter = 'JSON (*.json)|*.json'
        $dlg.Title = (Get-LangText 'exp.title')
        if ($dlg.ShowDialog() -ne $true) { return }
        Copy-Item -LiteralPath $script:DataFile -Destination $dlg.FileName -Force
        Show-Toast -Title ((Get-LangText 'exp.done') -f $dlg.FileName)
    } catch {
        Write-ErrLog ('Export-Data: ' + $_.Exception.Message)
        Show-Toast -Title (Get-LangText 'exp.fail') -Text $_.Exception.Message
    }
}

function Import-Data {
    # 导入日程/任务数据（第十五轮，分享 PC / 换电脑）。
    # 覆盖前先把当前数据备份成 .import-bak：导错了还能找回来。
    try {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'JSON (*.json)|*.json'
        $dlg.Title = (Get-LangText 'imp.title')
        if ($dlg.ShowDialog() -ne $true) { return }
        $raw = [System.IO.File]::ReadAllText($dlg.FileName, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj -or $null -eq $obj.events -or $null -eq $obj.tasks) {
            Show-Toast -Title (Get-LangText 'imp.badfile')
            return
        }
        if (Test-Path -LiteralPath $script:DataFile) {
            Copy-Item -LiteralPath $script:DataFile -Destination ($script:DataFile + '.import-bak') -Force
        }
        Copy-Item -LiteralPath $dlg.FileName -Destination $script:DataFile -Force
        Load-Data
        Refresh-All
        Show-Toast -Title (Get-LangText 'imp.done')
    } catch {
        Write-ErrLog ('Import-Data: ' + $_.Exception.Message)
        Show-Toast -Title (Get-LangText 'imp.fail') -Text $_.Exception.Message
    }
}

function Show-MainMenu {
    try {
        $menu = New-Object System.Windows.Controls.ContextMenu
        $menu.Background = Brush (Get-Pal 'Card')
        $menu.Foreground = Brush (Get-Pal 'Ink')
        $menu.BorderBrush = Brush (Get-Pal 'Border')
        $menu.BorderThickness = [System.Windows.Thickness]::new(2)
        $menu.FontSize = 12
        $menu.Padding = [System.Windows.Thickness]::new(4)

        $miPin = New-Object System.Windows.Controls.MenuItem
        $miPin.Header = $(if ($script:TopmostOn) { 'Unpin window' } else { 'Pin window' })
        $miPin.Add_Click({ Toggle-Topmost })
        [void]$menu.Items.Add($miPin)

        $miTheme = New-Object System.Windows.Controls.MenuItem
        $miTheme.Header = $(if ($script:Theme -eq 'night') { 'Use light theme' } else { 'Use night theme' })
        $miTheme.Add_Click({ Toggle-ThemeMode })
        [void]$menu.Items.Add($miTheme)

        $miFocus = New-Object System.Windows.Controls.MenuItem
        $miFocus.Header = 'Focus settings'
        $miFocus.Add_Click({ Open-FocusPanel })
        [void]$menu.Items.Add($miFocus)

        # 第十四轮（item 1）：悬浮窗常驻开关 —— 开着就不跑番茄钟也钉在桌面角落。
        $miMini = New-Object System.Windows.Controls.MenuItem
        $miniPinned = $false
        if ($script:Settings.Contains('MiniPinned')) { $miniPinned = [bool]$script:Settings['MiniPinned'] }
        $miMini.Header = $(if ($miniPinned) { 'Unpin widget' } else { 'Pin widget' })
        $miMini.Add_Click({ Toggle-MiniPinned })
        [void]$menu.Items.Add($miMini)

        $miAvatar = New-Object System.Windows.Controls.MenuItem
        $miAvatar.Header = 'Change avatar'
        $miAvatar.Add_Click({ Open-AvatarPanel })
        [void]$menu.Items.Add($miAvatar)

        # 第十五轮（分享 PC）：导出/导入数据 —— 换电脑不再需要手动拷 %APPDATA%
        $miExport = New-Object System.Windows.Controls.MenuItem
        $miExport.Header = (Get-LangText 'menu.export')
        $miExport.Add_Click({ Export-Data })
        [void]$menu.Items.Add($miExport)
        $miImport = New-Object System.Windows.Controls.MenuItem
        $miImport.Header = (Get-LangText 'menu.import')
        $miImport.Add_Click({ Import-Data })
        [void]$menu.Items.Add($miImport)

        $miSidebar = New-Object System.Windows.Controls.MenuItem
        $miSidebar.Header = $(if ($script:NavCol.Width.Value -gt 0) { 'Hide sidebar' } else { 'Show sidebar' })
        $miSidebar.Add_Click({ Toggle-Sidebar })
        [void]$menu.Items.Add($miSidebar)

        [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))

        $miFolder = New-Object System.Windows.Controls.MenuItem
        $miFolder.Header = 'Open data folder'
        $miFolder.Add_Click({ Open-DataFolder })
        [void]$menu.Items.Add($miFolder)

        $menu.PlacementTarget = $script:BtnMore
        $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
        $menu.IsOpen = $true
    } catch { Write-ErrLog ('Show-MainMenu: ' + $_.Exception.Message) }
}

function Build-Window {
    # 换皮复用候选：必须【进来就抓】，下面第几行就会把 $script:MainWindow 覆盖成
    # 临时窗口，末尾再看就只能看到那个从没显示过的窗口了。
    $prevWin = $script:MainWindow
    Write-Trace ('build-window enter, prev=' + $(try { $script:MainWindow.GetHashCode() } catch { 'null' }))
    $xaml = ConvertTo-ThemeXaml $windowXaml $script:Theme
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $w = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:MainWindow = $w
    Write-Trace ('build-window parsed new=' + $w.GetHashCode())

    # ---- 拖出所有命名元素 ----
    $n = @{}
    foreach ($name in @(
        'OuterRing','TitleBar','WinTitle','BtnMin','BtnMax','BtnClose','MainPanel','NavCol',
        'NavPanel','AvatarBox','AvatarCanvas','AvatarImage','AvatarHint','AvatarHintBox',
        'NavMonth','NavWeek','NavList','NavTask','NavFocus','NavSettings',
        'NavProfile',
        'BtnViewMonth','BtnViewWeek','BtnViewList','BtnAdd','BtnFocusMenu',
        'BtnMore',
        'HeroTitle','HeroDate','HeroStats','CalBar','BtnPrev','BtnNext','BtnThis',
        'HeroClock','HeroDone','HeroFocus','HeroBarTrack','HeroBarFill',
        'CalLabel','CalNote','CalPeriod','ViewHost','UiOverlay',
        'IcNavMonth','IcNavWeek','IcNavList','IcNavTask','IcNavFocus','IcNavSettings','IcNavProfile',
        'IcViewMonth','IcViewWeek','IcViewList','IcAdd','IcFocusMenu','IcPin','IcTheme','IcCollapse','IcMore',
        'IcPrev','IcNext','IcMin','IcMax','IcClose','AuthorLabel','UpdateLabel','UndoHint')) {
        $n[$name] = $w.FindName($name)
    }
    $script:WinTitle     = $n['WinTitle']
    $script:NodeHost     = $n['ViewHost']
    $script:TitleBar     = $n['TitleBar']
    # 下面这几个是窗口能力（最小化/最大化/关闭/折叠）必须用到的，
    # 漏掉任意一个都会在后面的 Add_Click 处炸"检索不到变量"
    $script:OuterRing    = $n['OuterRing']
    $script:MainPanel    = $n['MainPanel']
    $script:NavCol       = $n['NavCol']
    $script:NavPanel     = $n['NavPanel']
    $script:AvatarBox    = $n['AvatarBox']
    $script:AvatarImage  = $n['AvatarImage']
    $script:AvatarHint   = $n['AvatarHint']
    $script:AvatarHintBox = $n['AvatarHintBox']
    $script:BtnMin       = $n['BtnMin']
    $script:BtnMax       = $n['BtnMax']
    $script:BtnClose     = $n['BtnClose']
    $script:NavMonth     = $n['NavMonth']
    $script:NavWeek      = $n['NavWeek']
    $script:NavList      = $n['NavList']
    $script:NavTask      = $n['NavTask']
    $script:NavFocus     = $n['NavFocus']
    $script:NavSettings  = $n['NavSettings']
    $script:NavProfile   = $n['NavProfile']
    $script:AuthorLabel  = $n['AuthorLabel']
    $script:UpdateLabel  = $n['UpdateLabel']
    # 撤销反馈条（第六轮）：Apply-UndoHintText 往它上面写，切主题重建后必须重新绑定，
    #   否则 Ctrl+Z 的"还剩几次"提示会在换肤之后彻底消失（旧控件已随旧树一起丢掉）。
    $script:UndoHint     = $n['UndoHint']
    # 第七轮（第六轮第二十七节第 3 条）：让这行小字**可点** —— 点一下 = 撤销一次。
    #   理由：提示条 5 秒后就消失，那时唯一的撤销入口只剩 Ctrl+Z；
    #   而侧栏这行"还可撤销 N"一直在，做成可点就等于给撤销留了个常驻入口。
    #   每次 Build-Window 都要重新挂（换主题会重建整棵树，处理器随旧控件一起丢）。
    try {
        if ($null -ne $script:UndoHint) {
            $script:UndoHint.Cursor = [System.Windows.Input.Cursors]::Hand
            $script:UndoHint.ToolTip = (Get-LangText 'undo.clickTip')
            $script:UndoHint.Add_MouseLeftButtonUp({
                param($s, $e)
                try { Undo-Delete } catch { Write-ErrLog ('Undo hint click: ' + $_.Exception.Message) }
            })
        }
    } catch { Write-ErrLog ('Undo hint bind: ' + $_.Exception.Message) }
    $script:BtnViewMonth = $n['BtnViewMonth']
    $script:BtnViewWeek  = $n['BtnViewWeek']
    $script:BtnViewList  = $n['BtnViewList']
    $script:BtnAdd       = $n['BtnAdd']
    $script:BtnFocusMenu = $null
    $script:BtnPin       = $null
    $script:BtnTheme     = $null
    $script:BtnCollapse  = $null
    $script:BtnMore      = $n['BtnMore']
    $script:HeroTitle    = $n['HeroTitle']
    $script:HeroDate     = $n['HeroDate']
    $script:HeroStats    = $n['HeroStats']
    # 第十四轮：Hero 统计胶囊（日期/时钟/已完成/进度条/今日专注拆成三个 pill）
    $script:HeroClock    = $n['HeroClock']
    $script:HeroDone     = $n['HeroDone']
    $script:HeroFocus    = $n['HeroFocus']
    $script:HeroBarTrack = $n['HeroBarTrack']
    $script:HeroBarFill  = $n['HeroBarFill']
    # 侧栏番茄钟整块已删（第三轮）：PomoBox/PomoBg/PomoArc/PomoInner/PomoText/
    # PomoHint/BtnPomo/PomoBtnText/BtnPomoReset 这些 x:Name 在 XAML 里已经不存在，
    # TryFindName 会返回 $null —— 这里显式置 $null，让 Update-PomodoroVisual 的判空路径成立。
    $script:PomoBox      = $null
    $script:PomoBg       = $null
    $script:PomoArc      = $null
    $script:PomoInner    = $null
    $script:PomoText     = $null
    $script:PomoHint     = $null
    $script:BtnPomo      = $null
    $script:PomoBtnText  = $null
    $script:BtnPomoReset = $null
    $script:CalBar       = $n['CalBar']
    $script:BtnPrev      = $n['BtnPrev']
    $script:BtnNext      = $n['BtnNext']
    $script:BtnThis      = $n['BtnThis']
    $script:CalLabel     = $n['CalLabel']
    $script:CalNote      = $n['CalNote']
    $script:CalPeriod    = $n['CalPeriod']
    $script:AvatarCanvas = $n['AvatarCanvas']
    $script:UiOverlay    = $n['UiOverlay']

    # ---- 覆盖层：XAML 里已与 ViewHost 同格叠放，且后加 -> 永远在最上层 ----
    # $script:UiOverlay 现在是 Canvas。裸点 .Children 在 StrictMode 下叫不动
    # （Canvas.Children 是显式接口实现），必须走 Panel 强转。
    [System.Windows.Controls.Panel]$script:UiOverlay.Children.Clear()
    $script:OverlayOpen = ''

    # ---- 恢复窗口几何 ----
    $sw = [System.Windows.SystemParameters]::WorkArea.Width
    $sh = [System.Windows.SystemParameters]::WorkArea.Height
    $ww = [double]$script:Settings['WindowWidth']
    $wh = [double]$script:Settings['WindowHeight']
    if ($ww -lt 720) { $ww = 1080 }
    if ($wh -lt 520) { $wh = 720 }
    if ($ww -gt $sw) { $ww = $sw - 40 }
    if ($wh -gt $sh) { $wh = $sh - 40 }
    $w.Width = $ww; $w.Height = $wh

    $wl = [double]$script:Settings['WindowLeft']
    $wt = [double]$script:Settings['WindowTop']
    $needCenter = $true
    if ($wl -gt -1000 -and $wt -gt -1000) {
        # 允许部分出屏，但至少留 120px 在屏内，防止"窗口丢了"
        if ($wl -lt ($sw - 120) -and ($wl + $ww) -gt 120 -and
            $wt -lt ($sh - 60) -and ($wt + $wh) -gt 60) {
            $w.Left = $wl; $w.Top = $wt; $needCenter = $false
        }
    }
    if ($needCenter) {
        $w.Left = [double](($sw - $ww) / 2.0)
        $w.Top = [double](($sh - $wh) / 2.0)
    }
    $w.Topmost = [bool]$script:TopmostOn
    # ---- 拖动 / 双击最大化 ----
    $script:DragArmed = $false
    $script:TitleBar.Add_MouseLeftButtonDown({
        param($s, $e)
        # 点在标题栏按钮上时不拖动
        try {
            if ((Get-EventSourceOf $e $s) -is [System.Windows.Controls.Button]) { return }
        } catch { }
        try {
            $script:MainWindow.DragMove()
        } catch { Write-ErrLog ('DragMove: ' + $_.Exception.Message) }
    })

    $script:TitleBar.Add_MouseLeftButtonUp({
        param($s, $e)
        try {
            $el = Get-EventSourceOf $e $s
            if ($el -is [System.Windows.Controls.Button]) { return }
            if ((Get-MouseClickCount $e) -ge 2) {
                if ($script:MainWindow.WindowState -eq 'Maximized') {
                    $script:MainWindow.WindowState = 'Normal'
                } else {
                    $script:MainWindow.WindowState = 'Maximized'
                }
            }
        } catch { }
    })

    # ---- 最小化 / 最大化 / 关闭 ----
    $script:BtnMin.Add_Click({
        try {
            if ($script:CloseToTray) { $script:MainWindow.Hide() }
            else { $script:MainWindow.WindowState = 'Minimized' }
        } catch { Write-ErrLog ('BtnMin: ' + $_.Exception.Message) }
    })
    $script:BtnMax.Add_Click({
        try {
            if ($script:MainWindow.WindowState -eq 'Maximized') {
                $script:MainWindow.WindowState = 'Normal'
            } else {
                $script:MainWindow.WindowState = 'Maximized'
            }
        } catch { Write-ErrLog ('BtnMax: ' + $_.Exception.Message) }
    })
    $script:BtnClose.Add_Click({
        if (Confirm-Close) { $script:MainWindow.Close() }
    })

    $w.Add_Closing({
        param($s, $e)
        # 重建窗口时关的是旧窗口：既不要确认框，也不要把"窗口尺寸"这类
        # 还没恢复好的值写回设置文件。
        if ($script:Rebuilding) { return }
        if (-not $script:AllowClose -and -not $TestMode) {
            $e.Cancel = $true
            if (Confirm-Close) {
                $script:AllowClose = $true
                $script:MainWindow.Close()
            }
            return
        }
        try {
            $script:Settings['WindowWidth'] = [double]$script:MainWindow.Width
            $script:Settings['WindowHeight'] = [double]$script:MainWindow.Height
            if ($script:MainWindow.WindowState -eq 'Normal') {
                $script:Settings['WindowLeft'] = [double]$script:MainWindow.Left
                $script:Settings['WindowTop'] = [double]$script:MainWindow.Top
            }
            $script:Settings['Topmost'] = [bool]$script:TopmostOn
            $script:Settings['Theme'] = $script:Theme
            $script:Settings['View'] = $script:View
            Save-Settings
            Save-Data
            # Dispose 完必须置空：否则后续再判断 "$null -ne $script:TrayIcon" 仍为真，
            # 会对已释放的对象重复操作（也会让"是否该退出"的判断失真）。
            if ($null -ne $script:TrayIcon) {
                try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch { }
                $script:TrayIcon = $null
            }
        } catch { Write-ErrLog ('Closing-save: ' + $_.Exception.Message) }
    })

    $w.Add_StateChanged({
        try {
            if ($script:MainWindow.WindowState -eq 'Minimized' -and $script:CloseToTray) {
                $script:MainWindow.Hide()
            }
        } catch { }
    })

    # ---- 工具条 ----
    $script:NavMonth.Add_Click({ Set-View 'month' })
    $script:NavWeek.Add_Click({ Set-View 'week' })
    $script:NavList.Add_Click({ Set-View 'list' })
    # Tasks 以前是 Set-View 'list'（点了就是跳回列表页，等于没自己的位置），
    # 现在它对应一个真正的视图：任务面板已从列表页右侧搬到那里。
    $script:NavTask.Add_Click({ Set-View 'tasks' })
    $script:NavFocus.Add_Click({ Open-FocusPanel })
    $script:NavSettings.Add_Click({ Open-StatsPanel })
    $script:NavProfile.Add_Click({ Open-StatsPanel })

    $script:BtnAdd.Add_Click({ Open-EventEditor })
    $script:AvatarBox.Add_MouseLeftButtonUp({
        param($s, $e)
        try { Open-AvatarPanel; $e.Handled = $true } catch { Write-ErrLog ('Avatar box click: ' + $_.Exception.Message) }
    })

    $script:BtnMore.Add_Click({ Show-MainMenu })

    $script:BtnPrev.Add_Click({ Shift-Period -1 })
    $script:BtnNext.Add_Click({ Shift-Period 1 })
    $script:BtnThis.Add_Click({
        $script:Anchor = [datetime]::Today
        $script:Selected = [datetime]::Today
        Refresh-All
    })

    # 侧栏番茄钟整块已删 -> 这几个 `$script:` 都是 $null，挂事件会在 StrictMode 下炸。
    # 判空保留成"如果哪天圆环回来了就自动接上"，控制面现在全在 Focus 浮窗。
    if ($null -ne $script:BtnPomo) { $script:BtnPomo.Add_Click({ Toggle-Pomodoro }) }
    if ($null -ne $script:PomoBox) {
        $script:PomoBox.Add_MouseLeftButtonUp({
            param($s, $e)
            try {
                if ([bool]$script:Settings['PomodoroEnabled']) { Toggle-Pomodoro }
                else { Open-FocusPanel }
                $e.Handled = $true
            } catch { Write-ErrLog ('PomoBox click: ' + $_.Exception.Message) }
        })
    }
    if ($null -ne $script:BtnPomoReset) { $script:BtnPomoReset.Add_Click({ Open-FocusPanel }) }
    $script:BtnThis.Add_Click({ Open-PeriodPicker })
    $script:CalPeriod.Add_MouseLeftButtonUp({
        param($s, $e)
        try { Open-PeriodPicker; $e.Handled = $true }
        catch { Write-ErrLog ('CalPeriod click: ' + $_.Exception.Message) }
    })
    # 标题现在是个"可点入口"，必须自己给出可点的视觉线索 ——
    # WPF 的 TextBlock 默认是箭头光标，不给 Hand 用户根本不知道这里能点。
    $script:CalPeriod.Cursor = 'Hand'
    $script:CalPeriod.ToolTip = (Get-LangText 'pick.calTip')
    # ---- 头像与图标 ----
    Draw-Avatar $script:AvatarCanvas
    Apply-AvatarImage -Path ([string]$script:Settings['AvatarPath']) | Out-Null
    Draw-AllIcons $n

    # ---- 字号倍率基线 ----
    # 必须在"树刚建好、还没被任何倍率改写"的时刻采一次：这份基线是设计值，
    # Apply-UiScale 每次都用它 × 当前倍率，才不会累计放大（见 Collect-XamlFontNodes）。
    Collect-XamlFontNodes $w.Content
    Apply-UiScale

    # ---- 语言（第五轮）----
    # 和 Apply-UiScale 同理：XAML 里写死的侧栏导航文字 / DAILY NOTE 改不到，
    # 只能等树建好之后按 Name 找出来改。Initialize-Lang 先把"取词用的数组"
    # 设对（DowShort / MonNames），Apply-Lang 再刷 XAML 那批文案。
    Initialize-Lang
    Apply-Lang

    Attach-ViewHandlers $script:NodeHost

    # ---- 换皮不换窗 ----
    # Set-Theme 需要整棵树按新色板重画，但 Window 对象不能换（实测换窗必失败，
    # 见 Rebuild-Window 里的说明）。所以：新树建在临时 Window $w 上，
    # 然后把 Content 过户给"现在正显示着的那个窗口"。
    # （$prevWin 已在函数开头抓取）
    $reuse = $null
    try {
        if ($null -ne $prevWin -and $prevWin.IsLoaded) { $reuse = $prevWin }
    } catch { }
    if ($null -ne $reuse) {
        # 先过户资源字典，再过户内容树。顺序反了会漏掉一类控件：
        # Window.Resources 里那套隐式 ComboBox / ComboBoxItem 样式的颜色，是 XAML
        # 解析时把 __Key__ 占位符替换成当前主题的具体色值烘进去的，旧窗口的 Resources
        # 里存的还是【第一次启动时】烘出来的那一份。只搬 Content 不搬 Resources 的话，
        # 之后用代码 new 出来的 ComboBox 顺着可视树查样式，查到的是旧窗口那份浅色的：
        # 夜间模式下就是"白底 + 白字"，控件直接消失。
        # （周视图时段下拉当时能跟上主题，纯属它自己调了 Brush(Get-Pal)，不是因为它更正确。）
        if ($null -ne $w.Resources) {
            try {
                $dict = New-Object System.Windows.ResourceDictionary
                foreach ($k in @($w.Resources.Keys)) { $dict.Add($k, $w.Resources[$k]) }
                foreach ($md in @($w.Resources.MergedDictionaries)) { $dict.MergedDictionaries.Add($md) }
                $reuse.Resources = $dict
            } catch { Write-ErrLog ('Build-Window resources: ' + $_.Exception.Message) }
        }
        # 直接把整棵内容树过户给现有窗口。不要先 $w.Content = $null 再赋值：
        # 实测那样会在窗口 Close 时把进程整个带崩（exit 1，连 Closed 处理器都进不去）。
        $reuse.Content = $w.Content
        $script:MainWindow = $reuse
        Write-Trace ('build-window reused=' + $reuse.GetHashCode() + ' content-from=' + $w.GetHashCode())
    } else {
        $script:MainWindow = $w
    }

    # ---- 生命周期钩子（只挂一次，挂在"会一直活着的那个窗口"上）----
    # 走到 Closed 就说明是"真的要退出"：想留托盘的话，Confirm-Close 走的是
    # MainWindow.Hide()，根本不会触发 Closed。
    # 用 $script:LifecycleHooked 防重复：换皮不换窗时 Build-Window 会被多次调用，
    # 如果每次都 Add_Closed，处理器会越积越多。
    if (-not $script:ResponsiveHooked) {
        $script:ResponsiveHooked = $true
        $script:MainWindow.Add_SizeChanged({
            try { Apply-ResponsiveLayout } catch { Write-ErrLog ('Responsive: ' + $_.Exception.Message) }
        })
    }
    Apply-ResponsiveLayout

    # ---- 全局快捷键（第七轮，第六轮第二十七节第 4 条）----
    #   关于页里一直列着 Ctrl+N / Ctrl+F / Ctrl+Z 三条，但**从来没有被实现过** ——
    #   文档写了快捷键而按键没反应，比不写更糟（用户会以为是自己按错）。
    #   这里一次性补齐，并在审计里加 key:<combo> 动词做端到端确认。
    #
    #   为什么挂 PreviewKeyDown 而不是 KeyDown：
    #     KeyDown 会沿着"焦点元素 -> 冒泡"走，焦点在搜索框里时，Ctrl+F/N/Z 会先给
    #     文本框处理（甚至被它标记 Handled），主窗口收不到。PreviewKeyDown 是隧道事件，
    #     从窗口往下传，**在窗口这一层就能先拿到**，不受焦点在哪影响 ——
    #     这正是"全局快捷键"该有的语义。
    #
    #   绑定只挂一次（与 ResponsiveHooked 同理，换皮不换窗）。
    if (-not $script:HotkeyHooked) {
        $script:HotkeyHooked = $true
        $script:MainWindow.Add_PreviewKeyDown({
            param($s, $e)
            try {
                $ctrl = (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0)
                if (-not $ctrl) { return }
                $k = [string]$e.Key
                if ($k -eq 'Z') {
                    # Ctrl+Z = 撤销上一次操作（删除 / 勾选 / 拖动改时间）
                    Undo-Delete
                    $e.Handled = $true
                } elseif ($k -eq 'N') {
                    # Ctrl+N = 新建日程
                    Open-EventEditor
                    $e.Handled = $true
                } elseif ($k -eq 'F') {
                    # Ctrl+F = 聚焦当前视图的搜索框（列表页 / 任务页各有一个）
                    if ($script:View -eq 'tasks') {
                        if ($null -ne $script:TaskSearch) { $script:TaskSearch.Focus() | Out-Null }
                    } else {
                        if ($script:View -ne 'list') { Set-View 'list' }
                        if ($null -ne $script:ListSearch) { $script:ListSearch.Focus() | Out-Null }
                    }
                    $e.Handled = $true
                }
            } catch { Write-ErrLog ('Hotkey: ' + $_.Exception.Message) }
        })
    }

    # ---- 生命周期钩子（只挂一次，挂在"会一直活着的那个窗口"上）----
    if (-not $script:LifecycleHooked) {
        $script:LifecycleHooked = $true
        $script:MainWindow.Add_Closed({
            # 重建流程中不会走到这里（窗口对象根本不换，也就不会 Close）
            try {
                Write-Trace 'closed handler enter'
                $script:WindowClosed = $true
                Write-BootLog
            } catch { Write-Trace ('closed log ERR: ' + $_.Exception.Message) }
            try {
                Write-Trace 'before App.Shutdown'
                # 释放单实例锁：不释放的话，Mutex 要等进程退出才被系统标记为废弃，
                # 用户紧接着手动再开一个会弹"已经在运行"。
                try {
                    if ($null -ne $script:InstanceMutex) {
                        $script:InstanceMutex.ReleaseMutex()
                        $script:InstanceMutex.Dispose()
                        $script:InstanceMutex = $null
                    }
                } catch { }
                if ($null -ne $script:App) { $script:App.Shutdown() }
                Write-Trace 'closed handler exit'
            } catch { Write-Trace ('closed shutdown ERR: ' + $_.Exception.Message) }
        })
    }
}

function Shift-Period {
    param([int]$Dir)
    if ($script:View -eq 'month') {
        $script:Anchor = $script:Anchor.AddMonths($Dir)
    } elseif ($script:View -eq 'week') {
        $script:Anchor = $script:Anchor.AddDays(7 * $Dir)
    } else {
        $script:Anchor = $script:Anchor.AddMonths($Dir)
    }
    Refresh-All
}

# ---------------------------------------------------------------------------
#  G. 日期选择器（点日历条上的期间标题弹出）
# ---------------------------------------------------------------------------
# 为什么要它：月/周/列表三个视图原来只能靠 ← → 一格一格挪，"想跳到三个月后"要按三次，
# 而且从标题上看不出"我现在到底在哪一页"。现在点标题就出一张真正的月历，
# 可以翻月份 + 直接点某一天。
# 选中的那一天怎么落到各视图：
#   week  -> $script:Anchor 是该周的任意一天，直接赋这一天即可
#   month -> 赋这一天，Render-Month 会按它所在的月分页（Selected 同时跟过去，
#            这样月视图里选中的格子就是用户点的那个）
#   list  -> 赋这一天，列表按月分页
# 注意：$script:Selected 也要一起走，否则"跳过去了但选中框还留在原来那天"，
# 用户会以为没生效（这个坑在 Ctrl+T 的 Today 按钮那里已经踩过一次）。
function Set-PeriodDate {
    param([datetime]$Date)
    $d = $Date.Date
    $script:Anchor = $d
    $script:Selected = $d
    Refresh-All
}

function Shift-PeriodPickerMonth {
    # 期间选择窗的翻月：改 $script:DpFirst，然后重画。
    #
    # 为什么抽成命名函数，而不是在按钮处理器里直接改（原来的写法）：
    #   ① 处理器闭包里的 `& $script:DpPaint` 依赖"触发时 $script:DpPaint 仍是本窗口
    #      那一份"这个隐含前提。写测试/审计时连开两个 picker 是常见操作，后一个
    #      Show-PeriodPickerWindow 会把 $script:DpPaint 换成新的一份（指向新窗口的
    #      42 个格子与标签）—— 前一个窗口的按钮再去点，画的是后一个窗口。
    #   ② 更糟的是作用域：脚本块在"被事件处理器调用"与"被 & 直接调用"两种路径下
    #      解析变量的作用域链并不完全一致，任一路径解析失败都会抛异常，
    #      而处理器外面套着 catch -> 只写 errors.log，界面表现是"按钮是死的"。
    #   本函数把"翻月"这件事收在一处，只依赖 $script: 状态，两条路径行为一致。
    param([int]$Dir)
    if ($Dir -eq 0) { return }
    $first = [datetime]$script:DpFirst
    $script:DpFirst = $first.AddMonths($Dir)
    # 用 Invoke-Command 在脚本级作用域执行 paint，避免"被谁调用"影响变量解析。
    Invoke-PaintPeriodPicker
}

function Invoke-PaintPeriodPicker {
    # 触发一次期间选择窗重画。
    #
    # 为什么只需要一个 `&`：$script:DpPaint 内部**只引用 $script: 上的东西**
    # （$script:DpCells / $script:DpFirst / $script:DpLabelText / $script:Selected）。
    # $script: 变量的解析与"谁调用、在什么作用域调用"无关 —— 已实测：
    #   脚本块引用 $script:Val：从任意函数 / 处理器里 & 或 . 调用都能解析；
    #   脚本块引用**局部** $L：只有从"定义它的那个函数"内部调用才解析得到，
    #   一旦由 WPF 处理器（dispatcher 回调）触发就抛"检索不到变量 $L"。
    # 这正是本轮 item 1 的根因：$lbl 曾是 Show-PeriodPickerWindow 的局部变量，
    # 初始 paint 在函数内跑所以看着正常，点 < > 时处理器在函数外跑 -> 抛异常
    # -> 被 catch 吞掉 -> 界面上"按钮是死的"。
    # 用 & 而不是点源：点源会把脚本块里的变量写进调用方作用域，
    # 在 WPF 处理器里点源等于往处理器作用域塞变量，没有必要。
    if ($null -eq $script:DpPaint) { return }
    try { & $script:DpPaint } catch { Write-ErrLog ('Picker paint: ' + $_.Exception.Message) }
}

function Show-PeriodPickerWindow {
    $script:DpWin = New-Object System.Windows.Window
    $script:DpWin.Title = (Get-LangText 'win.pickDate')
    $script:DpWin.WindowStyle = 'None'
    $script:DpWin.AllowsTransparency = $true
    $script:DpWin.Background = $null
    $script:DpWin.ResizeMode = 'NoResize'
    $script:DpWin.SizeToContent = 'WidthAndHeight'
    # 和 Focus 浮窗同样的理由：CenterOwner 会在 Show() 一刻按 Owner 重算位置，
    # 手动赋的 Left/Top 被无声盖掉。
    $script:DpWin.WindowStartupLocation = 'Manual'
    $script:DpWin.ShowInTaskbar = $false
    $script:DpWin.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
    $sp.Width = 306

    [void]$sp.Children.Add((New-Txt -Text (Get-LangText 'pick.title') -Size 20 -Color (Get-Pal 'Ink') -Weight 'Bold'))
    [void]$sp.Children.Add((New-Txt -Text (Get-LangText 'pick.hint') `
        -Size 11 -Color (Get-Pal 'InkSoft')))

    # ---- 月份切换行：<  September 2026  > ----
    $head = New-Object System.Windows.Controls.Grid
    $head.Margin = [System.Windows.Thickness]::new(0, 14, 0, 8)
    $cdA = New-Object System.Windows.Controls.ColumnDefinition
    $cdA.Width = [System.Windows.GridLength]::Auto
    $cdB = New-Object System.Windows.Controls.ColumnDefinition
    $cdB.Width = [System.Windows.GridLength]::new(1, 'Star')
    $cdC = New-Object System.Windows.Controls.ColumnDefinition
    $cdC.Width = [System.Windows.GridLength]::Auto
    $head.ColumnDefinitions.Add($cdA)
    $head.ColumnDefinitions.Add($cdB)
    $head.ColumnDefinitions.Add($cdC)
    $bPrevM = New-PixBtn -Text '<' -Bg (Get-Pal 'Card') -Fg (Get-Pal 'Ink') -W 34 -H 30 -FontSize 13
    $bNextM = New-PixBtn -Text '>' -Bg (Get-Pal 'Card') -Fg (Get-Pal 'Ink') -W 34 -H 30 -FontSize 13
    $bPrevM.ToolTip = (Get-LangText 'pick.prevMonth')
    $bNextM.ToolTip = (Get-LangText 'pick.nextMonth')
    # 给翻月按钮挂语义 Tag：一是让审计能按 Tag 找到它（pickflip 动词），
    # 二是避免处理器闭包去抓函数局部变量 —— 本项目多次栽在"处理器看不见局部变量"上。
    $bPrevM.Tag = @{ kind = 'pick-flip'; dir = 'prev' }
    $bNextM.Tag = @{ kind = 'pick-flip'; dir = 'next' }
    # 月份标签挂到 $script: 上：$script:DpPaint 是脚本级脚本块，
    # 虽然 Windows PowerShell 的脚本块能动态解析调用方作用域里的 $lbl，
    # 但那是"碰巧能跑"的隐式行为 —— 一旦 DpPaint 在别的函数里被复用/被
    # 事件处理器（而非直接 &）调用，作用域就不再是本函数，$lbl 会解析失败，
    # 整段 paint 被 catch 吞掉，对外表现正是"点了 < > 完全没反应"。
    # 所以这里显式挂 $script:，让 DpPaint 只依赖 $script: 上的东西。
    $lbl = New-Txt -Text '' -Size 14 -Color (Get-Pal 'Ink') -Weight 'Bold'
    $script:DpLabelText = $lbl
    $lbl.HorizontalAlignment = 'Center'
    $lbl.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($bPrevM, 0)
    [System.Windows.Controls.Grid]::SetColumn($lbl, 1)
    [System.Windows.Controls.Grid]::SetColumn($bNextM, 2)
    [void]$head.Children.Add($bPrevM)
    [void]$head.Children.Add($lbl)
    [void]$head.Children.Add($bNextM)
    [void]$sp.Children.Add($head)

    # ---- 七个格子：星期表头 + 6x7 日期网格（固定 6 行，翻月份时高度不跳）----
    $grid = New-Object System.Windows.Controls.Grid
    for ($i = 0; $i -lt 7; $i++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = [System.Windows.GridLength]::new(1, 'Star')
        $grid.ColumnDefinitions.Add($cd)
    }
    for ($i = 0; $i -lt 7; $i++) {
        $rd = New-Object System.Windows.Controls.RowDefinition
        if ($i -eq 0) { $rd.Height = [System.Windows.GridLength]::new(22, 'Pixel') }
        else { $rd.Height = [System.Windows.GridLength]::new(32, 'Pixel') }
        $grid.RowDefinitions.Add($rd)
    }
    $dowNames = @('Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa')
    for ($i = 0; $i -lt 7; $i++) {
        $t = New-Txt -Text $dowNames[$i] -Size 10 -Color (Get-Pal 'InkFaint')
        $t.HorizontalAlignment = 'Center'
        $t.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetRow($t, 0)
        [System.Windows.Controls.Grid]::SetColumn($t, $i)
        [void]$grid.Children.Add($t)
    }
    # 日期按钮先全部建好、只改内容与配色：翻月份时重建 42 个控件会让窗口闪一下
    $script:DpCells = New-Object System.Collections.ArrayList
    for ($r = 1; $r -le 6; $r++) {
        for ($c = 0; $c -lt 7; $c++) {
            $b = New-Object System.Windows.Controls.Button
            $b.FontSize = 11
            $b.Margin = [System.Windows.Thickness]::new(1)
            $b.Cursor = 'Hand'
            $b.BorderThickness = [System.Windows.Thickness]::new(1)
            $b.Add_Click({
                param($s, $e)
                try {
                    $hit = $s.Tag
                    if ($null -eq $hit) { return }
                    $pick = [datetime]$hit['date']
                    Close-DialogWindow $script:DpWin $true
                    Set-PeriodDate $pick
                } catch { Write-ErrLog ('Pick day: ' + $_.Exception.Message) }
            })
            [System.Windows.Controls.Grid]::SetRow($b, $r)
            [System.Windows.Controls.Grid]::SetColumn($b, $c)
            [void]$grid.Children.Add($b)
            [void]$script:DpCells.Add($b)
        }
    }
    [void]$sp.Children.Add($grid)

    # ---- 底部：只留 Today ----
    #   第七轮 item 2：用户要求"去掉 save 键"。既然没有 Save，标题栏的 × 就是唯一的退出键，
    #   底部再放一个 Cancel 会重演第六轮那个问题（Cancel 与 × 同一功能，却占两个位置）。
    #   Today 保留：它不是"退出"，而是"跳回今天"这个独立动作。
    $foot = New-Object System.Windows.Controls.StackPanel
    $foot.Orientation = 'Horizontal'
    $foot.HorizontalAlignment = 'Right'
    $foot.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
    $bToday = New-PixBtn -Text (Get-LangText 'btn.today') -Bg (Get-Pal 'AccentFocus') -Fg (Get-Pal 'TodayInk') -W 84 -H 34
    [void]$foot.Children.Add($bToday)
    [void]$sp.Children.Add($foot)

    # 当前显示的是哪个月（和 $script:Anchor 解耦：翻月份不该立刻改视图，
    # 只有"点了某一天 / 点了 Today"才落实 —— 否则用户翻两下视图就跑了）。
    # 必须挂在 $script: 上：$script:DpPaint 里的处理器访问不到本函数的局部变量。
    $script:DpFirst = [datetime]::new([int]$script:Anchor.Year, [int]$script:Anchor.Month, 1)

    # 重画：只用 $script: 上的东西（WPF 处理器看不见创建函数的局部变量，StrictMode 直接抛）
    $script:DpPaint = {
        try {
            $first = [datetime]$script:DpFirst
            $lbl = $script:DpLabelText
            if ($null -ne $lbl) {
                $lbl.Text = [string](Get-Culture).DateTimeFormat.GetMonthName($first.Month) + ' ' + [string]$first.Year
            }
            $lead = ([int]$first.DayOfWeek + 6) % 7      # 周一为一周之始，和月视图一致
            $days = [int][datetime]::DaysInMonth($first.Year, $first.Month)
            $sel = ([datetime]$script:Selected).Date
            $today = [datetime]::Today
            $ink = Get-Pal 'Ink'
            $soft = Get-Pal 'InkSoft'
            $acc = Get-Pal 'AccentFocus'
            $accInk = Get-Pal 'TodayInk'
            $card = Get-Pal 'Card'
            $cellBg = Get-Pal 'CardAlt'
            $borderSoft = Get-Pal 'BorderSoft'
            $cells = @($script:DpCells)
            for ($i = 0; $i -lt $cells.Count; $i++) {
                $b = $cells[$i]
                $d = $i - $lead + 1
                if ($d -lt 1 -or $d -gt $days) {
                    # 补位格：相邻月份的日号，浅色、不可点（和月视图的 pad cell 一个语气）
                    $b.Visibility = 'Visible'
                    $b.IsEnabled = $false
                    $b.Content = ''
                    $b.Tag = $null
                    $b.Background = Brush 'Transparent'
                    $b.BorderBrush = Brush 'Transparent'
                    $b.Foreground = Brush $soft
                    continue
                }
                $dt = [datetime]::new($first.Year, $first.Month, $d)
                $b.Visibility = 'Visible'
                $b.IsEnabled = $true
                $b.Content = [string]$d
                $b.Tag = @{ kind = 'pick-day'; date = $dt }
                if ($dt -eq $sel) {
                    $b.Background = Brush $acc
                    $b.Foreground = Brush $accInk
                    $b.BorderBrush = Brush $borderSoft
                } elseif ($dt -eq $today) {
                    $b.Background = Brush $card
                    $b.Foreground = Brush $ink
                    $b.BorderBrush = Brush $acc
                } else {
                    $b.Background = Brush $cellBg
                    $b.Foreground = Brush $ink
                    $b.BorderBrush = Brush $borderSoft
                }
                $b.ToolTip = $dt.ToString('yyyy-MM-dd') + ' (' + $dt.ToString('ddd') + ')'
            }
        } catch { Write-ErrLog ('Picker paint: ' + $_.Exception.Message) }
    }
    # 注意：当前月份只由第 1097 行的 $script:DpFirst 决定。
    # 这里曾经留过一行 `$script:DpFirst = $firstOfMonth` 的旧草稿 —— $firstOfMonth
    # 这个局部变量早就不存在了，StrictMode 下会抛"检索不到变量"，把整个选日期
    # 窗口的构建打断（对外表现：点标题没反应，审计里是一行 crash）。
    Invoke-PaintPeriodPicker
    # 翻月按钮的处理器：**不闭包任何函数局部变量**，只调命名函数。
    #   历史坑：处理器里写 `& $script:DpPaint` 时，paint 内部若引用本函数的局部
    #   变量（例如旧版的 $lbl），会因为"处理器在函数作用域之外执行"而抛
    #   "检索不到变量"，异常被 catch 吞进 errors.log，界面上就是
    #   "点了 < > 完全没反应"，且没有任何可见报错。
    #   （本轮已实测复现：脚本块引用局部变量时，只有在定义它的函数内部调用才解析得到。）
    #   现在改成调 Shift-PeriodPickerMonth，它只读/写 $script: 上的状态。
    $bPrevM.Add_Click({ try { Shift-PeriodPickerMonth -1 } catch { Write-ErrLog ('Picker prev: ' + $_.Exception.Message) } })
    $bNextM.Add_Click({ try { Shift-PeriodPickerMonth 1 } catch { Write-ErrLog ('Picker next: ' + $_.Exception.Message) } })
    $bToday.Add_Click({
        try {
            $t = [datetime]::Today
            $script:DpFirst = [datetime]::new($t.Year, $t.Month, 1)
            Invoke-PaintPeriodPicker
            Close-DialogWindow $script:DpWin $true
            Set-PeriodDate $t
        } catch { Write-ErrLog ('Picker today: ' + $_.Exception.Message) }
    })

    # 期间选择窗只有"点某天 / Today"才落实跳转，没有"保存"这个动作 ——
    # Save 传 $false 不生成，标题栏只剩 [标题] + [×]（× = 取消）。
    $chrome = Get-EditorChrome 'Pick a date' $sp -NoSave
    $script:DpWin.Content = $chrome.Root
    # 标题栏可拖动（和 Avatar 窗口一致）；点在按钮上时不拖
    $chrome.Bar.Add_MouseLeftButtonDown({
        param($s, $e)
        if (Test-ClickOnButton $e) { return }
        try { $script:DpWin.DragMove(); Save-DialogPos $script:DpWin 'PeriodPicker' } catch { }
    })
    $chrome.BtnClose.Add_Click({ try { Close-DialogWindow $script:DpWin $false } catch { } })
    try {
        if ($null -ne $script:MainWindow -and $script:MainWindow.IsVisible) { $script:DpWin.Owner = $script:MainWindow }
    } catch { }
    $script:DpWin.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') { try { Close-DialogWindow $script:DpWin $false } catch { } }
    })
    Set-DialogStartPosition $script:DpWin 'PeriodPicker'
    return $script:DpWin
}

function Open-PeriodPicker {
    if ($Skeleton) { return }
    if ($script:SuppressModal) { $script:LastModalCall = 'period'; return }
    try {
        $win = Show-PeriodPickerWindow
        $win.ShowDialog() | Out-Null
    } catch { Write-ErrLog ('Open-PeriodPicker: ' + $_.Exception.Message) }
}
