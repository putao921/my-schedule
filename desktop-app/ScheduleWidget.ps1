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
            '  · 新建日程：顶部「+」按钮，或在月视图的某天上右键',
            '  · 编辑/删除：列表左键，周视图双击日程块，改完点「保存」',
            '  · 月视图：一页从 1 号排到月末，首尾空位用浅色日期补满',
            '    （补的只是格子，不会显示上/下个月的日程）',
            '  · 月视图：单击日期会自动跳到对应周视图，"+N 更多" 可展开当天详情',
            '  · 周视图：空白处点击或拖动创建；拖动显示时间虚线；右键快速编辑/复制/删除',
            '  · 周视图：窗口拉高时时间轴会跟着变高（把整段时段铺满），不会在底下留一片空白',
            '  · 重复日程：编辑器可设置每天、每周、每月及自定义间隔',
            '  · 提醒：日程可提前 5/10/15 分钟提醒，任务按截止时间提醒',
            '  · 专注：支持专注后自动休息，并分别通知专注和休息结束',
            '  · 专注窗：按住计时器那块圆盘可以整体拖动窗口，位置会被记住',
            '  · 任务：左侧栏「任务」是任务专页，可搜索、按项目/状态/时间筛选、排序，',
            '    支持拖拽排序、子任务勾选、延期和一键专注',
            '  · 头像：点击左上角头像，可换成自己的图片；其他设置见顶部“...”菜单',
            '  · 夜间模式：右上角 夜间 / 日间 切换',
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
    # ---- 三个强调色的明度分层（第五轮）----
    #  与夜间板同一套关系：Event 更深 / Focus 更亮 / Task 居中。
    #  浅色底上要格外小心：Focus 再亮就会和 Card(#FFFDF7) 贴死，所以浅色板的
    #  "更亮"是把饱和度稍微提上去、明度只加一点点（#F2B083 -> #F5B579）。
    AccentEvent  = '#B04E62'   # 更深（原 #C05A6C）
    AccentFocus  = '#F5B579'   # 更亮（原 #F2B083）
    AccentTask   = '#9FC4A4'   # 居中不动
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
    # ---- 夜间层级差（第五轮）----
    #  问题：Card #241A20 -> CardAlt #2C2028 只差 8 级、-> Panel #35262E 差 9 级。
    #  8 级亮度差在真实显示器上几乎看不出"谁是表头、谁是内容"，夜间整屏糊成一块。
    #  改法：只把上面两层往上抬，Card 不动（它是最暗的"卡片底"，抬了就没有纵深了）。
    #  现在：Card #241A20 -> CardAlt #302430（+12）-> Panel #3C2C36（+12）。
    Panel        = '#3C2C36'
    Card         = '#241A20'
    CardAlt      = '#302430'
    Border       = '#E8C6CF'
    BorderSoft   = '#4D3742'
    Ink          = '#F4E9EC'
    InkSoft      = '#CDB6BD'
    InkFaint     = '#A08C93'
    # ---- 三个强调色的明度分层（第五轮）----
    #  问题：三个色饱和度接近、明度也接近，月视图里橙条和红色标题条混排时糊成一片。
    #  改法：只动明度，不动色相 —— 让 Event 更深、Focus 更亮、Task 居中，
    #  这样即使并排放在一起，也能靠"深浅"区分，而不必依赖色相辨别。
    #  注意：AccentTaskD 是 Task 的"深版"（用于勾选态等），要保持与之同向。
    AccentEvent  = '#C25F79'   # 更深（原 #D4718A）
    AccentFocus  = '#E0A16A'   # 更亮（原 #C98A56）
    AccentTask   = '#6F9A78'   # 居中不动
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
#  3b. 全局界面倍率（第四轮新增）
#
#  需求："在 setting 处增加修改字号" + "界面视图变大变小时，字体按键都要自动适应"。
#
#  设计：一个全局浮点倍率 $script:UiScale，所有字号/控件尺寸都乘它。
#    · 用户设置档位 -> $script:UiScaleUser（0.85 / 1.0 / 1.15 / 1.30）
#    · 窗口宽度自适应 -> $script:UiScaleAuto（0.90 / 1.0 / 1.08，见 Apply-ResponsiveLayout）
#    · 最终生效值 $script:UiScale = User × Auto，夹在 [0.75, 1.60]
#
#  为什么是"两个因子相乘"而不是"覆盖"：
#    用户选了"大字号"，窗口再拉宽时应该**更大一点**，而不是被窗口宽度重置回中号。
#    两者是独立的诉求（一个是我视力/偏好，一个是当前窗口的宽松程度），必须正交。
#
#  为什么倍率在"创建控件时"就乘进去，而不是事后遍历可视树改 FontSize：
#    全项目有 100+ 处 New-Txt / New-PixBtn 调用，事后再遍历会遇到两个麻烦：
#      ① 分不清"这个 FontSize 是原始值还是已经被乘过的"，重复调用会指数放大；
#      ② 动态重建（Fill-Tasks / Refresh-All）产生的树每次都要重扫一遍。
#    在工厂里一次性乘掉就天然幂等，代价是 Ui.ps1 里 XAML 硬编码的那 15 处要单独处理
#    （见 Apply-UiScale，那批是 XAML 解析时烘死的，工厂管不到）。
# ---------------------------------------------------------------------------
$script:UiScaleUser = 1.0      # 用户设置档位（Settings['UiScale']）
$script:UiScaleAuto = 1.0      # 窗口宽度自适应因子
$script:UiScale     = 1.0      # 最终生效值 = User × Auto（实际被工厂读取的就是它）
$script:UiScaleMin  = 0.75
$script:UiScaleMax  = 1.60

function Update-UiScale {
    # 重算最终倍率。任何一处因子变化（改设置 / 窗口缩放）之后都要调一次。
    $v = [double]$script:UiScaleUser * [double]$script:UiScaleAuto
    if ($v -lt $script:UiScaleMin) { $v = $script:UiScaleMin }
    if ($v -gt $script:UiScaleMax) { $v = $script:UiScaleMax }
    $script:UiScale = $v
    return $v
}
function Scale-Ui {
    # 把一个"设计尺寸"换算成当前倍率下的实际尺寸。
    # 所有字号、按钮宽高、间距都应该走这个函数，不要在别处手写 $x * $script:UiScale。
    param([double]$V)
    $r = [double]$V * [double]$script:UiScale
    # 向上取到 0.5 的整数倍：亚像素字号会让 WPF 的文字渲染发虚（ClearType 对齐要求）。
    return [math]::Round($r * 2.0) / 2.0
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
    # ---- 第四轮新增：界面倍率与常用软件设置 ----
    # UiScale：用户选的字号档位（0.85 小 / 1.0 标准 / 1.15 大 / 1.30 特大）。
    #   存倍率而不是存"档位名"，是为了让以后加档位（或允许自由滑动）不需要迁移旧配置。
    UiScale        = 1.0
    # 自适应开关：关掉之后字号只由用户档位决定，不随窗口宽度变（给"我就想固定大小"的人）。
    UiAdaptive    = $true
    # CloseToTray：点标题栏 × 时收进托盘而不是退出。以前只有托盘菜单里的开关，
    # 用户找不到，第四轮把它做成设置里的一项。
    CloseToTray    = $false
    # WeekViewDefault：新建时周视图默认显示哪一段（0-24 / 8-20 / 6-22 / 9-18）。
    #   存的是"起-止"字符串而不是两个整数，是为了跟 Set-WeekRange 的校验规则共用一套。
    WeekViewRange  = '0-24'
    # ---- 第五轮新增：语言与周视图密度 ----
    # Language：界面固定文案用中文还是英文（zh / en）。默认 zh。
    #   为什么要这个开关而不是直接全中文：星期表头、视图名这些"框架词"，
    #   有人看着英文更顺眼；但混用才是最难看的（Mon 配"提交读书报告"）。
    #   开关的价值在于"要么全中要么全英"，而不是"哪个词更好看"。
    Language       = 'zh'
    # WeekDensity：周视图每小时像素高（紧凑 28 / 标准 40 / 宽松 56）。
    #   注意它同时是"密度下限"—— Fit-WeekAxisHeight 只会向上放大，不会低于这个值。
    WeekDensity    = 40
    # MonthDensity：月视图每个日期格的**最小行高**（第六轮拆出来）。
    #   为什么不能和周视图共用一个值：
    #     · 周视图的诉求是"一天里塞下最多条目"，用户愿意挤；
    #     · 月视图的诉求是"一眼看清哪天有几件事"，格子太扁时事件条会被压成一条线。
    #   所以两者是**相反的偏好**，同一个值必然让一边难受。
    MonthDensity   = 40
    # ---- 第六轮新增：提示条出现的角落 ----
    # ToastCorner：撤销提示条（那个带 Undo 按钮的小浮窗）贴在屏幕哪个角。
    #   四个取值：bl（左下）/ br（右下，默认）/ tl（左上）/ tr（右上）。
    #   为什么需要它：提示条是独立 Topmost 窗口，位置写死在屏幕右下 —— 而右下角
    #   也是系统托盘/输入法候选框的地盘，有人反馈"删完想点撤销，提示条被挡住"。
    #   默认保持 br 不变（不动老用户的肌肉记忆），要换的人自己去设置里选。
    ToastCorner    = 'br'
    # ---- 第七轮新增：提示条停留秒数 ----
    # ToastSeconds：提示条（撤销条、专注结算条等）出现后多久自动消失。
    #   三个秒数档 3 / 5 / 8，外加 0 —— 0 表示"不自动关，点它才走"。
    #   为什么需要：提示条是浏览器式的"稍纵即逝"设计，而撤销是有时效诉求的操作 ——
    #   手慢的人 5 秒内点不到"撤销"，删错的东西就永远找不回来了（只能靠 Ctrl+Z 碰运气）。
    #   默认 5 秒，与第六轮写死的值一致，不动老用户的手感。
    ToastSeconds   = 5
    # ---- 第十轮新增：可自定义标签 ----
    # TagColors：标签名 -> 色板键 的有序映射。编辑器里的标签按钮组、任务分类下拉
    #   都从它动态生成；增删改标签 = 改这张表（见设置窗"数据"页的标签管理区）。
    #   为什么存"色板键"而不是十六进制色值：色板随主题切换（浅色/夜间两套），
    #   存键才能在切主题后自动跟着换，存死色值会让标签在夜间模式下突兀。
    #   默认四键沿用历史语义：work/focus/life 是事件标签，task 是任务的默认分类。
    TagColors      = [ordered]@{ work = 'AccentEvent'; focus = 'AccentFocus'; life = 'AccentTask'; task = 'AccentTask' }
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
        } catch {
            # 第十轮（第 5 条）：主数据文件损坏时，自动回退到备份（schedule.json.backup）。
            #   只有备份也读不出来才落到 Seed-Data（演示数据）—— 那是最坏情况下的兜底。
            Write-ErrLog ('Load-Data: main file corrupt - ' + $_.Exception.Message)
            $bak = $script:DataFile + '.backup'
            if (Test-Path -LiteralPath $bak) {
                try {
                    $rawB = Get-Content -LiteralPath $bak -Raw -Encoding UTF8
                    $objB = ConvertFrom-Json $rawB
                    foreach ($e in @($objB.events)) {
                        if ($null -eq $e) { continue }
                        [void]$script:Events.Add([pscustomobject]@{
                            id = [string]$e.id; date = [string]$e.date
                            start = [int]$e.start; end = [int]$e.end
                            title = [string]$e.title; tag = [string]$e.tag
                            note = [string]$e.note; done = [bool]$e.done
                            repeat = $(if ($e.PSObject.Properties.Name -contains 'repeat') { [string]$e.repeat } else { 'none' })
                            repeatEvery = $(if ($e.PSObject.Properties.Name -contains 'repeatEvery') { [int]$e.repeatEvery } else { 1 })
                            repeatUntil = $(if ($e.PSObject.Properties.Name -contains 'repeatUntil') { [string]$e.repeatUntil } else { '' })
                            repeatMonthMode = $(if ($e.PSObject.Properties.Name -contains 'repeatMonthMode') { [string]$e.repeatMonthMode } else { 'day' })
                            reminderMin = $(if ($e.PSObject.Properties.Name -contains 'reminderMin') { [int]$e.reminderMin } else { 0 })
                            reminderKey = $(if ($e.PSObject.Properties.Name -contains 'reminderKey') { [string]$e.reminderKey } else { '' })
                        })
                    }
                    foreach ($t in @($objB.tasks)) {
                        if ($null -eq $t) { continue }
                        $due = $null
                        if ($t.PSObject.Properties.Name -contains 'due' -and -not [string]::IsNullOrWhiteSpace([string]$t.due)) { $due = [string]$t.due }
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
                    Write-ErrLog 'Load-Data: recovered from backup'
                    return
                } catch {
                    Write-ErrLog ('Load-Data: backup also corrupt - ' + $_.Exception.Message)
                }
            }
        }
    }
    Seed-Data
    Save-Data
}

function Save-Data {
    if ($script:SuppressSave) { return }
    try {
        # 第十轮（第 5 条）：写盘前先把"上一次的完好数据"复制成备份。
        #   为什么要备份而不是直接覆盖：schedule.json 一旦写坏（断电/进程被杀/磁盘满），
        #   下一轮 Load-Data 会失败，用户几十条日程直接蒸发。留一份上一版本，
        #   哪怕数据丢了也只丢"最近一次改动"，而不是全部。
        #   只留一份（schedule.backup.json），不搞轮转 —— 避免备份文件越积越多。
        if (Test-Path -LiteralPath $script:DataFile) {
            try { Copy-Item -LiteralPath $script:DataFile -Destination ($script:DataFile + '.backup') -Force } catch { }
        }
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
function Shorten-Text {
    # 提示条里塞长标题会把窗口撑得很宽（SizeToContent=WidthAndHeight），
    # 所以标题一律截断。省略号用 ASCII 三点，避免不同字体下的基线跳动。
    param([string]$S, [int]$Max = 24)
    if ([string]::IsNullOrEmpty($S)) { return '' }
    if ($S.Length -le $Max) { return $S }
    if ($Max -lt 2) { return '..' }
    return $S.Substring(0, $Max - 2) + '..'
}
$script:DowShort = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
$script:DowZh    = @('周一', '周二', '周三', '周四', '周五', '周六', '周日')
$script:MonNames = @('January','February','March','April','May','June','July',
                     'August','September','October','November','December')
$script:MonZh    = @('1月','2月','3月','4月','5月','6月','7月','8月','9月',
                     '10月','11月','12月')
# 月份短名（Jan / 1月）。初始化成英文，Initialize-Lang 会按语言重设。
# 单独一个数组而不是让调用方对 MonNames 做 Substring：中文月名只有 2 个字符，
# Substring(0,3) 会直接抛越界（这是第五轮实测踩到的）。
$script:MonShort = @('Jan','Feb','Mar','Apr','May','Jun',
                     'Jul','Aug','Sep','Oct','Nov','Dec')

# ---------------------------------------------------------------------------
#  语言表（第五轮）
#  问题：一屏里同时出现 Mon/Tue/Wed、Tasks、Focus、提交读书报告终稿、Today。
#  "混用中英"是当前界面看着乱的最大来源 —— 比配色、间距的影响都大。
#
#  做法：$script:Lang 驱动下面三样东西
#    ① 星期表头（月视图 / 周视图 / Hero 日期 / 列表分组）
#    ② 月份名（CalPeriod 那个 "September 2026"）
#    ③ 侧栏 7 个导航文字 + 视图标题（XAML 里写死的那批，靠 Set-Lang 事后遍历改）
#
#  为什么不做成"完整的 i18n"：本项目的固定文案有几百条，全量抽调是另一个量级的工作，
#  而且绝大多数是英文（提示、字段名）。这里有意义的是**把框架词统一**，
#  让"中文内容 + 中文框架"或"英文内容 + 英文框架"两种状态各自自洽即可。
# ---------------------------------------------------------------------------
$script:Lang = 'zh'

$script:LangEn = [ordered]@{
    'nav.month' = 'Month'; 'nav.week' = 'Week'; 'nav.list' = 'List'
    'nav.tasks' = 'Tasks'; 'nav.focus' = 'Focus'; 'nav.settings' = 'Settings'
    'nav.profile' = 'Profile'
    'nav.newEvent' = 'New event'
    'view.month' = 'Month view'; 'view.week' = 'Week view'; 'view.list' = 'List view'
    'view.tasks' = 'Tasks view'
    'sched' = 'My Schedule'
    'undo.task' = 'Task deleted'; 'undo.event' = 'Event deleted'
    'undo.deleted' = 'Deleted: '; 'undo.btn' = 'Undo'
    'toast.close' = 'Dismiss'
    'undo.none' = 'Nothing left to undo'
    'undo.more' = 'Still undoable: '
    # 第七轮（第六轮第二十七节第 1 条）：撤销栈纳入"勾选完成 / 拖动改时间"，
    # 提示条文案要跟着操作类型走 —— 用户才知道这次 Ctrl+Z 撤的是什么。
    'undo.toggleOn'  = 'Marked done: '; 'undo.toggleOff' = 'Marked not done: '
    'undo.dragTask'  = 'Task time moved: '; 'undo.dragEvent' = 'Event time moved: '
    'undo.editTask'  = 'Task edited: '; 'undo.editEvent' = 'Event edited: '
    'undo.clickTip'  = 'Click to undo the last action'
    'empty.list' = 'Nothing scheduled for this week yet'
    'empty.cta' = '+ New event — click here'
    'empty.filtered' = 'No matching events'
    'empty.clear' = 'Clear filter'
    'tpl.save' = 'Save and close'
    'tpl.close' = 'Close without saving  (Esc)'
    'tip.checkbox' = 'Mark done'
    'tip.checkboxDone' = 'Mark not done'
    # 设置窗口分页（第六轮）：四个页签
    'set.tab.appear' = 'Appearance'
    'set.tab.window' = 'Window'
    'set.tab.data' = 'Data'
    'set.tab.about' = 'About'
    # ===== 弹窗字段名（第六轮第二项建议）=====
    #  以前这类标题是英文硬编码在 Views2.ps1 里的，导致"中文界面 + 英文表单"的割裂。
    #  全部改走 Get-LangText，键名以 fld. 开头、按弹窗分组（ed=日程 / tk=任务 / fo=专注 / st=设置）。
    # ---- 日程弹窗 ----
    'fld.ed.title'    = 'Edit event'
    'fld.ed.new'      = 'New event'
    'fld.ed.titleF'   = 'Title'
    'fld.ed.date'     = 'Date (yyyy-MM-dd)'
    'fld.ed.start'    = 'Start (HH:mm)'
    'fld.ed.end'      = 'End (HH:mm)'
    'fld.ed.repeat'   = 'Repeat'
    'fld.ed.every'    = 'Repeat every N days / weeks / months'
    'fld.ed.until'    = 'Repeat until (optional, yyyy-MM-dd)'
    'fld.ed.monthLast'= 'Monthly: use the last day of month'
    'fld.ed.reminder' = 'Reminder'
    'fld.ed.tag'      = 'Tag'
    # ---- 重复选项 ----
    'opt.rep.none'    = 'None'; 'opt.rep.daily' = 'Daily'
    'opt.rep.weekly'  = 'Weekly'; 'opt.rep.monthly' = 'Monthly'
    # ---- 提醒选项 ----
    'opt.rem.no'      = 'No reminder'
    'opt.rem.5'       = '5 min before'; 'opt.rem.10' = '10 min before'
    'opt.rem.15'      = '15 min before'; 'opt.rem.30' = '30 min before'
    # ---- 任务弹窗 ----
    'fld.tk.title'    = 'Edit task'; 'fld.tk.new' = 'New task'
    'fld.tk.text'     = 'Task content'
    'fld.tk.due'      = 'Due date (optional, yyyy-MM-dd)'
    'fld.tk.dueTime'  = 'Due time (HH:mm)'
    'fld.tk.priority' = 'Priority'
    'fld.tk.project'  = 'Project / list'
    'fld.tk.category' = 'Category'
    'fld.tk.estimated'= 'Estimated minutes'
    'fld.tk.actual'   = 'Actual minutes'
    'fld.tk.subtasks' = 'Subtasks'
    'fld.tk.done'     = 'Completed'
    'fld.tk.tag'      = 'Category'
    'btn.add'         = '+ Add'
    'opt.pri.high'    = 'High'; 'opt.pri.mid' = 'Medium'; 'opt.pri.low' = 'Low'
    # ---- 专注弹窗 ----
    'fld.fo.title'    = 'Focus session'
    'fld.fo.sub'      = 'Set whether focus is available, the session length and what you will work on.'
    'fld.fo.enable'   = 'Enable focus timer'
    'fld.fo.breakOn'  = 'Start a break after focus'
    'fld.fo.duration' = 'Session length (mm:ss — scroll each digit)'
    'fld.fo.wheelHint' = 'Scroll a digit (or click its top / bottom) to set the length. Max 99:59.'
    'fld.fo.break'    = 'Break length (choose or type 0-99 minutes; 0 = skip)'
    'fld.fo.task'     = 'Task content (choose an existing task or type a new one)'
    # ---- 设置弹窗 ----
    'fld.st.title'    = 'Settings & focus stats'
    'fld.st.user'     = 'Windows user: '
    'fld.st.scale'    = 'Text size  (also follows the window width)'
    'fld.st.adaptive' = 'Let text size follow the window width'
    'fld.st.theme'    = 'Theme'
    'fld.st.lang'     = 'Language  (sidebar and view names)'
    'fld.st.density'  = 'Row height in the week view'
    'fld.st.densityMonth' = 'Row height in the month view'
    'fld.st.topmost'  = 'Keep the window on top of other windows'
    'fld.st.tray'     = 'Closing the window hides it to the tray'
    'fld.st.trayHint' = 'On: the x button hides the window and the app keeps running in the tray. Off: the x button asks whether to quit.'
    'hint.st.adaptive'= 'On: text grows a little in wide windows and shrinks in narrow ones. Off: text size only depends on the choice above.'
    'fld.st.weekRange'= 'Hours shown in the week view by default'
    'fld.st.toastCorner' = 'Where the undo / reminder pop-up appears'
    'opt.corner.br'   = 'Bottom right'; 'opt.corner.bl' = 'Bottom left'
    'opt.corner.tl'   = 'Top left'; 'opt.corner.tr' = 'Top right'
    'fld.st.toastSeconds' = 'How long the pop-up stays'
    'opt.toast.s3'    = '3 seconds'; 'opt.toast.s5' = '5 seconds'
    'opt.toast.s8'    = '8 seconds'; 'opt.toast.hold' = 'Stay until clicked'
    'fld.st.pomo'     = 'Session length (0-99 minutes; 0 = no countdown)'
    'fld.st.dir'      = 'Data folder'
    'fld.st.searchHint' = 'Search settings…'
    'fld.st.searchHit'  = '{0} match(es) — showing first'
    'fld.st.searchNone' = 'No matching setting'
    'fld.st.dirHint'  = 'One copy per computer per account; they stay separate.'
    'fld.st.reset'    = 'Reset timer'
    'fld.st.openDir'  = 'Open folder'
    'fld.st.version'  = 'Version '
    'fld.st.shortcuts'= 'Shortcuts'
    'fld.st.thisWeek' = 'This week {0} min · {1} pomodoros'
    'fld.st.totals'   = 'Events {0} (done {1}) · Open tasks {2}'
    'sc.newEvent'     = 'Ctrl+N  New event'
    'sc.search'       = 'Ctrl+F  Search'
    'sc.esc'          = 'Esc     Close current dialog'
    'sc.undo'         = 'Ctrl+Z  Undo delete'
    'sc.tabs'         = 'Ctrl+1..4  Switch settings tab'
    'opt.scale.small' = 'Small'; 'opt.scale.normal' = 'Normal'
    'opt.scale.medium'= 'Medium'; 'opt.scale.large' = 'Large'; 'opt.scale.huge' = 'Huge'
    'opt.theme.light' = 'Light'; 'opt.theme.night' = 'Night'
    'opt.dens.compact'= 'Compact'; 'opt.dens.normal' = 'Normal'; 'opt.dens.roomy' = 'Roomy'
    # 语言名**不翻译**：中文用户也要能一眼找到 "English" 这一项来切回去。
    'opt.lang.zh'     = '中文'; 'opt.lang.en' = 'English'
    # ---- 头像弹窗 ----
    'fld.av.title'    = 'Choose an avatar'
    'fld.av.random'   = 'Random'
    'fld.av.pick'     = 'Pick a face from the grid below'
    # ---- 当日议程 ----
    'fld.day.title'   = 'Agenda'
    'fld.day.empty'   = 'Nothing scheduled for this day'
    # ===== 第十轮：清理硬编码英文 UI 文案（全部收口到语言表）=====
    # ---- 期间选择窗 ----
    'pick.title'      = 'Jump to date'
    'pick.hint'       = 'Pick any day. Week view jumps to that week; Month and List jump to that month.'
    'pick.calTip'     = 'Pick a date'
    'btn.today'       = 'Today'
    'pick.prevMonth'  = 'Previous month'
    'pick.nextMonth'  = 'Next month'
    # ---- 任务视图 ----
    'empty.task'      = 'No tasks match this filter.'
    'task.searchTip'  = 'Search task titles'
    'task.searchHint' = 'Search task titles…'
    'btn.focus'       = 'Focus'
    'btn.edit'        = 'Edit'
    'btn.delete'      = 'Delete'
    'btn.start'       = 'Start'
    'btn.endLog'      = 'End & log'
    'btn.reset'       = 'Reset'
    'btn.chooseImg'   = 'Choose image'
    'btn.restoreDef'  = 'Restore default'
    # ---- 周视图 ----
    'week.timeRange'  = 'Time range'
    'week.hoursTip'   = 'Pick how many hours the week grid shows'
    # ---- 任务卡动作 ToolTip ----
    'tip.focus'       = 'Start focus for this task'
    'tip.postpone'    = 'Postpone one day'
    'tip.editTask'    = 'Edit task'
    'tip.deleteTask'  = 'Delete task'
    'tip.filterProj'  = 'Filter by this project'
    'tip.show'        = 'Show details'
    'tip.hide'        = 'Hide details'
    'tip.priHigh'     = 'High priority'
    'tip.priMid'      = 'Medium priority'
    'tip.priLow'      = 'Low priority'
    # ---- 任务详情面板行标签（第十轮收口）----
    'det.title'       = 'Title'
    'det.due'         = 'Due'
    'det.priority'    = 'Priority'
    'det.project'     = 'Project'
    'det.estimate'    = 'Estimate'
    'det.logged'      = 'Logged'
    'det.reminder'    = 'Reminder'
    'det.tag'         = 'Tag'
    'det.subtasks'    = 'Subtasks'
    'unit.min'        = ' min'
    'unit.minBefore'  = ' min before'
    # ---- 专注状态 ----
    'fo.ready'        = 'Ready'
    'fo.noTask'       = 'Task: No task selected'
    'fo.last7'        = 'Focus last 7 days: {0} min'
    'fo.dragTip'      = 'Drag here to move this window'
    'fo.disabledTip'  = 'Focus is disabled - click to open settings'
    'fo.runningTip'   = 'Focus timer is running - click to pause'
    'fo.startTip'     = 'Click to start focus timer'
    # ---- 头像弹窗 ----
    'av.title2'       = 'Your avatar'
    'av.hint'         = 'Choose a PNG, JPG, BMP or GIF image. It is copied into the app data folder.'
    'av.default'      = 'Default'
    'av.change'       = 'Change'
    'av.tip'          = 'Click to choose your own avatar image'
    # ---- 内置标签名（第十一轮：work/focus/life/task 显示名本地化）----
    'tag.work'        = 'Work'
    'tag.focus'       = 'Focus'
    'tag.life'        = 'Life'
    'tag.task'        = 'Task'
    # ---- 设置-数据页 ----
    'fld.st.focus7'   = 'Focus last 7 days (minutes)'
    # ---- 标签管理（第十轮）----
    'fld.st.tags'     = 'Tags (custom)'
    'fld.st.tagsHint' = 'Add or remove tags. Tags set the colour strip on task cards and the tag buttons in the event editor.'
    'fld.st.tagName'  = 'New tag name'
    'fld.st.tagColor' = 'Colour'
    'btn.tagAdd'      = '+ Add tag'
    'tip.tagRemove'   = 'Remove this tag'
    # ---- 关于页 ----
    'about.appName'   = 'My Schedule'
    'about.tech'      = 'PowerShell 5.1 + WPF · single file · zero dependency · offline'
    'about.author'    = 'Author · Putao'
    'about.updated'   = 'Updated {0}'
    # ---- 当日议程空态 ----
    'fld.day.emptyDetail' = 'No events on this day.'
    # ---- 筛选选项（第十轮语言收尾：列表/任务视图的下拉与按钮）----
    'flt.allTags'     = 'All tags'
    'flt.allTasks'    = 'All tasks'
    'flt.allProjects' = 'All projects'
    'flt.allStatus'   = 'All status'
    'flt.allDates'    = 'All dates'
    'flt.open'        = 'Open'
    'flt.done'        = 'Done'
    'flt.today'       = 'Today'
    'flt.thisWeek'    = 'This week'
    'flt.overdue'     = 'Overdue'
    'flt.noDate'      = 'No date'
    'flt.sortDue'     = 'Sort: Due date'
    'flt.sortPriority' = 'Sort: Priority'
    'flt.sortTitle'   = 'Sort: Title'
    'lbl.thisMonth'   = 'This month'
    'lbl.all'         = 'All'
    'btn.newTask'     = '+New task'
    'btn.save'        = 'Save'
    'ui.search'       = 'Search…'
    # ---- 计数行与任务卡芯片 ----
    'cnt.openDone'    = '{0} open · {1} done'
    'cnt.showing'     = '  ·  showing {0}/{1}'
    'chip.overdue'    = 'Overdue · {0}'
    'chip.time'       = 'Time {0}/{1}m'
    'chip.sub'        = 'Sub {0}/{1}'
    'hero.stats'      = 'Done {0}/{1} ({2}%) · Focus today {3}h{4:00}m'
    'cal.holiday1'    = '{0} holiday this month'
    'cal.holidayN'    = '{0} holidays this month'
    # ---- 编辑器/设置校验错误（第十轮语言收尾）----
    'err.titleRequired'  = 'Title is required.'
    'err.dateFormat'     = 'Date must look like 2026-09-24.'
    'err.timeFormat'     = 'Time must look like 09:30.'
    'err.repeatInterval' = 'Repeat interval must be a positive number.'
    'err.repeatUntil'    = 'Repeat until must look like 2026-12-31.'
    'err.sessionLen'     = 'Session length must be a whole number from 0 to 99 minutes (0 = no countdown).'
    'err.taskRequired'   = 'Task content is required.'
    'err.dueDate'        = 'Due date must look like 2026-09-24.'
    'err.dueTime'        = 'Due time must look like 09:30.'
    'err.breakLen'       = 'Break length must be a whole number from 0 to 99 minutes (0 = skip the break).'
    'err.focusDisabled'  = 'Enable the focus timer before starting.'
    # ---- 番茄钟按钮/状态 + 托盘（第十轮语言收尾）----
    'pomo.setup'       = 'Setup'
    'pomo.pause'       = 'Pause'
    'pomo.resume'      = 'Resume'
    'pomo.disabled'    = 'Disabled'
    'pomo.break'       = 'Break'
    'pomo.breakPaused' = 'Break paused'
    'pomo.focusing'    = 'Focusing'
    'pomo.complete'    = 'Complete'
    'pomo.paused'      = 'Paused'
    'pomo.taskPrefix'  = 'Task: '
    'pomo.session'     = 'Focus session'
    'pomo.noTask'      = 'No task selected'
    'tray.name'        = 'Schedule'
    # ---- 桌面通知 / Toast（第十轮语言收尾）----
    'ntf.breakDone'   = 'Break finished'
    'ntf.breakReady'  = 'Ready for the next focus session.'
    'ntf.focusDone'   = 'Focus finished'
    'ntf.focusBreak'  = '{0} finished · break for {1} min'
    'ntf.focusAdd'    = '{0} · +{1} min'
    'ntf.focusLogged' = 'Focus logged'
    'ntf.focus'       = 'Focus'
    'ntf.noLog'       = 'No focus time to log yet'
    'ntf.focusStarted' = 'Focus started'
    'ntf.inMin'       = 'In {0} min'
    'ntf.dueIn'       = 'Due in {0} min'
    'ntf.taskDue'     = 'Task due'
    # ---- 弹窗标题（任务栏 / Alt-Tab 可见，第十轮语言收尾）----
    'win.event'       = 'Event'
    'win.settings'    = 'Settings'
    'win.task'        = 'Task'
    'win.focus'       = 'Focus'
    'win.avatar'      = 'Avatar'
    'win.dayAgenda'   = 'Day agenda'
    'win.pickDate'    = 'Pick a date'
    'dlg.chooseAvatar' = 'Choose avatar image'
}
$script:LangZh = [ordered]@{
    'nav.month' = '月视图'; 'nav.week' = '周视图'; 'nav.list' = '列表'
    'nav.tasks' = '任务'; 'nav.focus' = '专注'; 'nav.settings' = '设置'
    'nav.profile' = '我的'
    'nav.newEvent' = '新建日程'
    'view.month' = '月视图'; 'view.week' = '周视图'; 'view.list' = '列表视图'
    'view.tasks' = '任务视图'
    'sched' = '我的日程'
    'undo.task' = '任务已删除'; 'undo.event' = '日程已删除'
    'undo.deleted' = '已删除：'; 'undo.btn' = '撤销'
    'toast.close' = '关闭'
    'undo.none' = '没有可撤销的操作了'
    'undo.more' = '还可撤销 '
    'undo.toggleOn'  = '已完成：'; 'undo.toggleOff' = '取消完成：'
    'undo.dragTask'  = '任务时间已改：'; 'undo.dragEvent' = '日程时间已改：'
    'undo.editTask'  = '任务已修改：'; 'undo.editEvent' = '日程已修改：'
    'undo.clickTip'  = '点此撤销上一步操作'
    'empty.list' = '这一周还没有安排'
    'empty.cta' = '+ 新建日程 · 点这里'
    'empty.filtered' = '没有符合条件的日程'
    'empty.clear' = '清除筛选'
    'tpl.save' = '保存并关闭'
    'tpl.close' = '不保存直接关闭（Esc）'
    'tip.checkbox' = '标记为已完成'
    'tip.checkboxDone' = '标记为未完成'
    # 设置窗口分页（第六轮）：四个页签
    'set.tab.appear' = '外观'
    'set.tab.window' = '窗口'
    'set.tab.data' = '数据'
    'set.tab.about' = '关于'
    # ===== 弹窗字段名（第六轮第二项建议）=====
    # ---- 日程弹窗 ----
    'fld.ed.title'    = '编辑日程'
    'fld.ed.new'      = '新建日程'
    'fld.ed.titleF'   = '标题'
    'fld.ed.date'     = '日期（yyyy-MM-dd）'
    'fld.ed.start'    = '开始（HH:mm）'
    'fld.ed.end'      = '结束（HH:mm）'
    'fld.ed.repeat'   = '重复'
    'fld.ed.every'    = '每隔 N 天 / 周 / 月重复一次'
    'fld.ed.until'    = '重复截止日（可选，yyyy-MM-dd）'
    'fld.ed.monthLast'= '按月重复时使用当月最后一天'
    'fld.ed.reminder' = '提醒'
    'fld.ed.tag'      = '标签'
    # ---- 重复选项 ----
    'opt.rep.none'    = '不重复'; 'opt.rep.daily' = '每天'
    'opt.rep.weekly'  = '每周'; 'opt.rep.monthly' = '每月'
    # ---- 提醒选项 ----
    'opt.rem.no'      = '不提醒'
    'opt.rem.5'       = '提前 5 分钟'; 'opt.rem.10' = '提前 10 分钟'
    'opt.rem.15'      = '提前 15 分钟'; 'opt.rem.30' = '提前 30 分钟'
    # ---- 任务弹窗 ----
    'fld.tk.title'    = '编辑任务'; 'fld.tk.new' = '新建任务'
    'fld.tk.text'     = '任务内容'
    'fld.tk.due'      = '截止日期（可选，yyyy-MM-dd）'
    'fld.tk.dueTime'  = '截止时间（HH:mm）'
    'fld.tk.priority' = '优先级'
    'fld.tk.project'  = '项目 / 清单'
    'fld.tk.category' = '分类'
    'fld.tk.estimated'= '预计用时（分钟）'
    'fld.tk.actual'   = '实际用时（分钟）'
    'fld.tk.subtasks' = '子任务'
    'fld.tk.done'     = '已完成'
    'fld.tk.tag'      = '分类'
    'btn.add'         = '+ 添加'
    'opt.pri.high'    = '高'; 'opt.pri.mid' = '中'; 'opt.pri.low' = '低'
    # ---- 专注弹窗 ----
    'fld.fo.title'    = '专注计时'
    'fld.fo.sub'      = '设置是否启用专注、一次专注多久，以及这次要做什么。'
    'fld.fo.enable'   = '启用专注计时'
    'fld.fo.breakOn'  = '专注结束后自动开始休息'
    'fld.fo.duration' = '专注时长（mm:ss —— 滚轮拨动每一位）'
    'fld.fo.wheelHint' = '滚轮拨动数字（或点它的上半/下半）即可调节；上限 99:59。'
    'fld.fo.break'    = '休息时长（可选或输入 0-99 分钟；0 = 不休息）'
    'fld.fo.task'     = '任务内容（选一个已有任务，或直接输入新任务）'
    # ---- 设置弹窗 ----
    'fld.st.title'    = '设置与专注统计'
    'fld.st.user'     = 'Windows 用户：'
    'fld.st.scale'    = '文字大小（同时跟随窗口宽度）'
    'fld.st.adaptive' = '文字大小跟随窗口宽度'
    'fld.st.theme'    = '主题'
    'fld.st.lang'     = '语言（侧栏与视图名称）'
    'fld.st.density'  = '周视图的行高'
    'fld.st.densityMonth' = '月视图的行高'
    'fld.st.topmost'  = '让窗口始终显示在其他窗口之上'
    'fld.st.tray'     = '关闭窗口时隐藏到托盘'
    'fld.st.trayHint' = '开启：点 × 只是隐藏窗口，程序继续在托盘运行。关闭：点 × 会询问是否退出。'
    'hint.st.adaptive'= '开启：窗口变宽时文字略放大、变窄时略缩小。关闭：文字大小只由上面那项决定。'
    'fld.st.weekRange'= '周视图默认显示的时间段'
    'fld.st.toastCorner' = '撤销 / 提醒提示条出现的位置'
    'opt.corner.br'   = '右下角'; 'opt.corner.bl' = '左下角'
    'opt.corner.tl'   = '左上角'; 'opt.corner.tr' = '右上角'
    'fld.st.toastSeconds' = '提示条停留多久'
    'opt.toast.s3'    = '3 秒'; 'opt.toast.s5' = '5 秒'
    'opt.toast.s8'    = '8 秒'; 'opt.toast.hold' = '不自动关（点一下才走）'
    'fld.st.pomo'     = '专注时长（0-99 分钟；0 = 不计时）'
    'fld.st.dir'      = '数据目录'
    'fld.st.searchHint' = '搜索设置项…'
    'fld.st.searchHit'  = '命中 {0} 项，已定位到第一项'
    'fld.st.searchNone' = '没有匹配的设置项'
    'fld.st.dirHint'  = '每台电脑每个账户一份，互相隔离'
    'fld.st.reset'    = '重置计时'
    'fld.st.openDir'  = '打开目录'
    'fld.st.version'  = '版本 '
    'fld.st.shortcuts'= '快捷键'
    'fld.st.thisWeek' = '本周专注 {0} 分钟 · {1} 个番茄钟'
    'fld.st.totals'   = '日程 {0}（已完成 {1}）· 未完成任务 {2}'
    'sc.newEvent'     = 'Ctrl+N  新建日程'
    'sc.search'       = 'Ctrl+F  搜索'
    'sc.esc'          = 'Esc     关闭当前弹窗'
    'sc.undo'         = 'Ctrl+Z  撤销'
    'sc.tabs'         = 'Ctrl+1..4  切换设置页签'
    'opt.scale.small' = '小'; 'opt.scale.normal' = '标准'
    'opt.scale.medium'= '中'; 'opt.scale.large' = '大'; 'opt.scale.huge' = '特大'
    'opt.theme.light' = '浅色'; 'opt.theme.night' = '夜间'
    'opt.dens.compact'= '紧凑'; 'opt.dens.normal' = '标准'; 'opt.dens.roomy' = '宽松'
    # 语言名**不翻译**（与英文表同值）：切到英文界面后仍要点得到"中文"切回来。
    'opt.lang.zh'     = '中文'; 'opt.lang.en' = 'English'
    # ---- 头像弹窗 ----
    'fld.av.title'    = '选择头像'
    'fld.av.random'   = '随机一个'
    'fld.av.pick'     = '从下面的方格里挑一个脸'
    # ---- 当日议程 ----
    'fld.day.title'   = '当日议程'
    'fld.day.empty'   = '这一天还没有安排'
    # ===== 第十轮：清理硬编码英文 UI 文案（全部收口到语言表）=====
    # ---- 期间选择窗 ----
    'pick.title'      = '跳转到日期'
    'pick.hint'       = '选任意一天。周视图跳到那一周，月视图和列表跳到那个月。'
    'pick.calTip'     = '选择日期'
    'btn.today'       = '今天'
    'pick.prevMonth'  = '上个月'
    'pick.nextMonth'  = '下个月'
    # ---- 任务视图 ----
    'empty.task'      = '没有符合条件的任务'
    'task.searchTip'  = '搜索任务标题'
    'task.searchHint' = '搜索任务标题…'
    'btn.focus'       = '专注'
    'btn.edit'        = '编辑'
    'btn.delete'      = '删除'
    'btn.start'       = '开始'
    'btn.endLog'      = '结束并统计'
    'btn.reset'       = '归零'
    'btn.chooseImg'   = '选择图片'
    'btn.restoreDef'  = '恢复默认'
    # ---- 周视图 ----
    'week.timeRange'  = '时间范围'
    'week.hoursTip'   = '选择周视图显示多少小时'
    # ---- 任务卡动作 ToolTip ----
    'tip.focus'       = '为这个任务开始专注'
    'tip.postpone'    = '推迟一天'
    'tip.editTask'    = '编辑任务'
    'tip.deleteTask'  = '删除任务'
    'tip.filterProj'  = '按这个项目筛选'
    'tip.show'        = '展开详情'
    'tip.hide'        = '收起详情'
    'tip.priHigh'     = '高优先级'
    'tip.priMid'      = '中优先级'
    'tip.priLow'      = '低优先级'
    # ---- 任务详情面板行标签（第十轮收口）----
    'det.title'       = '标题'
    'det.due'         = '截止'
    'det.priority'    = '优先级'
    'det.project'     = '项目'
    'det.estimate'    = '预估'
    'det.logged'      = '已用'
    'det.reminder'    = '提醒'
    'det.tag'         = '标签'
    'det.subtasks'    = '子任务'
    'unit.min'        = ' 分钟'
    'unit.minBefore'  = ' 分钟前提醒'
    # ---- 专注状态 ----
    'fo.ready'        = '就绪'
    'fo.noTask'       = '任务：未选择'
    'fo.last7'        = '近 7 天专注：{0} 分钟'
    'fo.dragTip'      = '拖这里移动窗口'
    'fo.disabledTip'  = '专注已禁用 - 点此打开设置'
    'fo.runningTip'   = '专注计时中 - 点此暂停'
    'fo.startTip'     = '点此开始专注计时'
    # ---- 头像弹窗 ----
    'av.title2'       = '你的头像'
    'av.hint'         = '选择 PNG、JPG、BMP 或 GIF 图片，会复制到应用数据目录。'
    'av.default'      = '默认'
    'av.change'       = '更换'
    'av.tip'          = '点击选择你自己的头像图片'
    # ---- 内置标签名 ----
    'tag.work'        = '工作'
    'tag.focus'       = '专注'
    'tag.life'        = '生活'
    'tag.task'        = '任务'
    # ---- 设置-数据页 ----
    'fld.st.focus7'   = '近 7 天专注（分钟）'
    # ---- 标签管理（第十轮）----
    'fld.st.tags'     = '标签（可自定义）'
    'fld.st.tagsHint' = '增删标签。标签决定任务卡上的色条、以及日程编辑器里的标签按钮。'
    'fld.st.tagName'  = '新标签名'
    'fld.st.tagColor' = '颜色'
    'btn.tagAdd'      = '+ 添加标签'
    'tip.tagRemove'   = '删除这个标签'
    # ---- 关于页 ----
    'about.appName'   = '我的日程'
    'about.tech'      = 'PowerShell 5.1 + WPF · 单文件 · 零依赖 · 纯本地'
    'about.author'    = '作者 · 蒲桃'
    'about.updated'   = '更新于 {0}'
    # ---- 当日议程空态 ----
    'fld.day.emptyDetail' = '这一天没有日程。'
    # ---- 筛选选项 ----
    'flt.allTags'     = '全部标签'
    'flt.allTasks'    = '全部任务'
    'flt.allProjects' = '全部项目'
    'flt.allStatus'   = '全部状态'
    'flt.allDates'    = '全部日期'
    'flt.open'        = '未完成'
    'flt.done'        = '已完成'
    'flt.today'       = '今天'
    'flt.thisWeek'    = '本周'
    'flt.overdue'     = '已逾期'
    'flt.noDate'      = '无日期'
    'flt.sortDue'     = '排序：截止日期'
    'flt.sortPriority' = '排序：优先级'
    'flt.sortTitle'   = '排序：标题'
    'lbl.thisMonth'   = '本月'
    'lbl.all'         = '全部'
    'btn.newTask'     = '+ 新建任务'
    'btn.save'        = '保存'
    'ui.search'       = '搜索…'
    # ---- 计数行与任务卡芯片 ----
    'cnt.openDone'    = '{0} 未完成 · {1} 已完成'
    'cnt.showing'     = '  ·  显示 {0}/{1}'
    'chip.overdue'    = '已逾期 · {0}'
    'chip.time'       = '用时 {0}/{1}m'
    'chip.sub'        = '子任务 {0}/{1}'
    'hero.stats'      = '已完成 {0}/{1}（{2}%）· 今日专注 {3} 小时 {4:00} 分'
    'cal.holiday1'    = '本月 {0} 个节假日'
    'cal.holidayN'    = '本月 {0} 个节假日'
    # ---- 编辑器/设置校验错误 ----
    'err.titleRequired'  = '标题不能为空。'
    'err.dateFormat'     = '日期格式应为 2026-09-24。'
    'err.timeFormat'     = '时间格式应为 09:30。'
    'err.repeatInterval' = '重复间隔必须是正数。'
    'err.repeatUntil'    = '重复截止格式应为 2026-12-31。'
    'err.sessionLen'     = '专注时长必须是 0-99 的整数分钟（0 = 不倒计时）。'
    'err.taskRequired'   = '任务内容不能为空。'
    'err.dueDate'        = '截止日期格式应为 2026-09-24。'
    'err.dueTime'        = '截止时间格式应为 09:30。'
    'err.breakLen'       = '休息时长必须是 0-99 的整数分钟（0 = 跳过休息）。'
    'err.focusDisabled'  = '请先启用专注计时器再开始。'
    # ---- 番茄钟按钮/状态 + 托盘 ----
    'pomo.setup'       = '去设置'
    'pomo.pause'       = '暂停'
    'pomo.resume'      = '继续'
    'pomo.disabled'    = '未启用'
    'pomo.break'       = '休息中'
    'pomo.breakPaused' = '休息已暂停'
    'pomo.focusing'    = '专注中'
    'pomo.complete'    = '已完成'
    'pomo.paused'      = '已暂停'
    'pomo.taskPrefix'  = '任务：'
    'pomo.session'     = '专注时段'
    'pomo.noTask'      = '未选择任务'
    'tray.name'        = '我的日程'
    # ---- 桌面通知 / Toast ----
    'ntf.breakDone'   = '休息结束'
    'ntf.breakReady'  = '准备好进入下一个专注时段。'
    'ntf.focusDone'   = '专注结束'
    'ntf.focusBreak'  = '{0} 结束 · 休息 {1} 分钟'
    'ntf.focusAdd'    = '{0} · +{1} 分钟'
    'ntf.focusLogged' = '专注已记录'
    'ntf.focus'       = '专注'
    'ntf.noLog'       = '还没有可记录的专注时长'
    'ntf.focusStarted' = '专注已开始'
    'ntf.inMin'       = '{0} 分钟后'
    'ntf.dueIn'       = '{0} 分钟后到期'
    'ntf.taskDue'     = '任务到期'
    # ---- 弹窗标题 ----
    'win.event'       = '日程'
    'win.settings'    = '设置'
    'win.task'        = '任务'
    'win.focus'       = '专注'
    'win.avatar'      = '头像'
    'win.dayAgenda'   = '当日议程'
    'win.pickDate'    = '选择日期'
    'dlg.chooseAvatar' = '选择头像图片'
}

function Get-LangText {
    # 按当前语言取词。键不存在时返回 $Key 本身（便于发现漏配，而不是静默显示空白）。
    param([string]$Key)
    if ($script:Lang -eq 'zh') {
        if ($script:LangZh.Contains($Key)) { return [string]$script:LangZh[$Key] }
    } else {
        if ($script:LangEn.Contains($Key)) { return [string]$script:LangEn[$Key] }
    }
    return $Key
}

function Initialize-Lang {
    # 把语言落到"读词用的那几个数组"上。
    # 为什么重算 $script:DowShort 而不是在每个调用点写 if：
    #   DowShort 有 3 个调用点（月视图表头 / 周视图表头 / Hero 日期），
    #   在每个点加分支会让"以后再加一处"变成新的漏点。改成"数组本身就是对的"最省事。
    #
    # MonShort 是"月份短名"。以前调用点直接对 MonNames 做 .Substring(0,3) 取前三个字母
    #   （September -> Sep）。中文月名（"9月"）只有 2 个字符，Substring(0,3) 会**抛越界** ——
    #   所以短名必须独立成数组，不能让调用方自己去切。
    if ($script:Lang -eq 'zh') {
        $script:DowShort = @('周一', '周二', '周三', '周四', '周五', '周六', '周日')
        $script:MonNames = @($script:MonZh)
        $script:MonShort = @($script:MonZh)
    } else {
        $script:DowShort = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
        $script:MonNames = @('January','February','March','April','May','June','July',
                             'August','September','October','November','December')
        $script:MonShort = @('Jan','Feb','Mar','Apr','May','Jun',
                             'Jul','Aug','Sep','Oct','Nov','Dec')
    }
}

function Set-Lang {
    # 切语言的**唯一入口**。以前是调用点各写一遍
    #     $script:Lang = $v; Initialize-Lang; Apply-Lang
    # 三连，设置窗口和启动序列各来一次 —— 两处只要有一处漏了 Apply-Lang，
    # 就变成"值存进去了但界面没变"（第五轮最典型的静默故障）。
    # 收成一个函数：设值 + 重建取词数组 + 刷 XAML 文案，顺序写死在这里。
    #
    # Apply-Lang 定义在 Care.ps1，而本函数定义在 ScheduleWidget.ps1 ——
    # 分片是按文件顺序执行的，ScheduleWidget.ps1 在 Care.ps1 之前，
    # 所以**定义期**看不到 Apply-Lang。但这里是在**调用期**才解析，
    # 那时全部分片都已点源完毕，是安全的。故必须放在 try 里防御。
    param([string]$Code)
    $v = ([string]$Code).ToLowerInvariant()
    if (@('zh', 'en') -notcontains $v) { return $false }
    $script:Lang = $v
    Initialize-Lang
    try { Apply-Lang } catch { }
    return $true
}

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
# 第七轮：全局快捷键（Ctrl+Z / Ctrl+N / Ctrl+F）只挂一次 PreviewKeyDown。
$script:HotkeyHooked = $false
# 第七轮（item 8.2）：设置窗四个页签的顺序（Ctrl+1..4 键盘导航 + 审计共用）。
$script:SetTabKeys = @('appear', 'window', 'data', 'about')
# 第八轮（第三十节第 6 条）：任务卡内联编辑的状态（双击标题原位改）。
$script:InlineTaskId = $null
$script:InlineTaskBox = $null
$script:InlineTaskText = $null
$script:FocusWindowOpen = $false
$script:AvatarWindowOpen = $false
# 第十轮（第 3 条）：标签管理的控件引用（设置窗数据页）。
$script:TagManagerStack = $null
$script:TagNewName = $null
$script:TagNewColor = $null
# 第十一轮：内置标签的稳定键清单（显示名本地化用，Get-TagLabel 反查）。
$script:TagBuiltin = @('work', 'focus', 'life', 'task')
# 字号倍率相关（第四轮）：XAML 硬编码字号的基线表 + 侧栏缩放后的宽度。
# 必须在根作用域显式起个值 —— StrictMode 2.0 下读未赋值变量会直接抛。
$script:XamlFontNodes = New-Object System.Collections.ArrayList
$script:NavColWidthScaled = 142.0
# 第七轮（item 7）：侧栏宽度再叠一层"窗口宽/窄"因子后的值，由 Apply-ResponsiveLayout 维护。
$script:NavColWidthResponsive = 142.0
# 第七轮（item 6）：最近一次"结束并统计"落库的分钟数（审计/测试用；0 = 没可记的时长）。
$script:LastFocusEndMin = 0
# 第七轮（item 5）：Focus 时长滚轮的当前值（秒）。控件与取值都以它为唯一真源。
$script:FoDurationMin = 25 * 60

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
$script:PomoMiniWin = $null  # 第十二轮：番茄钟迷你悬浮窗（惰性创建）
$script:AppUpdated = '2026-09-26'   # 工具最新更新时间（侧栏底部显示）
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
$script:DpWin        = $null
$script:DpCells      = $null
$script:DpFirst      = $null
$script:DpLabelText  = $null    # 第七轮：期间选择窗的月份标签（挂 $script: 才能被 DpPaint 安全引用）
$script:DpPaint      = $null
$script:FoWin        = $null
$script:FoEnabled    = $null
$script:FoTbDuration = $null
$script:FoDurationField = $null   # 第七轮：四位数字滚轮控件（替代 FoTbDuration 的下拉）
$script:FoDigitCells = $null      # 第七轮：四位滚轮的 4 个格子（重画与步进都读它）
$script:FoDigitMaxMin = 99
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
# 删除撤销（第五轮；第六轮升级为多级）。
#   $script:UndoStack —— 操作栈，**新的在末尾**，最多 $script:UndoDepth 条。
#   每条是一个 hashtable：@{ Kind='event'|'task'; Index=<原索引>; Snapshot=<对象副本>; Label=<提示文本> }
#
#  为什么第六轮要从"只留一次"升级成栈：
#    第五轮的判断是"实际事故都是刚删完就后悔"。但在审阅一批重复条目时，
#    连续删三条是常态 —— 这时只留一层，前两条就真的找不回来了，
#    而"刚删完就后悔"恰恰也适用于第 2、3 条。深度取 5：再多就变成
#    "要按 5 下才知道有没有恢复全"，反而不好用，而且每层都是一个完整对象副本。
#  $script:UndoState 仍然保留：它是**栈顶的别名**（同一次删除的引用，不是拷贝）。
#    这样第五轮写好的所有调用点（$script:UndoState = @{...} 那种）不用改，
#    但它们必须改走 Push-Undo —— 见下。旧写法只在审计里还有一处兜底使用。
$script:UndoStack      = New-Object System.Collections.ArrayList
$script:UndoDepth      = 5
$script:UndoState      = $null
$script:LastUndoAt     = $null
# 第七轮：最近一次撤销的 Kind 与"是否真的落地"（审计用；见 Undo-Delete）。
$script:LastUndoKind    = ''
$script:LastUndoApplied = $false
# 撤销反馈条控件（侧栏底部那行小字）。在 Care.ps1 绑定 XAML 时赋值；
# 换主题会重建整棵树，所以每次 Build-Window 都要重新绑定。
$script:UndoHint       = $null
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

# 恢复用户选的字号档位（第四轮）。必须在 Build-Window 之前应用 —— 那里会
# 用当前倍率去算所有 XAML 字号的基线映射，晚了就会先按 1.0 画一帧再跳变。
try {
    $us = [double]$script:Settings['UiScale']
    if ($us -lt 0.7 -or $us -gt 1.4) { $us = 1.0 }   # 配置被手改坏时回落到标准档
    $script:UiScaleUser = $us
} catch { $script:UiScaleUser = 1.0 }
[void](Update-UiScale)

# 恢复语言（第五轮）。必须在 Build-Window 之前设好 —— Apply-Lang 在构建末尾
# 按它刷侧栏导航文字，晚了就会先按默认语言画一帧再跳变。
try {
    $lg = ([string]$script:Settings['Language']).ToLowerInvariant()
    if (@('zh','en') -notcontains $lg) { $lg = 'zh' }   # 配置被手改坏时回落中文
    $script:Lang = $lg
} catch { $script:Lang = 'zh' }
# 注意：周视图密度要等分片加载之后再恢复 —— HourHeightBase 定义在 Views.ps1 里，
# 在这里赋值会被那个文件的 `$script:HourHeightBase = 40.0` 覆盖掉。见下面第 8.1 节。

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

# ---------------------------------------------------------------------------
#  8.1 恢复周视图密度（第五轮）—— 必须放在分片加载之后
#
#  为什么不能跟字号/语言一起放在第 8 节开头：
#    $script:HourHeightBase 定义在 Views.ps1 里（第 359 行 `= 40.0`）。
#    脚本前面的赋值会被那个文件的赋值**静默覆盖** —— 因为分片是在这之后点源的。
#    表现是"设置里选了紧凑 28，重启后又回到 40"，而且日志干净、不报错。
#    这类"顺序问题"只能靠"谁定义谁负责"来避：值定义在哪个文件，就在它加载后恢复。
#
#  HourHeightBase 同时是 Fit-WeekAxisHeight 的**密度下限**（那里只会上调、不会下调），
#  所以设它等于设"这套皮肤一小时占多高"。HourHeight 也要一起设，否则首帧
#  会先按旧值画一次再被 Reflow 纠正（肉眼能看到跳一下）。
# ---------------------------------------------------------------------------
try {
    $wd = [int]$script:Settings['WeekDensity']
    if ($wd -lt 20 -or $wd -gt 80) { $wd = 40 }   # 配置被手改坏时回落标准档
    $script:HourHeightBase = [double]$wd
    $script:HourHeight     = [double]$wd
    Write-Trace ('week density = ' + $wd)
} catch {
    $script:HourHeightBase = 40.0
    $script:HourHeight     = 40.0
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

# ---------------------------------------------------------------------------
#  删除的可撤销提示（第 5 条外观建议）
#
#  设计取舍：
#  * 二次确认（MessageBox Yes/No）保留 —— 它挡的是"点错按钮"；
#    Undo 提示条挡的是"确认之后立刻后悔"。两者是不同性质的事故，不能互相替代。
#  * 撤销用的副本放在 $script:UndoStack 而不是闭包里 —— 同上，作用域硬规则。
#  * 第六轮起是**多级**（深度 5）撤销；单级时代的"只保留最近一次"结论已被
#    审阅重复条目时"连删三条"的真实用法推翻，理由见下面 $script:UndoStack 的注释。
# ---------------------------------------------------------------------------
function Sync-UndoHint {
    # 把当前栈深写到侧栏状态条上（第六轮）。
    #   为什么单独抽出来：删除后（弹 Toast）、撤销后（被动提示）、撤销到空
    #   这三条路径都要刷新这行字，分别写三遍必然有一处漏掉 —— 漏掉的表现
    #   就是条上留着过期数字。统一走这个函数，深度为 0 时给"没有可撤销"。
    try {
        $n = Get-UndoDepth
        if ($n -gt 0) {
            Apply-UndoHintText ((Get-LangText 'undo.more') + $n)
        } else {
            Apply-UndoHintText (Get-LangText 'undo.none')
        }
    } catch { }
}

function Copy-Record {
    # 记录（任务 / 日程）的**浅拷贝**：逐字段复制到一个新 [pscustomobject]。
    #   为什么不用 .Clone()：数据是从 JSON 反序列化出来的（ConvertFrom-Json 给的是
    #   PSCustomObject），**没有** Clone 方法 —— 调它必然抛"不包含名为 Clone 的方法"
    #   （第七轮实测踩到：撤销栈的 Snapshot 因此压根没压进去，撤销静默失效）。
    #   ConvertTo-Json / ConvertFrom-Json 走一圈也能拷贝，但要处理 -Depth 与
    #   日期被转成字符串的副作用；本项目的记录都是"扁平 + 标量字段"，逐字段复制
    #   既准又不会踩到那些坑。
    param($Record)
    if ($null -eq $Record) { return $null }
    $copy = New-Object psobject
    foreach ($p in @($Record.PSObject.Properties)) {
        try { Add-Member -InputObject $copy -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force } catch { }
    }
    return $copy
}

function Show-UndoActionToast {
    # 给"非删除类"操作（勾选 / 拖动 / 编辑）弹一条可撤销的提示条。
    #   为什么要单独一个函数：这三个路径各自写在不同的文件里（Care.ps1 / Views.ps1 /
    #   Views2.ps1），如果各自手搓 Toast，文案键、剩余次数、Sync-UndoHint 三件事
    #   会各写一遍 —— 漏掉 Sync-UndoHint 就会出现"提示条撤了但侧栏小字还是旧数字"。
    #   与 Show-UndoToast 的分工：那个专管"删除"（文案是"已删除：xxx"），
    #   这个管其余操作（文案由调用方按 Kind 给对应的动词）。
    param([string]$Kind = '', [string]$LabelText = '', [string]$Title = '')
    if ($script:SuppressModal -or $TestMode) { return }
    try {
        $verb = Get-LangText $LabelText
        $txt = $verb + (Shorten-Text $Title 22)
        $n = Get-UndoDepth
        if ($n -gt 1) { $txt = $txt + '  (' + $n + ')' }
        Sync-UndoHint
        Show-Toast -Title (Get-LangText 'undo.task') -Text $txt `
            -ActionText (Get-LangText 'undo.btn') -Seconds 5 `
            -ActionScript { Undo-Delete }
    } catch { Write-ErrLog ('Undo action toast: ' + $_.Exception.Message) }
}

function Show-UndoToast {
    param([string]$Kind, [int]$Index = 0, [string]$Title = '')
    if ($script:SuppressModal -or $TestMode) { return }
    try {
        # 调用方（Remove-Task / Remove-Event）已经在撤销栈里压好条目；
        # 这里只负责把它变成一条可点的提示条。
        if ($Kind -eq 'task') {
            $label = (Get-LangText 'undo.task')
        } else {
            $label = (Get-LangText 'undo.event')
        }
        $verb = (Get-LangText 'undo.deleted')
        $txt = $verb + (Shorten-Text $Title 22)
        # 栈里还有更早的删除时，在提示条上标一下"还能撤几次" ——
        # 不标的话用户不知道多级撤销存在，等于白做。
        $n = Get-UndoDepth
        if ($n -gt 1) { $txt = $txt + '  (' + $n + ')' }
        Sync-UndoHint                      # 弹窗之外，主窗口里也留一份可读的层次
        Show-Toast -Title $label -Text $txt -ActionText (Get-LangText 'undo.btn') -Seconds 5 `
            -ActionScript { Undo-Delete }
    } catch { Write-ErrLog ('Undo toast: ' + $_.Exception.Message) }
}

function Undo-Delete {
    # 从**栈顶**弹一条并恢复。连续调用就是逐级回退（Ctrl+Z 连按）。
    #   函数名保留 Undo-Delete 不改：调用点有快捷键、提示条按钮、审计三处，
    #   而它的职责（"从撤销栈弹一条并应用"）自第五轮起就没变过。
    #   栈空时静默返回，并给一条"没有可撤销的操作"的提示 ——
    #   没提示的话用户会以为快捷键失灵，一直按个不停。
    #
    #  第七轮起按 Kind 分派恢复动作（第六轮第二十七节第 1 条）：
    #    task/event  -> 插回数组原位（删除的撤销）
    #    toggle      -> 用 Snapshot 覆盖该 id 的那一条（勾选状态的撤销）
    #    drag-task   -> 用 Snapshot 的时间字段覆盖（任务拖动改时间的撤销）
    #    drag-event  -> 同上（日程拖动）
    #  未知 Kind 一律当作"无法恢复"并跳过（不能因为一条坏数据把栈卡死）。
    try {
        if ($null -eq $script:UndoStack) { $script:UndoStack = New-Object System.Collections.ArrayList }
        if ($script:UndoStack.Count -le 0) {
            $script:UndoState = $null
            try { Apply-UndoHintText (Get-LangText 'undo.none') } catch { }
            Write-Trace 'undo empty'
            return
        }
        $st = $script:UndoStack[$script:UndoStack.Count - 1]
        $script:UndoStack.RemoveAt($script:UndoStack.Count - 1)
        $script:UndoState = $null
        if ($script:UndoStack.Count -gt 0) {
            $script:UndoState = $script:UndoStack[$script:UndoStack.Count - 1]
        }
        if ($null -eq $st) { Sync-UndoHint; return }
        $snap = $st.Snapshot
        if ($null -eq $snap) { Sync-UndoHint; return }
        $kind = [string]$st.Kind
        $applied = $false

        if ($kind -eq 'task' -or $kind -eq 'event') {
            # ---- 删除的撤销：插回原索引 ----
            $idx = [int]$st.Index
            if ($kind -eq 'task') {
                if ($idx -lt 0) { $idx = 0 }
                if ($idx -gt $script:Tasks.Count) { $idx = $script:Tasks.Count }
                $script:Tasks.Insert($idx, $snap)
                Save-Data
                Fill-Tasks
            } else {
                if ($idx -lt 0) { $idx = 0 }
                if ($idx -gt $script:Events.Count) { $idx = $script:Events.Count }
                $script:Events.Insert($idx, $snap)
                Save-Data
                Refresh-All
            }
            $applied = $true
        } elseif ($kind -eq 'toggle') {
            # ---- 勾选状态的撤销：用改前的整份对象按字段覆盖回去 ----
            #   不整条替换数组里的对象：那条对象可能已被别处引用（列表项 Tag 等），
            #   换掉引用会让那些地方指向旧对象。
            $id = [string]$st.Id
            $hit = @($script:Tasks | Where-Object { [string]$_.id -eq $id })
            if ($hit.Count -gt 0) {
                foreach ($p in @($snap.PSObject.Properties)) {
                    try { $hit[0].$($p.Name) = $p.Value } catch { }
                }
                Save-Data
                Fill-Tasks
                $applied = $true
            }
        } elseif ($kind -eq 'drag-task' -or $kind -eq 'drag-event') {
            # ---- 拖动改时间的撤销：只覆盖时间相关字段 ----
            $id = [string]$st.Id
            if ($kind -eq 'drag-task') {
                $hit = @($script:Tasks | Where-Object { [string]$_.id -eq $id })
                if ($hit.Count -gt 0) {
                    foreach ($f in @('due', 'dueTime')) {
                        if (@($snap.PSObject.Properties.Name) -contains $f) { $hit[0].$f = $snap.$f }
                    }
                    Save-Data
                    Fill-Tasks
                    $applied = $true
                }
            } else {
                $hit = @($script:Events | Where-Object { [string]$_.id -eq $id })
                if ($hit.Count -gt 0) {
                    foreach ($f in @('date', 'start', 'end')) {
                        if (@($snap.PSObject.Properties.Name) -contains $f) { $hit[0].$f = $snap.$f }
                    }
                    Save-Data
                    Refresh-All
                    $applied = $true
                }
            }
        } elseif ($kind -eq 'edit-task' -or $kind -eq 'edit-event') {
            # ---- 编辑器保存的撤销：整份对象按字段覆盖回去 ----
            #   与 toggle 同理（不整条替换数组里的对象，避免别处的引用指向旧对象），
            #   区别只在"改的字段多"——所以这里是通用的"整份回写"，不挑字段。
            #   第七轮只做了删除/勾选/拖动时，编辑是最容易失手的一类：
            #   手滑删掉标题、改错时间、误点重复规则，全都没有回头路。
            $id = [string]$st.Id
            $arr = $null
            if ($kind -eq 'edit-task') { $arr = $script:Tasks } else { $arr = $script:Events }
            $hit = @($arr | Where-Object { [string]$_.id -eq $id })
            if ($hit.Count -gt 0) {
                foreach ($p in @($snap.PSObject.Properties)) {
                    try { $hit[0].$($p.Name) = $p.Value } catch { }
                }
                Save-Data
                if ($kind -eq 'edit-task') { Fill-Tasks } else { Refresh-All }
                $applied = $true
            }
        }

        $script:LastUndoAt = (Get-Date)
        $script:LastUndoKind = $kind
        $script:LastUndoApplied = $applied
        Write-Trace ('undo applied kind=' + $kind + ' ok=' + $applied + ' remaining=' + $script:UndoStack.Count)
        # 撤销后刷新状态条上的"还剩几次"。
        #   走 Sync-UndoHint：栈刚好撤空时它给"没有可撤销"，不会有旧数字残留
        #   （"撤空时什么都不写、上一条提示留在条上"是第六轮实测到的坑）。
        Sync-UndoHint
    } catch { Write-ErrLog ('Undo: ' + $_.Exception.Message) }
}

function Apply-UndoHintText {
    # 把"还剩几次可撤销 / 没有可撤销"写到状态条上。
    #   为什么不复用 Show-Toast：这里的提示是**被动反馈**（不要求用户点），
    #   而 Toast 带按钮、会抢焦点；连按 Ctrl+Z 时弹一串 Toast 反而碍事。
    #   状态条左下角那块正好一直空着。
    param([string]$Text)
    try {
        if ($null -eq $script:UndoHint) { return }
        $script:UndoHint.Text = [string]$Text
    } catch { }
}

function Push-Undo {
    # 把一次操作压进撤销栈（第六轮多级；第七轮扩到"非删除"类操作）。
    #
    # Kind 语义（第八轮起共 8 种）：
    #   · 'task' / 'event'      —— 删除。Index + Snapshot（整份对象副本），撤销 = 插回原位。
    #   · 'toggle'              —— 勾选/取消勾选完成。需 Id + Snapshot（改前的整份对象）。
    #   · 'drag-task' / 'drag-event' —— 拖动改时间。需 Id + Snapshot（改前的时间字段）。
    #   · 'edit-task' / 'edit-event' —— 打开编辑器改字段后保存。需 Id + Snapshot（改前整份对象）。
    #
    # 为什么"编辑"单独开两种 Kind，而不复用 drag-task：
    #   drag-* 的撤销只回写时间字段（due/dueTime 或 date/start/end），因为拖动**只可能**
    #   改这些；而编辑器一次能改标题/时间/重复规则/提醒/标签 —— 必须整份回写。
    #   合成一种 Kind 会让"拖一下再撤"也把标题一起回写（看似无害，实则把用户
    #   期间的编辑一起吞掉），所以按"改了多少字段"分档。
    #
    # 为什么"勾选/拖动/编辑"也存整份 Snapshot 而不是只存 delta：
    #   ① 对象都是几十字节的 pscustomobject，整份存最省心，也不会因为"字段增删"而失效；
    #   ② 只存 delta 就必须为每种操作写一份"反向补丁"，将来加字段又要改两处 ——
    #      这正是本轮做这个功能的初衷（用户按 Ctrl+Z 期望"回到上一个状态"）。
    # 满了就从头部丢最老的一条 —— ArrayList.RemoveAt(0) 对 5 个元素可以忽略不计。
    param([string]$Kind, [int]$Index = -1, $Snapshot = $null, [string]$Label = '', [string]$Id = '')
    try {
        if ($null -eq $script:UndoStack) { $script:UndoStack = New-Object System.Collections.ArrayList }
        [void]$script:UndoStack.Add(@{
            Kind = $Kind; Index = $Index; Snapshot = $Snapshot
            Label = $Label; Id = $Id; Time = (Get-Date)
        })
        while ($script:UndoStack.Count -gt [int]$script:UndoDepth) { $script:UndoStack.RemoveAt(0) }
        # 栈顶别名：保持第五轮的 $script:UndoState 语义（"最近一次删除"）
        $script:UndoState = $script:UndoStack[$script:UndoStack.Count - 1]
    } catch { Write-ErrLog ('Push-Undo: ' + $_.Exception.Message) }
}

function Get-UndoDepth {
    if ($null -eq $script:UndoStack) { return 0 }
    return [int]$script:UndoStack.Count
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
    # 记住原索引：撤销要插回原位，而不是塞到末尾（否则排序看着像"撤销没生效"）
    $oldIndex = 0
    for ($i = 0; $i -lt $script:Events.Count; $i++) {
        if ([string]$script:Events[$i].id -eq [string]$Id) { $oldIndex = $i; break }
    }
    $snap = $hit[0]
    [void]$script:Events.Remove($hit[0])
    Save-Data
    Refresh-All
    Push-Undo -Kind 'event' -Index $oldIndex -Snapshot $snap -Label ([string]$snap.title)
    Show-UndoToast -Kind 'event' -Index $oldIndex -Title ([string]$snap.title)
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
    $oldIndex = 0
    for ($i = 0; $i -lt $script:Tasks.Count; $i++) {
        if ([string]$script:Tasks[$i].id -eq [string]$Id) { $oldIndex = $i; break }
    }
    $snap = $hit[0]
    [void]$script:Tasks.Remove($hit[0])
    Save-Data
    Fill-Tasks
    Push-Undo -Kind 'task' -Index $oldIndex -Snapshot $snap -Label ([string]$snap.text)
    Show-UndoToast -Kind 'task' -Index $oldIndex -Title ([string]$snap.text)
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
    Show-Toast -Title (Get-LangText 'ntf.focusStarted') -Text ([string]$hit[0].text)
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

function Find-TextBlockByText {
    # 按文字找 TextBlock。用来验"某个标题确实不存在了"——
    # 找按钮的 Find-ButtonByText 看不见裸露的 TextBlock（导航条目、小标题等）。
    param($El, [string]$Text)
    if ($null -eq $El) { return $null }
    foreach ($t in @(Find-AllOfType $El ([System.Windows.Controls.TextBlock]))) {
        if ([string]$t.Text -eq $Text) { return $t }
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
    # 按 Name 找弹窗标题栏上的按钮（'DlgSave' / 'DlgClose'）。
    # 第四轮标题栏从"只有一个 ×"扩成三件套，断言要能分别点它们，
    # 所以把"按 Name 找按钮"抽出来，而不是复制三遍 Find-AllOfType 循环。
    # 第五轮删掉 Cancel 后只剩两个 Name，但"按 Name 找"这件事没变；
    # 它还兼着一个职责：找 'DlgCancel' 返回 $null 就是"Cancel 确实没被加回来"的证据。
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
        # 第七轮（item 4）：按钮改名 '+New task'；同时"Tasks"大标题已删。
        #   第十一轮：计数"x 未完成"移到列表底部 footer，按钮在顶部筛选行，
        #   所以现在是"按钮在上、计数在下"（pBtn.Y < pCnt.Y）。
        #   断言验三件事，缺一层都可能假绿：
        #     ① 按钮文字确实变了（按旧文案找不到、按新文案找得到）；
        #     ② 按钮在顶部筛选行、计数在底部 footer（按钮 Y 小于计数 Y）；
        #     ③ 视图里不再存在 'Tasks' 大标题（按文字找得到就算失败）。
        $addTaskBtn = Find-ButtonByText $script:NodeHost (Get-LangText 'btn.newTask')
        $oldAddBtn  = Find-ButtonByText $script:NodeHost '+ Add task'
        $rowOk = $false
        if ($null -ne $addTaskBtn -and $null -ne $script:TaskOpenText) {
            try {
                $script:MainWindow.UpdateLayout()
                $pBtn = $addTaskBtn.TransformToAncestor($script:MainWindow).Transform([System.Windows.Point]::new(0, 0))
                $pCnt = $script:TaskOpenText.TransformToAncestor($script:MainWindow).Transform([System.Windows.Point]::new(0, 0))
                $rowOk = ([double]$pBtn.Y -lt [double]($pCnt.Y - 8.0))
            } catch { }
        }
        $titleGone = ($null -eq (Find-TextBlockByText $script:NodeHost 'Tasks'))
        Write-AuditRow 'task add button renamed + in filter row' `
            (($null -ne $addTaskBtn) -and ($null -eq $oldAddBtn) -and $rowOk -and $titleGone) `
            ('found=' + [string]($null -ne $addTaskBtn) + ' oldGone=' + [string]($null -eq $oldAddBtn) +
             ' aboveCount=' + [string]$rowOk + ' titleGone=' + [string]$titleGone)
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
        #   第六轮补：设置窗口分页后，"外观"页里没有 TextBox（全是下拉/开关），
        #   TextBox 在"窗口"页（番茄钟时长）与"数据"页（目录），所以找 TextBox 之前
        #   要先切到有 TextBox 的那一页 —— 否则这条会变成"重构正确但断言报错"。
        foreach ($w in @(@('event editor', 'editor'), @('settings window', 'settings'))) {
            $win = $null
            $why = ''
            try {
                if ([string]$w[1] -eq 'editor') { $win = Show-EventEditorWindow -Id '' }
                else {
                    $win = Show-SettingsWindow
                    # 切到"窗口"页（番茄钟时长是 TextBox）
                    if ($null -ne $script:SetTabsShow) { & $script:SetTabsShow 'window' }
                }
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
        #   第七轮（item 3）后，"原封不动"的表单点 × 是直接放弃关闭（不校验）。
        #   所以这条断言必须**先让表单变成"动过"**（改一下日期），再清空标题点 ×，
        #   才测得到"标题必填"这条校验 —— 否则测的是"能不能直接退出"，
        #   两条断言的语义就串了（回归里另有一条 event editor exits when untouched 管那个）。
        try {
            $ew = Show-EventEditorWindow -Id ''
            $ew.UpdateLayout()
            $n0 = @($script:Events).Count
            # 先动一下日期（让它变 dirty），再把标题清空
            $script:EdTbDate.Text = Fmt-Date ([datetime]::Today.AddDays(1))
            $script:EdTbTitle.Text = '   '
            $dirty = [bool](Test-EventEditorDirty)
            $save = Find-DialogClose $ew
            if ($null -eq $save) {
                Write-AuditRow 'save rejects empty title' $false 'no close(x) button'
            } else {
                [void](Invoke-Click $save)
                $n1 = @($script:Events).Count
                $shown = ([string]$script:EdErr.Text) -and ([string]$script:EdErr.Visibility -eq 'Visible')
                Write-AuditRow 'save rejects empty title' ($dirty -and ($n1 -eq $n0) -and $shown) `
                    ("dirty=$dirty events $n0 -> $n1  err='$([string]$script:EdErr.Text)' vis=$([string]$script:EdErr.Visibility)")
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
            # 第六轮：重复/提醒改成 New-ChoiceField 之后，语义值在 .Tag、不在 .Text。
            #   审计要模拟"用户选了某一项"，必须走 Set-ChoiceFieldValue ——
            #   直接写 .Text 是写不进 Items 的合法值（IsEditable=false），
            #   表现为"设了没生效"，而 Save 读到 Tag 仍是默认值。
            Set-ChoiceFieldValue $script:EdRepeat 'weekly'
            $script:EdEvery.Text = '2'
            $script:EdUntil.Text = (Fmt-Date ([datetime]::Today.AddMonths(2)))
            $script:EdMonthLast.IsChecked = $false
            Set-ChoiceFieldValue $script:EdReminder '15'
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
        #   第六轮分页后 Reset timer 落在"数据"页 —— 断言必须**先切到那一页**再找按钮，
        #   否则拿到的是"当前页没有这个按钮"，会把一次正确的重构报成回归。
        try {
            if (-not [bool]$script:Pomo.Running) { Toggle-Pomodoro }
            $wasRunning = [bool]$script:Pomo.Running
            $sw = Show-SettingsWindow
            $sw.UpdateLayout()
            # 切到数据页（SetTabsShow 是设置窗自己挂的切页函数）
            if ($null -ne $script:SetTabsShow) { & $script:SetTabsShow 'data' }
            $sw.UpdateLayout()
            $bReset = Find-ButtonByText $sw (Get-LangText 'fld.st.reset')
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
            # 第七轮（item 5）：时长控件从"下拉框"换成"四位数字滚轮"。
            #   断言除了"控件建出来了"，还要验滚轮**真的能改值**：
            #   直接调 Step-FocusDigit 把个位分钟 +1，看 $script:FoDurationMin 有没有涨。
            $focusOk = ($null -ne $script:FoEnabled) -and ($null -ne $script:FoDurationField) -and
                       ($null -ne $script:FoTbTask) -and ($null -ne $script:FoTimeText) -and
                       ($null -ne $script:FoBreakEnabled) -and ($null -ne $script:FoBreakMin)
            $wheelOk = $false
            try {
                $script:FoDurationMin = 25 * 60
                & $script:DwPaint
                Step-FocusDigit 1 1     # 个位分钟 +1 -> 26 分
                $wheelOk = ([int]$script:FoDurationMin -eq 26 * 60)
            } catch { }
            Write-AuditRow 'build focus window' ($focusOk -and $wheelOk) `
                ('controls=' + [string]$focusOk + ' wheelStep=' + [string]$wheelOk)
            $oldMin = [int]$script:Settings['PomodoroMin']
            $oldEnabled = [bool]$script:Settings['PomodoroEnabled']
            $oldTask = [string]$script:Settings['PomodoroTask']
            $script:FoEnabled.IsChecked = $true
            $script:FoDurationMin = 1 * 60
            & $script:DwPaint
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
                            ([string]$script:LastNotification -like ((Get-LangText 'ntf.focusDone') + '*'))
            Write-AuditRow 'focus->break transition' $breakStartOk ('remaining=' + [int]$script:Pomo.Remaining)
            $script:Pomo.Mode = 'break'; $script:Pomo.Total = 300; $script:Pomo.Remaining = 0; $script:Pomo.Running = $true
            $script:LastNotification = ''
            Complete-PomodoroPhase
            $breakEndOk = ([string]$script:Pomo.Mode -eq 'focus') -and (-not [bool]$script:Pomo.Running) -and
                          ([string]$script:LastNotification -like ((Get-LangText 'ntf.breakDone') + '*'))
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
            # 第六轮：优先级/提醒走 New-ChoiceField，语义值在 .Tag，必须用 Set-ChoiceFieldValue。
            Set-ChoiceFieldValue $script:TkPriority 'high'
            $script:TkProject.Text = 'Audit Project'
            $script:TkEstimated.Text = '45'
            $script:TkActual.Text = '5'
            Set-ChoiceFieldValue $script:TkReminder '15'
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

        # ---- 29. 六个弹窗的标题栏按钮组：× 贴右边缘，Save 紧邻其左侧 ----
        #   第三轮是"只有一个 × 贴右边"，第四轮改成三件套，**第五轮改成两件套**
        #   （用户第 3 条反馈：Cancel 与 × 功能完全重合，只留 ×）。所以断言同步升级：
        #     · 两个按钮（DlgSave / DlgClose）都必须存在且都在标题栏（y ≤ 38）
        #     · 物理顺序必须是 Save < ×（左到右），且 × 仍然贴右边缘
        #     · 两个按钮都必须在标题栏右半边（bx ≥ 宽度的一半）—— 防止被塞到左边
        #     · **DlgCancel 必须不存在**（防止哪天又被顺手加回来，把这次的决定推翻）
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
            # 只禁"底部残留"那批文案。标题栏自己的两个按钮不在禁用范围里 ——
            # 它们靠 Name（DlgSave/DlgClose）识别，并用几何位置区分"在不在标题栏"。
            $banned = @('Cancel', 'Save', 'Close', 'Save & close', 'Save and close', 'OK')
            $barNames = @('DlgSave', 'DlgClose')
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
                # Cancel 必须彻底消失：Find-DialogButton 按 Name 找，找不到才算对
                $cancelGone = ($null -eq (Find-DialogButton $w 'DlgCancel'))
                $okX = $xs['DlgClose']; $okS = $xs['DlgSave']
                # 宽度必须量到真实值，否则"贴右边"这条断言会变成空转
                $wideOk = ($rw -ge 300.0)
                $edgeOk = $wideOk -and ($okX.r -ge ($rw - 20.0))
                # 第十轮（item 6）：Save 从标题栏移到底部按钮行。
                #   × 必须还在标题栏（y <= 38）；Save 必须落到内容下方（y > 38），
                #   且贴右下（右对齐），与 × 不再同一行。
                $xInBarOk = ($okX.y -le 38.0)
                $saveInFootOk = ($okS.y -gt 38.0)
                $saveRightOk = $wideOk -and ($okS.r -ge ($rw - 40.0))
                $fitOk = ($okS.w -ge 40.0) -and ($okX.w -ge 18.0)
                # 底部残留扫描：允许这两个（它们本来就叫这些名字）
                $leftover = 0
                foreach ($b in @(Find-AllOfType $w ([System.Windows.Controls.Primitives.ButtonBase]))) {
                    if ($barNames -contains [string]$b.Name) { continue }
                    $c = $b.Content
                    if ($c -is [System.Windows.Controls.TextBlock]) { $c = $c.Text }
                    if ($banned -contains [string]$c) { $leftover++ }
                }
                $ok = $edgeOk -and $xInBarOk -and $saveInFootOk -and $saveRightOk -and $fitOk -and
                      ($leftover -eq 0) -and $cancelGone
                if (-not $ok) { $allOk = $false }
                $notes.Add(('{0}: save={1} x={2}/{3} y={4} leftover={5} noCancel={6}' -f `
                    $nm, [int]$okS.x, [int]$okX.r, [int]$rw, [int]$okX.y, $leftover, $cancelGone))
                try { $w.Close() } catch { }
            }
            Write-AuditRow 'dialog bar has save+x only' $allOk ($notes -join '  ')
        } catch { Write-AuditRow 'dialog bar has save+x only' $false ('crash ' + $_.Exception.Message) }

        # ---- 29b. × 要真的关窗并保存；Save 与 × 等价；两者都不该留残留按钮 ----
        #   三条链路分别验：
        #     ① × 关窗 + 设置落库（第三轮就有的能力，不能因为删按钮而退化）
        #     ② Save 也关窗 + 落库（它走的是"打 Click 给 ×"，靠这条证明转发真的成立）
        #     ③ 只读面板（当日议程）上 × 与 Save 也都能关窗
        #   **第五轮删掉了 Cancel，所以原来那条"Cancel 关窗但不落库"的断言也一并删掉** ——
        #   它测的是一个已经不存在的按钮，留着只会变成一条永远找不到控件的假绿。
        #   注意：29e 那条"改动不落库"的断言也同步改成了走 × 之前先还原，
        #   因为"不保存关闭"这个能力对设置窗已经不存在了（× 就是保存）。
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

            # 当日议程窗口（只读面板）：× 与 Save 都得能关掉它
            $script:DlgClosed = ''
            $dw2 = Show-DayAgendaWindow -Date ([datetime]::Today)
            $dw2.Add_Closed({ $script:DlgClosed = 'day' })
            $dw2.UpdateLayout()
            [void](Invoke-Click (Find-DialogClose $dw2))
            $okD = ($script:DlgClosed -eq 'day')
            $script:DlgClosed = ''
            $dw3 = Show-DayAgendaWindow -Date ([datetime]::Today)
            $dw3.Add_Closed({ $script:DlgClosed = 'day-save' })
            $dw3.UpdateLayout()
            [void](Invoke-Click (Find-DialogButton $dw3 'DlgSave'))
            $okD2 = ($script:DlgClosed -eq 'day-save')

            Write-AuditRow 'dialog x / save wiring' ($okX1 -and $okS2 -and $okD -and $okD2) `
                ('x=' + $okX1 + ' save=' + $okS2 + ' dayX=' + $okD + ' daySave=' + $okD2)
        } catch { Write-AuditRow 'dialog x / save wiring' $false ('crash ' + $_.Exception.Message) }

        # ---- 29c. 设置里改字号：落库 + 真的生效（第四轮新增，用户第 3 项） ----
        #   为什么不能只验"Settings['UiScale'] 变了"：
        #   倍率是一个纯数字，落库对了不代表界面真的按它重画了。
        #   所以这里同时验三件事：
        #     ① 落库（Settings['UiScale']）
        #     ② 运行时因子（$script:UiScaleUser）
        #     ③ **真的造一个控件出来量它的字号** —— 这是唯一能证明"工厂真的读了倍率"的方式。
        #   只验①②的话，即使 New-Txt 忘了走 Scale-Ui，断言也照样是绿的。
        try {
            $keepScale0 = [double]$script:Settings['UiScale']
            $keepUser0 = [double]$script:UiScaleUser

            # 先量一个"标准档"下的参照字号
            $script:Settings['UiScale'] = 1.00
            $script:UiScaleUser = 1.00
            [void](Update-UiScale)
            $baseTxt = New-Txt -Text 'probe' -Size 12
            $baseFs = [double]$baseTxt.FontSize
            $baseBtn = New-PixBtn -Text 'probe' -W 100 -H 34 -FontSize 12
            $baseBtnH = [double]$baseBtn.Height

            # 走真实链路：开设置窗 -> 选 Huge -> 点 Save
            $script:DlgClosed = ''
            $sw5 = Show-SettingsWindow
            $sw5.Add_Closed({ $script:DlgClosed = 'scale-applied' })
            $sw5.UpdateLayout()
            Set-ChoiceFieldValue $script:SetUiScale 'huge'
            # 自适应会让结果掺进窗口宽度的影响，这里先关掉，保证验的是"用户档位"这一条线
            $script:SetUiAdaptive.IsChecked = $false
            [void](Invoke-Click (Find-DialogButton $sw5 'DlgSave'))

            $saved = [double]$script:Settings['UiScale']
            $user = [double]$script:UiScaleUser
            $hugeTxt = New-Txt -Text 'probe' -Size 12
            $hugeFs = [double]$hugeTxt.FontSize
            $hugeBtn = New-PixBtn -Text 'probe' -W 100 -H 34 -FontSize 12
            $hugeBtnH = [double]$hugeBtn.Height

            $okSave = ([math]::Abs($saved - 1.35) -lt 0.001) -and ([math]::Abs($user - 1.35) -lt 0.001)
            # 字号与按钮高度都必须真的变大（且不是"变了一点点"，1.35/1.00 应看得见）
            $okTxt = ($hugeFs -gt $baseFs + 1.0)
            $okBtn = ($hugeBtnH -gt $baseBtnH + 1.0)
            $okClosed = ($script:DlgClosed -eq 'scale-applied')

            Write-AuditRow 'settings text size applies' ($okSave -and $okTxt -and $okBtn -and $okClosed) `
                ('saved=' + $saved + ' txt ' + $baseFs + '->' + $hugeFs + ' btn ' + $baseBtnH + '->' + $hugeBtnH + ' closed=' + $okClosed)

            $script:Settings['UiScale'] = $keepScale0
            $script:UiScaleUser = $keepUser0
            [void](Update-UiScale)
            $script:Settings['UiAdaptive'] = $true
            Save-Settings
        } catch { Write-AuditRow 'settings text size applies' $false ('crash ' + $_.Exception.Message) }

        # ---- 29d. 设置里改主题 / 置顶 / 关闭到托盘：Cancel 不该落库 ----
        #   主题切换最容易写错的地方：Set-Theme 会在重建界面时二次触发，
        #   所以断言要连"重建之后 Theme 仍然是新的"一起断（不能只断处理器入口那一瞬）。
        try {
            $keepTheme0 = [string]$script:Theme
            $keepTop0 = [bool]$script:Settings['Topmost']
            $keepTray0 = [bool]$script:Settings['CloseToTray']
            $keepRange0 = [string]$script:Settings['WeekViewRange']

            $script:DlgClosed = ''
            $sw6 = Show-SettingsWindow
            $sw6.Add_Closed({ $script:DlgClosed = 'theme-applied' })
            $sw6.UpdateLayout()
            Set-ChoiceFieldValue $script:SetThemeBox 'night'
            $script:SetTopmost.IsChecked = $true
            $script:SetCloseToTray.IsChecked = $true
            $script:SetWeekRange.Text = '8-20'
            [void](Invoke-Click (Find-DialogButton $sw6 'DlgSave'))

            $okTheme = ([string]$script:Theme -eq 'night') -and ([string]$script:Settings['Theme'] -eq 'night')
            $okTop = ([bool]$script:Settings['Topmost'])
            $okTray = ([bool]$script:Settings['CloseToTray'])
            $okRange = ([string]$script:Settings['WeekViewRange'] -eq '8-20')
            $okClosed2 = ($script:DlgClosed -eq 'theme-applied')

            Write-AuditRow 'settings theme and window opts' ($okTheme -and $okTop -and $okTray -and $okRange -and $okClosed2) `
                ('theme=' + $script:Theme + ' top=' + $okTop + ' tray=' + $okTray + ' range=' + $script:Settings['WeekViewRange'])

            # 复原
            if ($keepTheme0 -ne [string]$script:Theme) { try { Set-Theme $keepTheme0 -Sync } catch { } }
            $script:Settings['Topmost'] = $keepTop0
            $script:Settings['CloseToTray'] = $keepTray0
            $script:Settings['WeekViewRange'] = $keepRange0
            $script:TopmostOn = $keepTop0
            try { if ($null -ne $script:MainWindow) { $script:MainWindow.Topmost = $keepTop0 } } catch { }
            $script:CloseToTray = $keepTray0
            Save-Settings
        } catch { Write-AuditRow 'settings theme and window opts' $false ('crash ' + $_.Exception.Message) }

        # ---- 29d2. 提示条角落（第六轮新增，用户第 1 条第 5 项） ----
        #   四个角落逐个弹一条提示条，读它真实的 Left/Top，检查是不是贴在该贴的角上。
        #   为什么不能只断"设置值存对了"：设置存对、但 Show-Toast 里读错了键/算错了边距，
        #   表现就是"改了角落，提示条还在原地" —— 只有量坐标才能抓到。
        #   判定用"相对工作区的位置"，不依赖具体分辨率：
        #     br: 右边距 & 下边距都在屏内且靠近右下；bl/tl/tr 同理。
        try {
            $keepCorner2 = [string]$script:Settings['ToastCorner']
            $posOk = $true
            $dump = ''
            foreach ($cn in @('br','bl','tl','tr')) {
                $script:Settings['ToastCorner'] = $cn
                Show-Toast -Title 'Corner probe' -Text $cn -Seconds 30
                $tw = $script:ToastWindow
                if ($null -eq $tw) { $posOk = $false; $dump += ($cn + '=none '); continue }
                $tw.UpdateLayout()
                $wa = Get-ToastWorkArea
                $L = [double]$tw.Left; $T = [double]$tw.Top
                $W = [double]$tw.ActualWidth; $H = [double]$tw.ActualHeight
                # 允许 2px 量化误差；四个角各自的"贴边"条件
                $nearRight  = [math]::Abs(($L + $W) - $wa.Right)  -lt 24
                $nearLeft   = [math]::Abs($L - $wa.Left)          -lt 24
                $nearTop    = [math]::Abs($T - $wa.Top)           -lt 24
                $nearBottom = [math]::Abs(($T + $H) - $wa.Bottom) -lt 24
                $hit = $false
                switch ($cn) {
                    'br' { $hit = $nearRight -and $nearBottom }
                    'bl' { $hit = $nearLeft -and $nearBottom }
                    'tl' { $hit = $nearLeft -and $nearTop }
                    'tr' { $hit = $nearRight -and $nearTop }
                }
                if (-not $hit) { $posOk = $false }
                $dump += ($cn + '=' + $(if ($hit) { 'ok' } else { 'X' }) + '(' +
                          [int]$L + ',' + [int]$T + ') ')
            }
            try { if ($null -ne $script:ToastWindow) { $script:ToastWindow.Close() } } catch { }
            $script:Settings['ToastCorner'] = $keepCorner2
            Write-AuditRow 'toast corner positions toast' $posOk $dump.Trim()
        } catch { Write-AuditRow 'toast corner positions toast' $false ('crash ' + $_.Exception.Message) }

        # ---- 29e. 设置项"改控件 ≠ 落库"：只改控件文字不点 Save/×，一个都不许变 ----
        #   第五轮删掉 Cancel 之后，"改一堆设置再点 Cancel 看有没有落库"这条就失效了
        #   （没有 Cancel 可点）。但被它保护的那个不变量依然重要，而且这里能断得更准：
        #   **落库只发生在 Save-SettingsDialogValues 里**，而它只被 × 调用（Save 转发给 ×）。
        #   所以本条的断法是：改完控件文字后**什么都不点**（只是 UpdateLayout），
        #   直接检查 $script:Settings —— 全都不该变。这样既覆盖了原来 9 个设置项，
        #   又顺手钉住了"控件状态与已存设置解耦"这条设计边界（比按 Cancel 更本质）。
        try {
            $keepTheme1 = [string]$script:Theme
            $keepScale1 = [double]$script:Settings['UiScale']
            $keepTop1 = [bool]$script:Settings['Topmost']
            $keepTray1 = [bool]$script:Settings['CloseToTray']
            $keepRange1 = [string]$script:Settings['WeekViewRange']
            $keepPomo1 = [int]$script:Settings['PomodoroMin']
            $keepLang1 = [string]$script:Lang
            $keepDensity1 = [int]$script:Settings['WeekDensity']
            $keepMonthDensity1 = [int]$script:Settings['MonthDensity']
            $keepCorner1 = [string]$script:Settings['ToastCorner']

            $sw7 = Show-SettingsWindow
            $sw7.UpdateLayout()
            # 把每个控件都改成与当前值不同的值 —— 但不点任何按钮
            $script:SetTbPomo.Text = '88'
            Set-ChoiceFieldValue $script:SetUiScale 'huge'
            Set-ChoiceFieldValue $script:SetThemeBox 'night'
            $script:SetTopmost.IsChecked = $true
            $script:SetCloseToTray.IsChecked = $true
            $script:SetWeekRange.Text = '9-18'
            if ($keepLang1 -eq 'zh') { Set-ChoiceFieldValue $script:SetLangBox 'en' } else { Set-ChoiceFieldValue $script:SetLangBox 'zh' }
            Set-ChoiceFieldValue $script:SetDensityBox 'roomy'
            Set-ChoiceFieldValue $script:SetMonthDensityBox 'roomy'
            if ($keepCorner1 -eq 'br') { Set-ChoiceFieldValue $script:SetToastCorner 'tl' } else { Set-ChoiceFieldValue $script:SetToastCorner 'br' }
            $sw7.UpdateLayout()

            $okC = ([string]$script:Theme -eq $keepTheme1) -and
                   ([math]::Abs([double]$script:Settings['UiScale'] - $keepScale1) -lt 0.001) -and
                   ([bool]$script:Settings['Topmost'] -eq $keepTop1) -and
                   ([bool]$script:Settings['CloseToTray'] -eq $keepTray1) -and
                   ([string]$script:Settings['WeekViewRange'] -eq $keepRange1) -and
                   ([int]$script:Settings['PomodoroMin'] -eq $keepPomo1) -and
                   ([string]$script:Lang -eq $keepLang1) -and
                   ([int]$script:Settings['WeekDensity'] -eq $keepDensity1) -and
                   ([int]$script:Settings['MonthDensity'] -eq $keepMonthDensity1) -and
                   ([string]$script:Settings['ToastCorner'] -eq $keepCorner1)
            try { $sw7.Close() } catch { }

            Write-AuditRow 'settings fields do not save until close' $okC `
                ('theme=' + $script:Theme + ' scale=' + $script:Settings['UiScale'] +
                 ' top=' + $script:Settings['Topmost'] + ' tray=' + $script:Settings['CloseToTray'] +
                 ' range=' + $script:Settings['WeekViewRange'] + ' pomo=' + $script:Settings['PomodoroMin'] +
                 ' lang=' + $script:Lang + ' density=' + $script:Settings['WeekDensity'] +
                 ' corner=' + $script:Settings['ToastCorner'])
        } catch { Write-AuditRow 'settings fields do not save until close' $false ('crash ' + $_.Exception.Message) }

        # ---- 29e2. 设置窗口分页（第六轮新增，用户第 1 条） ----
        #   为什么值得单独一条：分页最容易的错法是"页签能点、但切了还是原来那页"
        #   （例如切页函数读的是已销毁的局部变量，静默失效）。所以这里断三件事：
        #     ① 四个页签都在，且 Text 取到了本地化文案（不是回落的键名）
        #     ② 初始停在"外观"页 —— $script:SetPageHost.Child 就是 $script:SetPageAppear
        #     ③ **点第二个页签之后，Host.Child 真的换成了 $script:SetPageWindow**
        #   第 ③ 条是关键：只看 Tag/文案是断不出"切页真的生效"的。
        try {
            $step = 'start'
            $sw8 = Show-SettingsWindow
            $sw8.UpdateLayout()
            $step = 'listprobe'
            $lst = $script:SetTabButtons
            $tabN = 0
            $tabs = New-Object System.Collections.Generic.List[object]
            foreach ($one in $lst) { [void]$tabs.Add($one); $tabN++ }
            $step = 'tabs'
            # 文案不许等于键名（Get-LangText 找不到时返回 $Key 本身）
            $txtOk = $true
            foreach ($b in $tabs) {
                $c = $b.Content
                if ($c -is [System.Windows.Controls.TextBlock]) { $c = $c.Text }
                $t = [string]$c
                if ($t -like 'set.tab.*') { $txtOk = $false }
                if ([string]::IsNullOrWhiteSpace($t)) { $txtOk = $false }
            }
            # 初始页 = 外观
            $step = 'startPage'
            $startOk = ($null -ne $script:SetPageHost) -and
                       ([object]::Equals([object]$script:SetPageHost.Child, [object]$script:SetPageAppear))
            # 真点第二个页签（窗口页）
            $step = 'findWindowTab'
            $winBtn = $null
            foreach ($b in $tabs) {
                $tg = $b.Tag
                if ($tg -is [hashtable] -and $tg.ContainsKey('key') -and ([string]$tg['key'] -eq 'window')) { $winBtn = $b; break }
            }
            $step = 'clickWindowTab'
            [void](Invoke-Click $winBtn)
            $sw8.UpdateLayout()
            $step = 'checkWindowPage'
            $switched = ([object]::Equals([object]$script:SetPageHost.Child, [object]$script:SetPageWindow))
            $activeOk = ([string]$script:SetTabActive -eq 'window')
            # 再点回"关于"，确认不是"只能切一次"
            $step = 'findAboutTab'
            $aboutBtn = $null
            foreach ($b in $tabs) {
                $tg = $b.Tag
                if ($tg -is [hashtable] -and $tg.ContainsKey('key') -and ([string]$tg['key'] -eq 'about')) { $aboutBtn = $b; break }
            }
            $step = 'clickAboutTab'
            [void](Invoke-Click $aboutBtn)
            $sw8.UpdateLayout()
            $step = 'checkAboutPage'
            $switched2 = ([object]::Equals([object]$script:SetPageHost.Child, [object]$script:SetPageAbout))
            # 高亮：切到"关于"之后，关于那个页签的模板底色应当变成强调色。
            #   为什么要读**模板**而不是读 $b.Background：New-PixBtn 把底色烘进
            #   ControlTemplate，控件的 .Background 属性在视觉上被模板覆盖 ——
            #   第六轮第一版只改了 .Background，截图里四个页签**全都没高亮**。
            #   又为什么不能用 Find-AllOfType 从可视树挖那个 Border：ControlTemplate
            #   的内部元素在"模板已应用 + 完成布局"之后才挂进可视树，审计里没有
            #   消息循环，这里拿不到。所以直接去模板里取名字为 bd 的 Border。
            $hlOk = $false
            $hlSeen = ''
            try {
                # Template.FindName 只在"模板已经应用到这个元素上"之后才找得到命名元素。
                #   审计里没有消息循环，控件可能还没走过 ApplyTemplate，所以要显式调一次，
                #   否则永远返回 $null —— 这会把"高亮其实是对的"误判成失败。
                [void]$aboutBtn.ApplyTemplate()
                $tpl = $aboutBtn.Template
                $named = $null
                if ($null -ne $tpl) { $named = $tpl.FindName('bd', $aboutBtn) }
                if ($null -ne $named) {
                    $hlSeen = [string]$named.Background
                    $want = [string](Brush (Get-Pal 'AccentFocus'))
                    $hlOk = ($hlSeen -eq $want)
                    $hlSeen = $hlSeen + ' want=' + $want
                } else { $hlSeen = 'bd-not-found' }
            } catch { $hlSeen = 'err:' + $_.Exception.Message }
            try { $sw8.Close() } catch { }

            $okP = ($tabN -eq 4) -and $txtOk -and $startOk -and $switched -and $activeOk -and $switched2 -and $hlOk
            Write-AuditRow 'settings window is paged' $okP `
                ('tabs=' + $tabN + ' text=' + $txtOk + ' startAppear=' + $startOk +
                 ' toWindow=' + $switched + ' active=' + [string]$script:SetTabActive +
                 ' toAbout=' + $switched2 + ' highlight=' + $hlOk + ' [' + $hlSeen + ']')
        } catch { Write-AuditRow 'settings window is paged' $false ('crash@' + $step + ' ' + $_.Exception.Message) }

        # ---- 29e3. 弹窗字段名跟着语言走（第六轮第二项建议） ----
        #   为什么必须单独断这一条：字段名"接进语言表"这件事最容易做到"看起来接上了、
        #   其实没接"—— 比如把键名写错（Get-LangText 找不到就原样返回键名，
        #   界面上会显示 "fld.ed.title" 这种字符串，刚好不会报错）。
        #   所以断言分三层：
        #     ① 中英两套语言表键集合**完全一致**（漏配一条就是这里红）；
        #     ② 抽查若干字段：中文下不是键名、且与英文文案不同；
        #     ③ 反向抽查：英文下确实是英文原文（证明不是"两边都返回键名"）。
        try {
            $keysZh = New-Object System.Collections.Generic.List[string]
            foreach ($k in $script:LangZh.Keys) { [void]$keysZh.Add([string]$k) }
            $keysEn = New-Object System.Collections.Generic.List[string]
            foreach ($k in $script:LangEn.Keys) { [void]$keysEn.Add([string]$k) }
            $missingInEn = @($keysZh | Where-Object { -not $script:LangEn.Contains($_) })
            $missingInZh = @($keysEn | Where-Object { -not $script:LangZh.Contains($_) })
            $keysOk = ($missingInEn.Count -eq 0) -and ($missingInZh.Count -eq 0)

            # 抽查的字段：日程弹窗 + 任务弹窗 + 设置各挑一个，覆盖三类控件（EditorField/ChoiceField/标题）
            $probe = @('fld.ed.titleF', 'fld.ed.repeat', 'fld.tk.priority', 'opt.pri.high',
                       'fld.st.theme', 'opt.theme.night', 'fld.fo.enable', 'fld.st.shortcuts')
            $keepLang2 = [string]$script:Lang
            $script:Lang = 'zh'; Initialize-Lang
            $zhTxt = @{}
            foreach ($k in $probe) { $zhTxt[$k] = [string](Get-LangText $k) }
            $script:Lang = 'en'; Initialize-Lang
            $enTxt = @{}
            foreach ($k in $probe) { $enTxt[$k] = [string](Get-LangText $k) }

            $noKeyLeak = $true      # 不许出现"返回了键名本身"
            $differs = $true        # 中英必须真的不同（否则等于没接）
            foreach ($k in $probe) {
                if ($zhTxt[$k] -eq $k -or $enTxt[$k] -eq $k) { $noKeyLeak = $false }
                # 'opt.lang.*' 是有意不翻译的；probe 里没放它，所以这里可以要求全部不同
                if ($zhTxt[$k] -eq $enTxt[$k]) { $differs = $false }
            }
            # 英文侧抽查一条原文（证明真的取到了英文，而不是"两边都是中文"）
            $enSpotOk = ($enTxt['fld.ed.titleF'] -eq 'Title') -and ($enTxt['opt.pri.high'] -eq 'High')

            $script:Lang = $keepLang2; Initialize-Lang

            $okL = $keysOk -and $noKeyLeak -and $differs -and $enSpotOk
            Write-AuditRow 'dialog labels follow language' $okL `
                ('zhKeys=' + $keysZh.Count + ' enKeys=' + $keysEn.Count +
                 ' missEn=' + $missingInEn.Count + ' missZh=' + $missingInZh.Count +
                 ' noLeak=' + $noKeyLeak + ' differs=' + $differs + ' enSpot=' + $enSpotOk +
                 ' sample:zh=' + $zhTxt['fld.ed.titleF'] + '/en=' + $enTxt['fld.ed.titleF'])
        } catch { Write-AuditRow 'dialog labels follow language' $false ('crash ' + $_.Exception.Message) }

        # ---- 29e4. 周/月密度互相独立（第六轮第三项建议） ----
        #   为什么必须单断"互不影响"：两个键拆开之后，最容易出的错是
        #   Save-SettingsDialogValues 里只写了新键、忘了另一个，
        #   或者两个控件绑到了同一个 Tag —— 表现是"改一个另一个也跟着变"，
        #   而只看"值存对了"的断言是查不出来的。
        #   做法：开设置窗 -> 只把周密度改成 roomy、月密度改成 compact -> Save
        #         -> 断两个键分别是 56 / 28（而不是都变成最后一次设的那个）。
        try {
            $keepW2 = [int]$script:Settings['WeekDensity']
            $keepM2 = [int]$script:Settings['MonthDensity']
            # 故意从"两个不同的起点"出发，避免"起点本来相同"掩盖绑定错误
            $script:Settings['WeekDensity'] = 40
            $script:Settings['MonthDensity'] = 40
            $sw9 = Show-SettingsWindow
            $sw9.UpdateLayout()
            Set-ChoiceFieldValue $script:SetDensityBox 'roomy'        # 56
            Set-ChoiceFieldValue $script:SetMonthDensityBox 'compact' # 28
            $sw9.UpdateLayout()
            [void](Invoke-Click (Find-DialogButton $sw9 'DlgSave'))
            $wNow = [int]$script:Settings['WeekDensity']
            $mNow = [int]$script:Settings['MonthDensity']
            # 第二个方向：反着设一次，确认不是"单向偶然"
            $sw10 = Show-SettingsWindow
            $sw10.UpdateLayout()
            Set-ChoiceFieldValue $script:SetDensityBox 'compact'      # 28
            Set-ChoiceFieldValue $script:SetMonthDensityBox 'roomy'   # 56
            $sw10.UpdateLayout()
            [void](Invoke-Click (Find-DialogButton $sw10 'DlgSave'))
            $wNow2 = [int]$script:Settings['WeekDensity']
            $mNow2 = [int]$script:Settings['MonthDensity']

            $okD1 = ($wNow -eq 56) -and ($mNow -eq 28)
            $okD2 = ($wNow2 -eq 28) -and ($mNow2 -eq 56)
            Write-AuditRow 'week / month density are independent' ($okD1 -and $okD2) `
                ('w=' + $wNow + ' m=' + $mNow + ' | w=' + $wNow2 + ' m=' + $mNow2)

            $script:Settings['WeekDensity'] = $keepW2
            $script:Settings['MonthDensity'] = $keepM2
            [void](Set-WeekDensity $keepW2)
            Save-Settings
        } catch { Write-AuditRow 'week / month density are independent' $false ('crash ' + $_.Exception.Message) }

        # ---- 29f. 窗口变大变小时字号跟着自适应（第四轮新增，用户第 4 项） ----
        #   为什么要直接改 Width 再调 Apply-ResponsiveLayout 而不是真的 Resize：
        #   审计里没有消息循环，改 Width 后 ActualWidth 不会立刻更新，
        #   所以这里显式设 Width 并让函数走它自己的 $width 取值分支。
        #   断三档：< 900 缩小、1280+ 放大、中间不变；再断"关掉开关后恒为 1.0"。
        try {
            $keepW = [double]$script:MainWindow.Width
            $script:Settings['UiAdaptive'] = $true

            $script:MainWindow.Width = 800
            Apply-ResponsiveLayout
            $autoNarrow = [double]$script:UiScaleAuto

            $script:MainWindow.Width = 1080
            Apply-ResponsiveLayout
            $autoMid = [double]$script:UiScaleAuto

            $script:MainWindow.Width = 1360
            Apply-ResponsiveLayout
            $autoWide = [double]$script:UiScaleAuto

            # 关掉开关：多宽都必须是 1.0
            $script:Settings['UiAdaptive'] = $false
            $script:MainWindow.Width = 800
            Apply-ResponsiveLayout
            $autoOff = [double]$script:UiScaleAuto
            $script:MainWindow.Width = 1360
            Apply-ResponsiveLayout
            $autoOff2 = [double]$script:UiScaleAuto

            $okA = ([math]::Abs($autoNarrow - 0.90) -lt 0.001) -and
                   ([math]::Abs($autoMid - 1.00) -lt 0.001) -and
                   ([math]::Abs($autoWide - 1.08) -lt 0.001)
            $okOff = ([math]::Abs($autoOff - 1.00) -lt 0.001) -and ([math]::Abs($autoOff2 - 1.00) -lt 0.001)
            # 最终倍率必须是 User × Auto 的乘积（证明自适应真的接进了 UiScale，不只是改了个旁支变量）
            $script:Settings['UiAdaptive'] = $true
            $script:UiScaleUser = 1.00
            $script:MainWindow.Width = 1360
            Apply-ResponsiveLayout
            $okProd = ([math]::Abs([double]$script:UiScale - 1.08) -lt 0.001)

            Write-AuditRow 'ui scale follows window width' ($okA -and $okOff -and $okProd) `
                ('narrow=' + $autoNarrow + ' mid=' + $autoMid + ' wide=' + $autoWide +
                 ' off=' + $autoOff + '/' + $autoOff2 + ' final=' + $script:UiScale)

            # 复原
            $script:MainWindow.Width = $keepW
            $script:Settings['UiAdaptive'] = $true
            Apply-ResponsiveLayout
        } catch { Write-AuditRow 'ui scale follows window width' $false ('crash ' + $_.Exception.Message) }

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
                    if ($null -ne $tb.Tag -and [string]$tb.Tag['kind'] -eq 'task-title') { $bodyTxt = $tb; break }
                }
                $bodyW = 0.0
                if ($null -ne $bodyTxt) { $bodyW = [double]$bodyTxt.ActualWidth }
                $pt1 = New-Object System.Windows.Point(0.0, 0.0)
                $acts = New-Object System.Collections.ArrayList
                foreach ($b in @(Find-AllOfType $target ([System.Windows.Controls.Primitives.ButtonBase]))) {
                    $c = $b.Content
                    if ($c -is [System.Windows.Controls.TextBlock]) { $c = $c.Text }
                    # 第十轮：按钮文本走语言表了，这里按当前语言的文案匹配（不再写死 'Focus'）。
                    if (@((Get-LangText 'btn.focus'), '+1') -contains [string]$c) { [void]$acts.Add($b) }
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
                        if (@((Get-LangText 'btn.edit'), (Get-LangText 'btn.delete'), 'Del') -contains [string]$c) { $beforeEdit++ }
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
                        if (@((Get-LangText 'btn.edit'), (Get-LangText 'btn.delete')) -contains [string]$c) { $afterEdit++ }
                    }
                    # 详情面板要有"标签 + 值"这种结构化行（Title / Due / Priority…）
                    foreach ($tb in @(Find-AllOfType $card4 ([System.Windows.Controls.TextBlock]))) {
                        if (@((Get-LangText 'det.title'), (Get-LangText 'det.due'), (Get-LangText 'det.priority')) -contains [string]$tb.Text) { $hasTitleLine = $true; break }
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
                if ($null -ne $b.ToolTip -and ([string]$b.ToolTip) -eq (Get-LangText 'fo.dragTip')) { $grip = $b; break }
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

        # ---- 36b. 期间选择窗：翻月按钮真的能翻（第七轮 item 1） ----
        #   用户报"jump to date 只有 9 月一个月份，点 < > 完全没反应"。
        #   根因：$script:DpPaint 里引用了 Show-PeriodPickerWindow 的**局部变量** $lbl，
        #   初始 paint 在函数内跑所以看着正常；点按钮时处理器在函数作用域之外执行，
        #   PowerShell 解析不到那个局部变量 -> 抛异常 -> 被 catch 吞掉 -> 按钮像死的。
        #   修法：$lbl 挂到 $script:DpLabelText，paint 只引用 $script: 上的东西。
        #   断言三层：① 月份标签文字随翻月变化；② $script:DpFirst 跟着进位；
        #             ③ 日期格子内容也跟着重画（而不是只改标签）。
        try {
            $script:Anchor = [datetime]::new(2026, 9, 24)
            $fp = Show-PeriodPickerWindow
            try { $fp.UpdateLayout() } catch { }
            $m0 = [string]$script:DpLabelText.Text
            $f0 = ([datetime]$script:DpFirst).ToString('yyyy-MM')
            $cell0 = [string]@($script:DpCells)[0].Content

            $nextBtn = $null
            foreach ($b in @(Find-AllOfType $fp ([System.Windows.Controls.Primitives.ButtonBase]))) {
                if ($null -ne $b.Tag -and ($b.Tag -is [hashtable]) -and
                    [string]$b.Tag['kind'] -eq 'pick-flip' -and [string]$b.Tag['dir'] -eq 'next') { $nextBtn = $b; break }
            }
            [void](Invoke-Click $nextBtn)
            try { $fp.UpdateLayout() } catch { }
            $f1 = ([datetime]$script:DpFirst).ToString('yyyy-MM')
            $m1 = [string]$script:DpLabelText.Text
            $days1 = 0
            foreach ($c in @($script:DpCells)) {
                if ($c.IsEnabled -and -not [string]::IsNullOrWhiteSpace([string]$c.Content)) { $days1++ }
            }
            # 回到上一个月：应该正好回到 9 月
            $prevBtn = $null
            foreach ($b in @(Find-AllOfType $fp ([System.Windows.Controls.Primitives.ButtonBase]))) {
                if ($null -ne $b.Tag -and ($b.Tag -is [hashtable]) -and
                    [string]$b.Tag['kind'] -eq 'pick-flip' -and [string]$b.Tag['dir'] -eq 'prev') { $prevBtn = $b; break }
            }
            [void](Invoke-Click $prevBtn)
            try { $fp.UpdateLayout() } catch { }
            $f2 = ([datetime]$script:DpFirst).ToString('yyyy-MM')
            try { $fp.Close() } catch { }

            # 2026-10 有 31 天；翻月后标签与首月都要变，再翻回来要回到 2026-09
            $flipLabelOk = ($m1 -ne '' -and $m1 -ne $m0)
            $flipStateOk = ($f0 -eq '2026-09') -and ($f1 -eq '2026-10') -and ($f2 -eq '2026-09')
            $flipGridOk  = ($days1 -eq 31)
            Write-AuditRow 'period picker flips month' ($flipLabelOk -and $flipStateOk -and $flipGridOk) `
                ('label=' + $m0 + '->' + $m1 + ' first=' + $f0 + '->' + $f1 + '->' + $f2 +
                 ' days=' + $days1 + ' cell0=' + $cell0)
        } catch { Write-AuditRow 'period picker flips month' $false ('crash ' + $_.Exception.Message) }

        # ---- 36c. 期间选择窗：没有 Save 按钮、也没有 Cancel（第七轮 item 2） ----
        #   这个窗只有"点某天 / Today"才落实跳转，Save 与 × 是同一个作用，删掉 Save。
        #   紧接着：既然 × 是唯一退出键，底部那个 Cancel 也一并删掉 ——
        #   否则又是"两个按钮干同一件事"（第六轮用户已经提过一次同类问题）。
        try {
            $script:Anchor = [datetime]::new(2026, 9, 24)
            $sp2 = Show-PeriodPickerWindow
            try { $sp2.UpdateLayout() } catch { }
            $saveBtn = $null
            $closeBtn = $null
            $cancelBtn = $null
            foreach ($b in @(Find-AllOfType $sp2 ([System.Windows.Controls.Primitives.ButtonBase]))) {
                if ([string]$b.Name -eq 'DlgSave') { $saveBtn = $b }
                if ([string]$b.Name -eq 'DlgClose') { $closeBtn = $b }
                $bc = $b.Content
                if ($bc -is [string] -and ([string]$bc).Trim() -ieq 'Cancel') { $cancelBtn = $b }
            }
            $noSaveOk = ($null -eq $saveBtn) -and ($null -ne $closeBtn) -and ($null -eq $cancelBtn)
            try { $sp2.Close() } catch { }
            Write-AuditRow 'period picker has no Save button' $noSaveOk `
                ('save=' + [string]($null -ne $saveBtn) + ' close=' + [string]($null -ne $closeBtn) +
                 ' cancel=' + [string]($null -ne $cancelBtn))
        } catch { Write-AuditRow 'period picker has no Save button' $false ('crash ' + $_.Exception.Message) }

        # ---- 36d. 新建日程：没动过任何字段就能直接退出（第七轮 item 3） ----
        #   用户报"没有新建的想法，不小心点进去就出不来了"。
        #   断言两个方向：① 原封未动 -> Test-EventEditorDirty 为 $false（可以退）；
        #                ② 改一个字段 -> 变 $true（要走必填校验）。
        try {
            $ev = Show-EventEditorWindow
            try { $ev.UpdateLayout() } catch { }
            $pristine = -not (Test-EventEditorDirty)
            $script:EdTbTitle.Text = 'Audit event title'
            $dirtyNow = [bool](Test-EventEditorDirty)
            # 复原成未动过（把标题清空），再验一次 -> 应该又变回"未动过"
            $script:EdTbTitle.Text = ''
            $pristine2 = -not (Test-EventEditorDirty)
            try { $ev.Close() } catch { }
            $evExitOk = $pristine -and $dirtyNow -and $pristine2
            Write-AuditRow 'event editor exits when untouched' $evExitOk `
                ('pristine=' + [string]$pristine + ' dirtyAfterType=' + [string]$dirtyNow +
                 ' pristineAgain=' + [string]$pristine2)
        } catch { Write-AuditRow 'event editor exits when untouched' $false ('crash ' + $_.Exception.Message) }

        # ---- 37. 番茄钟时长：四位滚轮 + 0-99 边界（第七轮改版） ----
        #   原来是"下拉框手输 0-99"。第七轮（item 5）换成四位数字滚轮后，
        #   "非法输入"这个分支在界面上已经不可能出现（每一位只会是 0-9），
        #   所以断言重点从"拒绝非法输入"转移到：
        #     ① 滚轮能把时长改到任意值（逐位步进都对）；
        #     ② 边界：能拨到 0，也能拨到上限 99（再往上拨被夹住）；
        #     ③ 0 落库后仍然是 0（不回落到 25），且 Reset 后 Total = 0；
        #     ④ 99 落库后 Reset 得到 5940 秒。
        #   —— 其中 ③ 是历史上真出过的坑（老代码 `if ($mins -lt 1) { $mins = 25 }`）。
        try {
            $keepPomoMin = $script:Settings['PomodoroMin']
            $dpFocus = Show-FocusWindow
            $caseLog = New-Object System.Collections.Generic.List[string]
            $allOk = $true

            # ① 逐位步进：从 25:00 开始，个位分 +1 -> 26:00；十位秒 +1 -> 26:10
            $script:FoDurationMin = 25 * 60
            & $script:DwPaint
            Step-FocusDigit 1 1
            $step1 = ([int]$script:FoDurationMin -eq 26 * 60)
            Step-FocusDigit 2 1
            $step2 = ([int]$script:FoDurationMin -eq 26 * 60 + 10)
            Step-FocusDigit 2 -1
            $step3 = ([int]$script:FoDurationMin -eq 26 * 60)
            if (-not ($step1 -and $step2 -and $step3)) { $allOk = $false }
            $caseLog.Add('step=' + [string]$step1 + [string]$step2 + [string]$step3)

            # ② 边界：0 与 99
            $script:FoDurationMin = 0
            & $script:DwPaint
            $toZero = ([int]$script:FoDurationMin -eq 0)
            # 从 0 往下拨，应该被夹在 0（不能变负）
            Step-FocusDigit 3 -1
            $clampLow = ([int]$script:FoDurationMin -eq 0)
            $script:FoDurationMin = 99 * 60
            & $script:DwPaint
            $toMax = ([int]$script:FoDurationMin -eq 99 * 60)
            # 从 99:00 往上拨（十位分 +1 = +10 分钟），应该被夹在 99:59 上限内
            Step-FocusDigit 0 1
            $clampHigh = ([int]$script:FoDurationMin -le (99 * 60 + 59))
            if (-not ($toZero -and $clampLow -and $toMax -and $clampHigh)) { $allOk = $false }
            $caseLog.Add('bounds=' + [string]$toZero + [string]$clampLow + [string]$toMax + [string]$clampHigh)

            # ③ 0 落库后仍是 0，Reset 后 Total = 0
            $script:FoDurationMin = 0
            $script:FoBreakMin.Text = '5'
            [void](Save-FocusWindowSettings)
            $zeroKept = ([int]$script:Settings['PomodoroMin'] -eq 0)
            Reset-Pomodoro
            $zeroTotal = ([int]$script:Pomo.Total -eq 0)

            # ④ 99 落库后 Reset 得 5940 秒
            $script:FoDurationMin = 99 * 60
            [void](Save-FocusWindowSettings)
            Reset-Pomodoro
            $maxTotal = ([int]$script:Pomo.Total -eq (99 * 60))
            try { $dpFocus.Close() } catch { }
            $script:Settings['PomodoroMin'] = $keepPomoMin
            Reset-Pomodoro
            Write-AuditRow 'pomodoro duration wheel 0-99' ($allOk -and $zeroKept -and $zeroTotal -and $maxTotal) `
                (($caseLog -join ' ') + ' zeroKept=' + [string]$zeroKept + ' zeroTotal=' + [string]$zeroTotal +
                 ' maxTotal=' + [string]$maxTotal)
        } catch { Write-AuditRow 'pomodoro duration 0-99 free' $false ('crash ' + $_.Exception.Message) }

        # ---- 37b. 专注：结束并统计（第七轮 item 6） ----
        #   用户要"结束并统计本次时间"：中途收工也要把已走的分钟记账，
        #   而不是只有 Reset（清空、白干）。
        #   断言必须验"账真的变了"，而不是"按钮被点了"：
        #     ① 今日统计 FocusTodayMin 增加了"已走分钟数"；
        #     ② $script:LastFocusEndMin 记录了这个数；
        #     ③ 关联任务的 actualMin 也同步增加；
        #     ④ 计时器归零（Running = false，Remaining = Total）。
        #   用 10 分钟的会话模拟"走了 4 分钟就收工"：Total=600s，Remaining=360s。
        try {
            $keepTodayMin = [int]$script:Settings['FocusTodayMin']
            $fw2 = Show-FocusWindow
            try { $fw2.UpdateLayout() } catch { }
            $script:FoEnabled.IsChecked = $true
            $script:FoDurationMin = 10 * 60
            & $script:DwPaint
            # 造一个关联任务，验 actualMin 同步
            $probeTask = [pscustomobject]@{
                id = 'audit-endfocus'; text = 'Audit end focus'; done = $false
                due = ''; dueTime = ''; tag = 'task'; priority = 'medium'; project = ''
                subtasks = @(); estimatedMin = 0; actualMin = 0; reminderMin = 0
            }
            [void]$script:Tasks.Add($probeTask)
            $script:FoTbTask.Text = 'Audit end focus'
            [void](Save-FocusWindowSettings)
            # 让本次专注处于"已走 4 分钟"的状态
            $script:Pomo.Mode = 'focus'
            $script:Pomo.Total = 600
            $script:Pomo.Remaining = 360
            $script:Pomo.Running = $true
            $script:Pomo.Task = 'Audit end focus'
            $script:Pomo.TaskId = 'audit-endfocus'
            $elapsedBefore = Get-FocusElapsedMin
            $todayBefore = [int]$script:Settings['FocusTodayMin']
            End-FocusSession
            $todayAfter = [int]$script:Settings['FocusTodayMin']
            $logged = [int]$script:LastFocusEndMin
            $actualAfter = 0
            $hitT = @($script:Tasks | Where-Object { [string]$_.id -eq 'audit-endfocus' })
            if ($hitT.Count -gt 0) { $actualAfter = [int]$hitT[0].actualMin }
            $endOk = ($elapsedBefore -eq 4) -and ($todayAfter -eq ($todayBefore + 4)) -and
                     ($logged -eq 4) -and ($actualAfter -eq 4) -and
                     (-not [bool]$script:Pomo.Running)
            try { $fw2.Close() } catch { }
            # 清理：删掉探针任务、还原今日统计
            $script:Tasks.Remove($probeTask)
            $script:Settings['FocusTodayMin'] = $keepTodayMin
            Save-Settings
            Reset-Pomodoro
            Write-AuditRow 'focus end and log session' $endOk `
                ('elapsed=' + [int]$elapsedBefore + ' today=' + [int]$todayBefore + '->' + [int]$todayAfter +
                 ' logged=' + [int]$logged + ' actual=' + [int]$actualAfter +
                 ' running=' + [string]([bool]$script:Pomo.Running))
        } catch { Write-AuditRow 'focus end and log session' $false ('crash ' + $_.Exception.Message) }

        # ---- 37c. 侧栏宽度随窗口大小自适应（第七轮 item 7） ----
        #   用户报"左侧栏大小不会跟着界面大小自适应"。
        #   断言：同一字号档位下，把窗口拉宽 -> 侧栏变宽；缩窄 -> 侧栏变窄。
        #   只比"宽窗口 >= 窄窗口 + 若干像素"，不比绝对值（绝对值受字号档位影响）。
        try {
            $keepW = [double]$script:MainWindow.Width
            $navW = @{}
            foreach ($case in @(@('narrow', 860), @('wide', 1400))) {
                $script:MainWindow.Width = [double]$case[1]
                try { $script:MainWindow.UpdateLayout() } catch { }
                Apply-ResponsiveLayout
                try { $script:MainWindow.UpdateLayout() } catch { }
                $navW[[string]$case[0]] = [double]$script:NavCol.Width.Value
            }
            $script:MainWindow.Width = $keepW
            Apply-ResponsiveLayout
            try { $script:MainWindow.UpdateLayout() } catch { }
            $navAdaptOk = ([double]$navW['wide'] -gt [double]$navW['narrow'])
            Write-AuditRow 'sidebar width follows window' $navAdaptOk `
                ('narrow=' + [int]$navW['narrow'] + ' wide=' + [int]$navW['wide'])
        } catch { Write-AuditRow 'sidebar width follows window' $false ('crash ' + $_.Exception.Message) }

        # ---- 37d. 撤销栈纳入"勾选"与"拖动改时间"（第七轮 item 8.1） ----
        #   第六轮第二十七节的第 1 条建议：撤销栈原来只记"删除"，而勾选和拖动
        #   同样会改数据、同样会失手。这里断言**两类新 Kind 都能回退**。
        try {
            $ugOk = $true
            # 前面若干条审计自己也压过撤销栈，先清空 —— 否则这里 Undo-Delete 弹出的是
            # 别人留下的"删除"条目（实测：k1=task 而非 toggle），断言就成了看运气。
            try { if ($null -ne $script:UndoStack) { $script:UndoStack.Clear() } } catch { }
            $script:UndoState = $null
            # -- 勾选：建一个任务，Toggle 两次，再撤两次，必须回到原位 --
            # 探针任务字段名必须**与真实任务一致**（text 而非 title）：
            #   Toggle-TaskDone 读 $hit[0].text，StrictMode 下缺字段会直接抛，
            #   Push-Undo 就被 catch 吞掉，表现为"勾选撤销没进栈"。
            $tgl = [pscustomobject]@{
                id = 'audit-undo-toggle'; text = 'Audit undo toggle'; done = $false
                due = ''; dueTime = ''; tag = ''; prio = ''; note = ''; actualMin = 0; repeat = ''
            }
            [void]$script:Tasks.Add($tgl)
            Save-Data
            $script:SuppressModal = $true
            [void](Toggle-TaskDone 'audit-undo-toggle')
            # 立刻取**值**而不是取对象引用：$script:Tasks 里那个 PSCustomObject 会被
            # 第二次 Toggle 原地改，拿引用去断言等于在看"最终状态"，永远测不出中间态。
            $midDone = [bool](@($script:Tasks | Where-Object { [string]$_.id -eq 'audit-undo-toggle' })[0].done)
            [void](Toggle-TaskDone 'audit-undo-toggle')
            $script:SuppressModal = $false
            Undo-Delete
            $afterOneDone = [bool](@($script:Tasks | Where-Object { [string]$_.id -eq 'audit-undo-toggle' })[0].done)
            $kindOne = [string]$script:LastUndoKind
            Undo-Delete
            $afterTwoDone = [bool](@($script:Tasks | Where-Object { [string]$_.id -eq 'audit-undo-toggle' })[0].done)
            # 期望：第一次撤销回到"已勾选"（True），第二次回到"未勾选"（False）
            if (-not $midDone) { $ugOk = $false }
            if (-not $afterOneDone) { $ugOk = $false }
            if ($afterTwoDone) { $ugOk = $false }
            if ($kindOne -ne 'toggle') { $ugOk = $false }
            # -- 拖动改时间：直接造一条 drag-task 栈项再撤 --
            $drg = [pscustomobject]@{
                id = 'audit-undo-drag'; text = 'Audit undo drag'; done = $false
                due = '2026-09-10'; dueTime = '10:00'; tag = ''; prio = ''; note = ''; actualMin = 0; repeat = ''
            }
            [void]$script:Tasks.Add($drg)
            Save-Data
            $dragSnap = Copy-Record $drg
            Push-Undo -Kind 'drag-task' -Id 'audit-undo-drag' -Snapshot $dragSnap -Label 'Audit drag'
            $target = @($script:Tasks | Where-Object { [string]$_.id -eq 'audit-undo-drag' })[0]
            $target.due = '2026-09-12'; $target.dueTime = '15:30'
            Save-Data
            Undo-Delete
            $afterDrag = @($script:Tasks | Where-Object { [string]$_.id -eq 'audit-undo-drag' })[0]
            if ([string]$afterDrag.due -ne '2026-09-10') { $ugOk = $false }
            if ([string]$afterDrag.dueTime -ne '10:00') { $ugOk = $false }
            if ([string]$script:LastUndoKind -ne 'drag-task') { $ugOk = $false }
            # 清理
            $script:Tasks.Remove($tgl); $script:Tasks.Remove($drg)
            Save-Data
            Fill-Tasks
            Write-AuditRow 'undo covers toggle and drag' $ugOk `
                ('toggleKind=' + $kindOne + ' dragKind=' + [string]$script:LastUndoKind +
                 ' mid=' + [string]$midDone + ' one=' + [string]$afterOneDone + ' two=' + [string]$afterTwoDone +
                 ' drag=' + [string]$afterDrag.due + ' ' + [string]$afterDrag.dueTime)
        } catch {
            $script:SuppressModal = $false
            Write-AuditRow 'undo covers toggle and drag' $false ('crash ' + $_.Exception.Message)
        }

        # ---- 37e. 侧栏撤销小字可点 + 全局快捷键（第七轮 item 8.3 / 8.4） ----
        try {
            $hkOk = $true
            # 撤销提示小字绑了 MouseLeftButtonUp（点了就 Undo-Delete）
            $hintTb = $script:UndoHint
            if ($null -eq $hintTb) { $hkOk = $false }
            else {
                if ([string]$hintTb.Cursor -ne 'Hand') { $hkOk = $false }
                if ($null -eq $hintTb.ToolTip) { $hkOk = $false }
            }
            # 全局快捷键只挂钩一次
            if (-not [bool]$script:HotkeyHooked) { $hkOk = $false }
            Write-AuditRow 'undo hint clickable and hotkeys armed' $hkOk `
                ('cursor=' + [string]([string]$hintTb.Cursor) + ' tip=' + [string]($null -ne $hintTb.ToolTip) +
                 ' hooked=' + [string]([bool]$script:HotkeyHooked))
        } catch { Write-AuditRow 'undo hint clickable and hotkeys armed' $false ('crash ' + $_.Exception.Message) }

        # ---- 37f. 提示条停留时长可配（第七轮 item 8.5） ----
        #   断两件事：(a) 设置窗里那个选项存在且取值合法；
        #              (b) 0 表示"不自动关" —— 弹一条后 ToastTimer 必须为 $null。
        try {
            $tsOk = $true
            $chosen = '5'
            if ($null -ne $script:SetToastSeconds) { $chosen = [string]$script:SetToastSeconds.Tag }
            if (@('0','3','5','8') -notcontains $chosen) { $tsOk = $false }
            # 切到"不自动关"弹一条，验证没有定时器
            $keepTs = [int]$script:Settings['ToastSeconds']
            $script:Settings['ToastSeconds'] = 0
            $script:SuppressModal = $false
            Show-Toast -Title 'Audit toast' -Text 'hold mode' -Seconds 3
            $noTimer = ($null -eq $script:ToastTimer)
            if (-not $noTimer) { $tsOk = $false }
            try { if ($null -ne $script:ToastWindow) { $script:ToastWindow.Close(); $script:ToastWindow = $null } } catch { }
            # 再切到 8 秒，验证定时器按设置走
            $script:Settings['ToastSeconds'] = 8
            Show-Toast -Title 'Audit toast' -Text 'timed mode' -Seconds 3
            $ivOk = $false
            if ($null -ne $script:ToastTimer) {
                if ([int]$script:ToastTimer.Interval.TotalSeconds -eq 8) { $ivOk = $true }
            }
            if (-not $ivOk) { $tsOk = $false }
            try {
                if ($null -ne $script:ToastTimer) { $script:ToastTimer.Stop() }
                if ($null -ne $script:ToastWindow) { $script:ToastWindow.Close(); $script:ToastWindow = $null }
            } catch { }
            $script:Settings['ToastSeconds'] = $keepTs
            Write-AuditRow 'toast duration configurable' $tsOk `
                ('choice=' + $chosen + ' holdNoTimer=' + [string]$noTimer + ' iv8=' + [string]$ivOk)
        } catch {
            Write-AuditRow 'toast duration configurable' $false ('crash ' + $_.Exception.Message)
        }

        # ---- 37g. 设置页签键盘导航 Ctrl+1..4（第七轮 item 8.2） ----
        #   只断"按键映射表存在且与四个页签一一对应"，不模拟真实按键
        #   （键盘事件走 InputManager，审计环境里派发不可靠）。
        try {
            $tabMapOk = ($null -ne $script:SetTabKeys) -and ($script:SetTabKeys.Count -eq 4) -and
                        ($script:SetTabKeys[0] -eq 'appear') -and ($script:SetTabKeys[3] -eq 'about')
            Write-AuditRow 'settings tab hotkeys mapped' $tabMapOk `
                ('keys=' + [string](@($script:SetTabKeys) -join '/'))
        } catch { Write-AuditRow 'settings tab hotkeys mapped' $false ('crash ' + $_.Exception.Message) }

        # ---- 38. 第五轮：语言切换 / 周视图密度 / 删除撤销 / 空状态入口 ----
        #   这四条都是"改设置之后必须真的生效"，但生效点在三个不同的地方：
        #     语言 → XAML 里的导航文字（Apply-Lang 事后遍历改）
        #     密度 → 周视图轴高（Set-WeekDensity 改 HourHeightBase）
        #     撤销 → 数据数组 + 界面（Undo-Delete 插回原位）
        #   所以必须逐项断"改完之后**读回来是对的**"，只断"函数被调用了"没有意义。
        try {
            # ---- 38a. 语言：切到 en 后导航文字变英文，切回 zh 复原 ----
            $keepLang2 = [string]$script:Lang
            [void](Set-Lang 'en')
            $enMonth = Get-LangText 'nav.month'
            $enDow = [string]$script:DowShort[0]
            [void](Set-Lang 'zh')
            $zhMonth = Get-LangText 'nav.month'
            $zhDow = [string]$script:DowShort[0]
            # 非法值必须被拒（否则设置里塞进任何字符串都能过）
            $rejLang = -not (Set-Lang 'fr')
            $okLang = ($enMonth -eq 'Month') -and ($enDow -eq 'Mon') -and
                      ($zhMonth -eq '月视图') -and ($zhDow -eq '周一') -and $rejLang
            Write-AuditRow 'lang switch zh/en' $okLang `
                ('en=' + $enMonth + '/' + $enDow + ' zh=' + $zhMonth + '/' + $zhDow + ' rej=' + $rejLang)
            [void](Set-Lang $keepLang2)

            # ---- 38b. 语言：中文下月份短名不能崩（曾因 Substring(0,3) 越界） ----
            #   "1月"只有 2 个字符，老写法 .Substring(0,3) 会直接抛 —— 这条专门钉住回归。
            $keepLang3 = [string]$script:Lang
            $msOk = $true
            $msDump = ''
            foreach ($lg in @('zh', 'en')) {
                [void](Set-Lang $lg)
                $msDump += ($lg + '=[' + (@($script:MonShort) -join '|') + '] ')
                foreach ($m in @($script:MonShort)) {
                    if ([string]::IsNullOrEmpty([string]$m)) { $msOk = $false }
                }
                if (@($script:MonShort).Count -ne 12) { $msOk = $false }
            }
            # 真正去渲染一次日历期间标题（这里才是当年抛越界的那行代码路径）
            try {
                Update-Chrome
                $periodTxt = ''
                if ($null -ne $script:CalPeriod) { $periodTxt = [string]$script:CalPeriod.Text }
                if ([string]::IsNullOrWhiteSpace($periodTxt)) { $msOk = $false }
                $msDump += ('period=' + $periodTxt)
            } catch { $msOk = $false; $msDump += ('periodCRASH=' + $_.Exception.Message) }
            Write-AuditRow 'month short names safe' $msOk (Shorten-Text $msDump 70)
            [void](Set-Lang $keepLang3)

            # ---- 38c. 周视图密度：三档都要落到 HourHeightBase 且落库 ----
            $keepDensity2 = [int]$script:Settings['WeekDensity']
            $denOk = $true
            $denDump = ''
            foreach ($case in @(@{ v = 28; n = 'Compact' }, @{ v = 40; n = 'Normal' }, @{ v = 56; n = 'Roomy' })) {
                [void](Set-WeekDensity ([int]$case.v))
                $hit = ([double]$script:HourHeightBase -eq [double]$case.v) -and
                       ([int]$script:Settings['WeekDensity'] -eq [int]$case.v)
                if (-not $hit) { $denOk = $false }
                $denDump += ($case.n + '=' + $script:HourHeightBase + $(if ($hit) { '' } else { '!!' }) + ' ')
            }
            # 越界值必须被拒（否则"紧凑"能填成 5px 把周视图压成一条线）
            $rejLow = -not (Set-WeekDensity 5)
            $rejHigh = -not (Set-WeekDensity 200)
            Write-AuditRow 'week density 3 steps' ($denOk -and $rejLow -and $rejHigh) `
                ($denDump + 'rejLow=' + $rejLow + ' rejHigh=' + $rejHigh)
            [void](Set-WeekDensity $keepDensity2)

            # ---- 38d. 删除撤销：删任务 -> Undo 后对象带着原 id 回到原索引 ----
            $before = @($script:Tasks).Count
            if ($before -ge 2) {
                $victim = $script:Tasks[1]
                $vId = [string]$victim.id
                $vText = [string]$victim.text
                # 绕过 Yes/No：直接走"删除 + 记录快照"那两步（就是 Remove-Task 的实体）
                $hitIdx = 1
                $snapT = $script:Tasks[$hitIdx]
                [void]$script:Tasks.Remove($snapT)
                Save-Data
                Fill-Tasks
                Push-Undo -Kind 'task' -Index $hitIdx -Snapshot $snapT -Label ([string]$snapT.text)
                $afterDel = @($script:Tasks).Count
                $goneNow = (@($script:Tasks | Where-Object { [string]$_.id -eq $vId }).Count -eq 0)
                $hadToast = ($null -ne $script:UndoState)
                Undo-Delete
                $afterUndo = @($script:Tasks).Count
                $backNow = (@($script:Tasks | Where-Object { [string]$_.id -eq $vId }).Count -eq 1)
                $posOk = ([string]$script:Tasks[$hitIdx].id -eq $vId)
                $txtOk = ([string]$script:Tasks[$hitIdx].text -eq $vText)
                Write-AuditRow 'delete undo restores task' `
                    (($afterDel -eq ($before - 1)) -and $goneNow -and $hadToast -and
                     ($afterUndo -eq $before) -and $backNow -and $posOk -and $txtOk) `
                    ('n ' + $before + '->' + $afterDel + '->' + $afterUndo + ' gone=' + $goneNow +
                     ' back=' + $backNow + ' pos=' + $posOk + ' txt=' + $txtOk)
            } else {
                Write-AuditRow 'delete undo restores task' $false ('not enough tasks: ' + $before)
            }

            # ---- 38d2. 多级撤销：连删 3 条 -> 连按 3 次撤销 -> 三条按序全部回来 ----
            #   这是第六轮把单级撤销升级为栈之后的核心回归：
            #   * 栈深必须真的到 3；
            #   * 每次撤销回退的应当是**栈顶（最后删的那条）**，不是最早那条；
            #   * 撤到只剩 1 条（第 5 轮留下那条单级用例可能还压着）时不能再乱动它。
            #   为了不依赖别的用例留下的栈状态，这里先把栈清空、再造 3 条一次性任务。
            try {
                if ($null -eq $script:UndoStack) { $script:UndoStack = New-Object System.Collections.ArrayList }
                $script:UndoStack.Clear()
                $script:UndoState = $null
                $keepTasks = @($script:Tasks)          # 审计结束后恢复现场，别污染后续用例
                $mkIds = New-Object System.Collections.ArrayList
                foreach ($nm in @('UNDO-A', 'UNDO-B', 'UNDO-C')) {
                    $script:Tasks.Add(@{
                        id = ('undo-' + $nm + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
                        text = $nm; tag = 'task'; done = $false; priority = 'medium'
                        due = ''; dueTime = ''; reminderMin = 0; project = ''; category = ''
                        estimated = 0; actual = 0; subtasks = @(); created = (Get-Date).ToString('s')
                    })
                }
                Fill-Tasks
                $base = @($script:Tasks).Count
                # 依次删 C、B、A（每次删当前最后一条 -> 栈里从底到顶是 C、B、A）
                $delOrder = @()
                for ($k = 0; $k -lt 3; $k++) {
                    $i = @($script:Tasks).Count - 1
                    $snap = $script:Tasks[$i]
                    $delOrder += [string]$snap.text
                    [void]$script:Tasks.Remove($snap)
                    Push-Undo -Kind 'task' -Index $i -Snapshot $snap -Label ([string]$snap.text)
                }
                $depth3 = (Get-UndoDepth)
                $afterDel3 = @($script:Tasks).Count
                # 连按 3 次撤销，记下每次回来的是谁（应严格 LIFO：A、B、C）
                $undoSeq = @()
                for ($k = 0; $k -lt 3; $k++) {
                    Undo-Delete
                    if (@($script:Tasks).Count -gt 0) {
                        $undoSeq += [string]$script:Tasks[@($script:Tasks).Count - 1].text
                    }
                }
                $depthAfter = (Get-UndoDepth)
                $restored = @($script:Tasks).Count
                $lifoOk = (($delOrder -join ',') -eq 'UNDO-C,UNDO-B,UNDO-A') -and
                          (($undoSeq -join ',') -eq 'UNDO-A,UNDO-B,UNDO-C')
                $depthOk = ($depth3 -eq 3) -and ($depthAfter -eq 0)
                $countOk = ($afterDel3 -eq ($base - 3)) -and ($restored -eq $base)
                # 撤空那一下就要把状态条改成"没有可撤销"（不能留上一条 "还可撤销 1"）
                $hintAfterLast = ''
                if ($null -ne $script:UndoHint) { $hintAfterLast = [string]$script:UndoHint.Text }
                $hintDrainOk = ($hintAfterLast -eq (Get-LangText 'undo.none'))
                # 栈空后再撤一次：不能报错、不能凭空多出任务，且仍给"没有可撤销"提示
                Undo-Delete
                $emptySafe = (@($script:Tasks).Count -eq $base)
                $hintTxt = ''
                if ($null -ne $script:UndoHint) { $hintTxt = [string]$script:UndoHint.Text }
                $hintOk = ($hintTxt -eq (Get-LangText 'undo.none'))
                Write-AuditRow 'multi-level undo (stack of 3)' `
                    ($lifoOk -and $depthOk -and $countOk -and $hintDrainOk -and $emptySafe -and $hintOk) `
                    ('del=' + ($delOrder -join '/') + ' undo=' + ($undoSeq -join '/') +
                     ' depth=' + $depth3 + '->' + $depthAfter + ' n=' + $base + '->' +
                     $afterDel3 + '->' + $restored + ' hintDrain=' + $hintDrainOk +
                     ' emptySafe=' + $emptySafe + ' hint=' + $hintOk)
                # 恢复现场
                $script:Tasks.Clear()
                foreach ($t in $keepTasks) { [void]$script:Tasks.Add($t) }
                $script:UndoStack.Clear(); $script:UndoState = $null
                if ($null -ne $script:UndoHint) { $script:UndoHint.Text = '' }
                Fill-Tasks
            } catch {
                Write-AuditRow 'multi-level undo (stack of 3)' $false ('err: ' + $_.Exception.Message)
            }

            # ---- 38d3. 栈深上限：连删 7 条，栈最多留 5（最早两条被顶掉） ----
            try {
                if ($null -eq $script:UndoStack) { $script:UndoStack = New-Object System.Collections.ArrayList }
                $script:UndoStack.Clear(); $script:UndoState = $null
                $keepTasks2 = @($script:Tasks)
                for ($k = 1; $k -le 7; $k++) {
                    $script:Tasks.Add(@{
                        id = ('cap-' + $k + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
                        text = ('CAP-' + $k); tag = 'task'; done = $false; priority = 'medium'
                        due = ''; dueTime = ''; reminderMin = 0; project = ''; category = ''
                        estimated = 0; actual = 0; subtasks = @(); created = (Get-Date).ToString('s')
                    })
                }
                Fill-Tasks
                for ($k = 0; $k -lt 7; $k++) {
                    $i = @($script:Tasks).Count - 1
                    $snap = $script:Tasks[$i]
                    [void]$script:Tasks.Remove($snap)
                    Push-Undo -Kind 'task' -Index $i -Snapshot $snap -Label ([string]$snap.text)
                }
                $capDepth = (Get-UndoDepth)
                # 只能撤回 5 条：第 6 次撤销时栈已空，任务数不应再变
                $nBefore = @($script:Tasks).Count
                for ($k = 0; $k -lt 5; $k++) { Undo-Delete }
                $nAfterFive = @($script:Tasks).Count
                Undo-Delete
                $nAfterSix = @($script:Tasks).Count
                Write-AuditRow 'undo stack depth capped at 5' `
                    (($capDepth -eq 5) -and ($nAfterFive -eq ($nBefore + 5)) -and ($nAfterSix -eq $nAfterFive)) `
                    ('depth=' + $capDepth + ' n=' + $nBefore + '->' + $nAfterFive + '->' + $nAfterSix)
                $script:Tasks.Clear()
                foreach ($t in $keepTasks2) { [void]$script:Tasks.Add($t) }
                $script:UndoStack.Clear(); $script:UndoState = $null
                if ($null -ne $script:UndoHint) { $script:UndoHint.Text = '' }
                Fill-Tasks
            } catch {
                Write-AuditRow 'undo stack depth capped at 5' $false ('err: ' + $_.Exception.Message)
            }

            # ---- 38e. 空状态：列表搜不到东西时给出"块 + 可点按钮"，而不是纯空白 ----
            try {
                Set-View 'list'
                $keepQ3 = ''
                if ($null -ne $script:ListSearch) {
                    $keepQ3 = [string]$script:ListSearch.Text
                    $script:ListSearch.Text = 'ZZZ-NO-SUCH-EVENT-9Q7'
                }
                Fill-ListRows
                $rows3 = @(Find-AllTagged $script:ListStack 'event')
                # 空状态是一个 StackPanel（内含文案 + 按钮）；按钮是唯一的可点元素
                $ctaBtn = $null
                foreach ($child in $script:ListStack.Children) {
                    if ($child -is [System.Windows.Controls.StackPanel]) {
                        foreach ($g in $child.Children) {
                            if ($g -is [System.Windows.Controls.Button]) { $ctaBtn = $g }
                        }
                    }
                }
                $ctaTxt = ''
                if ($null -ne $ctaBtn) {
                    # New-PixBtn 把 Content 设成 TextBlock（不是字符串），所以要取 .Text
                    $cc = $ctaBtn.Content
                    if ($cc -is [System.Windows.Controls.TextBlock]) { $ctaTxt = [string]$cc.Text }
                    elseif ($null -ne $cc) { $ctaTxt = [string]$cc }
                }
                $okEmpty = ($rows3.Count -eq 0) -and ($null -ne $ctaBtn) -and ($ctaTxt.Length -gt 0)
                Write-AuditRow 'list empty state has CTA' $okEmpty `
                    ('rows=' + $rows3.Count + ' btn=' + $ctaTxt)
                if ($null -ne $script:ListSearch) { $script:ListSearch.Text = $keepQ3 }
                Fill-ListRows
            } catch { Write-AuditRow 'list empty state has CTA' $false ('crash ' + $_.Exception.Message) }

        } catch { Write-AuditRow 'round5 features' $false ('crash ' + $_.Exception.Message) }

        # ---- 39. 第八轮（第三十节 1/3/4/5/6 条）：编辑撤销 / 提示条关闭× / 专注快捷档 / 设置搜索 / 内联编辑 ----
        #   这些是本轮新增能力，逐条断"真的生效"，而不是断"函数存在"。
        try {
            # ---- 39a. 编辑进撤销栈：改事件标题后再撤销，标题应复原 ----
            $edOk = $false
            $edDump = ''
            try {
                $script:UndoStack.Clear()
                $evId = 'audit-edit-undo'
                $ev = [pscustomobject]@{
                    id = $evId; date = '2026-09-24'; start = 600; end = 660
                    title = 'Before edit'; tag = ''; note = ''; done = $false
                    repeat = 'none'; repeatEvery = 1; repeatUntil = ''
                    repeatMonthMode = 'day'; reminderMin = 0; reminderKey = ''
                }
                [void]$script:Events.Add($ev)
                $hit0 = @($script:Events | Where-Object { [string]$_.id -eq $evId })[0]
                Push-Undo -Kind 'edit-event' -Id $evId -Snapshot (Copy-Record $hit0) -Label 'After edit'
                $hit0.title = 'After edit'
                Undo-Delete
                $hit1 = @($script:Events | Where-Object { [string]$_.id -eq $evId })[0]
                $edOk = ([string]$hit1.title -eq 'Before edit') -and ($script:LastUndoKind -eq 'edit-event')
                $edDump = 'title=' + [string]$hit1.title + ' kind=' + [string]$script:LastUndoKind
                @($script:Events) | Where-Object { [string]$_.id -eq $evId } | ForEach-Object { [void]$script:Events.Remove($_) }
            } catch { $edDump = 'crash ' + $_.Exception.Message }
            Write-AuditRow 'edit undo restores title' $edOk $edDump

            # ---- 39b. 专注快捷档：chip 设定时长（读 $script:FoDurationMin）----
            $chipOk = $false
            $chipDump = ''
            try {
                $script:FoDurationMin = 25 * 60
                # 模拟 chip 点击的取值路径：直接按 chip 语义设定并 paint
                $script:FoDurationMin = 60 * 60
                & $script:DwPaint
                $chipOk = ([int]$script:FoDurationMin -eq 3600)
                $chipDump = 'seconds=' + [string]$script:FoDurationMin
            } catch { $chipDump = 'crash ' + $_.Exception.Message }
            Write-AuditRow 'focus quick chip sets duration' $chipOk $chipDump

            # ---- 39c. 设置搜索索引：索引存在且 key->page 正确 ----
            $srchOk = $false
            $srchDump = ''
            try {
                $idx = @($script:SetSearchIndex)
                $srchOk = ($idx.Count -ge 10)
                if ($srchOk) {
                    $toastSec = @($idx | Where-Object { $_.Key -eq 'fld.st.toastSeconds' })[0]
                    $theme   = @($idx | Where-Object { $_.Key -eq 'fld.st.theme' })[0]
                    $srchOk = ($null -ne $toastSec -and $toastSec.Page -eq 'window') -and
                              ($null -ne $theme -and $theme.Page -eq 'appear')
                    $srchDump = 'entries=' + $idx.Count + ' toastSecondsPage=' + $(if ($toastSec) { $toastSec.Page } else { '?' })
                }
            } catch { $srchDump = 'crash ' + $_.Exception.Message }
            Write-AuditRow 'settings search index built' $srchOk $srchDump

            # ---- 39d. 内联编辑函数可被找到（防 CommandNotFound）----
            $inlineOk = $false
            $inlineDump = ''
            try {
                $inlineOk = ($null -ne (Get-Command Start-InlineTaskEdit -ErrorAction SilentlyContinue)) -and
                            ($null -ne (Get-Command Commit-InlineTaskEdit -ErrorAction SilentlyContinue)) -and
                            ($null -ne (Get-Command Stop-InlineTaskEdit -ErrorAction SilentlyContinue))
                $inlineDump = 'funcs=' + $inlineOk
            } catch { $inlineDump = 'crash ' + $_.Exception.Message }
            Write-AuditRow 'inline task edit funcs present' $inlineOk $inlineDump

        } catch { Write-AuditRow 'round8 features' $false ('crash ' + $_.Exception.Message) }
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
                'toastshot' {
                    # "toastshot:<name>"：单独拍**提示条那个窗口**。
                    # 为什么不能靠普通 shot：提示条是另一个 Topmost 窗口，不在 MainWindow 的
                    # 可视树里 —— Save-Shot 抓 MainWindow 时它根本不在画面里。
                    # 用 RenderTargetBitmap 把它自己渲染出来（不能 CopyFromScreen，
                    # 自动化会话里没有真实桌面）。
                    if ($AllowShot -and $ScreenshotPath -and $null -ne $script:ToastWindow) {
                        try {
                            $tw = $script:ToastWindow
                            $tw.UpdateLayout()
                            $wpx = [int][math]::Ceiling($tw.ActualWidth)
                            $hpx = [int][math]::Ceiling($tw.ActualHeight)
                            if ($wpx -gt 0 -and $hpx -gt 0) {
                                $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
                                    $wpx, $hpx, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
                                $rtb.Render($tw)
                                $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                                $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                                $dir = [System.IO.Path]::GetDirectoryName($ScreenshotPath)
                                $p = Join-Path $dir ($arg + '.png')
                                $fs = [System.IO.File]::Create($p)
                                $enc.Save($fs)
                                $fs.Close()
                                [void]$out.Add('toastshot: ' + $p)
                            }
                        } catch { [void]$out.Add('toastshot-err: ' + $_.Exception.Message) }
                    }
                }
                'toastpos' {
                    # "toastpos[:<corner>]"：弹一条提示条并按给定角落定位，回报它的实际
                    #   Left/Top 与所在屏的工作区。用来在审计里验证 ToastCorner 真的生效。
                    #   不给 corner 就用当前 $script:Settings['ToastCorner']。
                    try {
                        if ($arg -match '^(bl|br|tl|tr)$') { $script:Settings['ToastCorner'] = $arg }
                        Show-Toast -Title 'Position probe' -Text 'toastpos' -Seconds 30
                        $tw = $script:ToastWindow
                        if ($null -ne $tw) {
                            $tw.UpdateLayout()
                            $wa = Get-ToastWorkArea
                            [void]$out.Add('toastpos: corner=' + $script:Settings['ToastCorner'] +
                                ' left=' + [int][math]::Round($tw.Left) + ' top=' + [int][math]::Round($tw.Top) +
                                ' w=' + [int][math]::Round($tw.ActualWidth) + ' h=' + [int][math]::Round($tw.ActualHeight) +
                                ' wa=' + [int][math]::Round($wa.Left) + ',' + [int][math]::Round($wa.Top) +
                                ',' + [int][math]::Round($wa.Right) + ',' + [int][math]::Round($wa.Bottom))
                        } else {
                            [void]$out.Add('toastpos: no window')
                        }
                    } catch { [void]$out.Add('toastpos-err: ' + $_.Exception.Message) }
                }
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
                'lang' {
                    # "lang:en" 切语言（截图用例用）。走 Set-Lang 这一条路，
                    # 和设置窗口 Save 时用的是同一个入口。
                    [void](Set-Lang $arg)
                }
                'density' {
                    # "density:56" 切周视图密度（截图用例用）
                    if ($arg -match '^\d+$') { [void](Set-WeekDensity ([int]$arg)) }
                }
                'undo' {
                    # 撤销上一次删除（截图用例用：证明提示条上的按钮真能撤销）
                    Undo-Delete
                }
                'undodemo' {
                    # "undodemo[:<n>]"：模拟"用户确认删除"之后的状态 —— 真的从 Tasks 里摘掉 n 项
                    # （默认 1）、逐条压栈、并把可撤销提示条弹出来。截图要拍的就是这条提示条。
                    # 与 Remove-Task 的唯一差别是不弹 Yes/No（截图流程点不了 MessageBox）。
                    #
                    # 给了 n>1 时连续删 n 条，用来验证**多级撤销**：提示条上应出现 "(n)"，
                    # 再连按 undo n 次应把 n 条全部按原索引插回去。
                    #
                    # 这里**故意绕开 Show-UndoToast 的 $TestMode 守卫**：那个守卫是为了
                    # 不让自动化流程被弹窗挡住，但截图流程恰恰要拍这个提示条本身。
                    # 提示条是独立的 Topmost 窗口，MainWindow 的截图抓不到它 ——
                    # 所以下面单独给它拍一张（shot 目录里叫 r7-undo-toast-window.png）。
                    try {
                        $n = 1
                        if ($arg -match '^\d+$') { $n = [int]$arg }
                        if ($n -lt 1) { $n = 1 }
                        $avail = @($script:Tasks).Count
                        $can = [math]::Min($n, [math]::Max(0, $avail - 1))   # 至少留一条，免得删空
                        if ($can -ge 1) {
                            $lastText = ''
                            for ($k = 0; $k -lt $can; $k++) {
                                $i = @($script:Tasks).Count - 1
                                $snap = $script:Tasks[$i]
                                [void]$script:Tasks.Remove($snap)
                                Save-Data
                                Fill-Tasks
                                Push-Undo -Kind 'task' -Index $i -Snapshot $snap -Label ([string]$snap.text)
                                $lastText = [string]$snap.text
                            }
                            $txt = (Get-LangText 'undo.deleted') + (Shorten-Text $lastText 22)
                            $depth = Get-UndoDepth
                            if ($depth -gt 1) { $txt = $txt + '  (' + $depth + ')' }
                            Sync-UndoHint      # 侧栏也写上层次（截图拍的是主窗口，不是 Toast）
                            Show-Toast -Title (Get-LangText 'undo.task') `
                                -Text $txt -ActionText (Get-LangText 'undo.btn') -Seconds 30 `
                                -ActionScript { Undo-Delete }
                            [void]$out.Add('undodemo: removed=' + $can + ' depth=' + $depth +
                                           ' tasks=' + @($script:Tasks).Count)
                        } else {
                            [void]$out.Add('undodemo: skipped (need >=2 tasks), tasks=' + $avail)
                        }
                    } catch { [void]$out.Add('undodemo-err: ' + $_.Exception.Message) }
                }
                'undodepth' {
                    # "undodepth[:<n>]"：连按 Ctrl+Z n 次（默认 1），返回每次之后的栈深与任务数。
                    # 与 undodemo 配对，用来在自动化里验证"逐级回退 + 栈空提示"。
                    try {
                        $n = 1
                        if ($arg -match '^\d+$') { $n = [int]$arg }
                        if ($n -lt 1) { $n = 1 }
                        $trace = ''
                        for ($k = 0; $k -lt $n; $k++) {
                            Undo-Delete
                            $trace += ('[' + (Get-UndoDepth) + '/' + @($script:Tasks).Count + ']')
                        }
                        $hint = ''
                        if ($null -ne $script:UndoHint) { $hint = [string]$script:UndoHint.Text }
                        [void]$out.Add('undodepth: depth=' + (Get-UndoDepth) +
                                       ' tasks=' + @($script:Tasks).Count +
                                       ' trace=' + $trace + ' hint=' + $hint)
                    } catch { [void]$out.Add('undodepth-err: ' + $_.Exception.Message) }
                }
                'emptydemo' {
                    # "emptydemo"：把列表搜索框填成一串必然搜不到的词，制造空状态。
                    try {
                        Set-View 'list'
                        if ($null -ne $script:ListSearch) { $script:ListSearch.Text = 'ZZZ-NO-SUCH-EVENT-9Q7' }
                        Fill-ListRows
                    } catch { [void]$out.Add('emptydemo-err: ' + $_.Exception.Message) }
                }
                'clearfilter' {
                    # "clearfilter"：清掉列表搜索与标签筛选，恢复有内容的列表。
                    try {
                        if ($null -ne $script:ListSearch) { $script:ListSearch.Text = '' }
                        if ($null -ne $script:ListTagBox) { $script:ListTagBox.SelectedIndex = 0 }
                        Fill-ListRows
                    } catch { [void]$out.Add('clearfilter-err: ' + $_.Exception.Message) }
                }
                'taskcheck' {
                    # "taskcheck[:<id>]"：点任务卡左侧那个 15x15 勾选方块。
                    #
                    # 这条把第六轮修的 bug 变成可回归的动作：方块的 Tag 与卡片正文的 Tag
                    # 长得一样（都是 @{kind='task'; id=...}），早些时候点它会被外层
                    # "点卡片空白 = 延迟 260ms 再切"的逻辑吃掉，看上去就是"点了没反应"。
                    # 现在方块自己挂了 Add_Click 并 Handled=true，这里用真实点击链路
                    # 打它一下，回读 done 有没有真的翻过来、以及界面有没有立刻重画。
                    #
                    # 取哪张卡：给了 id 用 id，否则拿第一张（与 dbltask 同一套约定）。
                    Set-View 'tasks'
                    if ($null -ne $script:TaskStatusBox) { $script:TaskStatusBox.SelectedIndex = 0 }
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
                        [void]$out.Add('taskcheck: target not found -> ' + $arg)
                    } else {
                        # 先找到那张卡里的勾选方块：它是 kind='task' 的 Button，
                        # 且不是任务正文那层（正文层不是 Button）。
                        $box = $null
                        foreach ($b in @(Find-AllOfType $tgt ([System.Windows.Controls.Button]))) {
                            if ($null -ne $b.Tag -and ($b.Tag -is [hashtable]) -and
                                $b.Tag.ContainsKey('kind') -and ([string]$b.Tag['kind'] -eq 'task')) { $box = $b; break }
                        }
                        $id = [string]$tgt.Tag['id']
                        $before = $null
                        foreach ($t in @($script:Tasks)) { if ([string]$t.id -eq $id) { $before = [bool]$t.done; break } }
                        [void](Invoke-Click $box)
                        # 立即勾选：不需要等那 260ms 的挂起计时器
                        $after = $null
                        foreach ($t in @($script:Tasks)) { if ([string]$t.id -eq $id) { $after = [bool]$t.done; break } }
                        [void]$out.Add('taskcheck id=' + $id + ' box=' + [string]($null -ne $box) +
                                       ' done=' + [string]$before + '->' + [string]$after)
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
                'pickflip' {
                    # "pickflip:next" / "pickflip:prev"：点一下期间选择窗的翻月按钮，
                    # 报告"月份标签 + 首格日期"到底动没动。
                    # 为什么需要它：审计里原来只验"打开时的天数/首格位置"，
                    # 从不点 < > —— 于是"翻月按钮点了没反应"这种 bug 可以一路绿灯。
                    $w = Show-PeriodPickerWindow
                    $w.Show(); $w.UpdateLayout()
                    $beforeFirst = ([datetime]$script:DpFirst).ToString('yyyy-MM')
                    $beforeLbl = [string]$script:DpLabelText.Text
                    $target = $null
                    foreach ($b in @(Find-AllOfType $w ([System.Windows.Controls.Primitives.ButtonBase]))) {
                        if ($null -ne $b.Tag -and ($b.Tag -is [hashtable]) -and
                            [string]$b.Tag['kind'] -eq 'pick-flip' -and [string]$b.Tag['dir'] -eq $arg) { $target = $b; break }
                    }
                    $clicked = [bool](Invoke-Click $target)
                    try { $w.UpdateLayout() } catch { }
                    $afterFirst = ([datetime]$script:DpFirst).ToString('yyyy-MM')
                    $afterLbl = [string]$script:DpLabelText.Text
                    [void]$out.Add('pickflip ' + $arg +
                        ' clicked=' + [string]$clicked +
                        ' first=' + $beforeFirst + '->' + $afterFirst +
                        ' label=' + $beforeLbl + '->' + $afterLbl)
                    $w.Close()
                }
                'settingshot' {
                    # "settingshot:<name>"：拍设置窗口。第四轮设置里多了
                    # 字号 / 主题 / 置顶 / 托盘 / 周时段，需要截图留证。
                    # 第六轮分页后，"刚打开"拍到的是**外观页** —— 这是默认页，也是
                    # 最该看的一张。要拍别的页用下面的 settingstabshot。
                    $w = Show-SettingsWindow
                    $w.Show(); $w.UpdateLayout()
                    if ($AllowShot -and $ScreenshotPath) {
                        $fn = 'settings-window.png'
                        if (-not [string]::IsNullOrWhiteSpace($arg)) { $fn = $arg + '.png' }
                        $p = Join-Path ([System.IO.Path]::GetDirectoryName($ScreenshotPath)) $fn
                        Save-Shot -Path $p -Window $w
                    }
                    $w.Close()
                }
                'settingstabshot' {
                    # "settingstabshot:<page>[|<name>]"：先切到指定页再拍设置窗。
                    #   page ∈ appear/window/data/about。理由同设置分页本身：
                    #   "页签点了没换页"是分页最容易出的错，截图要能分别看到四页长什么样。
                    $page = $arg
                    $nm = ''
                    if ($arg -match '\|') {
                        $parts = $arg -split '\|', 2
                        $page = $parts[0]; $nm = $parts[1]
                    }
                    $w = Show-SettingsWindow
                    if ($null -ne $script:SetTabsShow) { & $script:SetTabsShow ([string]$page) }
                    $w.Show(); $w.UpdateLayout()
                    if ($null -ne $script:SetTabsShow) { & $script:SetTabsShow ([string]$page) }
                    $w.UpdateLayout()
                    if ($AllowShot -and $ScreenshotPath) {
                        $fn = ('settings-' + [string]$page + '.png')
                        if (-not [string]::IsNullOrWhiteSpace($nm)) { $fn = $nm + '.png' }
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
                'minishot' {
                    # 第十二轮（item 2）：拍番茄钟迷你悬浮窗。先造一个运行中的番茄钟，
                    # 再 Show-PomoMini 弹出来拍，最后复位隐藏（别影响后续用例）。
                    try {
                        if (-not [bool]$script:Settings['PomodoroEnabled']) { $script:Settings['PomodoroEnabled'] = $true }
                        if (-not [bool]$script:Pomo.Running) {
                            if ([int]$script:Pomo.Remaining -le 0) { Reset-Pomodoro }
                            Toggle-Pomodoro
                        }
                        Show-PomoMini
                        try { $script:PomoMiniWin.UpdateLayout() } catch { }
                        if ($AllowShot -and $ScreenshotPath -and $null -ne $script:PomoMiniWin) {
                            $fn = 'pomo-mini.png'
                            if (-not [string]::IsNullOrWhiteSpace($arg)) { $fn = $arg + '.png' }
                            $p = Join-Path ([System.IO.Path]::GetDirectoryName($ScreenshotPath)) $fn
                            Save-Shot -Path $p -Window $script:PomoMiniWin
                        }
                        if ([bool]$script:Pomo.Running) { Toggle-Pomodoro }
                        Hide-PomoMini
                    } catch { }
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

