# =============================================================================
#  My Schedule - 像素风桌面日程小工具
#  PowerShell + WPF，Windows 原生运行，无需安装任何运行环境
#
#  数据存放：%APPDATA%\MyScheduleWidget\
#  每个 Windows 用户账户自动隔离，互不干扰
# =============================================================================
param(
    # 数据目录（测试时指向临时目录，绝不碰用户真实数据）
    [string]$DataDir,
    # 测试模式：跳过互斥锁与关闭确认弹窗
    [switch]$TestMode,
    # 截图输出路径（渲染完一帧后自动保存并退出）
    [string]$ScreenshotPath,
    # 初始视图：month / week / list / tasks
    [ValidateSet('month', 'week', 'list', 'tasks')]
    [string]$StartView = 'month',
    # 初始主题：light / night
    [ValidateSet('light', 'night')]
    [string]$ThemeOverride = '',
    # 覆盖视口尺寸（测试用，如 "1000x700"）
    [string]$SizeOverride = '',
    # 自动关闭秒数（测试用，0 = 不自动关）
    [int]$AutoCloseSeconds = 0,
    # 自动化脚本：逗号分隔的动作序列，如 "view:week,theme:night,shot"
    [string]$Script = '',
    # 骨架屏：只渲染布局结构，不建单元格与事件（用于秒出结构截图）
    [switch]$Skeleton,
    # 启动时序追踪：把启动各阶段写进 errors.log，用于定位"卡在哪一步"
    [switch]$Trace
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
#  0. 程序集
# ---------------------------------------------------------------------------
foreach ($asm in @('PresentationFramework', 'PresentationCore', 'WindowsBase',
                   'System.Xaml', 'System.Windows.Forms', 'System.Drawing')) {
    try { Add-Type -AssemblyName $asm } catch { }
}

# ---------------------------------------------------------------------------
#  1. 路径与数据目录
# ---------------------------------------------------------------------------
$script:AppName = 'MyScheduleWidget'

if ([string]::IsNullOrWhiteSpace($DataDir)) {
    $script:DataDir = Join-Path $env:APPDATA $script:AppName
} else {
    $script:DataDir = $DataDir
}
if (-not (Test-Path -LiteralPath $script:DataDir)) {
    New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
}
$script:DataFile     = Join-Path $script:DataDir 'schedule.json'
$script:SettingsFile = Join-Path $script:DataDir 'settings.json'
$script:ErrorLog     = Join-Path $script:DataDir 'errors.log'

# ---------------------------------------------------------------------------
#  1.5 单实例
#      同一个 Windows 账户同时只开一个。不同账户各自有各自的实例和
#      各自的 %APPDATA% 数据目录，互不影响（这正是"多用户可用"的含义）。
#      TestMode 不加锁：回归要连续起很多个实例，锁会把它们串成"已经在运行"。
# ---------------------------------------------------------------------------
$script:InstanceMutex = $null
if (-not $TestMode) {
    $mutexName = 'Local\' + $script:AppName + '_' + $env:USERNAME
    $created = $false
    try {
        $script:InstanceMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$created)
    } catch {
        $script:InstanceMutex = $null
        $created = $true   # 拿不到锁的极端情况（权限等）：宁可重复开，也不挡用户
    }
    if (-not $created) {
        if ($null -ne $script:InstanceMutex) { $script:InstanceMutex.Dispose() }
        $script:InstanceMutex = $null
        [System.Windows.MessageBox]::Show(
            'Schedule 已经在运行了。' + [Environment]::NewLine +
            '请在系统托盘里找它（右下角小图标，双击即可显示窗口）。',
            'Schedule',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information) | Out-Null
        exit 0
    }
}

# ---------------------------------------------------------------------------
#  1.6 首次运行说明
#      数据是"每个 Windows 账户一份"的，第一次跑时把这件事和数据位置讲清楚。
# ---------------------------------------------------------------------------
if (-not $TestMode -and -not (Test-Path -LiteralPath $script:DataFile)) {
    try {
        $firstRun = @(
            'Schedule —— 使用说明',
            '',
            ('数据位置：' + $script:DataDir),
            '  日程和设置都存在你自己 Windows 账户的数据目录里，',
            '  换账户登录看到的是另一份（互相隔离，不会串）。',
            '',
            '常用操作：',
            '  · 新建日程：顶部 + Event，或在月视图的某天上右键',
            '  · 编辑/删除：列表左键，周视图双击日程块，改完 Save',
            '  · 月视图：一页从 1 号排到月末，首尾空位用浅色日期补满',
            '    （补的只是格子，不会显示上/下个月的日程）',
            '  · 月视图：单击日期会自动跳到对应周视图，+N more 可展开当天详情',
            '  · 周视图：空白处点击或拖动创建；拖动显示时间虚线；右键快速编辑/复制/删除',
            '  · 周视图：窗口拉高时时间轴会跟着变高（把整段时段铺满），不会在底下留一片空白',
            '  · 重复日程：编辑器可设置每天、每周、每月及自定义间隔',
            '  · 提醒：日程可提前 5/10/15 分钟提醒，任务按截止时间提醒',
            '  · 专注：支持专注后自动休息，并分别通知专注和休息结束',
            '  · 专注窗：按住计时器那块圆盘可以整体拖动窗口，位置会被记住',
            '  · Tasks：左侧栏「Tasks」是任务专页，可搜索、按项目/状态/时间筛选、排序，',
            '    支持拖拽排序、子任务勾选、延期和一键专注',
            '  · 头像：点击左上角头像，可换成自己的图片；其他设置见顶部“...”菜单',
            '  · 夜间模式：右上角 Night / Day',
            '  · 窗口缩放：鼠标拖动窗口四周边缘',
            '  · 关闭窗口 = 最小化到托盘，真正退出要用托盘右键的"退出"',
            '',
            '这套程序不需要安装，把整个文件夹拷给同事也能直接用。'
        )
        [System.IO.File]::WriteAllLines((Join-Path $script:DataDir '使用说明.txt'), $firstRun,
            (New-Object System.Text.UTF8Encoding($true)))
    } catch { }
}

# ---------------------------------------------------------------------------
#  2. 日志（静默异常的唯一证据来源）
# ---------------------------------------------------------------------------
function Write-ErrLog {
    param([string]$Text)
    try {
        $line = '[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Text
        Add-Content -LiteralPath $script:ErrorLog -Value $line -Encoding UTF8
    } catch { }
}

$script:UnhandledCount = 0

# 启动时序追踪（-Trace 打开）。排查"进程挂死且无异常"这类问题时的唯一抓手：
# 挂死不会写任何异常，只有逐步打点才能看出最后越过的是哪一步。
function Write-Trace {
    param([string]$Text)
    if ($script:TraceOn) { Write-ErrLog ('TRACE ' + $Text) }
}
try {
    $script:Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $script:Dispatcher.add_UnhandledException({
        param($s, $e)
        $script:UnhandledCount++
        $msg = $e.Exception.Message
        $ln = ''
        try { $ln = [string]$e.Exception.StackTrace } catch { }
        Write-ErrLog ("UNHANDLED: " + $msg + " | " + $ln)
        $e.Handled = $true
    })
} catch { }

# ---------------------------------------------------------------------------
#  3. 色板与主题（像素粉系，取自网页版设计令牌）
# ---------------------------------------------------------------------------
$script:PaletteLight = [ordered]@{
    Backdrop     = '#EFD7D4'   # 窗口外圈
    Chrome       = '#F2C9C6'   # 标题栏
    ChromeDeep   = '#E9AEAE'   # 标题栏渐变末端
    Panel        = '#F7DEDB'   # 主面板底
    Card         = '#FFFDF7'   # 卡片/格子
    CardAlt      = '#FDF6E9'   # 表头/次级底
    Border       = '#7D4550'   # 描边主色
    BorderSoft   = '#F2C9C6'
    Ink          = '#3A2F2C'   # 主文字
    InkSoft      = '#6D5C58'   # 次级文字
    InkFaint     = '#9A8884'   # 弱化文字
    AccentEvent  = '#C05A6C'   # 事件/主按钮
    AccentFocus  = '#F2B083'   # 今日/专注
    AccentTask   = '#9FC4A4'   # 任务卡
    AccentTaskD  = '#7EA886'
    Weekend      = '#FBEAEA'   # 周末底
    WeekendHead  = '#F2C9C6'
    Holiday      = '#E08A8A'   # 节假日
    HolidayRib   = '#DC9494'
    TodayInk     = '#4A2F16'   # 今日格文字
    Ring         = '#E8B93F'   # 番茄钟环
    OnAccent     = '#FFFFFF'   # 强调色按钮上的文字
    Shadow       = '#C47F85'
}
$script:PaletteNight = [ordered]@{
    Backdrop     = '#1B1318'
    Chrome       = '#4A333D'
    ChromeDeep   = '#3A2831'
    Panel        = '#35262E'
    Card         = '#241A20'
    CardAlt      = '#2C2028'
    Border       = '#E8C6CF'
    BorderSoft   = '#4D3742'
    Ink          = '#F4E9EC'
    InkSoft      = '#CDB6BD'
    InkFaint     = '#A08C93'
    AccentEvent  = '#D4718A'
    AccentFocus  = '#C98A56'
    AccentTask   = '#6F9A78'
    AccentTaskD  = '#8FB897'
    Weekend      = '#3A262C'
    WeekendHead  = '#3E2C35'
    Holiday      = '#C9707A'
    HolidayRib   = '#6B4A58'
    TodayInk     = '#F4E1C8'
    Ring         = '#C9A24A'
    OnAccent     = '#1A1116'
    Shadow       = '#150E12'
}
$script:Theme = 'light'

function Get-Pal { param([string]$Key)
    if ($script:Theme -eq 'night') { return $script:PaletteNight[$Key] }
    return $script:PaletteLight[$Key]
}
function Brush { param([string]$Hex)
    $b = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze()
    return $b
}
function Col { param([string]$Hex)
    return [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
}

# ---------------------------------------------------------------------------
#  4. 默认设置
# ---------------------------------------------------------------------------
$script:Settings = [ordered]@{
    Theme          = 'light'
    View           = 'month'
    WindowWidth    = 1080
    WindowHeight   = 720
    WindowLeft     = -1
    WindowTop     = -1
    Topmost        = $false
    PomodoroMin    = 25
    PomodoroEnabled = $true
    PomodoroTask   = ''
    BreakEnabled   = $true
    BreakMin       = 5
    AvatarPath     = ''
    FocusTodayMin  = 456     # 演示值，接真实统计后替换
    WeekStartHour  = 0       # 周视图时段范围（整点，0..23）
    WeekEndHour    = 24      # 周视图时段范围（整点，1..24）
    # Focus 浮窗的位置记忆（-1 = 没存过，首次打开居中到主窗口）。
    # 存这里而不是每次重算：那个窗是"要一直开着看倒计时"的工具，
    # 每次打开都回到屏幕正中、还得再拖一次，是它最烦人的一点。
    FocusWinLeft   = -1
    FocusWinTop    = -1
}

function Load-Settings {
    if (-not (Test-Path -LiteralPath $script:SettingsFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $obj = ConvertFrom-Json $raw
        foreach ($k in @($script:Settings.Keys)) {
            if ($obj.PSObject.Properties.Name -contains $k) {
                $script:Settings[$k] = $obj.$k
            }
        }
    } catch { Write-ErrLog ('Load-Settings: ' + $_.Exception.Message) }
}
function Save-Settings {
    if ($script:SuppressSave) { return }
    try {
        ($script:Settings | ConvertTo-Json -Depth 4) |
            Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    } catch { Write-ErrLog ('Save-Settings: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------
#  5. 数据模型
#    event: id / date(yyyy-MM-dd) / start(分钟) / end(分钟) / title / tag / note / done
#    task : id / text / done / due / tag
# ---------------------------------------------------------------------------
$script:Events = New-Object System.Collections.ArrayList
$script:Tasks  = New-Object System.Collections.ArrayList

function New-Id { return [guid]::NewGuid().ToString('N').Substring(0, 10) }

# 节假日为演示数据，接真实来源时替换此表
$script:Holidays = @{
    '2026-09-25' = '中秋节'
    '2026-10-01' = '国庆节'
    '2026-10-02' = '国庆假期'
    '2026-10-03' = '国庆假期'
}

function Seed-Data {
    $y = 2026; $m = 9
    $mk = {
        param($d, $sh, $sm, $eh, $em, $title, $tag, $done)
        [pscustomobject]@{
            id = (New-Id); date = ('{0:0000}-{1:00}-{2:00}' -f $y, $m, $d)
            start = ($sh * 60 + $sm); end = ($eh * 60 + $em)
            title = $title; tag = $tag; note = ''; done = [bool]$done
            repeat = 'none'; repeatEvery = 1; repeatUntil = ''; repeatMonthMode = 'day'
            reminderMin = 0; reminderKey = ''
        }
    }
    $seed = @(
        (& $mk 2 2 0 3 0 'Morning run' 'focus' $false),
        (& $mk 3 2 0 3 0 'Deep work' 'focus' $false),
        (& $mk 4 2 0 3 0 'Morning run' 'focus' $false),
        (& $mk 2 7 30 9 0 'Team Meeting' 'work' $false),
        (& $mk 3 7 30 9 0 'Team Meeting' 'work' $false),
        (& $mk 5 7 30 9 0 'Team Meeting' 'work' $false),
        (& $mk 2 10 0 11 0 'Design Review' 'work' $false),
        (& $mk 3 10 0 11 0 'Design Review' 'work' $false),
        (& $mk 4 10 0 11 0 'Design Review' 'work' $false),
        (& $mk 2 12 0 13 0 'Lunch' 'life' $false),
        (& $mk 3 12 0 13 0 'Lunch' 'life' $false),
        (& $mk 4 12 0 13 0 'Lunch' 'life' $false),
        (& $mk 5 12 0 13 0 'Lunch' 'life' $false),
        (& $mk 4 15 0 16 30 'Project Sync' 'work' $false),
        (& $mk 5 15 0 16 30 'Project Sync' 'work' $false),
        (& $mk 4 18 0 19 30 'Yoga Class' 'life' $false),
        (& $mk 23 9 0 10 0 'Ideation' 'work' $true),
        (& $mk 23 14 0 15 0 'Thesis draft' 'focus' $true),
        (& $mk 23 16 30 17 30 'Reading group' 'work' $false),
        (& $mk 24 11 0 12 0 'Advisor call' 'work' $false),
        (& $mk 26 9 0 12 0 'Weekend lab' 'focus' $false),
        (& $mk 28 13 0 15 0 'Paper revision' 'focus' $false)
    )
    foreach ($e in $seed) { [void]$script:Events.Add($e) }

    $tk = @(
        [pscustomobject]@{ id = (New-Id); text = 'Task and task-sheet description tasks'; done = $false; due = $null; dueTime = '09:00'; tag = 'task'; priority = 'medium'; project = 'Inbox'; subtasks = @(); estimatedMin = 45; actualMin = 0; reminderMin = 10 },
        [pscustomobject]@{ id = (New-Id); text = 'Task production staff for compiling'; done = $false; due = $null; dueTime = '09:00'; tag = 'task'; priority = 'high'; project = 'Work'; subtasks = @(); estimatedMin = 90; actualMin = 0; reminderMin = 10 },
        [pscustomobject]@{ id = (New-Id); text = '整理本周会议纪要'; done = $true; due = '2026-09-23'; dueTime = '09:00'; tag = 'task'; priority = 'medium'; project = 'Work'; subtasks = @(); estimatedMin = 30; actualMin = 25; reminderMin = 10 },
        [pscustomobject]@{ id = (New-Id); text = '提交读书报告终稿'; done = $false; due = '2026-09-26'; dueTime = '18:00'; tag = 'task'; priority = 'high'; project = 'Study'; subtasks = @(); estimatedMin = 120; actualMin = 0; reminderMin = 15 }
    )
    foreach ($t in $tk) { [void]$script:Tasks.Add($t) }
}

function Load-Data {
    $script:Events.Clear(); $script:Tasks.Clear()
    if (Test-Path -LiteralPath $script:DataFile) {
        try {
            $raw = Get-Content -LiteralPath $script:DataFile -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = ConvertFrom-Json $raw
                foreach ($e in @($obj.events)) {
                    if ($null -eq $e) { continue }
                    [void]$script:Events.Add([pscustomobject]@{
                        id    = [string]$e.id
                        date  = [string]$e.date
                        start = [int]$e.start
                        end   = [int]$e.end
                        title = [string]$e.title
                        tag   = [string]$e.tag
                        note  = [string]$e.note
                        done  = [bool]$e.done
                        repeat = $(if ($e.PSObject.Properties.Name -contains 'repeat') { [string]$e.repeat } else { 'none' })
                        repeatEvery = $(if ($e.PSObject.Properties.Name -contains 'repeatEvery') { [int]$e.repeatEvery } else { 1 })
                        repeatUntil = $(if ($e.PSObject.Properties.Name -contains 'repeatUntil') { [string]$e.repeatUntil } else { '' })
                        repeatMonthMode = $(if ($e.PSObject.Properties.Name -contains 'repeatMonthMode') { [string]$e.repeatMonthMode } else { 'day' })
                        reminderMin = $(if ($e.PSObject.Properties.Name -contains 'reminderMin') { [int]$e.reminderMin } else { 0 })
                        reminderKey = $(if ($e.PSObject.Properties.Name -contains 'reminderKey') { [string]$e.reminderKey } else { '' })
                    })
                }
                foreach ($t in @($obj.tasks)) {
                    if ($null -eq $t) { continue }
                    $due = $null
                    if ($t.PSObject.Properties.Name -contains 'due' -and -not [string]::IsNullOrWhiteSpace([string]$t.due)) {
                        $due = [string]$t.due
                    }
                    $subtasks = @()
                    if ($t.PSObject.Properties.Name -contains 'subtasks' -and $null -ne $t.subtasks) {
                        foreach ($st in @($t.subtasks)) {
                            $subtasks += [pscustomobject]@{
                                id = $(if ($st.PSObject.Properties.Name -contains 'id') { [string]$st.id } else { New-Id })
                                text = [string]$st.text
                                done = $(if ($st.PSObject.Properties.Name -contains 'done') { [bool]$st.done } else { $false })
                            }
                        }
                    }
                    [void]$script:Tasks.Add([pscustomobject]@{
                        id = [string]$t.id; text = [string]$t.text
                        done = [bool]$t.done; due = $due; tag = [string]$t.tag
                        priority = $(if ($t.PSObject.Properties.Name -contains 'priority') { [string]$t.priority } else { 'medium' })
                        project = $(if ($t.PSObject.Properties.Name -contains 'project') { [string]$t.project } else { '' })
                        subtasks = $subtasks
                        estimatedMin = $(if ($t.PSObject.Properties.Name -contains 'estimatedMin') { [int]$t.estimatedMin } else { 0 })
                        actualMin = $(if ($t.PSObject.Properties.Name -contains 'actualMin') { [int]$t.actualMin } else { 0 })
                        dueTime = $(if ($t.PSObject.Properties.Name -contains 'dueTime') { [string]$t.dueTime } else { '09:00' })
                        reminderMin = $(if ($t.PSObject.Properties.Name -contains 'reminderMin') { [int]$t.reminderMin } else { 0 })
                    })
                }
                return
            }
        } catch { Write-ErrLog ('Load-Data: ' + $_.Exception.Message) }
    }
    Seed-Data
    Save-Data
}

function Save-Data {
    if ($script:SuppressSave) { return }
    try {
        $payload = [pscustomobject]@{
            events = @($script:Events)
            tasks  = @($script:Tasks)
        }
        ($payload | ConvertTo-Json -Depth 6) |
            Set-Content -LiteralPath $script:DataFile -Encoding UTF8
    } catch { Write-ErrLog ('Save-Data: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------
#  6. 日期工具
# ---------------------------------------------------------------------------
function Fmt-Date { param([datetime]$D) return $D.ToString('yyyy-MM-dd') }
function Parse-Date { param([string]$S) return [datetime]::ParseExact($S, 'yyyy-MM-dd', $null) }
function Add-Days { param([datetime]$D, [int]$N) return $D.AddDays($N) }
function Start-Of-Week { param([datetime]$D)
    $dow = ([int]$D.DayOfWeek + 6) % 7      # 周一 = 0
    return $D.AddDays(-$dow).Date
}
function Same-Day { param([datetime]$A, [datetime]$B)
    return ($A.Year -eq $B.Year -and $A.Month -eq $B.Month -and $A.Day -eq $B.Day)
}
function Min-To-HHMM { param([int]$M)
    return ('{0:00}:{1:00}' -f ([math]::Floor($M / 60) % 24), ($M % 60))
}
$script:DowShort = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
$script:DowZh    = @('周一', '周二', '周三', '周四', '周五', '周六', '周日')
$script:MonNames = @('January','February','March','April','May','June','July',
                     'August','September','October','November','December')

function Is-Weekend { param([datetime]$D)
    return ($D.DayOfWeek -eq [System.DayOfWeek]::Saturday -or $D.DayOfWeek -eq [System.DayOfWeek]::Sunday)
}
function Get-Holiday { param([datetime]$D)
    $k = Fmt-Date $D
    # StrictMode 下读不存在的键会抛 PropertyNotFoundException，所以必须判存在再取 ——
    # 但 $script:Holidays 是 OrderedDictionary，只有 Contains 没有 ContainsKey
    # （写 ContainsKey 会抛"不包含名为 ContainsKey 的方法"）。这行以前写错过。
    if ($script:Holidays.Contains($k)) { return $script:Holidays[$k] }
    return $null
}
function Test-EventOccursOn {
    param($Event, [datetime]$Date)
    if ($null -eq $Event) { return $false }
    $origin = Parse-Date ([string]$Event.date)
    if ($Date.Date -lt $origin.Date) { return $false }
    $repeat = 'none'
    if ($Event.PSObject.Properties.Name -contains 'repeat') { $repeat = [string]$Event.repeat }
    if ([string]::IsNullOrWhiteSpace($repeat)) { $repeat = 'none' }
    if ($repeat -eq 'none') { return (Same-Day $origin $Date) }
    $untilRaw = ''
    if ($Event.PSObject.Properties.Name -contains 'repeatUntil') { $untilRaw = [string]$Event.repeatUntil }
    if (-not [string]::IsNullOrWhiteSpace($untilRaw)) {
        try { if ($Date.Date -gt (Parse-Date $untilRaw).Date) { return $false } } catch { }
    }
    $every = 1
    if ($Event.PSObject.Properties.Name -contains 'repeatEvery') { $every = [math]::Max(1, [int]$Event.repeatEvery) }
    if ($repeat -eq 'daily') {
        return (([int]($Date.Date - $origin.Date).TotalDays % $every) -eq 0)
    }
    if ($repeat -eq 'weekly') {
        if ($Date.DayOfWeek -ne $origin.DayOfWeek) { return $false }
        $days = [int]($Date.Date - $origin.Date).TotalDays
        return (([math]::Floor($days / 7.0) % $every) -eq 0)
    }
    if ($repeat -eq 'monthly') {
        $months = (($Date.Year - $origin.Year) * 12) + ($Date.Month - $origin.Month)
        if ($months -lt 0 -or ($months % $every) -ne 0) { return $false }
        $mode = 'day'
        if ($Event.PSObject.Properties.Name -contains 'repeatMonthMode') { $mode = [string]$Event.repeatMonthMode }
        if ($mode -eq 'last') {
            return ($Date.Day -eq [datetime]::DaysInMonth($Date.Year, $Date.Month))
        }
        $day = [math]::Min($origin.Day, [datetime]::DaysInMonth($Date.Year, $Date.Month))
        return ($Date.Day -eq $day)
    }
    return $false
}

function New-EventOccurrence {
    param($Event, [datetime]$Date)
    return [pscustomobject]@{
        id = [string]$Event.id
        date = (Fmt-Date $Date)
        start = [int]$Event.start
        end = [int]$Event.end
        title = [string]$Event.title
        tag = [string]$Event.tag
        note = [string]$Event.note
        done = [bool]$Event.done
        repeat = $(if ($Event.PSObject.Properties.Name -contains 'repeat') { [string]$Event.repeat } else { 'none' })
        repeatEvery = $(if ($Event.PSObject.Properties.Name -contains 'repeatEvery') { [int]$Event.repeatEvery } else { 1 })
        repeatUntil = $(if ($Event.PSObject.Properties.Name -contains 'repeatUntil') { [string]$Event.repeatUntil } else { '' })
        repeatMonthMode = $(if ($Event.PSObject.Properties.Name -contains 'repeatMonthMode') { [string]$Event.repeatMonthMode } else { 'day' })
        reminderMin = $(if ($Event.PSObject.Properties.Name -contains 'reminderMin') { [int]$Event.reminderMin } else { 0 })
        occurrence = $true
    }
}

function Events-On { param([datetime]$D)
    $hits = New-Object System.Collections.ArrayList
    foreach ($e in @($script:Events)) {
        if ($null -eq $e) { continue }
        if (Test-EventOccursOn $e $D) { [void]$hits.Add((New-EventOccurrence $e $D)) }
    }
    return @($hits.ToArray() | Sort-Object -Property start)
}

function Occurrences-Between {
    param([datetime]$Start, [datetime]$End)
    $out = New-Object System.Collections.ArrayList
    $d = $Start.Date
    while ($d.Date -le $End.Date) {
        foreach ($e in @(Events-On $d)) { [void]$out.Add($e) }
        $d = $d.AddDays(1)
    }
    return @($out.ToArray())
}
function Month-Grid { param([datetime]$Anchor)
    $first = [datetime]::new($Anchor.Year, $Anchor.Month, 1)
    $gs = Start-Of-Week $first
    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt 42; $i++) { [void]$out.Add($gs.AddDays($i)) }
    return @($out)
}
function Week-Days { param([datetime]$Anchor)
    $s = Start-Of-Week $Anchor
    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt 7; $i++) { [void]$out.Add($s.AddDays($i)) }
    return @($out)
}

# ---------------------------------------------------------------------------
#  7. 状态
# ---------------------------------------------------------------------------
$script:View       = $StartView
$script:Anchor     = [datetime]::Today
$script:Selected   = [datetime]::Today
$script:NightMode  = $false
$script:SuppressSave = $false
$script:TopmostOn  = $false
$script:Pomo = [pscustomobject]@{
    Remaining = 25 * 60
    Running   = $false
    Total     = 25 * 60
    Task      = ''
    TaskId    = ''
    Mode      = 'focus'
}
$script:NotifiedKeys = @{}
$script:LastNotification = ''
$script:ReminderTimer = $null
$script:NavUserCollapsed = $false
$script:ResponsiveHooked = $false
$script:FocusWindowOpen = $false
$script:AvatarWindowOpen = $false

$script:MainWindow = $null
$script:NodeHost   = $null      # 视图宿主（三视图挂在这里）
$script:UiOverlay  = $null      # 覆盖层（遮罩），在 ViewHost 之上；目前只用于禁用底层点击
$script:OverlayOpen = ''        # '' / 非空表示覆盖层开着
$script:ViewWrap   = $null
$script:Skeleton   = $false     # 骨架屏模式：只出结构，不建事件与数据
$script:AllowClose = $false
$script:CloseToTray = $false
$script:TrayIcon   = $null
$script:PomoTimer  = $null
$script:WindowClosed = $false
$script:App        = $null      # Application 实例（消息循环那段才创建）
$script:TraceOn    = [bool]$Trace

# ---------------------------------------------------------------------------
#  7b. 惰性创建的界面状态——必须在根作用域显式初始化
#
#  为什么必须写在这里：
#    本程序开着 Set-StrictMode -Version 2.0，**读取一个从未赋值的变量会直接抛
#    PropertyNotFoundException**，而不是像普通模式那样安静地得到 $null。
#    这些变量原本只在各自的渲染函数里赋值（如 ListSearch 只在 Render-List 里建），
#    但 Refresh-All 会在"还没渲染列表"的情况下读它们做判空——
#    月视图启动时 $null 判断根本走不到，先抛异常。
#    统一在根作用域置初值后，判空才是真的判空。
# ---------------------------------------------------------------------------
$script:ListStack    = $null    # 列表视图：事件行容器
$script:TaskStack    = $null    # 任务视图：任务行容器
$script:ListSearch   = $null    # 列表视图：搜索框
$script:ListSearchHint = $null  # 列表视图：搜索框的占位提示文字（叠在框里的 TextBlock）
$script:ListTagBox   = $null    # 列表视图：标签筛选下拉
$script:ListScopeBox = $null    # 列表视图：范围筛选下拉
$script:TaskOpenText = $null    # 任务视图：计数文字
$script:TaskPanelCollapsed = $false   # 已退休（任务面板不再是可折叠侧栏），保留给旧调用
$script:TaskScroll = $null
$script:TaskAddButton = $null
$script:TaskPanelTitle = $null
$script:TaskProjectBox = $null  # 任务视图：项目筛选
$script:TaskFilterRow = $null
$script:TaskStatusBox = $null   # 任务视图：状态筛选（All / Open / Done）
$script:TaskScopeBox  = $null   # 任务视图：时间范围筛选
$script:TaskSortBox   = $null   # 任务视图：排序键
$script:TaskSearch    = $null   # 任务视图：标题搜索框
$script:TaskSearchHint = $null  # 任务视图：搜索框的占位提示文字（叠在框里的 TextBlock）
$script:TaskCardWide  = $false  # 任务卡是否用宽版式（只有 Tasks 视图是）
# 双击展开的那张任务卡的 id（'' = 全部收起）。Editor / Del 都在展开面板里，
# 所以这个状态必须活到下一次 Fill-Tasks —— 放 $script: 里而不是处理器局部。
$script:TaskExpandedId = ''
$script:TaskDragId = ''
$script:TaskDragPoint = $null
# 手工 RaiseEvent 造不出真实的双击，ClickCount 只能靠这个旁路变量带进来
# （见 Get-MouseClickCount / Invoke-MouseUp 的注释）。正常运行时恒为 $null。
$script:SyntheticClickCount = $null
# 手工事件里"被点的子元素"同样带不进去：MouseLeftButtonUp 是 Direct 路由（不冒泡），
# 只能在"挂了处理器的祖先"上 RaiseEvent，再用 Source 指明子元素 —— 而
# RoutedEventArgs.Source 写进去之后 OriginalSource 并不保证就等于它。
# 所以子元素也走旁路传进来，由 Get-EventSourceOf 优先读取。
# 真实鼠标输入时它恒为 $null，处理器仍读 $e.OriginalSource，行为完全不变。
$script:SyntheticEventSource = $null
# 任务卡"单击=勾选完成"的待办 id 与延时器。
# 双击的第一下也是 ClickCount=1，若立刻勾选，卡片会在第二下到达之前就从
# "未完成"筛选里消失 —— 用户看到的现象就是"双击一下任务，它不见了"。
# 所以单击先记下来，等双击窗口过去再落地；第二下 ClickCount=2 会把它取消。
$script:PendingTaskId = ''
$script:TaskClickTimer = $null
$script:WeekCanvas   = $null    # 周视图：时间网格画布
$script:WeekOverlay  = $null    # 周视图：事件层
$script:WeekScroll   = $null    # 周视图：滚动容器
$script:WeekDays     = @()      # 周视图：当前展示的 7 天
$script:WeekEvents   = @()
$script:WeekDrag     = $null  # 周视图拖动状态
$script:WeekCreate   = $null  # 周视图空白区拖动创建状态      # 周视图：当前展示的事件
$script:HourHeight   = 34.0     # 周视图：每小时像素高（布局算术用，不能为 $null）
$script:WeekGutter   = 54.0     # 周视图：时间列宽
$script:WeekAxis     = $null    # 周视图：时间轴层（刻度/列底/横线）
$script:WkRangeBox   = $null    # 周视图：时段范围下拉
$script:WkStartBox   = $null    # 周视图：自定义起始小时
$script:WkEndBox     = $null    # 周视图：自定义结束小时
$script:WkSuppress   = $false   # 范围控件回填期间的重入锁
$script:PomoRingSize = 46.0     # 遗留：侧栏圆环已删（第三轮），仅 Update-PomodoroVisual 的
                                # "圆环万一回来"分支还会读它，保留以免判空分支里出现未定义变量
# 月视图：本页布局的"账本"（Render-Month 每画一次就重写一份）
#   MonthDaysShown = 按格子顺序记下显示的"日"（本月之外的空位记 0）
#   MonthPadDates  = 补位格（相邻月份的浅色日号）的日期，'yyyy-MM-dd' 升序
#   MonthPageInfo  = Rows/Offset/Days/Pads，供审计核对行数、留空位置与补位格数量
$script:MonthGridRoot  = $null
$script:MonthDaysShown = @()
$script:MonthPadDates  = @()
$script:MonthPageInfo  = $null
$script:DlgClosed      = ''     # 审计用：弹窗 Closed 事件的落点（处理器里只能写 $script:）
$script:EdTag        = 'work'   # 编辑器：当前选中的标签
$script:FoWin        = $null
$script:FoEnabled    = $null
$script:FoTbDuration = $null
$script:FoTbTask     = $null
$script:FoErr        = $null
$script:FoTimeText   = $null
$script:FoStatusText = $null
$script:FoStartText  = $null
$script:FoTaskText   = $null
$script:DragWin      = $null   # 可拖动浮窗的句柄（处理器里只能读 $script:）
$script:DragPosKey   = ''      # 它的位置记忆键
$script:FoBreakEnabled = $null
$script:FoBreakMin   = $null
$script:AvWin        = $null
$script:AvPreviewImage = $null
$script:AvPreviewCanvas = $null
$script:AvPreviewHint = $null
$script:AvDraftPath  = ''
$script:TkWin        = $null
$script:TkText       = $null
$script:TkDue        = $null
$script:TkTag        = $null
$script:TkDone       = $null
$script:TkErr        = $null
$script:TkEditing    = $false
$script:TkTask       = $null
$script:TkPriority   = $null
$script:DayAgendaWin = $null
$script:DayAgendaDate = [datetime]::Today
$script:TkProject    = $null
$script:TkEstimated  = $null
$script:TkActual     = $null
$script:TkDueTime    = $null
$script:TkReminder   = $null
$script:TkSubtasks   = $null
$script:TkSubtaskStack = $null
$script:TkNewSubtask = $null
# 编辑器标签芯片：按钮表与配色表。必须挂 $script:，因为芯片的 Click 回调触发时
# 建它的那个函数作用域已经销毁，回调里只能看见 $script: 和形参。见 Views2.ps1。
$script:EdTagButtons = $null
$script:EdTagColors  = $null
$script:EdTagSavedOk = $false   # 交互自查：编辑窗口"保存"是否真的走通
# 独立窗口的控件句柄：编辑窗口 / 设置窗口的处理器要用，所以必须挂在 $script:
# （处理器触发时建窗口的那个函数早已返回，局部变量取不到，StrictMode 下直接抛）
$script:EdWin     = $null
$script:EdTbTitle = $null
$script:EdTbDate  = $null
$script:EdTbStart = $null
$script:EdTbEnd   = $null
$script:EdErr     = $null
$script:EdRepeat  = $null
$script:EdEvery   = $null
$script:EdUntil   = $null
$script:EdMonthLast = $null
$script:EdReminder = $null
$script:EdEditing = $false
$script:EdEv      = $null
$script:SetWin    = $null
$script:SetTbPomo = $null
# 延迟回调（DispatcherTimer / 关闭钩子）里会读到的变量，一律必须是 $script: 作用域，
# 因为回调触发时"创建它的那个作用域"可能已经销毁了。见文件内各处注释。
$script:AutoCloseTimer = $null
$script:ToastWindow    = $null
$script:ToastTimer      = $null
# 交互自查专用：为 $true 时，会弹模态窗口的动作只记录不真弹（否则 ShowDialog 会卡死调度器）。
$script:SuppressModal  = $false
$script:LastModalCall  = ''
$script:DragArmed    = $false   # 标题栏拖动状态
$script:Rebuilding   = $false   # Set-Theme 重建内容期间为 true
$script:LifecycleHooked = $false # 生命周期钩子只挂一次（换皮不换窗）

# ---------------------------------------------------------------------------
#  8. 启动
# ---------------------------------------------------------------------------
$script:Theme = 'light'
Load-Settings

# 主题/视图/置顶覆盖（测试与快捷启动用；覆盖值不落盘）
$script:ThemeOverrideApplied = $false
if ($ThemeOverride) {
    $script:Theme = $ThemeOverride
    $script:SuppressSave = $true
    $script:ThemeOverrideApplied = $true
} elseif ($script:Settings['Theme'] -eq 'night') {
    $script:Theme = 'night'
    $script:NightMode = $true
}
if ($PSBoundParameters.ContainsKey('StartView')) { $script:View = $StartView }
if (-not [string]::IsNullOrWhiteSpace($SizeOverride) -and $SizeOverride -match '^(\d+)x(\d+)$') {
    $script:Settings['WindowWidth'] = [int]$Matches[1]
    $script:Settings['WindowHeight'] = [int]$Matches[2]
}
$script:TopmostOn = [bool]$script:Settings['Topmost']

$script:Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# 分片加载：默认用点源，保持脚本作用域语义。
# 但 Windows 客户端默认执行策略是 Restricted，点源会被 PSSecurityException 拒绝，
# 这里退化为「读取源码后以 scriptblock 执行」——同样落在当前脚本作用域，语义等价，
# 保证工具在未显式放行脚本策略的机器上也能启动。
foreach ($part in @('Ui.ps1', 'Views.ps1', 'Views2.ps1', 'Care.ps1')) {
    $p = Join-Path $script:Root $part
    if (-not (Test-Path -LiteralPath $p)) { throw "缺少文件：$p" }
    try {
        . $p
    } catch {
        $ex = $null; $fq = ''
        try { $ex = $_.Exception } catch { }
        try { $fq = [string]$_.FullyQualifiedErrorId } catch { }
        $isPolicy = ($ex -is [System.Management.Automation.PSSecurityException]) -or ($fq -like '*PSSecurityException*')
        if (-not $isPolicy) { throw }
        Write-ErrLog ('POLICY-FALLBACK: ' + $part + ' | ' + $fq)
        # 必须用「点源 scriptblock」而不是 Invoke-Expression：
        # Invoke-Expression 会让分片内嵌套的 scriptblock 字面量绑到别的作用域，
        # 事件处理器里的 $script:xxx 就会读错变量桶（StrictMode 下直接抛异常）。
        . ([scriptblock]::Create([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)))
    }
    Write-Trace ('part loaded: ' + $part)
}

# 覆盖层编辑器已被独立窗口取代，这里显式收掉，避免误用旧版本
function Open-EventEditor {
    param([string]$Id = '', [string]$PrefillDate = '', [int]$PrefillStart = -1, [int]$PrefillEnd = -1)
    if ($Skeleton) { return }
    if ($script:SuppressModal) { $script:LastModalCall = 'editor:' + $Id; return }
    try {
        $win = Show-EventEditorWindow -Id $Id -PrefillDate $PrefillDate -PrefillStart $PrefillStart -PrefillEnd $PrefillEnd
        $win.ShowDialog() | Out-Null
    } catch { Write-ErrLog ('Open-EventEditor: ' + $_.Exception.Message) }
}

function Open-StatsPanel {
    if ($Skeleton) { return }
    if ($script:SuppressModal) { $script:LastModalCall = 'stats'; return }
    try {
        $win = Show-SettingsWindow
        $win.ShowDialog() | Out-Null
    } catch { Write-ErrLog ('Open-StatsPanel: ' + $_.Exception.Message) }
}

function Open-FocusPanel {
    if ($Skeleton) { return }
    if ($script:SuppressModal) { $script:LastModalCall = 'focus'; return }
    if ($script:FocusWindowOpen) { return }
    try {
        $script:FocusWindowOpen = $true
        $win = Show-FocusWindow
        $win.ShowDialog() | Out-Null
    } catch { Write-ErrLog ('Open-FocusPanel: ' + $_.Exception.Message) }
    finally { $script:FocusWindowOpen = $false }
}

function Duplicate-Event {
    param([string]$Id)
    $hit = @($script:Events | Where-Object { [string]$_.id -eq [string]$Id })
    if ($hit.Count -eq 0) { return }
    $src = $hit[0]
    [void]$script:Events.Add([pscustomobject]@{
        id = (New-Id); date = [string]$src.date; start = [int]$src.start; end = [int]$src.end
        title = [string]$src.title + ' copy'; tag = [string]$src.tag; note = [string]$src.note; done = $false
        repeat = [string]$src.repeat; repeatEvery = [int]$src.repeatEvery; repeatUntil = [string]$src.repeatUntil
        repeatMonthMode = [string]$src.repeatMonthMode; reminderMin = [int]$src.reminderMin; reminderKey = ''
    })
    Save-Data
    Refresh-All
}

function Remove-Event {
    param([string]$Id)
    $hit = @($script:Events | Where-Object { [string]$_.id -eq [string]$Id })
    if ($hit.Count -eq 0) { return }
    if (-not $script:SuppressModal -and -not $TestMode) {
        $answer = [System.Windows.MessageBox]::Show('Delete this event?', 'Schedule',
            [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    [void]$script:Events.Remove($hit[0])
    Save-Data
    Refresh-All
}

function Open-DayAgenda {
    param([datetime]$Date)
    if ($Skeleton) { return }
    if ($script:SuppressModal) { $script:LastModalCall = 'dayagenda:' + (Fmt-Date $Date); return }
    try {
        $win = Show-DayAgendaWindow -Date $Date
        $win.ShowDialog() | Out-Null
    } catch { Write-ErrLog ('Open-DayAgenda: ' + $_.Exception.Message) }
}

function Open-TaskEditor {
    param([string]$Id = '')
    if ($Skeleton) { return }
    if ($script:SuppressModal) { $script:LastModalCall = 'taskeditor:' + $Id; return }
    try {
        $win = Show-TaskEditorWindow -Id $Id
        $win.ShowDialog() | Out-Null
    } catch { Write-ErrLog ('Open-TaskEditor: ' + $_.Exception.Message) }
}

function Remove-Task {
    param([string]$Id)
    $hit = @($script:Tasks | Where-Object { [string]$_.id -eq [string]$Id })
    if ($hit.Count -eq 0) { return }
    if (-not $script:SuppressModal -and -not $TestMode) {
        $answer = [System.Windows.MessageBox]::Show(
            'Delete this task?' + [Environment]::NewLine + [Environment]::NewLine + [string]$hit[0].text,
            'My Schedule', [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    [void]$script:Tasks.Remove($hit[0])
    Save-Data
    Fill-Tasks
}

function Move-Task {
    param([string]$SourceId, [string]$TargetId)
    if ([string]::IsNullOrWhiteSpace($SourceId) -or [string]::IsNullOrWhiteSpace($TargetId) -or $SourceId -eq $TargetId) { return }
    $src = @($script:Tasks | Where-Object { [string]$_.id -eq $SourceId })
    if ($src.Count -eq 0) { return }
    $targetIndex = -1
    for ($i = 0; $i -lt $script:Tasks.Count; $i++) {
        if ([string]$script:Tasks[$i].id -eq $TargetId) { $targetIndex = $i; break }
    }
    if ($targetIndex -lt 0) { return }
    [void]$script:Tasks.Remove($src[0])
    $targetIndex = [math]::Min($targetIndex, $script:Tasks.Count)
    $script:Tasks.Insert($targetIndex, $src[0])
    Save-Data
    Fill-Tasks
}

function Start-FocusForTask {
    param([string]$Id)
    $hit = @($script:Tasks | Where-Object { [string]$_.id -eq [string]$Id })
    if ($hit.Count -eq 0) { return }
    $script:Settings['PomodoroEnabled'] = $true
    $script:Settings['PomodoroTask'] = [string]$hit[0].text
    $script:Pomo.Task = [string]$hit[0].text
    $script:Pomo.TaskId = [string]$hit[0].id
    Save-Settings
    Reset-Pomodoro
    Toggle-Pomodoro
    Show-Toast -Title 'Focus started' -Text ([string]$hit[0].text)
}

function Postpone-Task {
    param([string]$Id)
    $hit = @($script:Tasks | Where-Object { [string]$_.id -eq [string]$Id })
    if ($hit.Count -eq 0) { return }
    $base = [datetime]::Today
    if ($null -ne $hit[0].due -and -not [string]::IsNullOrWhiteSpace([string]$hit[0].due)) {
        try { $base = Parse-Date ([string]$hit[0].due) } catch { $base = [datetime]::Today }
    }
    if ($base.Date -lt [datetime]::Today) { $base = [datetime]::Today }
    $hit[0].due = Fmt-Date ($base.AddDays(1))
    if ($hit[0].PSObject.Properties.Name -notcontains 'dueTime' -or [string]::IsNullOrWhiteSpace([string]$hit[0].dueTime)) {
        $hit[0].dueTime = '09:00'
    }
    Save-Data
    Fill-Tasks
}

function Open-AvatarPanel {
    if ($Skeleton) { return }
    if ($script:SuppressModal) { $script:LastModalCall = 'avatar'; return }
    if ($script:AvatarWindowOpen) { return }
    try {
        $script:AvatarWindowOpen = $true
        $win = Show-AvatarWindow
        $win.ShowDialog() | Out-Null
    } catch { Write-ErrLog ('Open-AvatarPanel: ' + $_.Exception.Message) }
    finally { $script:AvatarWindowOpen = $false }
}

Load-Data
Write-Trace 'Load-Data ok'

# ---- 界面 ----
$script:Skeleton = $Skeleton
Build-Window
Write-Trace 'Build-Window ok'

# 番茄钟要先等界面建好（它要读 Focus 浮窗的 FoTimeText 等；侧栏圆环已删）
Reset-Pomodoro
Write-Trace 'Reset-Pomodoro ok'

# -ThemeOverride / -StartView 只影响本次运行
if ($script:ThemeOverrideApplied) { $script:SuppressSave = $true }

# ---- 托盘 ----
if (-not $Skeleton -and -not $TestMode) {
    try {
        $script:TrayIcon = New-TrayIcon
    } catch { Write-ErrLog ('Tray: ' + $_.Exception.Message) }
}
if (-not $Skeleton) {
    $script:MainWindow.Add_Closed({
        try {
            if ($null -ne $script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() }
            $script:App.Shutdown()
        } catch { }
    })
}

# ---- 测试钩子 ----
# ---------------------------------------------------------------------------
#  交互自查（-Script audit）
#
#  为什么必须走 RaiseEvent 而不是直接调函数：
#    "按钮点了没反应"的根因几乎只有两类——处理器根本没挂上，或者处理器跑起来时
#    看不到它要用的变量（事件处理器只能在 $script: 作用域里可靠取变量）。
#    直接调函数把这两类问题全绕过去了，等于没测。
#    RaiseEvent 走的是真实路由，等价于真的按了一下。
# ---------------------------------------------------------------------------
function Find-TaggedNode {
    # 递归找 Tag 里 kind 匹配的元素（月格 / 事件 / 任务都靠 Tag 标记）
    param($El, [string]$Kind)
    if ($null -eq $El) { return $null }
    $fe = $El -as [System.Windows.FrameworkElement]
    if ($null -ne $fe) {
        $tag = $fe.Tag
        if ($tag -is [hashtable] -and $tag.ContainsKey('kind') -and [string]$tag['kind'] -eq $Kind) { return $fe }
    }
    $kids = @()
    if ($El -is [System.Windows.Controls.Panel]) { $kids = $El.Children }
    elseif ($El -is [System.Windows.Controls.Decorator]) { $kids = @($El.Child) }
    elseif ($El -is [System.Windows.Controls.ContentControl]) { $kids = @($El.Content) }
    foreach ($k in $kids) {
        $r = Find-TaggedNode $k $Kind
        if ($null -ne $r) { return $r }
    }
    return $null
}

function Find-AllTagged {
    # 收集所有 Tag.kind 匹配的元素（找"今天那一格"需要全量而不是第一个）。
    # 用非泛型 ArrayList + 递归：泛型 List[object] 在这种递归累加场景下容易出类型问题。
    param($El, [string]$Kind, $Acc = $null)
    if ($null -eq $Acc) { $Acc = New-Object System.Collections.ArrayList }
    if ($null -eq $El) { return $Acc.ToArray() }
    $fe = $El -as [System.Windows.FrameworkElement]
    if ($null -ne $fe) {
        $tag = $fe.Tag
        if ($tag -is [hashtable] -and $tag.ContainsKey('kind') -and [string]$tag['kind'] -eq $Kind) {
            [void]$Acc.Add($fe)
            return $Acc.ToArray()
        }
    }
    $kids = @()
    if ($El -is [System.Windows.Controls.Panel]) { $kids = $El.Children }
    elseif ($El -is [System.Windows.Controls.Decorator]) { $kids = @($El.Child) }
    elseif ($El -is [System.Windows.Controls.ContentControl]) { $kids = @($El.Content) }
    foreach ($k in $kids) { [void](Find-AllTagged $k $Kind $Acc) }
    # 返回真数组：ArrayList 交给 @() 不会展开，调用方会拿到"装着一个 ArrayList 的数组"
    return $Acc.ToArray()
}

function Find-AllOfType {
    # 收集同类型元素（编辑窗口里要按"第几个输入框"取控件，第一个不够用）
    param($El, [type]$T, $Acc = $null)
    if ($null -eq $Acc) { $Acc = New-Object System.Collections.ArrayList }
    if ($null -eq $El) { return $Acc.ToArray() }
    if ($T.IsInstanceOfType($El)) { [void]$Acc.Add($El) }
    $kids = @()
    if ($El -is [System.Windows.Controls.Panel]) { $kids = $El.Children }
    elseif ($El -is [System.Windows.Controls.Decorator]) { $kids = @($El.Child) }
    elseif ($El -is [System.Windows.Controls.ContentControl]) { $kids = @($El.Content) }
    foreach ($k in $kids) { [void](Find-AllOfType $k $T $Acc) }
    return $Acc.ToArray()
}

function Find-ButtonByText {
    # 按按钮上的文字找按钮。像素风按钮的 Content 是一个 TextBlock（不是字符串），
    # 所以两边都要兼顾。
    param($El, [string]$Text)
    if ($null -eq $El) { return $null }
    foreach ($b in @(Find-AllOfType $El ([System.Windows.Controls.Primitives.ButtonBase]))) {
        $c = $b.Content
        if ($c -is [System.Windows.Controls.TextBlock]) { $c = $c.Text }
        if ([string]$c -eq $Text) { return $b }
    }
    return $null
}

function Find-FirstOfType {
    param($El, [type]$T)
    if ($null -eq $El) { return $null }
    if ($T.IsInstanceOfType($El)) { return $El }
    $kids = @()
    if ($El -is [System.Windows.Controls.Panel]) { $kids = $El.Children }
    elseif ($El -is [System.Windows.Controls.Decorator]) { $kids = @($El.Child) }
    elseif ($El -is [System.Windows.Controls.ContentControl]) { $kids = @($El.Content) }
    foreach ($k in $kids) {
        $r = Find-FirstOfType $k $T
        if ($null -ne $r) { return $r }
    }
    return $null
}

function Find-DialogClose {
    # 弹窗标题栏右上角的 ×（Name = 'DlgClose'）。
    # 这里必须按 Name 找而不能按文字找：× 里是一段 Path 几何，Content 根本不是文字，
    # Find-ButtonByText 永远返回 $null。
    param($El)
    if ($null -eq $El) { return $null }
    foreach ($b in @(Find-AllOfType $El ([System.Windows.Controls.Primitives.ButtonBase]))) {
        if ([string]$b.Name -eq 'DlgClose') { return $b }
    }
    return $null
}

function Find-DialogButton {
    # 按 Name 找弹窗标题栏上的按钮（'DlgSave' / 'DlgCancel' / 'DlgClose'）。
    # 第四轮标题栏从"只有一个 ×"变成三件套，断言要能分别点它们，
    # 所以把"按 Name 找按钮"抽出来，而不是复制三遍 Find-AllOfType 循环。
    param($El, [string]$Name, [string]$WinName = '')
    if ($null -eq $El) { return $null }
    foreach ($b in @(Find-AllOfType $El ([System.Windows.Controls.Primitives.ButtonBase]))) {
        if ([string]$b.Name -eq $Name) { return $b }
    }
    # 兜底：按 Name 找不到时退回按文字找（用于旧版本/未来改名时的诊断）。
    if (-not [string]::IsNullOrWhiteSpace($WinName)) { return (Find-ButtonByText $El $WinName) }
    return $null
}

function Measure-DialogContent {
    # 从未 Show 过的 Window 没有 HwndSource，ActualWidth 恒为 0 —— 光调 Window.UpdateLayout()
    # 也没用（窗口自身没有尺寸，量出来全是 0，断言会退化成空转）。
    # 这里直接在内容根上手工 Measure/Arrange 一遍：尺寸由内容自然决定（弹窗都是
    # SizeToContent），拿到真实几何后再做位置判断，既不用弹窗闪屏，也不依赖渲染时机。
    param($Win)
    if ($null -eq $Win) { return $null }
    $root = $Win.Content
    if ($null -eq $root) { return $null }
    try {
        $inf = [double]::PositiveInfinity
        $root.Measure([System.Windows.Size]::new($inf, $inf))
        $ds = $root.DesiredSize
        $root.Arrange([System.Windows.Rect]::new(0.0, 0.0, $ds.Width, $ds.Height))
        $root.UpdateLayout()
    } catch { }
    return $root
}

function Invoke-Click {
    param($Btn)
    if ($null -eq $Btn) { return $false }
    try {
        $Btn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        return $true
    } catch { return $false }
}

function Invoke-MouseDown {
    # 与 Invoke-MouseUp 对称：用来模拟真实的按下 / 抬起序列（含"双击"）。
    param($Target, $Source = $null, [string]$Kind = 'Left', [int]$Count = 1)
    if ($null -eq $Target) { return $false }
    try {
        $btn = [System.Windows.Input.MouseButton]::Left
        $evt = [System.Windows.UIElement]::MouseLeftButtonDownEvent
        if ($Kind -eq 'Right') {
            $btn = [System.Windows.Input.MouseButton]::Right
            $evt = [System.Windows.UIElement]::MouseRightButtonDownEvent
        }
        $mbe = New-Object System.Windows.Input.MouseButtonEventArgs(
            [System.Windows.Input.Mouse]::PrimaryDevice, 0, $btn)
        $mbe.RoutedEvent = $evt
        # 赋 .Source 才能让 OriginalSource 派生出来，处理器里的 Test-AncestorTag 才找得到 Tag
        if ($null -ne $Source) { $mbe.Source = $Source }
        # 两个旁路变量一起进出：ClickCount 和"被点的子元素"都塞不进手工事件。
        $script:SyntheticClickCount = $Count
        $script:SyntheticEventSource = $Source
        try {
            $Target.RaiseEvent($mbe)
        } finally {
            $script:SyntheticClickCount = $null
            $script:SyntheticEventSource = $null
        }
        return $true
    } catch { return $false }
}

function Get-EventSourceOf {
    # 处理器里统一走这里取"事件源"，替代裸的 $e.OriginalSource。
    # 目的有两个：
    #   ① 让它在 StrictMode 下**永远不抛**（取不到就 $null，等价于原来读到 null）；
    #   ② 让手工 RaiseEvent 的事件也能带上"被点的子元素"。
    # MouseLeftButtonUp 是 Direct 路由，不会从子元素冒泡到祖先，所以模拟点击必须
    # 在祖先上 RaiseEvent；而 .Source 写进去后 OriginalSource 不保证等于它，
    # 于是 Invoke-MouseUp/Down 用 $script:SyntheticEventSource 旁路传入。
    #
    # 不要在这里"兜底成最近的祖先元素"：那会让 Test-AncestorTag 从一个错误的起点
    # 往上走，找不到子元素身上的 Tag，所有点按变成静默失效 —— 看起来像功能没实现。
    #
    # 但"完全不给兜底"同样有坑（第三轮实测）：手工 RaiseEvent 造的事件
    # OriginalSource 经常是 null，而调用方明明把 $s 当 $Fallback 传了进来 ——
    # 参数传了却从来没用过，等于白传。周视图的手工双击用例就是这样：
    #   Source=卡片 / OriginalSource=null / $Fallback=卡片
    # 结果取不到卡片自己的 Tag，"双击编辑"和"空白拖拽新建"两条一起静默失效。
    # 所以这里的顺序是：旁路 → OriginalSource → Source → 调用方给的 $Fallback。
    # Source 放在 OriginalSource 之后是安全的：真事件里 Source 就是挂了处理器的那个元素
    # （等于 $s），只有在 OriginalSource 读不到时才会用到它。
    # ⚠ 参数名绝对不能叫 $Args / $args。
    #   PowerShell 的自动变量 $args（未绑定参数数组）与它**同名同变量**，
    #   入口处会被绑定器覆盖成 @()：参数明明传进来了，函数里读到的却是一个空数组，
    #   于是 $Args.OriginalSource 在 StrictMode 2.0 下直接抛
    #   "在此对象上找不到属性 OriginalSource" —— 被 catch 吞掉后**静默降级**。
    #   实测（verification\_args_probe.txt）：
    #     param($Args) 读 .ClickCount -> THREW
    #     param($X)    读 .ClickCount -> 2
    #   这个坑在本项目里实际造成过两个假绿灯 + 两个真 bug（见下）。
    param($Evt, $Fallback = $null)
    if ($null -ne $script:SyntheticEventSource) { return $script:SyntheticEventSource }
    if ($null -eq $Evt) { return $Fallback }
    try {
        $src = $Evt.OriginalSource
        if ($null -ne $src) { return $src }
    } catch { }
    try {
        $src2 = $Evt.Source
        if ($null -ne $src2) { return $src2 }
    } catch { }
    return $Fallback
}

function Get-MouseClickCount {
    # 鼠标事件的 ClickCount 在**手工 RaiseEvent** 的场景下拿不到真值：
    #   · MouseButtonEventArgs 的构造函数签名是 (MouseDevice, int timestamp, MouseButton)，
    #     第二个参数是**时间戳**，不是 ClickCount —— 很容易记错并误以为能注入；
    #   · 真正的 ClickCount 由 WPF 的双击计时器在输入管道里填，绕过它没有正当办法。
    # 所以 Invoke-MouseUp/Invoke-MouseDown 在需要"双击"时，把期望值写进
    # $script:SyntheticClickCount，这里优先读它，读不到才回落到事件自带的 ClickCount。
    # ⚠ 同 Get-EventSourceOf：参数名不能叫 $Args，否则读到的是被覆盖成 @() 的自动变量，
    #   $Args.ClickCount 一路抛异常 → 这个函数**永远返回 1** → 所有"双击"分支全部失效
    #   （周视图双击编辑就是被这个打哑的，而任务卡双击因为走 $script:SyntheticClickCount
    #   旁路先返回，把这个 bug 盖住了 —— 典型的假绿灯）。
    param($Evt)
    if ($null -ne $script:SyntheticClickCount) { return [int]$script:SyntheticClickCount }
    try { return [int]$Evt.ClickCount } catch { return 1 }
}

function Invoke-MouseUp {
    # 月格 / 事件 / 任务的交互都挂在 MouseLeftButtonUp / MouseRightButtonUp 上。
    # 坑：这两个事件在 WPF 里是 Direct 路由——在子元素上 RaiseEvent 不会冒泡到
    #     挂在祖先（ViewHost / TaskStack）上的处理器。真实输入时框架会沿祖先链
    #     逐个重新触发，所以这里必须显式 raise 在"挂了处理器的那个元素"上，
    #     再把 source 指到具体子元素，处理器里的 Test-AncestorTag 才找得到 Tag。
    param($Target, $Source = $null, [string]$Kind = 'Left', [int]$Count = 1)
    if ($null -eq $Target) { return $false }
    try {
        $btn = [System.Windows.Input.MouseButton]::Left
        $evt = [System.Windows.UIElement]::MouseLeftButtonUpEvent
        if ($Kind -eq 'Right') {
            $btn = [System.Windows.Input.MouseButton]::Right
            $evt = [System.Windows.UIElement]::MouseRightButtonUpEvent
        }
        $mbe = New-Object System.Windows.Input.MouseButtonEventArgs(
            [System.Windows.Input.Mouse]::PrimaryDevice, 0, $btn)
        $mbe.RoutedEvent = $evt
        # 赋 .Source 会把 SourceObject 填上，OriginalSource 随之派生 —— 这是处理器里
        # Test-AncestorTag 能定位到具体子元素的前提，别改成反射或别的写法。
        if ($null -ne $Source) { $mbe.Source = $Source }
        # ClickCount 注入不进构造函数（第二个参数是 timestamp），只能走旁路变量。
        # 两个旁路变量一起进出：ClickCount 和"被点的子元素"都塞不进手工事件。
        $script:SyntheticClickCount = $Count
        $script:SyntheticEventSource = $Source
        try {
            $Target.RaiseEvent($mbe)
        } finally {
            $script:SyntheticClickCount = $null
            $script:SyntheticEventSource = $null
        }
        return $true
    } catch { return $false }
}

function Write-AuditRow {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:AuditPass++ } else { $script:AuditFail++ }
    $flag = if ($Ok) { 'PASS' } else { 'FAIL' }
    $line = '{0}  {1,-32} {2}' -f $flag, $Name, $Detail
    [void]$script:AuditRows.Add($line)
    # 逐条落盘（audit.txt 是最后一次性写的）。
    # 没有这个，审计一旦卡住/被杀，磁盘上什么都看不到 —— 表现成
    # "跑了十分钟，rundata 目录里只有 settings.json"，完全无法定位卡在哪一行。
    # 有它就能直接看 audit.live.txt 的最后一行 = 卡住的位置。
    try {
        [System.IO.File]::AppendAllText((Join-Path $script:DataDir 'audit.live.txt'),
            ($line + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Invoke-HandlerAudit {
    $script:AuditRows = New-Object System.Collections.Generic.List[string]
    $script:AuditPass = 0
    $script:AuditFail = 0
    $script:SuppressModal = $true
    try {
        # ---- 0. 自检：手工造的事件能不能带上事件源 ----
        # Test-AncestorTag / Test-BtnTag 全靠 $e.OriginalSource 找到被点的那个子元素。
        # 这一条把"能不能带"直接量出来，免得后面几十条点按用例失败时只能靠猜。
        # 顺序很关键：必须**先**赋 RoutedEvent 再赋 Source ——
        #   反过来的话 RoutedEventArgs.Source 会抛
        #   "每个 RoutedEventArgs 都必须有一个与其关联的非空 RoutedEvent"。
        try {
            $probeEvt = New-Object System.Windows.Input.MouseButtonEventArgs(
                [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
            $err = ''
            try { $probeEvt.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent }
            catch { $err += 'setEvt=[' + $_.Exception.Message + '] ' }
            try { $probeEvt.Source = $script:NodeHost } catch { $err += 'setSource=[' + $_.Exception.Message + '] ' }
            $srcOk = $false
            $osOk = $false
            try { $srcOk = ($null -ne $probeEvt.Source) } catch { $err += 'getSource=[' + $_.Exception.Message + '] ' }
            try { $osOk = ($null -ne $probeEvt.OriginalSource) } catch { $err += 'getOrig=[' + $_.Exception.Message + '] ' }
            Write-AuditRow 'synthetic event carries source' ($srcOk -and $osOk) `
                ('source=' + $srcOk + ' original=' + $osOk + ' err=' + $err.Trim())
        } catch {
            Write-AuditRow 'synthetic event carries source' $false ('crash ' + $_.Exception.Message)
        }
        # ---- 1. 顶部不重复视图导航 ----
        $topViewDuplicates = ($null -ne $script:BtnViewMonth) -or ($null -ne $script:BtnViewWeek) -or ($null -ne $script:BtnViewList)
        Write-AuditRow 'top view duplication removed' (-not $topViewDuplicates) ('duplicates=' + [string]$topViewDuplicates)
        # ---- 2. 侧边栏切换视图 ----
        foreach ($pair in @(@('month', $script:NavMonth), @('week', $script:NavWeek),
                            @('list', $script:NavList), @('tasks', $script:NavTask))) {
            [void](Invoke-Click $pair[1])
            Write-AuditRow ('sidebar -> ' + $pair[0]) ($script:View -eq [string]$pair[0]) ('View=' + $script:View)
        }
        # ---- 3. 侧边栏 Tasks / Settings / Profile ----
        #   Tasks 现在是一个真正的视图（以前点了只是跳回 list，自己永远不高亮）
        [void](Invoke-Click $script:NavTask)
        Write-AuditRow 'sidebar Tasks' ($script:View -eq 'tasks') ('View=' + $script:View)
        $addTaskBtn = Find-ButtonByText $script:NodeHost '+ Add task'
        Write-AuditRow 'task add button' ($null -ne $addTaskBtn) $(if ($null -ne $addTaskBtn) { 'found' } else { 'missing' })
        $script:LastModalCall = ''
        [void](Invoke-Click $script:NavFocus)
        Write-AuditRow 'sidebar Focus' ($script:LastModalCall -eq 'focus') $script:LastModalCall
        Write-AuditRow 'top Focus duplication removed' ($null -eq $script:BtnFocusMenu) 'moved to sidebar'
        $script:LastModalCall = ''
        [void](Invoke-MouseUp -Target $script:AvatarBox)
        Write-AuditRow 'avatar window entry' ($script:LastModalCall -eq 'avatar') $script:LastModalCall
        $script:LastModalCall = ''
        [void](Invoke-Click $script:NavSettings)
        Write-AuditRow 'sidebar Settings' ($script:LastModalCall -eq 'stats') $script:LastModalCall
        $script:LastModalCall = ''
        [void](Invoke-Click $script:NavProfile)
        Write-AuditRow 'sidebar Profile' ($script:LastModalCall -eq 'stats') $script:LastModalCall

        # ---- 4. 前后翻页 / 回到今天 ----
        Set-View 'month'
        $mom = $script:Anchor
        [void](Invoke-Click $script:BtnNext)
        $a1 = $script:Anchor
        [void](Invoke-Click $script:BtnPrev)
        $a2 = $script:Anchor
        Write-AuditRow 'cal next/prev' (($a1.Month -ne $mom.Month) -and ($a2.Month -eq $mom.Month)) `
            ($mom.ToString('yyyy-MM') + ' -> ' + $a1.ToString('yyyy-MM') + ' -> ' + $a2.ToString('yyyy-MM'))
        $script:Anchor = $script:Anchor.AddMonths(3)
        [void](Invoke-Click $script:BtnThis)
        Write-AuditRow 'cal this-month' ($script:Anchor.Date -eq [datetime]::Today) ('Anchor=' + $script:Anchor.ToString('yyyy-MM-dd'))

        # ---- 5. 置顶 ----
        $t0 = [bool]$script:MainWindow.Topmost
        Toggle-Topmost
        $t1 = [bool]$script:MainWindow.Topmost
        Toggle-Topmost
        $t2 = [bool]$script:MainWindow.Topmost
        Write-AuditRow 'pin toggle' (($t1 -ne $t0) -and ($t2 -eq $t0)) ("$t0 -> $t1 -> $t2")

        # ---- 6. 折叠侧栏 ----
        $w0 = [double]$script:NavCol.Width.Value
        Toggle-Sidebar
        $w1 = [double]$script:NavCol.Width.Value
        Toggle-Sidebar
        $w2 = [double]$script:NavCol.Width.Value
        Write-AuditRow 'collapse sidebar' (($w1 -eq 0) -and ($w2 -eq $w0) -and ($w2 -gt 0)) ("$w0 -> $w1 -> $w2")

        # ---- 7. 番茄钟启停（控制面已从侧栏搬到 Focus 浮窗）----
        # 侧栏圆环/按钮整块删掉后，$script:BtnPomo 等为 $null，不能再靠点侧栏按钮驱动。
        # 改成直接调 Toggle-Pomodoro 验证状态机，并按浮窗文案验证"显示面还在"。
        if ([bool]$script:Pomo.Running) { Toggle-Pomodoro }
        Toggle-Pomodoro
        $r1 = [bool]$script:Pomo.Running
        Toggle-Pomodoro
        $r2 = [bool]$script:Pomo.Running
        Write-AuditRow 'pomodoro start/stop' ($r1 -and (-not $r2)) ("running=$r1 running2=$r2")

        # 侧栏番茄钟控件必须全部为 $null（真删干净了，不是隐藏）
        $pomoNull = ($null -eq $script:BtnPomo) -and ($null -eq $script:PomoBox) -and
                    ($null -eq $script:PomoArc) -and ($null -eq $script:PomoText) -and
                    ($null -eq $script:PomoHint) -and ($null -eq $script:PomoBg) -and
                    ($null -eq $script:PomoInner) -and ($null -eq $script:PomoBtnText) -and
                    ($null -eq $script:BtnPomoReset)
        Write-AuditRow 'sidebar pomodoro fully removed' $pomoNull `
            ("btn=$($null -ne $script:BtnPomo) box=$($null -ne $script:PomoBox) arc=$($null -ne $script:PomoArc)")

        # Focus 浮窗必须是唯一的显示面。这里**不能**调 Open-FocusPanel：
        #   它内部是 $win.ShowDialog()，在无头审计里会挂住整个消息泵，
        #   后面的几十个用例全部跑不到（表现成审计报告在中间被截断，只有 20 多条）。
        #   改为直接建窗口 + SuppressModal 走非模态闸门，拿 $script:LastModalCall 验证。
        $script:SuppressModal = $false
        $foWin = Show-FocusWindow
        $foOk = ($null -ne $script:FoTimeText) -and ($null -ne $script:FoStatusText)
        $foTxt = ''
        if ($foOk) { $foTxt = [string]$script:FoTimeText.Text }
        # 顺便验证"ShowDialog 之前不做布局"这个老坑没回归：浮窗内容要真的被量过。
        # 注意：$foWin 是 SizeToContent='WidthAndHeight'，Show() 之前 Width 是 NaN，
        #       直接 [int] 转换会抛"值对于 Int32 太大或太小"把整个审计打断。
        #       所以这里量内容根（Measure/Arrange）拿真实尺寸，并对 NaN 做兜底。
        $foW = 0.0
        $foH = 0.0
        $foRoot = $null
        try { $foRoot = $foWin.Content } catch { }
        if ($null -ne $foRoot) {
            # 量内容根的 DesiredSize：因为 $foWin 是 SizeToContent，Show() 前 .Width 是 NaN。
            # 注意 New-Object 不接受 Foo(Type(...)) 这种写法，必须走 -ArgumentList。
            try {
                $inf = [double]::PositiveInfinity
                $sz = New-Object System.Windows.Size -ArgumentList @($inf, $inf)
                $foRoot.Measure($sz)
                $ds = $foRoot.DesiredSize
                $rc = New-Object System.Windows.Rect -ArgumentList @(0.0, 0.0, [double]$ds.Width, [double]$ds.Height)
                $foRoot.Arrange($rc)
                $foRoot.UpdateLayout()
                $mw = [double]$foRoot.ActualWidth
                $mh = [double]$foRoot.ActualHeight
                if (-not [double]::IsNaN($mw)) { $foW = $mw }
                if (-not [double]::IsNaN($mh)) { $foH = $mh }
            } catch {
                Write-ErrLog ('Measure focus content: ' + $_.Exception.Message)
            }
        }
        Write-AuditRow 'focus window is the sole surface' ($foOk -and ($foTxt.Length -ge 4)) `
            ('time=' + $foTxt + ' content=' + [int]$foW + 'x' + [int]$foH)
        try { $foWin.Close() } catch { }
        # Open-FocusPanel 在 SuppressModal 下必须"只记录、不弹窗"（这就是审计能继续跑的前提）
        $script:LastModalCall = ''
        $script:SuppressModal = $true
        try { Open-FocusPanel } catch { }
        Write-AuditRow 'focus panel respects suppress modal' ($script:LastModalCall -eq 'focus') `
            ('last=' + [string]$script:LastModalCall)
        # 必须还原成 $true —— 这是审计的常态闸门。
        # 写成 $false 的后果：紧接着的【add-event button】→ Open-EventEditor → ShowDialog()
        # 会真的弹出一个模态框，而无头环境里没人能点它，消息泵就此停住。
        # 表现极具迷惑性：审计正好停在第 21 行，rundata 里只有 settings.json，
        # 没有 audit.txt 也没有 testlog.txt，像"莫名其妙不产出报告"。
        $script:SuppressModal = $true
        try {
            $chrome = [System.Windows.Shell.WindowChrome]::GetWindowChrome($script:MainWindow)
            $rb = [double]$chrome.ResizeBorderThickness.Left
            Write-AuditRow 'window resize border' ($rb -ge 8.0) ('border=' + $rb)
        } catch {
            Write-AuditRow 'window resize border' $false $_.Exception.Message
        }

        # ---- 8. 新建日程按钮 ----
        # 保险丝：这一步会走 Open-EventEditor，闸门若被前面的用例弄成开的，
        # 就会真弹模态框把审计永久卡住。这里强制拉回常态。
        $script:SuppressModal = $true
        $script:LastModalCall = ''
        [void](Invoke-Click $script:BtnAdd)
        Write-AuditRow 'add-event button' ($script:LastModalCall -eq 'editor:') $script:LastModalCall

        # ---- 9. 月格左键选中（真实鼠标路由）----
        # 断言必须"反着设"：先把选中项改成今天-5，再点"今天"那格，
        # 只有处理器真的跑到了才会变回今天。若先把期望值设好，测试就恒真了。
        Set-View 'month'
        $days = @(Find-AllTagged $script:NodeHost 'day')
        $withDate = @($days | Where-Object {
                ($null -ne $_) -and ($_.Tag -is [hashtable]) -and
                $_.Tag.ContainsKey('date') -and ($null -ne $_.Tag['date'])
            })
        $cell = $null
        foreach ($cand in $withDate) {
            if (([datetime]$cand.Tag['date']).Date -eq [datetime]::Today) { $cell = $cand; break }
        }
        if (($null -eq $cell) -and ($withDate.Count -gt 0)) { $cell = $withDate[0] }
        if ($null -eq $cell) {
            Write-AuditRow 'month cell click' $false ('day nodes=' + $days.Count + ' withDate=' + $withDate.Count)
        } else {
            $want = ([datetime]$cell.Tag['date']).Date
            # 真实点击是"从被点的元素起、沿祖先链冒泡"：事件必须在**日格自己**身上发出。
            # 挂在 NodeHost 上发是早期写法，处理器确实能跑；但更贴近真实输入的
            # 做法是从 $cell 发，让 WPF 自己把路由走到挂了处理器的祖先。
            $script:Selected = [datetime]::Today.AddDays(-5)
            $probeTag = Test-AncestorTag $cell
            $probeKind = '(none)'
            if ($null -ne $probeTag) { $probeKind = [string]$probeTag.kind }
            $raised = [bool](Invoke-MouseUp -Target $cell -Source $cell)
            $viaCell = ($script:Selected.Date -eq $want) -and ($script:View -eq 'week')
            $viaHost = $false
            if (-not $viaCell) {
                # 回落到"直接发给挂处理器的宿主"，把两种路由都量出来，
                # 免得下次只能看到一句"没生效"而分不清是路由还是逻辑的问题。
                $script:Selected = [datetime]::Today.AddDays(-5)
                $script:View = 'month'
                [void](Invoke-MouseUp -Target $script:NodeHost -Source $cell)
                $viaHost = ($script:Selected.Date -eq $want) -and ($script:View -eq 'week')
            }
            Write-AuditRow 'month cell jump to week' ($viaCell -or $viaHost) `
                ('want=' + $want.ToString('yyyy-MM-dd') + ' got=' + $script:Selected.ToString('yyyy-MM-dd') +
                 ' view=' + $script:View + ' dayNodes=' + $days.Count +
                 ' tag=' + $probeKind + ' raised=' + $raised +
                 ' viaCell=' + $viaCell + ' viaHost=' + $viaHost + ' ov=[' + [string]$script:OverlayOpen + ']')
        }

        # ---- 10. 右键月格 -> 请求打开编辑器 ----
        Set-View 'month'
        $cell2 = Find-TaggedNode $script:NodeHost 'day'
        if ($null -ne $cell2) {
            $script:LastModalCall = ''
            [void](Invoke-MouseUp -Target $script:NodeHost -Source $cell2 -Kind 'Right')
            Write-AuditRow 'month right-click -> editor' ($script:LastModalCall -like 'editor:*') ("got='" + $script:LastModalCall + "'")
        } else {
            Write-AuditRow 'month right-click -> editor' $false 'no tagged cell'
        }

        # ---- 11. 列表：勾选任务 ----
        # ---- 11. 任务勾选（任务面板现在在独立的 Tasks 视图里）----
        Set-View 'tasks'
        $node = Find-TaggedNode $script:NodeHost 'task'
        if ($null -eq $node) {
            Write-AuditRow 'task toggle' $false 'no tagged task found'
        } else {
            $tid = [string]$node.Tag['id']
            $before = @($script:Tasks | Where-Object { [string]$_.id -eq $tid })
            $d0 = $false
            if ($before.Count -gt 0) { $d0 = [bool]$before[0].done }
            [void](Invoke-MouseUp -Target $script:TaskStack -Source $node)
            # 单击现在是"延后落地"的（见 PendingTaskId）：无头审计里计时器不保证跑，
            # 所以这里显式把待办推下去，测的仍然是真实的单击链路。
            [void](Invoke-PendingTaskToggle)
            $after = @($script:Tasks | Where-Object { [string]$_.id -eq $tid })
            $d1 = $d0
            if ($after.Count -gt 0) { $d1 = [bool]$after[0].done }
            Write-AuditRow 'task toggle' ($d1 -ne $d0) ("done $d0 -> $d1")
        }

        # ---- 12. 列表：搜索过滤 ----
        # 注意"无结果"时列表里会放一个 "No events found" 文本，所以计数不会是 0，
        # 断言要比"过滤后行数明显少于过滤前"。
        Set-View 'list'
        if ($null -eq $script:ListSearch) {
            Write-AuditRow 'list search filter' $false 'no search box'
        } else {
            Fill-ListRows
            $n0 = @($script:ListStack.Children).Count
            $script:ListSearch.Text = 'zzz-no-such-event-zzz'
            Fill-ListRows
            $n1 = @($script:ListStack.Children).Count
            $msg = ''
            if ($n1 -eq 1) {
                $tb = $script:ListStack.Children[0]
                if ($tb -is [System.Windows.Controls.TextBlock]) { $msg = [string]$tb.Text }
            }
            $script:ListSearch.Text = ''
            Fill-ListRows
            $n2 = @($script:ListStack.Children).Count
            Write-AuditRow 'list search filter' (($n0 -gt 1) -and ($n1 -lt $n0) -and ($n2 -eq $n0)) `
                ("rows $n0 -> $n1 -> $n2  empty='$msg'")
        }

        # ---- 12b. 任务视图：侧栏 Tasks 按钮对应的是一个真视图 ----
        #   以前 NavTask 只是 Set-View 'list'：点了跳到列表页、自己永远不高亮，
        #   看着就是"这个按钮没用"。现在它渲染 Render-Tasks，并且：
        #     · 列表页不再内嵌任务栏（两边各管一摊，互不抢宽度）
        #     · 任务页有自己的五个筛选，且**真的会过滤**
        Set-View 'list'
        $listHasTasks = ($null -ne $script:TaskStack) -or ($null -ne $script:TaskProjectBox)
        Write-AuditRow 'list view has no task panel' (-not $listHasTasks) ('taskStackNull=' + [string]($null -eq $script:TaskStack))
        Set-View 'tasks'
        Write-AuditRow 'tasks is its own view' ($script:View -eq 'tasks') ('View=' + $script:View)
        if ($null -ne $script:TaskProjectBox) {
            $tags = @($script:TaskProjectBox.Items | ForEach-Object { [string]$_.Tag })
            $hasAll = $tags -contains 'all'
            $hasProject = @($tags | Where-Object { $_ -ne 'all' }).Count -gt 0
            $sortTags = @($script:TaskSortBox.Items | ForEach-Object { [string]$_.Tag })
            $sortOk = (@('due','priority','title') | ForEach-Object { $sortTags -contains $_ }) -notcontains $false
            $stTags = @($script:TaskStatusBox.Items | ForEach-Object { [string]$_.Tag })
            $stOk = (@('all','open','done') | ForEach-Object { $stTags -contains $_ }) -notcontains $false
            $scTags = @($script:TaskScopeBox.Items | ForEach-Object { [string]$_.Tag })
            $scOk = (@('today','week','overdue','nodate') | ForEach-Object { $scTags -contains $_ }) -notcontains $false
            Write-AuditRow 'tasks toolbar options' ($hasAll -and $hasProject -and $sortOk -and $stOk -and $scOk) `
                ('proj=' + $tags.Count + ' sort=' + ($sortTags -join '/') + ' status=' + ($stTags -join '/') + ' scope=' + $scTags.Count)
        } else {
            Write-AuditRow 'tasks toolbar options' $false 'no project box'
        }
        # 筛选"真的会滤"：状态切 Done 之后，卡片里不该再出现未完成任务的标题
        if ($null -ne $script:TaskStatusBox) {
            $probeOpen = [pscustomobject]@{
                id = 'AUDIT-FILTER'; text = 'Audit filter probe open task'
                done = $false; due = $null; dueTime = ''; tag = 'task'
                priority = 'medium'; project = 'AuditFilter'; subtasks = @()
                estimatedMin = 0; actualMin = 0; reminderMin = 0
            }
            [void]$script:Tasks.Add($probeOpen)
            $script:TaskStatusBox.SelectedIndex = 1        # open
            Fill-Tasks
            $foundOpen = $false
            foreach ($r in @($script:TaskStack.Children)) {
                if ($null -ne $r.Tag -and [string]$r.Tag['id'] -eq 'AUDIT-FILTER') { $foundOpen = $true; break }
            }
            $script:TaskStatusBox.SelectedIndex = 2        # done
            Fill-Tasks
            $foundDone = $false
            foreach ($r in @($script:TaskStack.Children)) {
                if ($null -ne $r.Tag -and [string]$r.Tag['id'] -eq 'AUDIT-FILTER') { $foundDone = $true; break }
            }
            $script:TaskStatusBox.SelectedIndex = 0        # all
            Fill-Tasks
            $foundAll = $false
            foreach ($r in @($script:TaskStack.Children)) {
                if ($null -ne $r.Tag -and [string]$r.Tag['id'] -eq 'AUDIT-FILTER') { $foundAll = $true; break }
            }
            Write-AuditRow 'tasks status filter works' ($foundOpen -and (-not $foundDone) -and $foundAll) `
                ('open=' + [string]$foundOpen + ' done=' + [string]$foundDone + ' all=' + [string]$foundAll)
            [void]$script:Tasks.Remove($probeOpen)
            Fill-Tasks
        }

        # ---- 12c. 搜索框占位提示：空 -> 提示可见；有内容 -> 隐藏；清空 -> 又回来 ----
        #   为什么连"输入框底色透明"也要断言：这个土办法的支点是"底色画在 wrapper 上、
        #   输入框自己透明"，提示才能从下面透出来。如果哪天有人把底色改回输入框上，
        #   提示会被整块盖住 —— 界面上看就是"没做提示"，而可见性逻辑却全部通过，
        #   典型的假绿灯。所以物理量必须一起断言。
        try {
            Set-View 'tasks'
            $hint = $script:TaskSearchHint
            $tbProbe = $script:TaskSearch
            $visEmpty = ''; $visTyped = ''; $visBack = ''
            $bgTrans = $false
            if ($null -ne $hint -and $null -ne $tbProbe) {
                $br = $tbProbe.Background -as [System.Windows.Media.SolidColorBrush]
                $bgTrans = ($null -ne $br) -and ($br.Color.A -eq 0)
                $tbProbe.Text = ''
                $visEmpty = [string]$hint.Visibility
                $tbProbe.Text = 'zzz'          # 赋值会同步触发 TextChanged -> Sync-SearchHint
                $visTyped = [string]$hint.Visibility
                $tbProbe.Text = ''
                $visBack = [string]$hint.Visibility
            }
            # 列表页那个搜索框走的是同一套：切过去确认它也挂上了提示
            Set-View 'list'
            $listHintOk = ($null -ne $script:ListSearchHint) -and
                          ([string]$script:ListSearchHint.Visibility -eq 'Visible')
            Set-View 'tasks'
            $phOk = ($null -ne $hint) -and $bgTrans -and
                    ($visEmpty -eq 'Visible') -and ($visTyped -eq 'Collapsed') -and ($visBack -eq 'Visible') -and
                    $listHintOk
            Write-AuditRow 'search box placeholder' $phOk `
                ('tasks=' + $visEmpty + '/' + $visTyped + '/' + $visBack + ' bgAlpha=' +
                 $(if ($bgTrans) { '0' } else { 'opaque' }) + ' listHint=' + [string]$listHintOk)
        } catch { Write-AuditRow 'search box placeholder' $false ('crash ' + $_.Exception.Message) }

        # ---- 13. 两个独立窗口能构建（这里曾因参数名 $Host 直接抛异常）----
        foreach ($w in @(@('event editor', 'editor'), @('settings window', 'settings'))) {
            $win = $null
            $why = ''
            try {
                if ([string]$w[1] -eq 'editor') { $win = Show-EventEditorWindow -Id '' }
                else { $win = Show-SettingsWindow }
            } catch { $why = $_.Exception.Message }
            $ok = ($null -ne $win) -and ($null -ne $win.Content)
            $tb = $false
            if ($ok) { $tb = ($null -ne (Find-FirstOfType $win.Content ([System.Windows.Controls.TextBox]))) }
            $detail = "window=$ok textbox=$tb"
            if ($why) { $detail = $detail + ' err=' + $why }
            Write-AuditRow ('build ' + $w[0]) ($ok -and $tb) $detail
            if ($null -ne $win) { try { $win.Close() } catch { } }
        }

        # ---- 14~18. 独立窗口里的【真实点按】----
        # 光"能构建"不够。用户抱怨的正是"点了没反应"，所以这里必须用 RaiseEvent
        # 真的触发 Click，而不是直接调函数 —— 直接调函数会把"处理器取不到变量"这类
        # 错误完全掩盖掉。
        # ---- 14. 标签芯片：点了要真的换色 ----
        try {
            $ew = Show-EventEditorWindow -Id ''
            $ew.UpdateLayout()
            $script:EdTag = 'work'
            Update-TagChipSelection
            $chip = $null
            if ($null -ne $script:EdTagButtons) { $chip = $script:EdTagButtons['focus'] }
            if ($null -eq $chip) {
                Write-AuditRow 'tag chip click' $false 'no focus chip'
            } else {
                [void](Invoke-Click $chip)
                $gotTag = [string]$script:EdTag
                # 还要证明"确实重画了"：像素按钮的底色在模板的 bd 边框上
                $painted = ''
                try {
                    [void]$chip.ApplyTemplate()
                    $bd = $chip.Template.FindName('bd', $chip)
                    if ($null -ne $bd -and $null -ne $bd.Background) { $painted = [string]$bd.Background.Color }
                } catch { $painted = 'ERR ' + $_.Exception.Message }
                $wantCol = [string]([System.Windows.Media.ColorConverter]::ConvertFromString((Get-Pal 'AccentFocus')))
                Write-AuditRow 'tag chip click' (($gotTag -eq 'focus') -and ($painted -eq $wantCol)) `
                    ("EdTag=$gotTag painted=$painted want=$wantCol")
            }
            try { $ew.Close() } catch { }
        } catch { Write-AuditRow 'tag chip click' $false ('crash ' + $_.Exception.Message) }

        # ---- 15. 空标题保存：要被拦下，且不能新增 ----
        try {
            $ew = Show-EventEditorWindow -Id ''
            $ew.UpdateLayout()
            $n0 = @($script:Events).Count
            $script:EdTbTitle.Text = '   '
            $save = Find-DialogClose $ew
            if ($null -eq $save) {
                Write-AuditRow 'save rejects empty title' $false 'no close(x) button'
            } else {
                [void](Invoke-Click $save)
                $n1 = @($script:Events).Count
                $shown = ([string]$script:EdErr.Text) -and ([string]$script:EdErr.Visibility -eq 'Visible')
                Write-AuditRow 'save rejects empty title' (($n1 -eq $n0) -and $shown) `
                    ("events $n0 -> $n1  err='$([string]$script:EdErr.Text)' vis=$([string]$script:EdErr.Visibility)")
            }
            try { $ew.Close() } catch { }
        } catch { Write-AuditRow 'save rejects empty title' $false ('crash ' + $_.Exception.Message) }

        # ---- 16. 正常保存：要真的写进数据 ----
        try {
            $ew = Show-EventEditorWindow -Id ''
            $ew.UpdateLayout()
            $n0 = @($script:Events).Count
            $want = 'AUDIT-' + (Get-Random -Minimum 10000 -Maximum 99999)
            $script:EdTbTitle.Text = $want
            $script:EdTbDate.Text = (Fmt-Date ([datetime]::Today))
            $script:EdTbStart.Text = '09:00'
            $script:EdTbEnd.Text = '10:00'
            $save = Find-DialogClose $ew
            if ($null -eq $save) {
                Write-AuditRow 'save adds event' $false 'no close(x) button'
            } else {
                [void](Invoke-Click $save)
                $n1 = @($script:Events).Count
                $hit = @($script:Events | Where-Object { [string]$_.title -eq $want }).Count
                Write-AuditRow 'save adds event' (($n1 -eq $n0 + 1) -and ($hit -eq 1)) `
                    ("events $n0 -> $n1  titleHit=$hit  want='$want'")
            }
            try { $ew.Close() } catch { }
        } catch { Write-AuditRow 'save adds event' $false ('crash ' + $_.Exception.Message) }

        # ---- 16a. 重复日程编辑器保存 ----
        try {
            $ew = Show-EventEditorWindow -Id ''
            $ew.UpdateLayout()
            $repName = 'AUDIT REPEAT ' + (Get-Random -Minimum 1000 -Maximum 9999)
            $script:EdTbTitle.Text = $repName
            $script:EdTbDate.Text = (Fmt-Date ([datetime]::Today))
            $script:EdTbStart.Text = '08:00'
            $script:EdTbEnd.Text = '09:00'
            $script:EdRepeat.Text = 'Weekly'
            $script:EdEvery.Text = '2'
            $script:EdUntil.Text = (Fmt-Date ([datetime]::Today.AddMonths(2)))
            $script:EdMonthLast.IsChecked = $false
            $script:EdReminder.Text = '15 min before'
            [void](Invoke-Click (Find-DialogClose $ew))
            $repHit = @($script:Events | Where-Object { [string]$_.title -eq $repName })
            $repSaveOk = ($repHit.Count -eq 1) -and ([string]$repHit[0].repeat -eq 'weekly') -and
                         ([int]$repHit[0].repeatEvery -eq 2) -and ([int]$repHit[0].reminderMin -eq 15)
            Write-AuditRow 'repeat editor save' $repSaveOk ('hits=' + $repHit.Count)
            if ($repHit.Count -eq 1) { [void]$script:Events.Remove($repHit[0]) }
            try { $ew.Close() } catch { }
        } catch { Write-AuditRow 'repeat editor save' $false ('crash ' + $_.Exception.Message) }

        # ---- 16b. 重复日程展开 ----
        try {
            $origin = [datetime]::Today
            $daily = [pscustomobject]@{
                id='AUDIT-REPEAT-DAILY'; date=(Fmt-Date $origin); start=600; end=660
                title='Daily audit'; tag='focus'; note=''; done=$false
                repeat='daily'; repeatEvery=2; repeatUntil=(Fmt-Date $origin.AddDays(4)); repeatMonthMode='day'; reminderMin=0
            }
            [void]$script:Events.Add($daily)
            $d2 = @(Events-On $origin.AddDays(2) | Where-Object { [string]$_.id -eq $daily.id }).Count
            $d1 = @(Events-On $origin.AddDays(1) | Where-Object { [string]$_.id -eq $daily.id }).Count
            Write-AuditRow 'repeat daily interval' (($d2 -eq 1) -and ($d1 -eq 0)) ('d1=' + $d1 + ' d2=' + $d2)
            [void]$script:Events.Remove($daily)

            $last = [datetime]::new(2026, 1, 31)
            $monthly = [pscustomobject]@{
                id='AUDIT-REPEAT-MONTH'; date=(Fmt-Date $last); start=600; end=660
                title='Monthly audit'; tag='work'; note=''; done=$false
                repeat='monthly'; repeatEvery=1; repeatUntil=''; repeatMonthMode='last'; reminderMin=0
            }
            [void]$script:Events.Add($monthly)
            $m2 = @(Events-On ([datetime]::new(2026,2,28)) | Where-Object { [string]$_.id -eq $monthly.id }).Count
            Write-AuditRow 'repeat monthly last day' ($m2 -eq 1) ('hits=' + $m2)
            [void]$script:Events.Remove($monthly)
        } catch { Write-AuditRow 'repeat rules' $false ('crash ' + $_.Exception.Message) }

        # ---- 17. 设置窗口：Reset timer ----
        try {
            if (-not [bool]$script:Pomo.Running) { Toggle-Pomodoro }
            $wasRunning = [bool]$script:Pomo.Running
            $sw = Show-SettingsWindow
            $sw.UpdateLayout()
            $bReset = Find-ButtonByText $sw 'Reset timer'
            if ($null -eq $bReset) {
                Write-AuditRow 'settings reset timer' $false 'no Reset button'
            } else {
                [void](Invoke-Click $bReset)
                Write-AuditRow 'settings reset timer' ((-not [bool]$script:Pomo.Running)) `
                    ("wasRunning=$wasRunning nowRunning=$([bool]$script:Pomo.Running)")
            }
            try { $sw.Close() } catch { }
        } catch { Write-AuditRow 'settings reset timer' $false ('crash ' + $_.Exception.Message) }

        # ---- 18. 专注设置窗口构建 ----
        try {
            $fw = Show-FocusWindow
            $fw.UpdateLayout()
            $focusOk = ($null -ne $script:FoEnabled) -and ($null -ne $script:FoTbDuration) -and
                       ($null -ne $script:FoTbTask) -and ($null -ne $script:FoTimeText) -and
                       ($null -ne $script:FoBreakEnabled) -and ($null -ne $script:FoBreakMin)
            Write-AuditRow 'build focus window' $focusOk 'controls=true'
            $oldMin = [int]$script:Settings['PomodoroMin']
            $oldEnabled = [bool]$script:Settings['PomodoroEnabled']
            $oldTask = [string]$script:Settings['PomodoroTask']
            $script:FoEnabled.IsChecked = $true
            $script:FoTbDuration.Text = '1'
            $script:FoTbTask.Text = 'Audit focus task'
            $saved = Save-FocusWindowSettings
            $focusSaveOk = $saved -and ([int]$script:Settings['PomodoroMin'] -eq 1) -and
                           ([string]$script:Settings['PomodoroTask'] -eq 'Audit focus task') -and
                           ([string]$script:Pomo.Task -eq 'Audit focus task')
            Write-AuditRow 'focus settings save' $focusSaveOk ('task=' + [string]$script:Pomo.Task)
            if (-not [bool]$script:Pomo.Running) { Toggle-Pomodoro }
            $focusRunOk = [bool]$script:Pomo.Running
            if ([bool]$script:Pomo.Running) { Toggle-Pomodoro }
            Write-AuditRow 'focus window start' $focusRunOk ('running=' + $focusRunOk)

            $oldBreak = [bool]$script:Settings['BreakEnabled']
            $oldBreakMin = [int]$script:Settings['BreakMin']
            $script:Settings['BreakEnabled'] = $true
            $script:Settings['BreakMin'] = 5
            if ($null -eq $script:PomoTimer) { $script:PomoTimer = New-Object System.Windows.Threading.DispatcherTimer }
            $script:Pomo.Mode = 'focus'; $script:Pomo.Total = 60; $script:Pomo.Remaining = 0; $script:Pomo.Running = $true
            $script:LastNotification = ''
            Complete-PomodoroPhase
            $breakStartOk = ([string]$script:Pomo.Mode -eq 'break') -and ([int]$script:Pomo.Remaining -eq 300) -and
                            ([string]$script:LastNotification -like 'Focus finished*')
            Write-AuditRow 'focus->break transition' $breakStartOk ('remaining=' + [int]$script:Pomo.Remaining)
            $script:Pomo.Mode = 'break'; $script:Pomo.Total = 300; $script:Pomo.Remaining = 0; $script:Pomo.Running = $true
            $script:LastNotification = ''
            Complete-PomodoroPhase
            $breakEndOk = ([string]$script:Pomo.Mode -eq 'focus') -and (-not [bool]$script:Pomo.Running) -and
                          ([string]$script:LastNotification -like 'Break finished*')
            Write-AuditRow 'break->focus transition' $breakEndOk ([string]$script:LastNotification)
            $script:Settings['BreakEnabled'] = $oldBreak
            $script:Settings['BreakMin'] = $oldBreakMin
            $script:Settings['PomodoroMin'] = $oldMin
            $script:Settings['PomodoroEnabled'] = $oldEnabled
            $script:Settings['PomodoroTask'] = $oldTask
            Reset-Pomodoro
            try { $fw.Close() } catch { }
        } catch { Write-AuditRow 'build focus window' $false ('crash ' + $_.Exception.Message) }

        # ---- 19. 头像窗口构建 ----
        try {
            $aw = Show-AvatarWindow
            $aw.UpdateLayout()
            $avatarOk = ($null -ne $script:AvPreviewImage) -and ($null -ne $script:AvPreviewCanvas)
            Write-AuditRow 'build avatar window' $avatarOk 'preview=true'
            $oldAvatar = [string]$script:Settings['AvatarPath']
            $avatarTestPath = Join-Path $script:DataDir 'avatar-test.png'
            try {
                $testBmp = New-Object System.Drawing.Bitmap(8, 8)
                $gfx = [System.Drawing.Graphics]::FromImage($testBmp)
                $gfx.Clear([System.Drawing.Color]::FromArgb(190, 90, 110))
                $gfx.Dispose()
                $testBmp.Save($avatarTestPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $testBmp.Dispose()
            } catch { }
            $avatarLoadOk = (Apply-AvatarImage -Path $avatarTestPath) -and
                            ($null -ne $script:AvatarImage.Source) -and
                            ([string]$script:AvatarCanvas.Visibility -eq 'Collapsed')
            Write-AuditRow 'avatar image load' $avatarLoadOk $avatarTestPath
            $script:AvDraftPath = $avatarTestPath
            $avatarSave = Find-DialogClose $aw
            if ($null -eq $avatarSave) {
                Write-AuditRow 'avatar image save' $false 'no close(x) button'
            } else {
                [void](Invoke-Click $avatarSave)
                $savedAvatar = [string]$script:Settings['AvatarPath']
                $avatarSaveOk = (Test-Path -LiteralPath $savedAvatar) -and
                                ($savedAvatar -eq (Join-Path $script:DataDir 'avatar.dat'))
                Write-AuditRow 'avatar image save' $avatarSaveOk $savedAvatar
            }
            $script:Settings['AvatarPath'] = $oldAvatar
            Apply-AvatarImage -Path $oldAvatar | Out-Null
            Save-Settings
            try { $aw.Close() } catch { }
        } catch { Write-AuditRow 'build avatar window' $false ('crash ' + $_.Exception.Message) }

        # ---- 19b. 日期详情窗口 ----
        try {
            $dayWin = Show-DayAgendaWindow -Date ([datetime]::Today)
            $dayWin.UpdateLayout()
            Write-AuditRow 'build day agenda' ($null -ne $dayWin.Content) 'month +N details'
            try { $dayWin.Close() } catch { }
        } catch { Write-AuditRow 'build day agenda' $false ('crash ' + $_.Exception.Message) }

        # ---- 20. 任务新增 / 修改 / 删除 ----
        try {
            $tw = Show-TaskEditorWindow
            $tw.UpdateLayout()
            $n0 = @($script:Tasks).Count
            $taskName = 'AUDIT TASK ' + (Get-Random -Minimum 1000 -Maximum 9999)
            $script:TkText.Text = $taskName
            $script:TkDue.Text = (Fmt-Date ([datetime]::Today.AddDays(1)))
            $script:TkDueTime.Text = '14:30'
            $script:TkPriority.Text = 'High'
            $script:TkProject.Text = 'Audit Project'
            $script:TkEstimated.Text = '45'
            $script:TkActual.Text = '5'
            $script:TkReminder.Text = '15 min before'
            New-TaskSubtaskRow -Stack $script:TkSubtaskStack -Text 'first subtask' -Done $false
            $script:TkTag.Text = 'focus'
            $taskSave = Find-DialogClose $tw
            $taskClicked = Invoke-Click $taskSave
            $taskHit = @($script:Tasks | Where-Object { [string]$_.text -eq $taskName })
            $taskAddOk = (@($script:Tasks).Count -eq ($n0 + 1)) -and ($taskHit.Count -eq 1)
            if ($taskHit.Count -eq 1) {
                $taskAddOk = $taskAddOk -and ([string]$taskHit[0].priority -eq 'high') -and
                             ([string]$taskHit[0].project -eq 'Audit Project') -and
                             ([int]$taskHit[0].estimatedMin -eq 45) -and ([int]$taskHit[0].actualMin -eq 5) -and
                             (@($taskHit[0].subtasks).Count -eq 1) -and ([int]$taskHit[0].reminderMin -eq 15)
            }
            Write-AuditRow 'task add advanced' $taskAddOk ($taskName + ' saveFound=' + [string]($null -ne $taskSave) + ' clicked=' + [string]$taskClicked + ' err=' + [string]$script:TkErr.Text)
            if ($taskHit.Count -eq 1) {
                $taskId = [string]$taskHit[0].id
                $tw = Show-TaskEditorWindow -Id $taskId
                $tw.UpdateLayout()
                $editedName = $taskName + ' edited'
                $script:TkText.Text = $editedName
                [void](Invoke-Click (Find-DialogClose $tw))
                $editHit = @($script:Tasks | Where-Object { [string]$_.id -eq $taskId -and [string]$_.text -eq $editedName })
                Write-AuditRow 'task edit' ($editHit.Count -eq 1) $editedName
                Reset-Pomodoro
                Start-FocusForTask -Id $taskId
                $focusTaskOk = ([bool]$script:Pomo.Running) -and ([string]$script:Pomo.TaskId -eq $taskId)
                Write-AuditRow 'task start focus' $focusTaskOk ('task=' + [string]$script:Pomo.TaskId)
                Reset-Pomodoro
                $beforePostpone = Parse-Date ([string]$editHit[0].due)
                Postpone-Task -Id $taskId
                $afterPostpone = Parse-Date ([string]$editHit[0].due)
                Write-AuditRow 'task postpone one day' ($afterPostpone.Date -eq $beforePostpone.AddDays(1).Date) `
                    ($beforePostpone.ToString('yyyy-MM-dd') + ' -> ' + $afterPostpone.ToString('yyyy-MM-dd'))
                $targetId = [string]$script:Tasks[0].id
                if ($targetId -eq $taskId) { $targetId = [string]$script:Tasks[1].id }
                Move-Task -SourceId $taskId -TargetId $targetId
                $movedIndex = -1
                for ($i = 0; $i -lt $script:Tasks.Count; $i++) { if ([string]$script:Tasks[$i].id -eq $taskId) { $movedIndex = $i; break } }
                Write-AuditRow 'task drag reorder' ($movedIndex -ge 0) ('index=' + $movedIndex)
                Remove-Task -Id $taskId
                $afterDelete = @($script:Tasks | Where-Object { [string]$_.id -eq $taskId }).Count
                Write-AuditRow 'task delete' ($afterDelete -eq 0) ('remaining=' + $afterDelete)
            } else {
                Write-AuditRow 'task edit' $false 'new task missing'
                Write-AuditRow 'task delete' $false 'new task missing'
            }
        } catch { Write-AuditRow 'task CRUD' $false ('crash ' + $_.Exception.Message) }

        # ---- 20b. 任务截止提醒 ----
        try {
            $notifyAt = [datetime]::Now.AddMinutes(10)
            $rt = [pscustomobject]@{
                id='AUDIT-REMINDER'; text='Reminder audit task'; done=$false
                due=(Fmt-Date $notifyAt); dueTime=$notifyAt.ToString('HH:mm'); tag='task'
                priority='high'; project='Audit'; subtasks=@(); estimatedMin=10; actualMin=0; reminderMin=10
            }
            [void]$script:Tasks.Add($rt)
            $script:LastNotification = ''
            $script:NotifiedKeys = @{}
            Check-Reminders
            $reminderOk = [string]$script:LastNotification -like '*Reminder audit task*'
            Write-AuditRow 'task due reminder' $reminderOk ([string]$script:LastNotification)
            [void]$script:Tasks.Remove($rt)

            $eventAt = [datetime]::Now.AddMinutes(10)
            $eventMin = $eventAt.Hour * 60 + $eventAt.Minute
            $rev = [pscustomobject]@{
                id='AUDIT-EVENT-REMINDER'; date=(Fmt-Date $eventAt); start=$eventMin; end=[math]::Min(1439,$eventMin+30)
                title='Event reminder audit'; tag='work'; note=''; done=$false
                repeat='none'; repeatEvery=1; repeatUntil=''; repeatMonthMode='day'; reminderMin=10
            }
            [void]$script:Events.Add($rev)
            $script:LastNotification = ''
            $script:NotifiedKeys = @{}
            Check-Reminders
            $eventReminderOk = [string]$script:LastNotification -like '*Event reminder audit*'
            Write-AuditRow 'event due reminder' $eventReminderOk ([string]$script:LastNotification)
            [void]$script:Events.Remove($rev)
        } catch { Write-AuditRow 'task due reminder' $false ('crash ' + $_.Exception.Message) }

        # ---- 21. 设置窗口：改番茄钟长度并关闭 ----
        try {
            $sw = Show-SettingsWindow
            $sw.UpdateLayout()
            $old = [int]$script:Settings['PomodoroMin']
            $script:SetTbPomo.Text = '30'
            $bClose = Find-DialogClose $sw
            if ($null -eq $bClose) {
                Write-AuditRow 'settings save pomo' $false 'no close(x) button'
            } else {
                [void](Invoke-Click $bClose)
                $new = [int]$script:Settings['PomodoroMin']
                Write-AuditRow 'settings save pomo' ($new -eq 30) ("PomodoroMin $old -> $new")
                $script:Settings['PomodoroMin'] = $old
                Save-Settings
            }
            try { $sw.Close() } catch { }
        } catch { Write-AuditRow 'settings save pomo' $false ('crash ' + $_.Exception.Message) }

        # ---- 22. 本期按钮夹在左右翻页键中间 ----
        try {
            $bar = $script:CalBar
            $kids = @($bar.Children)
            $iPrev = $kids.IndexOf($script:BtnPrev)
            $iThis = $kids.IndexOf($script:BtnThis)
            $iNext = $kids.IndexOf($script:BtnNext)
            $orderOk = ($iPrev -ge 0) -and ($iThis -gt $iPrev) -and ($iNext -gt $iThis)
            # 只比"子元素顺序"还不够：DockPanel 会重排视觉位置，两处都要成立才算真夹在中间
            $pxPrev = [double]$script:BtnPrev.TranslatePoint(
                ([System.Windows.Point]::new(0.0, 0.0)), $bar).X
            $pxThis = [double]$script:BtnThis.TranslatePoint(
                ([System.Windows.Point]::new(0.0, 0.0)), $bar).X
            $pxNext = [double]$script:BtnNext.TranslatePoint(
                ([System.Windows.Point]::new(0.0, 0.0)), $bar).X
            $posOk = ($pxPrev -lt $pxThis) -and ($pxThis -lt $pxNext)
            Write-AuditRow 'period button between arrows' ($orderOk -and $posOk) `
                ("idx=$iPrev/$iThis/$iNext  x=" + [int]$pxPrev + '/' + [int]$pxThis + '/' + [int]$pxNext)
        } catch { Write-AuditRow 'period button between arrows' $false ('crash ' + $_.Exception.Message) }

        # ---- 23. 番茄钟控件已从可视树中彻底消失 ----
        # 这一块原来是"番茄钟只留在左侧栏 / 右上角那个已删除"。第三轮把侧栏那块也删了，
        # 断言升级为：整棵树里 Name='PomoBox' 的元素数量必须为 0（真删，不是 Visibility 隐藏）。
        try {
            $pomoCount = 0
            $stack = New-Object System.Collections.Stack
            $stack.Push($script:MainWindow.Content)
            $guard = 0
            while ($stack.Count -gt 0 -and $guard -lt 40000) {
                $guard++
                $n0 = $stack.Pop()
                $fe0 = $n0 -as [System.Windows.FrameworkElement]
                if ($null -ne $fe0 -and [string]$fe0.Name -eq 'PomoBox') { $pomoCount++ }
                if ($n0 -is [System.Windows.Controls.Panel]) { foreach ($k in @($n0.Children)) { $stack.Push($k) } }
                elseif ($n0 -is [System.Windows.Controls.Decorator]) { $stack.Push($n0.Child) }
                elseif ($n0 -is [System.Windows.Controls.ContentControl]) { $stack.Push($n0.Content) }
            }
            Write-AuditRow 'sidebar pomodoro gone from visual tree' ($pomoCount -eq 0) `
                ("pomoBoxCount=$pomoCount scanned=$guard")
            # 顶部信息头里也不该再有番茄钟/专注按钮（右边那棵树的根就是信息头的父容器）
            $rightGrid = $script:NodeHost.Parent.Parent
            $topFocusBtn = $null
            if ($null -ne $rightGrid) { $topFocusBtn = Find-ButtonByText $rightGrid 'Focus setup' }
            Write-AuditRow 'top-right pomodoro removed' (($null -eq $topFocusBtn) -and ($null -eq $script:BtnPomo)) `
                ('topFocusBtn=' + [string]($null -ne $topFocusBtn) + ' sidebarBtn=' + [string]($null -ne $script:BtnPomo))
        } catch { Write-AuditRow 'sidebar pomodoro gone from visual tree' $false ('crash ' + $_.Exception.Message) }

        # ---- 24. 窗口变窄不折叠侧栏 ----
        try {
            $wOld = [double]$script:MainWindow.Width
            $hOld = [double]$script:MainWindow.Height
            $script:NavUserCollapsed = $false
            Set-NavCollapsed $false
            $script:MainWindow.Width = 820.0
            try { $script:MainWindow.UpdateLayout() } catch { }
            Apply-ResponsiveLayout
            $awNarrow = [double]$script:MainWindow.ActualWidth
            $colNarrow = [double]$script:NavCol.Width.Value
            $navVis = [string]$script:NavPanel.Visibility
            # 说明：ActualWidth 要靠 WM_SIZE 回到 UI 线程才会更新（时机不确定），
            # 所以这里把"设成多少"和"量到多少"都打出来；真正的结论并不依赖这个尺寸——
            # 侧栏折叠现在只由 NavUserCollapsed 决定，宽度断言在块 26 静态扫描里兜底。
            Write-AuditRow 'sidebar stays open when narrow' (($colNarrow -gt 0.0) -and ($navVis -eq 'Visible')) `
                ('setW=' + [int]$script:MainWindow.Width + ' actualW=' + [int]$awNarrow +
                 ' col=' + [int]$colNarrow + ' vis=' + $navVis)
            # 用户手动折叠仍然要有效
            $script:NavUserCollapsed = $true
            Apply-ResponsiveLayout
            $colUser = [double]$script:NavCol.Width.Value
            $script:NavUserCollapsed = $false
            Apply-ResponsiveLayout
            Write-AuditRow 'sidebar manual collapse still works' ($colUser -eq 0.0) ('col=' + [int]$colUser)
            $script:MainWindow.Width = $wOld
            $script:MainWindow.Height = $hOld
            try { $script:MainWindow.UpdateLayout() } catch { }
            Apply-ResponsiveLayout
        } catch { Write-AuditRow 'sidebar stays open when narrow' $false ('crash ' + $_.Exception.Message) }

        # ---- 25. 周视图时段范围选择 ----
        try {
            Set-View 'week'
            try { $script:MainWindow.UpdateLayout() } catch { }
            $presets = @($script:WeekRangePresets)
            $itemOk = ($null -ne $script:WkRangeBox) -and
                      ([int]$script:WkRangeBox.Items.Count -eq ($presets.Count + 1))
            Write-AuditRow 'week range selector present' $itemOk `
                ('items=' + $(if ($null -ne $script:WkRangeBox) { [int]$script:WkRangeBox.Items.Count } else { -1 }))
            $startHour = [int]$script:WeekStartHour
            $rowsAll = Week-RangeRows
            $axisAll = @($script:WeekAxis.RowDefinitions).Count
            # 切到常用时段：行数、轴行数、首行刻度都要跟着变
            [void](Set-WeekRange 8 20)
            try { $script:MainWindow.UpdateLayout() } catch { }
            $rowsWork = Week-RangeRows
            $axisWork = @($script:WeekAxis.RowDefinitions).Count
            $labels = @()
            foreach ($c in @($script:WeekAxis.Children)) {
                if ($c -is [System.Windows.Controls.TextBlock]) { $labels += [string]$c.Text }
            }
            $labelOk = ($labels.Count -ge 1) -and ([string]$labels[0] -eq '08:00')
            $boxOk = ([int]$script:WkRangeBox.SelectedIndex -eq 1) -and
                     ([int]$script:WkStartBox.SelectedIndex -eq 8) -and
                     ([int]$script:WkEndBox.SelectedIndex -eq 19)
            Write-AuditRow 'week range switch (08-20)' (($rowsWork -eq 12) -and ($axisWork -eq 12) -and $labelOk -and $boxOk) `
                ("rows=$rowsWork axisRows=$axisWork first='" + [string]$labels[0] +
                 "' sel=" + [int]$script:WkRangeBox.SelectedIndex + '/' + [int]$script:WkStartBox.SelectedIndex + '/' + [int]$script:WkEndBox.SelectedIndex +
                 " allRows=$rowsAll/$axisAll")
            # 映射关系：8:00 必须落在 Y=0，20:00 落在轴底
            # 轴高按"行数 × 每小时像素"算，不用 ActualHeight：轴层是 Stretch 的，
            # ScrollViewer 视口比内容高时 ActualHeight 会被撑大，量出来就不是轴高。
            $y800 = Week-MinuteToY 480
            $y2000 = Week-MinuteToY 1200
            $axisPx = [double](Week-RangeRows) * [double]$script:HourHeight
            $mapOk = ([math]::Abs($y800) -le 0.01) -and
                     ([math]::Abs($y2000 - $axisPx) -le 1.5)
            Write-AuditRow 'week range Y mapping' $mapOk `
                ('y(08:00)=' + [int]$y800 + ' y(20:00)=' + [int]$y2000 + ' axisH=' + [int]$axisPx)
            # Y -> 分钟 的往返（吸附后误差不超过 15 分钟）
            $back = Get-WeekMinuteFromY $y2000
            Write-AuditRow 'week range Y->minute' ([math]::Abs([int]$back - 1200) -le 15) ('min=' + [int]$back)
            # 越界钳制：轴上方/下方都只能落在时段内
            $clampUp = Get-WeekMinuteFromY (-500.0)
            $clampDown = Get-WeekMinuteFromY ([double]$axisPx + 500.0)
            Write-AuditRow 'week range clamps to range' (($clampUp -eq 480) -and ($clampDown -eq 1200)) `
                ('up=' + [int]$clampUp + ' down=' + [int]$clampDown)
            # 非法区间（起 >= 止）必须被拒绝
            $bad0 = [int]$script:WeekStartHour
            $rejected = -not (Set-WeekRange 20 8)
            $unchanged = ([int]$script:WeekStartHour -eq $bad0)
            Write-AuditRow 'week range rejects invalid' ($rejected -and $unchanged) `
                ('rejected=' + [string]$rejected + ' start=' + [int]$script:WeekStartHour)
            # 自定义：起点下拉改到 10，止点自动抬到 11（非法组合的兜底）
            $script:WkStartBox.SelectedIndex = 7    # 07:00
            $script:WkEndBox.SelectedIndex = 3      # 04:00 -> 非法
            Apply-WeekCustomRange
            $custOk = ([int]$script:WeekStartHour -eq 7) -and ([int]$script:WeekEndHour -eq 8) -and
                      ([int]$script:WkRangeBox.SelectedIndex -eq $presets.Count)
            Write-AuditRow 'week range custom + clamp' $custOk `
                ('start=' + [int]$script:WeekStartHour + ' end=' + [int]$script:WeekEndHour +
                 ' sel=' + [int]$script:WkRangeBox.SelectedIndex)
            # 恢复全天（后面的用例依赖"能看到 0-24 点"）
            [void](Set-WeekRange 0 24)
            try { $script:MainWindow.UpdateLayout() } catch { }
            Write-AuditRow 'week range restored to all-day' `
                (([int]$script:WeekStartHour -eq 0) -and ([int]$script:WeekEndHour -eq 24) -and ((Week-RangeRows) -eq 24)) `
                ('rows=' + (Week-RangeRows) + ' axisRows=' + @($script:WeekAxis.RowDefinitions).Count)
        } catch { Write-AuditRow 'week range selector present' $false ('crash ' + $_.Exception.Message) }

        # ---- 26. 侧栏折叠不再由窗口宽度自动触发（静态断言）----
        try {
            $careSrc = [System.IO.File]::ReadAllText((Join-Path $script:Root 'Care.ps1'), [System.Text.Encoding]::UTF8)
            $autoLeft = ([regex]::Matches($careSrc, 'forceCollapsed')).Count
            Write-AuditRow 'no width-based auto collapse' ($autoLeft -eq 0) ('forceCollapsed x' + $autoLeft)
        } catch { Write-AuditRow 'no width-based auto collapse' $false ('crash ' + $_.Exception.Message) }

        # ---- 27. 侧栏内部两区布局：导航（可滚动，一整列）/ DAILY NOTE（固定）----
        #   为什么单独测：把 DockPanel 换成 Grid 之后，"谁在上面"不再由书写顺序决定，
        #   而是由 Grid.Row 决定；写反了界面还是能跑，只是 NOTE 会被顶到最上面。
        #   历史：上一轮把侧栏从三行拆成四行（Task/Focus/Settings/Profile 独立成"次导航"行），
        #   想靠"上下两组"填掉多余高度；结果用户直接报"左侧栏上下部分脱节了" ——
        #   多余高度落在两组之间，视觉上就是断成两截。这一轮合并回一条连续导航 + 固定 NOTE，
        #   断言随之升级为：行数=2、NavTask 必须在**可滚动的那一簇**里（合并的证据）、
        #   且四个导航按钮的物理纵坐标在滚动簇内严格递增（没有被拆散）。
        try {
            # NavPanel -> 两行 Grid
            $sideGrid = $script:NavPanel.Child
            $rowNav = -1; $rowNote = -1
            $navSv = $null; $noteSp = $null
            foreach ($c in @($sideGrid.Children)) {
                $r = [System.Windows.Controls.Grid]::GetRow($c)
                if ($c -is [System.Windows.Controls.ScrollViewer]) { $navSv = $c; $rowNav = $r; continue }
                $noteSp = $c; $rowNote = $r
            }
            # 合并的证据：Task/Focus/Settings/Profile 必须全部落在同一个可滚动容器里
            $navSp = $null
            if ($null -ne $navSv) { $navSp = $navSv.Content -as [System.Windows.Controls.StackPanel] }
            $needBtns = @($script:NavMonth, $script:NavWeek, $script:NavList,
                          $script:NavTask, $script:NavFocus, $script:NavSettings, $script:NavProfile)
            $foundInNav = 0
            if ($null -ne $navSp) {
                $navBtns = @(Find-AllOfType $navSp ([System.Windows.Controls.Button]))
                foreach ($b in $needBtns) {
                    if ($null -eq $b) { continue }
                    foreach ($nb in $navBtns) {
                        if ([object]::ReferenceEquals($nb, $b)) { $foundInNav++; break }
                    }
                }
            }
            $rowsOk = (($rowNav -eq 0) -and ($rowNote -eq 1) -and ($null -ne $navSv) -and
                       ($null -ne $noteSp) -and ($foundInNav -eq 7))
            Write-AuditRow 'sidebar single nav column + note' $rowsOk `
                ('nav=' + $rowNav + ' note=' + $rowNote + ' navBtns=' + $foundInNav + '/7')

            try { $script:MainWindow.UpdateLayout() } catch { }
            # 注意：类型转换的优先级高于成员访问，"cast 后紧跟点号取成员"会先转换 $x 本身、
            # 再去被转换结果上取成员。所以这里统一用 [double]( 整个表达式 ) 的形式，杜绝歧义。
            $pt = New-Object System.Windows.Point (0.0, 0.0)
            $yNav  = [double]($navSv.TranslatePoint($pt, $script:NavPanel).Y)
            $yNote = [double]($noteSp.TranslatePoint($pt, $script:NavPanel).Y)
            $hPanel  = [double]$script:NavPanel.ActualHeight
            $noteBot = $yNote + [double]$noteSp.ActualHeight
            $orderOk = ($yNav -lt $yNote)
            $clipOk  = ($noteBot -le ($hPanel + 1.0))
            Write-AuditRow 'sidebar blocks top-to-bottom' ($orderOk -and $clipOk) `
                ('y=' + [int]$yNav + '/' + [int]$yNote +
                 ' noteBottom=' + [int]$noteBot + ' panelH=' + [int]$hPanel)

            # 关键回归（就是用户报的"脱节"）：导航簇内部按钮的纵坐标必须严格递增且**等距连续**，
            #   不允许中间出现一个明显的空档。上一版把这种空档设计进了布局（两组之间的余高），
            #   所以这条断言在旧代码上必挂 —— 它测的是"机制"，不是"数值"。
            $ys = New-Object System.Collections.Generic.List[double]
            $gaps = New-Object System.Collections.Generic.List[double]
            foreach ($b in @(@($script:NavMonth), @($script:NavWeek), @($script:NavList),
                             @($script:NavTask), @($script:NavFocus), @($script:NavSettings), @($script:NavProfile))) {
                if ($null -eq $b) { continue }
                $ys.Add([double]($b.TranslatePoint($pt, $navSp).Y))
            }
            $asc = $true
            for ($k = 1; $k -lt $ys.Count; $k++) {
                $gp = $ys[$k] - $ys[$k - 1]
                $gaps.Add($gp)
                if ($gp -le 0.0) { $asc = $false }
            }
            $gMax = 0.0
            $gMin = 9999.0
            foreach ($gp in $gaps) { if ($gp -gt $gMax) { $gMax = $gp }; if ($gp -lt $gMin) { $gMin = $gp } }
            # 七个按钮的步距必须一致（button 高 52 + margin 4 = 56；分隔线那处稍大），
            # 用一个宽松但有意义的上限：任何一步都不许超过最小步距的 2.5 倍。
            # "两组被余高撑开"会让某一步骤涨到几百像素，一定挂。
            $contOk = $asc -and ($ys.Count -eq 7) -and ($gMax -le ($gMin * 2.5 + 1.0))
            Write-AuditRow 'sidebar nav has no internal gap' $contOk `
                ('n=' + $ys.Count + ' minGap=' + [int]$gMin + ' maxGap=' + [int]$gMax + ' asc=' + [string]$asc)

            # 最小窗口高度（MinHeight=560）下，底部固定块必须放得下：
            #   room = 560 - 标题栏 42 - 外框上下各 2
            # 为什么不用"把窗口改矮再量"：改用 Width/Height 要靠 WM_SIZE 回到 UI 线程，
            # 这条消息什么时候被泵到是不确定的（实测同一段代码两次运行，一次生效、
            # 一次量到的还是旧尺寸），那种断言会假通过。改成解析式比较：结果只由布局决定。
            $needH = [double]$noteSp.ActualHeight
            $roomH = 560.0 - 42.0 - 4.0
            $fitOk = ($needH -le $roomH)
            Write-AuditRow 'sidebar fixed blocks fit min height' $fitOk `
                ('need=' + [int]$needH + ' room=' + [int]$roomH)
        } catch { Write-AuditRow 'sidebar single nav column + note' $false ('crash ' + $_.Exception.Message) }

        # ---- 28. 下拉框换肤（夜间模式白底白字的坑）----
        #   系统默认 ComboBox 模板里画底色的那块是 StaticResource，给 ComboBox.Background
        #   赋值根本不生效，于是夜间模式变成"白底 + 白字"，整个控件肉眼消失。
        #   断言落在物理量上：真正画底色的那个 Border 的颜色必须等于当前主题的 Card 色，
        #   且文字色必须与底色不同。默认模板下 PART_Toggle 取不到 -> 必挂。
        try {
            $cmbNotes = New-Object System.Collections.Generic.List[string]
            $cmbOk = $true
            $cmbLightRef = $null
            foreach ($th in @('light', 'night')) {
                Set-Theme $th -Sync
                Set-View 'week'
                try { $script:MainWindow.UpdateLayout() } catch { }
                $want = Col (Get-Pal 'Card')
                $bx = $script:WkRangeBox
                if ($null -eq $bx) { $cmbOk = $false; $cmbNotes.Add($th + ':no range box'); continue }
                [void]$bx.ApplyTemplate()
                $tg = $bx.Template.FindName('PART_Toggle', $bx)
                $br = $null
                if ($null -ne $tg) { $br = $tg.Background -as [System.Windows.Media.SolidColorBrush] }
                $fg = $bx.Foreground -as [System.Windows.Media.SolidColorBrush]
                $bgOk = ($null -ne $br) -and ($br.Color -eq $want)
                $fgOk = ($null -ne $fg) -and ($fg.Color -ne $want)
                $rowTxt = $th + ':bg=' + $(if ($null -ne $br) { $br.Color.ToString() } else { 'n/a' }) +
                          ' want=' + $want.ToString() + ' fgOk=' + [string]$fgOk
                if (-not ($bgOk -and $fgOk)) { $cmbOk = $false }
                # 列表页与任务页的筛选下拉也必须换肤。任务页那几个筛选是这一轮新加的，
                # 一并纳入断言（新控件最容易只走"代码里 new 出来的"那条路而漏掉借样式）。
                $lstOk = 0
                $lstNeed = 0
                $lstTxt = New-Object System.Collections.Generic.List[string]
                foreach ($vn in @('list', 'tasks')) {
                    Set-View $vn
                    try { $script:MainWindow.UpdateLayout() } catch { }
                    $boxes = @()
                    if ($vn -eq 'list') { $boxes = @($script:ListTagBox, $script:ListScopeBox) }
                    else { $boxes = @($script:TaskProjectBox, $script:TaskStatusBox, $script:TaskSortBox, $script:TaskScopeBox) }
                    foreach ($c in $boxes) {
                        $lstNeed++
                        if ($null -eq $c) { $lstTxt.Add($vn + ':null'); continue }
                        [void]$c.ApplyTemplate()
                        $tg2 = $c.Template.FindName('PART_Toggle', $c)
                        $br2 = $null
                        if ($null -ne $tg2) { $br2 = $tg2.Background -as [System.Windows.Media.SolidColorBrush] }
                        if ($null -eq $br2) { $lstTxt.Add($vn + ':noTpl'); continue }
                        if ($br2.Color -eq $want) { $lstOk++; $lstTxt.Add($vn + ':ok') }
                        else { $lstTxt.Add($vn + ':' + $br2.Color.ToString()) }
                    }
                }
                # 回到列表页：下面的 sameRef 诊断要拿"列表页的标签下拉"做跨轮比较
                Set-View 'list'
                try { $script:MainWindow.UpdateLayout() } catch { }
                if ($lstOk -lt $lstNeed) { $cmbOk = $false }
                # 对话框那批下拉框是"从主窗口借样式"（Apply-SharedComboStyle）。这里验证
                # 借到的那份已经是当前主题的色值 —— 这正是"换皮不换窗"漏搬资源字典那一环。
                try {
                    $probeBox = New-Object System.Windows.Controls.ComboBox
                    Apply-SharedComboStyle $probeBox
                    $pbg = $probeBox.Background -as [System.Windows.Media.SolidColorBrush]
                    $shareTxt = 'n/a'
                    if ($null -ne $pbg) { $shareTxt = $pbg.Color.ToString() }
                    if (($null -eq $pbg) -or ($pbg.Color -ne $want)) { $cmbOk = $false }
                    $cmbNotes.Add('share=' + $shareTxt)
                } catch { $cmbOk = $false; $cmbNotes.Add('share=crash') }
                # 诊断用：如果两轮拿到的是同一批对象，说明 Refresh-All 没重建列表视图，
                # 那么"颜色还是浅色"就是旧对象残留，而不是样式没跟上主题。
                $sameRef = $false
                if ($null -ne $cmbLightRef) { $sameRef = [object]::ReferenceEquals($cmbLightRef, $script:ListTagBox) }
                if ($th -eq 'light') { $cmbLightRef = $script:ListTagBox }
                $cmbNotes.Add($rowTxt + ' list=' + ($lstTxt -join ',') + ' sameRef=' + [string]$sameRef)
            }
            Set-Theme 'light' -Sync
            Set-View 'week'
            try { $script:MainWindow.UpdateLayout() } catch { }
            Write-AuditRow 'combo follows theme' $cmbOk ($cmbNotes -join '  ')
        } catch { Write-AuditRow 'combo follows theme' $false ('crash ' + $_.Exception.Message) }

        # ---- 29. 六个弹窗的标题栏按钮组：× 贴右边缘，Save / Cancel 紧邻其左侧 ----
        #   第三轮是"只有一个 × 贴右边"，第四轮改成三件套，所以断言同步升级：
        #     · 三个按钮（DlgSave / DlgCancel / DlgClose）都必须存在且都在标题栏（y ≤ 38）
        #     · 物理顺序必须是 Save < Cancel < ×（左到右），且 × 仍然贴右边缘
        #     · 三个按钮都必须在标题栏右半边（bx ≥ 宽度的一半）—— 防止被塞到左边
        #     · 底部仍然不许出现"关闭类"文字按钮（Cancel / Save / Close / OK…）
        #   为什么坚持量几何而不是只查存在：Grid 列宽写错时按钮依然"存在"，
        #   只是被裁掉一半或叠在一起 —— 那种情况肉眼截图才看得出，断言必须能自己发现。
        try {
            $dlgDefs = New-Object System.Collections.Generic.List[object]
            $dlgDefs.Add(@{ name = 'event';    win = (Show-EventEditorWindow -Id '') })
            $dlgDefs.Add(@{ name = 'settings'; win = (Show-SettingsWindow) })
            $dlgDefs.Add(@{ name = 'task';     win = (Show-TaskEditorWindow) })
            $dlgDefs.Add(@{ name = 'focus';    win = (Show-FocusWindow) })
            $dlgDefs.Add(@{ name = 'avatar';   win = (Show-AvatarWindow) })
            $dlgDefs.Add(@{ name = 'day';      win = (Show-DayAgendaWindow -Date ([datetime]::Today)) })
            $notes = New-Object System.Collections.Generic.List[string]
            $allOk = $true
            # 只禁"底部残留"那批文案。标题栏自己的三个按钮不在禁用范围里 ——
            # 它们靠 Name（DlgSave/DlgCancel/DlgClose）识别，并用几何位置区分"在不在标题栏"。
            $banned = @('Cancel', 'Save', 'Close', 'Save & close', 'Save and close', 'OK')
            $barNames = @('DlgSave', 'DlgCancel', 'DlgClose')
            $pt0 = New-Object System.Windows.Point(0.0, 0.0)
            foreach ($d in $dlgDefs) {
                $w = $d['win']
                $nm = [string]$d['name']
                if ($null -eq $w) { $allOk = $false; $notes.Add($nm + ':null'); continue }
                try { $w.UpdateLayout() } catch { }
                $root = Measure-DialogContent $w
                if ($null -eq $root) { $allOk = $false; $notes.Add($nm + ':noContent'); continue }
                $rw = [double]$root.ActualWidth
                $xs = @{}
                $missing = ''
                foreach ($bn in $barNames) {
                    $hit = Find-DialogButton $w $bn
                    if ($null -eq $hit) { $missing += $bn + ','; continue }
                    $xs[$bn] = @{
                        x = [double]($hit.TranslatePoint($pt0, $root).X)
                        y = [double]($hit.TranslatePoint($pt0, $root).Y)
                        r = [double]($hit.TranslatePoint($pt0, $root).X) + [double]$hit.ActualWidth
                        w = [double]$hit.ActualWidth
                    }
                }
                if ($missing) {
                    $allOk = $false
                    $notes.Add($nm + ':missing=' + $missing.TrimEnd(','))
                    try { $w.Close() } catch { }
                    continue
                }
                $okX = $xs['DlgClose']; $okS = $xs['DlgSave']; $okC = $xs['DlgCancel']
                # 宽度必须量到真实值，否则"贴右边"这条断言会变成空转
                $wideOk = ($rw -ge 300.0)
                $edgeOk = $wideOk -and ($okX.r -ge ($rw - 20.0))
                $orderOk = ($okS.r -lt $okC.x) -and ($okC.r -lt $okX.x)
                $inBarOk = ($okX.y -le 38.0) -and ($okS.y -le 38.0) -and ($okC.y -le 38.0)
                # 三个按钮都得真的落在标题栏右半边，且宽度没被压扁（> 20px 才能显示文字）
                $halfOk = $wideOk -and ($okS.x -ge ($rw * 0.5)) -and ($okC.x -ge ($rw * 0.5))
                $fitOk = ($okS.w -ge 40.0) -and ($okC.w -ge 40.0) -and ($okX.w -ge 18.0)
                # 底部残留扫描：允许标题栏这三个（它们本来就叫这些名字）
                $leftover = 0
                foreach ($b in @(Find-AllOfType $w ([System.Windows.Controls.Primitives.ButtonBase]))) {
                    if ($barNames -contains [string]$b.Name) { continue }
                    $c = $b.Content
                    if ($c -is [System.Windows.Controls.TextBlock]) { $c = $c.Text }
                    if ($banned -contains [string]$c) { $leftover++ }
                }
                $ok = $edgeOk -and $orderOk -and $inBarOk -and $halfOk -and $fitOk -and ($leftover -eq 0)
                if (-not $ok) { $allOk = $false }
                $notes.Add(('{0}: save={1} cancel={2} x={3}/{4} y={5} leftover={6}' -f `
                    $nm, [int]$okS.x, [int]$okC.x, [int]$okX.r, [int]$rw, [int]$okX.y, $leftover))
                try { $w.Close() } catch { }
            }
            Write-AuditRow 'dialog bar has save+cancel+x' $allOk ($notes -join '  ')
        } catch { Write-AuditRow 'dialog bar has save+cancel+x' $false ('crash ' + $_.Exception.Message) }

        # ---- 29b. × 要真的关窗并保存；Save 与 × 等价；Cancel 关窗但**不**落库 ----
        #   三条链路分别验：
        #     ① × 关窗 + 设置落库（第三轮就有的能力，不能因为加按钮而退化）
        #     ② Save 也关窗 + 落库（它走的是"打 Click 给 ×"，靠这条证明转发真的成立）
        #     ③ Cancel 关窗但设置**不变**（这是本轮新增的能力，也是用户要的"不保存关闭"）
        #   第 ③ 条最关键：Cancel 如果被误接成和 Save 同一个处理器，
        #   前两条依然全绿，用户却会发现"点 Cancel 它还是给我存了"。
        try {
            $keepPomo0 = [int]$script:Settings['PomodoroMin']

            # ① × = 保存并关闭
            $script:DlgClosed = ''
            $sw2 = Show-SettingsWindow
            $sw2.Add_Closed({ $script:DlgClosed = 'settings' })
            $sw2.UpdateLayout()
            $script:SetTbPomo.Text = '45'
            [void](Invoke-Click (Find-DialogClose $sw2))
            $okX1 = ($script:DlgClosed -eq 'settings') -and ([int]$script:Settings['PomodoroMin'] -eq 45)
            $script:Settings['PomodoroMin'] = $keepPomo0
            Save-Settings; Reset-Pomodoro

            # ② Save = 同 × （打 Click 转发）
            $script:DlgClosed = ''
            $sw3 = Show-SettingsWindow
            $sw3.Add_Closed({ $script:DlgClosed = 'settings-save' })
            $sw3.UpdateLayout()
            $script:SetTbPomo.Text = '50'
            [void](Invoke-Click (Find-DialogButton $sw3 'DlgSave'))
            $okS2 = ($script:DlgClosed -eq 'settings-save') -and ([int]$script:Settings['PomodoroMin'] -eq 50)
            $script:Settings['PomodoroMin'] = $keepPomo0
            Save-Settings; Reset-Pomodoro

            # ③ Cancel = 关窗但不落库
            $script:DlgClosed = ''
            $sw4 = Show-SettingsWindow
            $sw4.Add_Closed({ $script:DlgClosed = 'settings-cancel' })
            $sw4.UpdateLayout()
            $script:SetTbPomo.Text = '77'
            [void](Invoke-Click (Find-DialogButton $sw4 'DlgCancel'))
            $okC3 = ($script:DlgClosed -eq 'settings-cancel') -and ([int]$script:Settings['PomodoroMin'] -eq $keepPomo0)
            $script:Settings['PomodoroMin'] = $keepPomo0
            Save-Settings; Reset-Pomodoro

            # 当日议程窗口：Save / Cancel 都要能关掉它（只读面板，两者等价）
            $script:DlgClosed = ''
            $dw2 = Show-DayAgendaWindow -Date ([datetime]::Today)
            $dw2.Add_Closed({ $script:DlgClosed = 'day' })
            $dw2.UpdateLayout()
            [void](Invoke-Click (Find-DialogClose $dw2))
            $okD = ($script:DlgClosed -eq 'day')
            $script:DlgClosed = ''
            $dw3 = Show-DayAgendaWindow -Date ([datetime]::Today)
            $dw3.Add_Closed({ $script:DlgClosed = 'day-cancel' })
            $dw3.UpdateLayout()
            [void](Invoke-Click (Find-DialogButton $dw3 'DlgCancel'))
            $okD2 = ($script:DlgClosed -eq 'day-cancel')

            Write-AuditRow 'dialog x / save / cancel wiring' ($okX1 -and $okS2 -and $okC3 -and $okD -and $okD2) `
                ('x=' + $okX1 + ' save=' + $okS2 + ' cancel-keeps=' + $okC3 + ' day=' + $okD + ' dayCancel=' + $okD2)
        } catch { Write-AuditRow 'dialog x / save / cancel wiring' $false ('crash ' + $_.Exception.Message) }

        # ---- 30. 月视图每页只画本月：1 号起、当月最后一天止 ----
        try {
            $keepAnchor = $script:Anchor
            Set-View 'month'
            try { $script:MainWindow.UpdateLayout() } catch { }
            $info = $script:MonthPageInfo
            $shown = @($script:MonthDaysShown)
            $nums = @($shown | Where-Object { $_ -gt 0 })
            $days = [int]$info['Days']
            $rows = [int]$info['Rows']
            $seqOk = ($nums.Count -eq $days) -and ([int]$nums[0] -eq 1) -and ([int]$nums[-1] -eq $days)
            $contOk = $true
            for ($i = 0; $i -lt $nums.Count; $i++) { if ([int]$nums[$i] -ne ($i + 1)) { $contOk = $false; break } }
            $cellsOk = ($shown.Count -eq ($rows * 7))
            $rowsOk = (@($script:MonthGridRoot.RowDefinitions).Count -eq ($rows + 1))
            $headBlank = [int]$info['Offset']
            $tailBlank = ($rows * 7) - $headBlank - $days
            $headOk = $true
            for ($i = 0; $i -lt $headBlank; $i++) { if ([int]$shown[$i] -ne 0) { $headOk = $false } }
            $tailOk = $true
            for ($i = ($headBlank + $days); $i -lt $shown.Count; $i++) { if ([int]$shown[$i] -ne 0) { $tailOk = $false } }
            $blankCnt = @($shown | Where-Object { $_ -eq 0 }).Count
            $padOk = ($blankCnt -eq ($headBlank + $tailBlank)) -and $headOk -and $tailOk
            Write-AuditRow 'month page = 1st..last day' ($seqOk -and $contOk -and $cellsOk -and $rowsOk -and $padOk) `
                ('days=' + $days + ' rows=' + $rows + ' offset=' + $headBlank + ' cells=' + $shown.Count +
                 ' blanks=' + $blankCnt + ' gridRows=' + @($script:MonthGridRoot.RowDefinitions).Count +
                 ' first=' + [int]$nums[0] + ' last=' + [int]$nums[-1] + ' cont=' + $contOk)

            # 邻月日程不许漏进本页：在本月前一天 / 后一天各插一条探针，页面里必须一条都扫不到
            $first = [datetime]::new($keepAnchor.Year, $keepAnchor.Month, 1)
            $lastD = [datetime]::new($keepAnchor.Year, $keepAnchor.Month,
                [datetime]::DaysInMonth($keepAnchor.Year, $keepAnchor.Month))
            $pa = 'AUDITPREV' + (Get-Random -Minimum 1000 -Maximum 9999)
            $pb = 'AUDITNEXT' + (Get-Random -Minimum 1000 -Maximum 9999)
            $probes = New-Object System.Collections.ArrayList
            foreach ($pr in @(@{ d = $first.AddDays(-1); t = $pa }, @{ d = $lastD.AddDays(1); t = $pb })) {
                $obj = [pscustomobject]@{
                    id = (New-Id); date = (Fmt-Date $pr.d); start = 600; end = 660
                    title = $pr.t; tag = 'work'; note = ''; done = $false
                    repeat = 'none'; repeatEvery = 1; repeatUntil = ''; repeatMonthMode = 'day'
                    reminderMin = 0; reminderKey = ''
                }
                [void]$script:Events.Add($obj)
                [void]$probes.Add($obj)
            }
            Set-View 'month'
            try { $script:MainWindow.UpdateLayout() } catch { }
            $texts = @(Find-AllOfType $script:MonthGridRoot ([System.Windows.Controls.TextBlock]) |
                ForEach-Object { [string]$_.Text })
            $leak = 0
            foreach ($tx in $texts) { if (($tx -like ($pa + '*')) -or ($tx -like ($pb + '*'))) { $leak++ } }
            Write-AuditRow 'month page hides other months' ($leak -eq 0) `
                ('leak=' + $leak + ' texts=' + $texts.Count + ' probes=' + $probes.Count)
            foreach ($o in $probes) { [void]$script:Events.Remove($o) }

            # 行数按需（不再是死板的 6 行）：2027-02 是 4 行、2026-08 是 6 行
            $script:Anchor = [datetime]::new(2027, 2, 1)
            Set-View 'month'
            $rFeb = @($script:MonthGridRoot.RowDefinitions).Count - 1
            $nFeb = @($script:MonthDaysShown | Where-Object { $_ -gt 0 }).Count
            $script:Anchor = [datetime]::new(2026, 8, 1)
            Set-View 'month'
            $rAug = @($script:MonthGridRoot.RowDefinitions).Count - 1
            $script:Anchor = $keepAnchor
            Set-View 'month'
            try { $script:MainWindow.UpdateLayout() } catch { }
            Write-AuditRow 'month rows grow with the month' (($rFeb -eq 4) -and ($nFeb -eq 28) -and ($rAug -eq 6)) `
                ('feb2027 rows=' + $rFeb + ' days=' + $nFeb + '  aug2026 rows=' + $rAug)
        } catch { Write-AuditRow 'month page = 1st..last day' $false ('crash ' + $_.Exception.Message) }

        # ---- 31. 任务卡版式：正文占满整宽 + 卡片上只留 2 个高频动作 + 不横向溢出 ----
        #   旧版把信息拆进 4 列（24/star/52/104），316px 的侧栏里正文只剩 ~117px；
        #   第三轮又把 Edit / Del 从卡片挪进"双击展开"的详情面板，卡片上只剩 Focus / +1。
        #   所以断言同步改成 acts=2（Focus/+1 同一行、不溢出），并额外验证：
        #   双击展开后 Edit / Delete 必须出现在面板里（这是本轮的核心诉求，不能只靠肉眼）。
        try {
            $probeTask = [pscustomobject]@{
                id = 'AUDIT-LAYOUT'; text = 'Audit layout probe task with a long enough title to wrap'
                done = $false; due = (Fmt-Date ([datetime]::Today.AddDays(3))); dueTime = '14:30'
                tag = 'task'; priority = 'high'; project = 'AuditLayout'
                subtasks = @([pscustomobject]@{ id = 's1'; text = 'sub'; done = $false })
                estimatedMin = 45; actualMin = 10; reminderMin = 0
            }
            [void]$script:Tasks.Add($probeTask)
            $script:TaskExpandedId = ''
            Set-View 'tasks'
            Fill-Tasks
            try { $script:MainWindow.UpdateLayout() } catch { }
            $target = $null
            foreach ($r in @($script:TaskStack.Children)) {
                if ($null -ne $r.Tag -and [string]$r.Tag['id'] -eq 'AUDIT-LAYOUT') { $target = $r; break }
            }
            if ($null -eq $target) {
                Write-AuditRow 'task card layout' $false 'probe row not found'
            } else {
                $bodyTxt = $null
                foreach ($tb in @(Find-AllOfType $target ([System.Windows.Controls.TextBlock]))) {
                    if ([double]$tb.FontSize -eq 12.0) { $bodyTxt = $tb; break }
                }
                $bodyW = 0.0
                if ($null -ne $bodyTxt) { $bodyW = [double]$bodyTxt.ActualWidth }
                $pt1 = New-Object System.Windows.Point(0.0, 0.0)
                $acts = New-Object System.Collections.ArrayList
                foreach ($b in @(Find-AllOfType $target ([System.Windows.Controls.Primitives.ButtonBase]))) {
                    $c = $b.Content
                    if ($c -is [System.Windows.Controls.TextBlock]) { $c = $c.Text }
                    if (@('Focus', '+1') -contains [string]$c) { [void]$acts.Add($b) }
                }
                $ys = New-Object System.Collections.ArrayList
                $rightMost = 0.0
                foreach ($a in $acts) {
                    [void]$ys.Add([int][math]::Round([double]($a.TranslatePoint($pt1, $target).Y)))
                    $rx = [double]($a.TranslatePoint($pt1, $target).X) + [double]$a.ActualWidth
                    if ($rx -gt $rightMost) { $rightMost = $rx }
                }
                $oneRow = ($acts.Count -eq 2) -and ((@($ys | Sort-Object -Unique)).Count -eq 1)
                $noClip = ($rightMost -le ([double]$target.ActualWidth + 1.0)) -and ($rightMost -gt 0.0)
                $wideOk = ($bodyW -ge 200.0)
                Write-AuditRow 'task card layout' ($oneRow -and $noClip -and $wideOk) `
                    ('bodyW=' + [int]$bodyW + ' acts=' + $acts.Count + ' ys=' + ($ys -join '/') +
                     ' right=' + [int]$rightMost + '/' + [int]$target.ActualWidth)

                # ---- 31b. 双击任务卡 -> 直接打开任务编辑窗口（第四轮改版） ----
                #   用户原话："双击 task 中的任务，不能调出修改界面"。
                #   第三轮的实现是"双击展开行内只读面板 + 再点 Edit"，用户不认这个 ——
                #   要的是双击就进编辑界面。这里用真实鼠标路由
                #   （Invoke-MouseDown/Up with ClickCount=2）驱动，不去直接调 Open-TaskEditor：
                #   否则测的是"我会不会调函数"，而不是"双击这条路到底通不通"。
                #
                #   断言落在 $script:LastModalCall 上 —— 编辑窗口入口 Open-TaskEditor
                #   在 SuppressModal 模式下只记一笔 'taskeditor:<id>' 就返回（不真弹窗，
                #   否则 ShowDialog 会卡死调度器）。所以"双击真的走到了开窗入口"这件事
                #   是可观测的，不是靠肉眼。
                $script:TaskExpandedId = ''
                # 先把状态筛选切到 All：双击的第一下会（延后）把任务勾成已完成，
                # 若停在"未完成"筛选上卡片会消失，后面的断言就没得看了。
                if ($null -ne $script:TaskStatusBox) { $script:TaskStatusBox.SelectedIndex = 0 }
                Fill-Tasks
                try { $script:MainWindow.UpdateLayout() } catch { }
                $target2 = $null
                foreach ($r in @($script:TaskStack.Children)) {
                    if ($null -ne $r.Tag -and [string]$r.Tag['id'] -eq 'AUDIT-LAYOUT') { $target2 = $r; break }
                }
                $script:LastModalCall = ''
                # 双击 = 两次 ClickCount=1/2 的 Down+Up（WPF 就是这么派发的）
                if ($null -ne $target2) {
                    [void](Invoke-MouseDown -Target $target2 -Source $target2 -Count 1)
                    [void](Invoke-MouseUp -Target $target2 -Source $target2 -Count 1)
                    [void](Invoke-MouseDown -Target $target2 -Source $target2 -Count 2)
                    [void](Invoke-MouseUp -Target $target2 -Source $target2 -Count 2)
                }
                $dblCall = [string]$script:LastModalCall
                # 双击的第一下会排一次"待勾选完成"，双击必须把它取消掉 ——
                # 否则用户双击看一眼编辑界面，回来发现任务被勾掉了。
                $dblCancelled = [string]::IsNullOrWhiteSpace([string]$script:PendingTaskId)
                $dblOk = ($dblCall -eq 'taskeditor:AUDIT-LAYOUT') -and $dblCancelled
                Write-AuditRow 'task double-click opens editor' $dblOk `
                    ('lastModal=' + $dblCall + ' pendingCleared=' + [string]$dblCancelled +
                     ' target=' + [string]($null -ne $target2))

                # ---- 31c. 卡片上的 ▾/▸ 按钮仍能展开行内详情面板，Edit / Delete 在里面 ----
                #   双击改语义之后，"看详情 + Edit/Delete" 这个能力不能丢，
                #   只是入口从"隐藏的双击"换成"看得见的按钮"。这条断言就是它的护栏。
                $script:TaskExpandedId = ''
                Fill-Tasks
                try { $script:MainWindow.UpdateLayout() } catch { }
                $card3 = $null
                foreach ($r in @($script:TaskStack.Children)) {
                    if ($null -ne $r.Tag -and [string]$r.Tag['id'] -eq 'AUDIT-LAYOUT') { $card3 = $r; break }
                }
                $expBtn = $null
                $beforeEdit = 0
                $btnNames = New-Object System.Collections.ArrayList
                if ($null -ne $card3) {
                    foreach ($b in @(Find-AllOfType $card3 ([System.Windows.Controls.Primitives.ButtonBase]))) {
                        $c = $b.Content
                        if ($c -is [System.Windows.Controls.TextBlock]) { $c = $c.Text }
                        [void]$btnNames.Add([string]$c)
                        if (@('Edit', 'Delete', 'Del') -contains [string]$c) { $beforeEdit++ }
                        if ($null -ne $b.Tag -and ($b.Tag -is [hashtable]) -and
                            [string]$b.Tag['kind'] -eq 'task-expand') { $expBtn = $b }
                    }
                }
                if ($null -ne $expBtn) { [void](Invoke-Click $expBtn) }
                try { $script:MainWindow.UpdateLayout() } catch { }
                # 展开会重建整列卡片，$card3 / $expBtn 都是脱离可视树的旧引用，
                # 必须按 id 从 TaskStack 重新取一次（第三轮在这里栽过）。
                $card4 = $null
                foreach ($r in @($script:TaskStack.Children)) {
                    if ($null -ne $r.Tag -and [string]$r.Tag['id'] -eq 'AUDIT-LAYOUT') { $card4 = $r; break }
                }
                $expandedId = [string]$script:TaskExpandedId
                $afterEdit = 0
                $hasTitleLine = $false
                if ($null -ne $card4) {
                    foreach ($b in @(Find-AllOfType $card4 ([System.Windows.Controls.Primitives.ButtonBase]))) {
                        $c = $b.Content
                        if ($c -is [System.Windows.Controls.TextBlock]) { $c = $c.Text }
                        if (@('Edit', 'Delete') -contains [string]$c) { $afterEdit++ }
                    }
                    # 详情面板要有"标签 + 值"这种结构化行（Title / Due / Priority…）
                    foreach ($tb in @(Find-AllOfType $card4 ([System.Windows.Controls.TextBlock]))) {
                        if (@('Title', 'Due', 'Priority') -contains [string]$tb.Text) { $hasTitleLine = $true; break }
                    }
                }
                $caretOk = ($null -ne $expBtn) -and ($expandedId -eq 'AUDIT-LAYOUT') -and
                           ($beforeEdit -eq 0) -and ($afterEdit -ge 2) -and $hasTitleLine
                Write-AuditRow 'task details toggle via caret' $caretOk `
                    ('caretFound=' + [string]($null -ne $expBtn) + ' expanded=' + $expandedId +
                     ' editBefore=' + $beforeEdit + ' editAfter=' + $afterEdit +
                     ' fields=' + [string]$hasTitleLine + ' btns=[' + ($btnNames -join '|') + ']')
                # 再点一次必须收起（不能只开不合）
                if ($null -ne $card4) {
                    foreach ($b in @(Find-AllOfType $card4 ([System.Windows.Controls.Primitives.ButtonBase]))) {
                        if ($null -ne $b.Tag -and ($b.Tag -is [hashtable]) -and
                            [string]$b.Tag['kind'] -eq 'task-expand') { [void](Invoke-Click $b); break }
                    }
                }
                Write-AuditRow 'task caret toggles closed' ([string]::IsNullOrEmpty([string]$script:TaskExpandedId)) `
                    ('expanded=' + [string]$script:TaskExpandedId + ' kids=' + @($script:TaskStack.Children).Count)
                $script:TaskExpandedId = ''
            }
            [void]$script:Tasks.Remove($probeTask)
            Fill-Tasks
        } catch { Write-AuditRow 'task card layout' $false ('crash ' + $_.Exception.Message) }

        # ---- 32. 月视图补位格：相邻月份的浅色日号 ----
        #   每页只画本月 -> 首尾必然空出几格。断言这些格子确实补上了日号、
        #   日号恰好是相邻月份的连续日期、而且一个都不落进本月。
        try {
            $keepAnchor = $script:Anchor
            $script:Anchor = [datetime]::new(2026, 9, 24)
            Set-View 'month'
            try { $script:MainWindow.UpdateLayout() } catch { }
            $pi = $script:MonthPageInfo
            $pads = @($script:MonthPadDates)
            $first = [datetime]::new(2026, 9, 1)
            $days = [datetime]::DaysInMonth(2026, 9)
            $wantPad = ($pi.Rows * 7) - $days
            # 前导补位 = 8/31（offset=1 所以只有 1 个），后随 = 10/1..10/4
            $wantLead = @()
            for ($i = $pi.Offset; $i -ge 1; $i--) { $wantLead += (Fmt-Date $first.AddDays(-$i)) }
            $wantTail = @()
            for ($i = 0; $i -lt ($wantPad - $pi.Offset); $i++) { $wantTail += (Fmt-Date $first.AddDays($days + $i)) }
            $wantAll = @($wantLead + $wantTail)
            $orderOk = ($pads.Count -eq $wantAll.Count)
            if ($orderOk) {
                for ($i = 0; $i -lt $pads.Count; $i++) { if ($pads[$i] -ne $wantAll[$i]) { $orderOk = $false; break } }
            }
            # 补位格里不能混进本月的日子
            $leak = 0
            foreach ($p in $pads) {
                $d = Parse-Date $p
                if ($d.Month -eq 9 -and $d.Year -eq 2026) { $leak++ }
            }
            # 无空缺的月份（2027-02 正好 4 整周）必须一格补位都没有
            $script:Anchor = [datetime]::new(2027, 2, 1)
            Set-View 'month'
            try { $script:MainWindow.UpdateLayout() } catch { }
            $febPads = @($script:MonthPadDates).Count
            $script:Anchor = $keepAnchor
            Set-View 'month'
            Write-AuditRow 'month pad cells fill the gaps' `
                (($pads.Count -eq $wantPad) -and $orderOk -and ($leak -eq 0) -and ($febPads -eq 0)) `
                ('sep2026 pads=' + $pads.Count + '/' + [string]$wantPad + ' order=' + [string]$orderOk +
                 ' leak=' + [string]$leak + '  feb2027 pads=' + [string]$febPads +
                 '  [' + ($pads -join ',') + ']')
        } catch { Write-AuditRow 'month pad cells fill the gaps' $false ('crash ' + $_.Exception.Message) }

        # ---- 33. 周视图高度自适应：拉高窗口后不能留空白 ----
        #   断言"轴的总像素高 ≥ 可视高"（容 6px 取整误差）——这正是"底部一大片空白"的反面。
        #   同时断言下限：HourHeight 永远不小于设计密度，所以窗口不高时行为与过去一致。
        try {
            $h0 = [double]$script:MainWindow.ActualHeight
            $script:MainWindow.Height = 820.0
            [void](Set-WeekRange 8 20)
            Set-View 'week'
            try { $script:MainWindow.UpdateLayout() } catch { }
            [void](Reflow-WeekHeight)
            try { $script:MainWindow.UpdateLayout() } catch { }
            $h1 = [double]$script:MainWindow.ActualHeight
            $hh = [double]$script:HourHeight
            $axisPx = [double](Week-RangeRows) * $hh
            $vp = 0.0
            if ($null -ne $script:WeekScroll) { $vp = [double]$script:WeekScroll.ViewportHeight }
            $filled = ($vp -le 1.0) -or (($axisPx + 6.0) -ge $vp)
            $floorOk = ($hh -ge ([double]$script:HourHeightBase - 0.01))
            $grew = ($hh -gt [double]$script:HourHeightBase)
            Write-AuditRow 'week axis fills tall window' ($filled -and $floorOk) `
                ('win=' + [int]$h0 + '->' + [int]$h1 + ' vp=' + [int]$vp + ' hourH=' + $hh +
                 ' axis=' + [int]$axisPx + ' grew=' + [string]$grew)
            # 回到基准尺寸 + 全天范围：确认"参考尺寸下行为不变"（HourHeight 应回到 40）
            $script:MainWindow.Height = 720.0
            [void](Set-WeekRange 0 24)
            Set-View 'week'
            try { $script:MainWindow.UpdateLayout() } catch { }
            [void](Reflow-WeekHeight)
            $hh2 = [double]$script:HourHeight
            Write-AuditRow 'week density unchanged at 24h' ([math]::Abs($hh2 - 40.0) -lt 0.6) `
                ('hourH=' + $hh2 + ' base=' + [string]$script:HourHeightBase)
        } catch { Write-AuditRow 'week axis fills tall window' $false ('crash ' + $_.Exception.Message) }

        # ---- 34. 侧栏：七个入口合并成一条连续导航（修"上下脱节"）----
        #   上一轮的设计是"主导航可滚动 + 次导航固定在底部一簇"，多余的窗口高度落在两簇
        #   中间——本意是填洞，实际观感就是断成两截（用户原话"左侧栏上下部分脱节了"）。
        #   这一轮的断言直接反向：NavTask 必须**在** ScrollViewer 内部（和 Month/Week/List
        #   同一簇），并且 NavPanel 的直接子级 Grid 只能有 2 行（导航 + DAILY NOTE）。
        try {
            $navScroll = $null
            $navPanelEl = $null
            foreach ($el in @(Find-AllOfType $script:MainWindow ([System.Windows.Controls.ScrollViewer]))) {
                try {
                    if ([string]$el.Name -eq '' -and $null -ne $script:NavMonth) {
                        # 侧栏那个 ScrollViewer 没起名，用"它的子树里有没有 NavMonth"来认
                        foreach ($b in @(Find-AllOfType $el ([System.Windows.Controls.Button]))) {
                            if ([object]::ReferenceEquals($b, $script:NavMonth)) { $navScroll = $el; break }
                        }
                    }
                } catch { }
                if ($null -ne $navScroll) { break }
            }
            $navPanelEl = $script:NavPanel
            $taskInScroll = $false
            if ($null -ne $navScroll -and $null -ne $script:NavTask) {
                $p = $script:NavTask.Parent
                $hop = 0
                while ($null -ne $p -and $hop -lt 20) {
                    $hop++
                    if ([object]::ReferenceEquals($p, $navScroll)) { $taskInScroll = $true; break }
                    $p = $p.Parent
                }
            }
            $pt = New-Object System.Windows.Point(0.0, 0.0)
            $yList = [double]$script:NavList.TranslatePoint($pt, $navPanelEl).Y
            $yTask = [double]$script:NavTask.TranslatePoint($pt, $navPanelEl).Y
            # Month/Week/List/Tasks 四者纵坐标严格递增 = 真的排成一列（没有被拆到两个容器里）
            $orderOk = ($yList -lt $yTask)
            $gridOk = $false
            $rowCount = 0
            try {
                $g = $script:NavPanel.Child
                $rowCount = @($g.RowDefinitions).Count
                # 2 行：导航（*）+ DAILY NOTE（Auto）。>=4 就是旧结构回来了。
                $gridOk = ($g -is [System.Windows.Controls.Grid]) -and ($rowCount -eq 2)
            } catch { $gridOk = $false }
            Write-AuditRow 'sidebar nav is one continuous column' ($taskInScroll -and $orderOk -and $gridOk) `
                ('taskInScroll=' + [string]$taskInScroll + ' y(list/task)=' + [int]$yList + '/' + [int]$yTask +
                 ' rows=' + $rowCount)
        } catch { Write-AuditRow 'sidebar nav is one continuous column' $false ('crash ' + $_.Exception.Message) }

        # ---- 35. Focus 浮窗：可拖动 + 记住位置 ----
        #   拖动本身没法在无头环境里真跑（DragMove 是模态循环），所以断言落在
        #   "拖动所依赖的三件事"上：① 窗口是 Manual 定位（否则赋的 Left/Top 被 CenterOwner 盖掉）
        #   ② 有记忆时回到记忆的位置 ③ 抓手存在（计时器卡片 Cursor=SizeAll + 提示文字）
        try {
            $script:Settings['FocusWinLeft'] = 321.0
            $script:Settings['FocusWinTop'] = 234.0
            $fw = Show-FocusWindow
            $posOk = ([string]$fw.WindowStartupLocation -eq 'Manual') -and
                     ([math]::Abs([double]$fw.Left - 321.0) -lt 1.5) -and
                     ([math]::Abs([double]$fw.Top - 234.0) -lt 1.5)
            $grip = $null
            foreach ($b in @(Find-AllOfType $fw ([System.Windows.Controls.Border]))) {
                if ($null -ne $b.ToolTip -and ([string]$b.ToolTip) -match 'Drag here') { $grip = $b; break }
            }
            $gripOk = ($null -ne $grip) -and ([string]$grip.Cursor -eq 'SizeAll')
            try { $fw.Close() } catch { }
            # 没记忆时必须落到主窗口附近的可视范围内（别把窗口甩到屏幕外）
            $script:Settings['FocusWinLeft'] = -1
            $script:Settings['FocusWinTop'] = -1
            $fw2 = Show-FocusWindow
            $within = ([double]$fw2.Left -gt -5000.0) -and ([double]$fw2.Top -gt -5000.0)
            try { $fw2.Close() } catch { }
            Write-AuditRow 'focus window draggable + remembers' ($posOk -and $gripOk -and $within) `
                ('manual+pos=' + [string]$posOk + ' grip=' + [string]$gripOk + ' freshAt=' + [int]$fw2.Left + ',' + [int]$fw2.Top)
        } catch { Write-AuditRow 'focus window draggable + remembers' $false ('crash ' + $_.Exception.Message) }

        # ---- 36. 点期间标题 -> 日历跳转 ----
        #   用户报"日程中各个视图的日期不可自由选择跳转"。修法是把 CalPeriod 变成可点的，
        #   弹出真正的月历：能翻月份 + 点任一天。
        #   断言分三层，缺一层都可能假通过：
        #     ① 标题上确实挂了处理器、并且是 Hand 光标（没有的话就是"点了没反应"）
        #     ② 弹窗里画出了正确的天数与起始位置（9 月 2026 必须 30 天、首个格子落在周二）
        #     ③ 点某一天之后 $script:Anchor 与 $script:Selected 都要跟着走，
        #        且三个视图各自跳到"对的页"——这才是用户要的"自由跳转"。
        try {
            $cursorOk = ([string]$script:CalPeriod.Cursor -eq 'Hand') -and ($null -ne $script:CalPeriod.ToolTip)
            $dp = Show-PeriodPickerWindow
            try { $dp.UpdateLayout() } catch { }
            # 打开时显示的月份必须跟随当前 Anchor
            $script:Anchor = [datetime]::new(2026, 9, 24)
            $dp2 = Show-PeriodPickerWindow
            try { $dp2.UpdateLayout() } catch { }
            $cells = @($script:DpCells)
            $dayCells = 0
            $firstDayPos = -1
            for ($i = 0; $i -lt $cells.Count; $i++) {
                $c = $cells[$i]
                if ($c.IsEnabled -and -not [string]::IsNullOrWhiteSpace([string]$c.Content)) {
                    if ($firstDayPos -lt 0) { $firstDayPos = $i }
                    $dayCells++
                }
            }
            # 2026-09-01 是周二 -> 周一为首列时是第 2 列；前导补位 1 格，所以第一个可点格 index=1
            $gridOk = ($dayCells -eq 30) -and ($firstDayPos -eq 1) -and ($cells.Count -eq 42)
            try { $dp.Close() } catch { }
            try { $dp2.Close() } catch { }

            # 点 2026-10-15：三个视图分别应该跳过去
            $script:Anchor = [datetime]::new(2026, 9, 24)
            $script:Selected = [datetime]::new(2026, 9, 24)
            $dp3 = Show-PeriodPickerWindow
            try { $dp3.UpdateLayout() } catch { }
            $hitCell = $null
            foreach ($c in @($script:DpCells)) {
                if ($null -eq $c.Tag) { continue }
                $tag = $c.Tag
                if ($tag['date'] -is [datetime] -and ([datetime]$tag['date']).Date -eq ([datetime]::new(2026, 9, 15))) { $hitCell = $c; break }
            }
            $clickOk = $false
            if ($null -ne $hitCell) {
                [void](Invoke-Click $hitCell)
                $clickOk = ($script:Anchor.Date -eq ([datetime]::new(2026, 9, 15))) -and
                           ($script:Selected.Date -eq ([datetime]::new(2026, 9, 15)))
            }
            try { $dp3.Close() } catch { }
            Write-AuditRow 'period picker opens + jumps' ($cursorOk -and $gridOk -and $clickOk) `
                ('cursor=' + [string]$cursorOk + ' days=' + $dayCells + ' firstAt=' + $firstDayPos +
                 ' cells=' + $cells.Count + ' jump=' + [string]$clickOk +
                 ' anchor=' + $script:Anchor.ToString('yyyy-MM-dd'))
        } catch { Write-AuditRow 'period picker opens + jumps' $false ('crash ' + $_.Exception.Message) }

        # ---- 37. 番茄钟时长 0-99 自由填 ----
        #   用户要的是"0:00-99:00 可以自由选择"。断言必须覆盖两个方向：
        #     ① 边界值 0 与 99 都要被接受（旧代码 1-180 会把 0 判非法）
        #     ② 越界值 -1 与 100 都要被拒（否则"自由"会变成"随便填什么都能存"）
        #   还要验 0 真的被当成"不计时"存下来而不是回落到 25 ——
        #   老代码里的 `if ($mins -lt 1) { $mins = 25 }` 正是那个会让 0 永远存不住的坑。
        try {
            $keepPomoMin = $script:Settings['PomodoroMin']
            $dpFocus = Show-FocusWindow
            $caseLog = New-Object System.Collections.Generic.List[string]
            $allOk = $true
            foreach ($case in @(
                    @{ v = '0'; ok = $true }, @{ v = '99'; ok = $true },
                    @{ v = '1'; ok = $true }, @{ v = '45'; ok = $true },
                    @{ v = '-1'; ok = $false }, @{ v = '100'; ok = $false },
                    @{ v = 'abc'; ok = $false })) {
                $script:FoTbDuration.Text = [string]$case.v
                $script:FoBreakMin.Text = '5'
                $accepted = Save-FocusWindowSettings
                $hit = ($accepted -eq [bool]$case.ok)
                if (-not $hit) { $allOk = $false }
                $caseLog.Add([string]$case.v + '=' + $(if ($accepted) { 'ok' } else { 'rej' }) +
                             $(if ($hit) { '' } else { '!!' }))
            }
            # 0 必须原样存进去（不回落到 25），并且总秒数 = 0
            $script:FoTbDuration.Text = '0'
            $script:FoBreakMin.Text = '5'
            [void](Save-FocusWindowSettings)
            $zeroKept = ([int]$script:Settings['PomodoroMin'] -eq 0)
            Reset-Pomodoro
            $zeroTotal = ([int]$script:Pomo.Total -eq 0)
            # 99 也要能跑通并变成 5940 秒
            $script:FoTbDuration.Text = '99'
            [void](Save-FocusWindowSettings)
            Reset-Pomodoro
            $maxTotal = ([int]$script:Pomo.Total -eq (99 * 60))
            try { $dpFocus.Close() } catch { }
            $script:Settings['PomodoroMin'] = $keepPomoMin
            Reset-Pomodoro
            Write-AuditRow 'pomodoro duration 0-99 free' ($allOk -and $zeroKept -and $zeroTotal -and $maxTotal) `
                (($caseLog -join ' ') + ' zeroKept=' + [string]$zeroKept + ' zeroTotal=' + [string]$zeroTotal +
                 ' maxTotal=' + [string]$maxTotal)
        } catch { Write-AuditRow 'pomodoro duration 0-99 free' $false ('crash ' + $_.Exception.Message) }
    } catch {
        $ln = ''
        $stmt = ''
        try { $ln = [string]$_.InvocationInfo.ScriptLineNumber } catch { }
        try { $stmt = ([string]$_.InvocationInfo.Line).Trim() } catch { }
        Write-AuditRow 'audit crashed' $false ($_.Exception.Message + ' @line ' + $ln + ' :: ' + $stmt)
    } finally {
        $script:SuppressModal = $false
    }

    $head = @(
        ('AUDIT  pass=' + $script:AuditPass + '  fail=' + $script:AuditFail + '  at ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')),
        ''
    )
    # 逐条 Add：PowerShell 的 @() 数组是 object[]，直接 AddRange 到 List[string] 会类型不匹配
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $head) { [void]$all.Add([string]$ln) }
    foreach ($ln in $script:AuditRows) { [void]$all.Add([string]$ln) }
    [System.IO.File]::WriteAllLines((Join-Path $script:DataDir 'audit.txt'), $all,
        (New-Object System.Text.UTF8Encoding($false)))
    return $all
}

function Save-Shot {
    param([string]$Path, $Window = $null)
    try {
        $w = $Window
        if ($null -eq $w) { $w = $script:MainWindow }
        $w.UpdateLayout()
        $width = [int][math]::Max(1.0, [double]$w.ActualWidth)
        $height = [int][math]::Max(1.0, [double]$w.ActualHeight)
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
            $width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($w)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $fs = [System.IO.File]::Create($Path)
        try { $enc.Save($fs) } finally { $fs.Dispose() }
        Write-ErrLog ("SHOT ok ${width}x${height} -> $Path")
    } catch { Write-ErrLog ('SHOT FAIL: ' + $_.Exception.Message) }
}

function Invoke-WeekDragAudit {
    $rows = New-Object System.Collections.ArrayList
    Set-View 'week'
    try { $script:MainWindow.UpdateLayout() } catch { }
    if ($null -eq $script:WeekOverlay) {
        [void]$rows.Add('FAIL week overlay missing')
        return @($rows.ToArray())
    }
    $cards = @(Find-AllTagged $script:NodeHost 'event')
    $card = $null
    foreach ($cand in $cards) {
        if ($null -eq $cand -or $null -eq $cand.Tag) { continue }
        $id = [string]$cand.Tag['id']
        $hits = @($script:Events | Where-Object { [string]$_.id -eq $id })
        if ($hits.Count -eq 0) { continue }
        $d = Parse-Date ([string]$hits[0].date)
        if ($d.DayOfWeek -eq [System.DayOfWeek]::Sunday) { continue }
        $card = $cand
        break
    }
    if ($null -eq $card) {
        [void]$rows.Add('FAIL no movable week card')
        return @($rows.ToArray())
    }
    $id = [string]$card.Tag['id']
    $ev = @($script:Events | Where-Object { [string]$_.id -eq $id })[0]
    $oldDate = [string]$ev.date
    $oldStart = [int]$ev.start
    $oldEnd = [int]$ev.end
    $start = [System.Windows.Point]::new(
        [double]([System.Windows.Controls.Canvas]::GetLeft($card) + $card.Width / 2.0),
        [double]([System.Windows.Controls.Canvas]::GetTop($card) + $card.Height / 2.0))
    $end = [System.Windows.Point]::new(
        [double]($start.X + $script:WeekOverlay.ActualWidth / 7.0),
        [double]($start.Y + $script:HourHeight))
    $started = Start-WeekDrag $card $start
    Update-WeekDrag $card $end
    $guideOk = ($null -ne $script:WeekDrag) -and ($null -ne $script:WeekDrag.GuideLine) -and
               ($null -ne $script:WeekDrag.GuideBox) -and (-not [string]::IsNullOrWhiteSpace([string]$script:WeekDrag.GuideLabel.Text))
    [void]$rows.Add(('{0} drag time guide :: {1}' -f $(if ($guideOk) { 'PASS' } else { 'FAIL' }), [string]$script:WeekDrag.GuideLabel.Text))
    Finish-WeekDrag $card $end
    $movedDate = [string]$ev.date
    $movedStart = [int]$ev.start
    $movedEnd = [int]$ev.end
    $wantDate = (Parse-Date $oldDate).AddDays(1)
    $moveOk = $started -and ($movedDate -eq (Fmt-Date $wantDate)) -and
              ($movedStart -eq ($oldStart + 60)) -and ($movedEnd -eq ($oldEnd + 60))
    [void]$rows.Add(('{0} drag move :: {1} {2}-{3} -> {4} {5}-{6}' -f `
        $(if ($moveOk) { 'PASS' } else { 'FAIL' }), $oldDate, $oldStart, $oldEnd,
        $movedDate, $movedStart, $movedEnd))

    try { $script:MainWindow.UpdateLayout() } catch { }
    $cards = @(Find-AllTagged $script:NodeHost 'event')
    $card = $null
    foreach ($cand in $cards) {
        if ($null -ne $cand -and $null -ne $cand.Tag -and [string]$cand.Tag['id'] -eq $id) { $card = $cand; break }
    }
    if ($null -ne $card) {
        $beforeEnd = [int]$ev.end
        $bottom = [System.Windows.Point]::new(
            [double]([System.Windows.Controls.Canvas]::GetLeft($card) + $card.Width / 2.0),
            [double]([System.Windows.Controls.Canvas]::GetTop($card) + $card.Height - 3.0))
        $after = [System.Windows.Point]::new([double]$bottom.X, [double]($bottom.Y + $script:HourHeight / 2.0))
        [void](Start-WeekDrag $card $bottom)
        Update-WeekDrag $card $after
        Finish-WeekDrag $card $after
        $resizeOk = ([int]$ev.end -eq ($beforeEnd + 30))
        [void]$rows.Add(('{0} resize bottom :: end {1} -> {2}' -f `
            $(if ($resizeOk) { 'PASS' } else { 'FAIL' }), $beforeEnd, [int]$ev.end))
    } else {
        [void]$rows.Add('FAIL resize bottom card missing')
    }

    try { $script:MainWindow.UpdateLayout() } catch { }
    $cards = @(Find-AllTagged $script:NodeHost 'event')
    $card = $null
    foreach ($cand in $cards) {
        if ($null -ne $cand -and $null -ne $cand.Tag -and [string]$cand.Tag['id'] -eq $id) { $card = $cand; break }
    }
    if ($null -ne $card) {
        $beforeStart = [int]$ev.start
        $top = [System.Windows.Point]::new(
            [double]([System.Windows.Controls.Canvas]::GetLeft($card) + $card.Width / 2.0),
            [double]([System.Windows.Controls.Canvas]::GetTop($card) + 3.0))
        $after = [System.Windows.Point]::new([double]$top.X, [double]($top.Y + $script:HourHeight / 2.0))
        [void](Start-WeekDrag $card $top)
        Update-WeekDrag $card $after
        Finish-WeekDrag $card $after
        $resizeOk = ([int]$ev.start -eq ($beforeStart + 30))
        [void]$rows.Add(('{0} resize top :: start {1} -> {2}' -f `
            $(if ($resizeOk) { 'PASS' } else { 'FAIL' }), $beforeStart, [int]$ev.start))

        try { $script:MainWindow.UpdateLayout() } catch { }
        $editCard = $null
        foreach ($cand in @(Find-AllTagged $script:NodeHost 'event')) {
            if ($null -ne $cand -and $null -ne $cand.Tag -and [string]$cand.Tag['id'] -eq $id) { $editCard = $cand; break }
        }
        $wasSuppress = [bool]$script:SuppressModal
        $script:SuppressModal = $true
        $script:LastModalCall = ''
        $mouseError = ''
        $sameCardAfterClick = $false
        try {
            if ($null -ne $editCard) {
                $center = [System.Windows.Point]::new(
                    [double]([System.Windows.Controls.Canvas]::GetLeft($editCard) + $editCard.Width / 2.0),
                    [double]([System.Windows.Controls.Canvas]::GetTop($editCard) + $editCard.Height / 2.0))
                [void](Start-WeekDrag $editCard $center)
                Finish-WeekDrag $editCard $center
                $sameCardAfterClick = $script:WeekOverlay.Children.Contains($editCard)
                $mouse = New-Object System.Windows.Input.MouseButtonEventArgs(
                    [System.Windows.Input.Mouse]::PrimaryDevice, 0,
                    [System.Windows.Input.MouseButton]::Left)
                $clickProp = $mouse.GetType().GetProperty('ClickCount')
                $clickProp.SetValue($mouse, 2, $null)
                $mouse.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
                $mouse.Source = $editCard
                $editCard.RaiseEvent($mouse)
            }
        } catch { $mouseError = $_.Exception.Message }
        $script:SuppressModal = $wasSuppress
        $editOk = $sameCardAfterClick -and ([string]$script:LastModalCall -eq ('editor:' + $id))
        [void]$rows.Add(('{0} double-click edit :: {1} sameCard={2} err={3}' -f `
            $(if ($editOk) { 'PASS' } else { 'FAIL' }), [string]$script:LastModalCall,
            $(if ($sameCardAfterClick) { 'yes' } else { 'no' }), $mouseError))
    } else {
        [void]$rows.Add('FAIL resize top card missing')
    }

    $wasSuppress = [bool]$script:SuppressModal
    $script:SuppressModal = $true
    $script:LastModalCall = ''
    try {
        $cw = [double]$script:WeekOverlay.ActualWidth / 7.0
        $p1 = [System.Windows.Point]::new([double](3 * $cw + 12.0), [double](8 * $script:HourHeight + 3.0))
        $p2 = [System.Windows.Point]::new([double]$p1.X, [double]($p1.Y + $script:HourHeight * 1.5))
        Start-WeekCreate $p1
        Update-WeekCreate $p2
        $rectOk = ($null -ne $script:WeekCreate) -and ($null -ne $script:WeekCreate.Rect)
        # mouseMoved 取决于 StartMin/CurrentMin 是否差 >=15 分钟；
        # 两者相等通常意味着 Get-WeekMinuteFromY 把两个 Y 映到了同一分钟 ——
        # 把这两个数和 HourHeight 一起报出来，"空白拖拽没反应"一眼就能定位。
        $dbgA = '-'; $dbgB = '-'
        if ($null -ne $script:WeekCreate) {
            $dbgA = [string]$script:WeekCreate.StartMin
            $dbgB = [string]$script:WeekCreate.CurrentMin
        }
        Finish-WeekCreate
        $createOk = $rectOk -and ([string]$script:LastModalCall -like 'editor:*') -and ($null -eq $script:WeekCreate)
        [void]$rows.Add(('{0} blank-drag create :: {1} rect={2} a={3} b={4} hh={5} y1={6} y2={7}' -f `
            $(if ($createOk) { 'PASS' } else { 'FAIL' }), [string]$script:LastModalCall,
            [string]$rectOk, $dbgA, $dbgB, [string]$script:HourHeight, [int]$p1.Y, [int]$p2.Y))
    } catch {
        [void]$rows.Add('FAIL blank-drag create :: ' + $_.Exception.Message)
    }
    $script:SuppressModal = $wasSuppress

    # ---- 限定时段下的拖动：Y=0 不再等于 00:00，位移换算必须先过范围偏移 ----
    # 这一段是"时段范围"功能的物理量断言：不仅看时间写对没写对，还要看
    # 卡片位置（Canvas.Top）与时间是否仍然一致 —— 两者一旦脱钩，
    # 界面会出现"时间文字写着 10:00、块却画在 09:00 的位置"。
    [void](Set-WeekRange 8 20)
    try { $script:MainWindow.UpdateLayout() } catch { }
    $inCard = $null
    foreach ($cand in @(Find-AllTagged $script:NodeHost 'event')) {
        if ($null -eq $cand -or $null -eq $cand.Tag) { continue }
        $cid = [string]$cand.Tag['id']
        $chits = @($script:Events | Where-Object { [string]$_.id -eq $cid })
        if ($chits.Count -eq 0) { continue }
        if ((Parse-Date ([string]$chits[0].date)).DayOfWeek -eq [System.DayOfWeek]::Sunday) { continue }
        $cs = [int]$chits[0].start; $ce = [int]$chits[0].end
        if ($cs -lt 480 -or $cs -gt 1080 -or $ce -gt 1200) { continue }
        $inCard = $cand
        break
    }
    if ($null -eq $inCard) {
        [void]$rows.Add('FAIL ranged drag :: no card inside 08:00-20:00')
    } else {
        $rid = [string]$inCard.Tag['id']
        $rev = @($script:Events | Where-Object { [string]$_.id -eq $rid })[0]
        $rs0 = [int]$rev.start
        $rt0 = [double][System.Windows.Controls.Canvas]::GetTop($inCard)
        $rp0 = [System.Windows.Point]::new(
            [double]([System.Windows.Controls.Canvas]::GetLeft($inCard) + $inCard.Width / 2.0),
            [double]($rt0 + $inCard.Height / 2.0))
        $rp1 = [System.Windows.Point]::new([double]$rp0.X, [double]($rp0.Y + $script:HourHeight))
        [void](Start-WeekDrag $inCard $rp0)
        Update-WeekDrag $inCard $rp1
        $rguide = ''
        try {
            if ($null -ne $script:WeekDrag) {
                if ($null -ne $script:WeekDrag.GuideLabel) { $rguide = [string]$script:WeekDrag.GuideLabel.Text }
            }
        } catch { }
        Finish-WeekDrag $inCard $rp1
        $rs1 = [int]$rev.start
        $moveOk2 = ($rs1 -eq ($rs0 + 60))
        [void]$rows.Add(('{0} ranged drag +60min :: {1} -> {2} guide={3}' -f `
            $(if ($moveOk2) { 'PASS' } else { 'FAIL' }), $rs0, $rs1, $rguide))

        try { $script:MainWindow.UpdateLayout() } catch { }
        $rcard = $null
        foreach ($cand in @(Find-AllTagged $script:NodeHost 'event')) {
            if ($null -ne $cand -and $null -ne $cand.Tag -and [string]$cand.Tag['id'] -eq $rid) { $rcard = $cand; break }
        }
        if ($null -eq $rcard) {
            [void]$rows.Add('FAIL ranged card top :: card missing')
        } else {
            $topWant = Week-MinuteToY $rs1
            $topGot = [double][System.Windows.Controls.Canvas]::GetTop($rcard)
            $topOk = ([math]::Abs($topGot - $topWant) -le 1.0)
            [void]$rows.Add(('{0} ranged card top == minute :: got={1} want={2}' -f `
                $(if ($topOk) { 'PASS' } else { 'FAIL' }), [int]$topGot, [int]$topWant))

            # 向上拖出轴顶：位置被钳在 0（= 08:00），时间也必须停在 08:00
            $rt2 = [double][System.Windows.Controls.Canvas]::GetTop($rcard)
            $rq0 = [System.Windows.Point]::new(
                [double]([System.Windows.Controls.Canvas]::GetLeft($rcard) + $rcard.Width / 2.0),
                [double]($rt2 + $rcard.Height / 2.0))
            $rq1 = [System.Windows.Point]::new([double]$rq0.X, [double]($rq0.Y - 20.0 * $script:HourHeight))
            [void](Start-WeekDrag $rcard $rq0)
            Update-WeekDrag $rcard $rq1
            Finish-WeekDrag $rcard $rq1
            $clampOk = ([int]$rev.start -eq 480)
            [void]$rows.Add(('{0} ranged drag clamps at 08:00 :: start={1}' -f `
                $(if ($clampOk) { 'PASS' } else { 'FAIL' }), [int]$rev.start))
        }
    }
    [void](Set-WeekRange 0 24)
    try { $script:MainWindow.UpdateLayout() } catch { }

    return @($rows.ToArray())
}

function Invoke-TestScript {
    param([string]$Spec)
    $raw = Invoke-TestActions -Spec $Spec -AllowShot
    $lines = @()
    foreach ($r in @($raw)) { $lines += [string]$r }
    $lines -join "`n" | Set-Content -LiteralPath (Join-Path $script:DataDir 'testlog.txt') -Encoding UTF8
}

function Invoke-TestActions {
    param([string]$Spec, [switch]$AllowShot)
    $out = New-Object System.Collections.ArrayList
    foreach ($act in ([string]$Spec).Split(',')) {
        $a = $act.Trim()
        if (-not $a) { continue }
        try {
            $parts = $a.Split(':')
            $verb = $parts[0]
            $arg = ''
            if ($parts.Count -gt 1) { $arg = $parts[1] }
            switch ($verb) {
                'view'   { Set-View $arg }
                'theme'  { Set-Theme $arg -Sync }
                'pin'    { $script:TopmostOn = (-not $script:TopmostOn); $script:MainWindow.Topmost = $script:TopmostOn; Refresh-All }
                'size'   {
                    if ($arg -match '^(\d+)x(\d+)$') {
                        $script:MainWindow.Width = [double]$Matches[1]
                        $script:MainWindow.Height = [double]$Matches[2]
                    }
                }
                'layout' { $script:MainWindow.UpdateLayout() }
                'shot'   {
                    if ($AllowShot -and $ScreenshotPath) {
                        # 允许 "shot:week" 这种带名截图：一次运行就能把多个视图全拍完。
                        # （WPF 一个进程只能 Run 一个 Application，所以不能靠多进程反复跑）
                        $p = $ScreenshotPath
                        if (-not [string]::IsNullOrWhiteSpace($arg)) {
                            $dir = [System.IO.Path]::GetDirectoryName($ScreenshotPath)
                            if (-not [string]::IsNullOrWhiteSpace($dir)) { $p = Join-Path $dir ($arg + '.png') }
                        }
                        Save-Shot -Path $p
                    }
                }
                'start'  { Toggle-Pomodoro }
                'stats'  { Open-StatsPanel }
                'edit'   { Open-EventEditor -Id $arg }
                'add'    { Open-EventEditor }
                'tick'   { for ($i = 0; $i -lt 3; $i++) { $script:MainWindow.UpdateLayout() } }
                'weekrange' {
                    # "weekrange:8-20" 设置周视图时段范围（截图用例用）
                    if ($arg -match '^(\d{1,2})-(\d{1,2})$') {
                        [void](Set-WeekRange ([int]$Matches[1]) ([int]$Matches[2]))
                    }
                }
                'anchor' {
                    # "anchor:2027-02-01" 把日历锚点挪到指定日期（截图用例用）。
                    # 月视图的行数随月份变化，得能翻到"只要 4 行"和"要 6 行"的月份去拍。
                    if ($arg -match '^(\d{4})-(\d{2})-(\d{2})$') {
                        $script:Anchor = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
                        $script:Selected = $script:Anchor
                        Refresh-All
                    }
                }
                'audit'  { [void](Invoke-HandlerAudit) }
                'weekdrag' { foreach ($line in @(Invoke-WeekDragAudit)) { [void]$out.Add([string]$line) } }
                'dbltask' {
                    # "dbltask:<id>"：用**真实鼠标路由**双击指定任务卡。
                    #
                    # 第四轮起双击的语义变成"打开任务编辑窗口"，而截图/自动化运行时
                    # 弹模态窗（ShowDialog）会把调度器卡死。所以这里临时打开
                    # SuppressModal：Open-TaskEditor 在这个模式下只记一笔
                    # 'taskeditor:<id>' 就返回 —— 既证明"双击真的走到了开窗入口"，
                    # 又不会真弹窗。$out 里回读 LastModalCall，截图流程能直接看到结果。
                    Set-View 'tasks'
                    if ($null -ne $script:TaskStatusBox) { $script:TaskStatusBox.SelectedIndex = 0 }
                    $script:TaskExpandedId = ''
                    Fill-Tasks
                    for ($i = 0; $i -lt 3; $i++) { $script:MainWindow.UpdateLayout() }
                    $tgt = $null
                    foreach ($r in @($script:TaskStack.Children)) {
                        # 空参数（或 *）= 拿第一张卡片：截图用的数据目录是新建的，
                        # 写死 id 会因为"这个 id 不在这批数据里"而拍到一张空列表。
                        if ([string]::IsNullOrWhiteSpace($arg) -or $arg -eq '*') {
                            if ($null -ne $r.Tag -and $null -ne $r.Tag['id']) { $tgt = $r; break }
                            continue
                        }
                        if ($null -ne $r.Tag -and [string]$r.Tag['id'] -eq $arg) { $tgt = $r; break }
                    }
                    if ($null -eq $tgt) {
                        [void]$out.Add('dbltask: target not found -> ' + $arg)
                    } else {
                        $keepSuppress = $script:SuppressModal
                        $script:SuppressModal = $true
                        $script:LastModalCall = ''
                        try {
                            [void](Invoke-MouseDown -Target $tgt -Source $tgt -Count 1)
                            [void](Invoke-MouseUp   -Target $tgt -Source $tgt -Count 1)
                            [void](Invoke-MouseDown -Target $tgt -Source $tgt -Count 2)
                            [void](Invoke-MouseUp   -Target $tgt -Source $tgt -Count 2)
                        } finally { $script:SuppressModal = $keepSuppress }
                        for ($i = 0; $i -lt 3; $i++) { $script:MainWindow.UpdateLayout() }
                        [void]$out.Add('dbltask lastModal=' + [string]$script:LastModalCall +
                                       ' kids=' + @($script:TaskStack.Children).Count)
                    }
                }
                'caretshot' {
                    # "caretshot:<id>"：点任务卡右端的 ▾/▸ 按钮展开行内详情面板，再截图。
                    # 第四轮把"展开详情"的入口从双击换成了这个按钮，截图用例跟着改，
                    # 否则截出来的永远是一张"没有面板"的卡片，看上去像功能丢了。
                    Set-View 'tasks'
                    if ($null -ne $script:TaskStatusBox) { $script:TaskStatusBox.SelectedIndex = 0 }
                    $script:TaskExpandedId = ''
                    Fill-Tasks
                    for ($i = 0; $i -lt 3; $i++) { $script:MainWindow.UpdateLayout() }
                    $tgt = $null
                    foreach ($r in @($script:TaskStack.Children)) {
                        if ([string]::IsNullOrWhiteSpace($arg) -or $arg -eq '*') {
                            if ($null -ne $r.Tag -and $null -ne $r.Tag['id']) { $tgt = $r; break }
                            continue
                        }
                        if ($null -ne $r.Tag -and [string]$r.Tag['id'] -eq $arg) { $tgt = $r; break }
                    }
                    if ($null -eq $tgt) {
                        [void]$out.Add('caretshot: target not found -> ' + $arg)
                    } else {
                        $btn = $null
                        foreach ($b in @(Find-AllOfType $tgt ([System.Windows.Controls.Primitives.ButtonBase]))) {
                            if ($null -ne $b.Tag -and ($b.Tag -is [hashtable]) -and
                                [string]$b.Tag['kind'] -eq 'task-expand') { $btn = $b; break }
                        }
                        [void](Invoke-Click $btn)
                        for ($i = 0; $i -lt 3; $i++) { $script:MainWindow.UpdateLayout() }
                        [void]$out.Add('caretshot expanded=' + [string]$script:TaskExpandedId +
                                       ' btn=' + [string]($null -ne $btn) +
                                       ' kids=' + @($script:TaskStack.Children).Count)
                    }
                }
                'pickershot' {
                    $w = Show-PeriodPickerWindow
                    $w.Show(); $w.UpdateLayout()
                    if ($AllowShot -and $ScreenshotPath) {
                        $fn = 'period-picker.png'
                        if (-not [string]::IsNullOrWhiteSpace($arg)) { $fn = $arg + '.png' }
                        $p = Join-Path ([System.IO.Path]::GetDirectoryName($ScreenshotPath)) $fn
                        Save-Shot -Path $p -Window $w
                    }
                    $w.Close()
                }
                'focusshot' {
                    $w = Show-FocusWindow
                    $w.Show(); $w.UpdateLayout()
                    if ($AllowShot -and $ScreenshotPath) {
                        $fn = 'focus-window.png'
                        if (-not [string]::IsNullOrWhiteSpace($arg)) { $fn = $arg + '.png' }
                        $p = Join-Path ([System.IO.Path]::GetDirectoryName($ScreenshotPath)) $fn
                        Save-Shot -Path $p -Window $w
                    }
                    $w.Close()
                }
                'avatarshot' {
                    $w = Show-AvatarWindow
                    $w.Show(); $w.UpdateLayout()
                    if ($AllowShot -and $ScreenshotPath) {
                        $p = Join-Path ([System.IO.Path]::GetDirectoryName($ScreenshotPath)) 'avatar-window.png'
                        Save-Shot -Path $p -Window $w
                    }
                    $w.Close()
                }
                'taskshot' {
                    $w = Show-TaskEditorWindow
                    $w.Show(); $w.UpdateLayout()
                    if ($AllowShot -and $ScreenshotPath) {
                        $fn = 'task-window.png'
                        if (-not [string]::IsNullOrWhiteSpace($arg)) { $fn = $arg + '.png' }
                        $p = Join-Path ([System.IO.Path]::GetDirectoryName($ScreenshotPath)) $fn
                        Save-Shot -Path $p -Window $w
                    }
                    $w.Close()
                }
                'eventshot' {
                    $w = Show-EventEditorWindow -Id ''
                    $w.Show(); $w.UpdateLayout()
                    if ($AllowShot -and $ScreenshotPath) {
                        # 允许 "eventshot:name" 自定文件名：同一类弹窗要拍昼夜两版时，
                        # 固定文件名会互相覆盖，第二张永远是第一张的替身。
                        $fn = 'event-window.png'
                        if (-not [string]::IsNullOrWhiteSpace($arg)) { $fn = $arg + '.png' }
                        $p = Join-Path ([System.IO.Path]::GetDirectoryName($ScreenshotPath)) $fn
                        Save-Shot -Path $p -Window $w
                    }
                    $w.Close()
                }
                default  { }
            }
            [void]$out.Add("ok $a")
        } catch {
            [void]$out.Add("ERR $a :: " + $_.Exception.Message)
        }
    }
    return @($out)
}

function Write-BootLog {
    $lines = @()
    $lines += 'Boot OK'
    $lines += ('DataDir: ' + $script:DataDir)
    $lines += ('Theme: ' + $script:Theme)
    $lines += ('View: ' + $script:View)
    $lines += ('Events: ' + @($script:Events).Count)
    $lines += ('Tasks: ' + @($script:Tasks).Count)
    $lines += ('Window: ' + [int]$script:MainWindow.ActualWidth + 'x' + [int]$script:MainWindow.ActualHeight)
    $lines += ('Functions: ' + @(Get-ChildItem Function:\ | Where-Object { $_.Name -match '-' }).Count)
    $lines += ('Unhandled: ' + $script:UnhandledCount)
    if (Test-Path -LiteralPath $script:ErrorLog) {
        $raw = Get-Content -LiteralPath $script:ErrorLog -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { $lines += 'errors.log: (empty)' }
        else { $lines += 'errors.log:'; $lines += $raw }
    } else { $lines += 'errors.log: (none)' }
    $lines -join "`n" | Set-Content -LiteralPath (Join-Path $script:DataDir 'bootlog.txt') -Encoding UTF8
}

# 退出钩子已移入 Build-Window（见 Care.ps1 末尾）：
# Set-Theme 会整窗重建，钩子必须挂在"每一个新窗口实例"上，
# 只在启动时挂一次的话，重建后的窗口关闭时进程就退不出去了。

try {
    # 注意：这里不能用 [System.Windows.Application]::Current——
    # Application 实例是在下面"消息循环"那段才创建的（见文件末尾注释）。
    $script:Dispatcher.InvokeAsync({
        try {
            Write-Trace 'dispatch enter'
            if ($script:Skeleton) {
                $script:MainWindow.UpdateLayout()
                if ($ScreenshotPath) { Save-Shot -Path $ScreenshotPath }
                Write-BootLog
                $script:AllowClose = $true
                $script:MainWindow.Close()
                return
            }
            Write-Trace 'before Show-FromTray'
            Show-FromTray
            Write-Trace ('after Show-FromTray size=' + [int]$script:MainWindow.ActualWidth + 'x' + [int]$script:MainWindow.ActualHeight)
            $script:MainWindow.Topmost = $script:TopmostOn
            Write-Trace 'before Refresh-All'
            Refresh-All
            Start-ReminderTimer
            Write-Trace 'after Refresh-All'
            if ($Script) { Invoke-TestScript -Spec $Script }
            if ($AutoCloseSeconds -gt 0) {
                # 必须用 $script: 变量：这个 Tick 是延迟回调，
                # 回调时创建它的那个作用域已经没了，局部变量 $t 读不到（StrictMode 直接抛异常）。
                # 一旦抛异常，Stop() 就永远没执行 → 定时器每 N 秒重入 → 窗口永不关闭 → App.Run() 挂死。
                $script:AutoCloseTimer = New-Object System.Windows.Threading.DispatcherTimer
                $script:AutoCloseTimer.Interval = [timespan]::FromSeconds($AutoCloseSeconds)
                $script:AutoCloseTimer.Add_Tick({
                    try {
                        Write-Trace 'autoclose tick'
                        $script:AutoCloseTimer.Stop()
                        if ($ScreenshotPath) { Save-Shot -Path $ScreenshotPath }
                        Write-BootLog
                        $script:AllowClose = $true
                        Write-Trace 'before Close'
                        $script:MainWindow.Close()
                        Write-Trace 'after Close'
                    } catch { Write-Trace ('autoclose ERR: ' + $_.Exception.Message) }
                })
                $script:AutoCloseTimer.Start()
                Write-Trace 'autoclose timer started'
            }
            Write-Trace 'dispatch exit'
        } catch {
            Write-ErrLog ('Boot-dispatch: ' + $_.Exception.Message + ' | ' + $_.Exception.StackTrace)
            try { $script:AllowClose = $true; $script:MainWindow.Close() } catch { }
        }
    }) | Out-Null
} catch {
    Write-ErrLog ('Boot: ' + $_.Exception.Message)
}

# ---- 消息循环 ----
# 必须先自己 new 一个 Application：WPF 不会替我们创建，
# [System.Windows.Application]::Current 在这个时刻就是 $null——
# 后面所有 Application.Current.Dispatcher 都会连锁失败（坑：Current 为 null）。
try {
    Write-Trace 'creating Application'
    if ($null -eq [System.Windows.Application]::Current) {
        # ShutdownMode 必须显式设成 OnExplicitShutdown。
        # 默认的 OnLastWindowClose 在这里是错的：Application 是在主窗口【建好之后】
        # 才 new 的，所以主窗口从来没进过 Application.Windows；于是任何子窗口
        # （编辑器/设置）一关，这个集合就空了，WPF 立刻把整个应用关掉 ——
        # 表现为"关一下编辑窗口，程序就退出了"。退出时机由我们自己把控。
        $script:App = New-Object System.Windows.Application
        try { $script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown } catch { }
    } else {
        $script:App = [System.Windows.Application]::Current
        try { $script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown } catch { }
    }
    # 让窗体关闭后进程确实退出（测试模式下窗口即唯一出口）
    $script:App.add_Exit({ try { Write-ErrLog 'App.Exit' } catch { } })
    Write-Trace 'Application ready'
} catch {
    Write-ErrLog ('CreateApp: ' + $_.Exception.Message)
}

try {
    Write-Trace 'App.Run enter'
    $script:App.Run() | Out-Null
    Write-Trace 'App.Run returned'
} catch {
    Write-ErrLog ('App.Run: ' + $_.Exception.Message)
}

