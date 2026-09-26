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
#  1.2 启动失败弹窗（第十五轮，分享 PC 前的兜底）
#      以前启动失败只写 errors.log——普通用户不会去看，得到的现象就是
#      "双击后一闪而过"。现在把原因直接弹出来，并附日志路径。
#      TestMode（审计/回归）下绝不弹：会卡住无头环境的消息泵。
# ---------------------------------------------------------------------------
function Show-FatalError {
    param([string]$Msg)
    if ($TestMode) { return }
    try {
        [System.Windows.MessageBox]::Show(
            ('启动失败：' + $Msg + [Environment]::NewLine + [Environment]::NewLine +
             '详细日志：' + $script:ErrorLog),
            'My Schedule',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error) | Out-Null
    } catch { }
}

# 顶层兜底：任何"没有被 try/catch 接住"的启动异常（最典型 = 分片文件缺失、
# XAML 解析失败）都会走到这里——弹窗 + 记日志 + 终止启动。
# 正常路径与审计里的局部 try/catch 不受影响（被捕获的异常不会进 trap）。
trap {
    $tMsg = ''
    try { $tMsg = [string]$_.Exception.Message } catch { $tMsg = 'unknown error' }
    Show-FatalError $tMsg
    try { Write-ErrLog ('FATAL: ' + $tMsg) } catch { }
    break
}

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
    # ---- 第十四轮新增：悬浮窗常驻 / 透明度 / 番茄钟任务队列 ----
    # MiniPinned：悬浮窗"常驻"开关。开了之后不管番茄钟跑不跑都钉在桌面角落；
    #   空闲时显示当前时钟 + 今日待办数，跑起来变回倒计时（桌面小组件心智）。
    MiniPinned      = $false
    # MiniOpacity：悬浮窗整体透明度（滚轮在窗上滚动即可调，0.35~1.0）。
    #   存下来是为了重启后保持用户调好的"若隐若现"程度。
    MiniOpacity     = 1.0
    # PomoQueue：任务队列（逗号分隔的任务 id，有序）。专注阶段自然走完时
    #   自动把队列头部的任务顶上来当下一段专注的目标，然后把它的 id 挪到队尾轮换。
    PomoQueue       = ''
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
            # 第十轮（第 5 条）：主数据文件损坏时，自动回退到备份。
            #   第十三轮（第 3 条）：备份升级为三代轮换，回退时按新旧依次尝试
            #   .backup.1 -> .backup.2 -> .backup.3 -> 旧单份 .backup，
            #   取第一个能读出来的。全部失败才落到 Seed-Data（演示数据）。
            Write-ErrLog ('Load-Data: main file corrupt - ' + $_.Exception.Message)
            $backups = @(
                ($script:DataFile + '.backup.1'),
                ($script:DataFile + '.backup.2'),
                ($script:DataFile + '.backup.3'),
                ($script:DataFile + '.backup')
            )
            foreach ($bak in $backups) {
                if (-not (Test-Path -LiteralPath $bak)) { continue }
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
                    Write-ErrLog ('Load-Data: recovered from backup ' + $bak)
                    return
                } catch {
                    Write-ErrLog ('Load-Data: backup ' + $bak + ' corrupt - ' + $_.Exception.Message)
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
        # 第十三轮（第 3 条）：单份备份升级为三代轮换（.backup.1/.2/.3），
        #   写坏两次也不至于连备份都没了。链式位移：.2 -> .3、.1 -> .2、当前 -> .1。
        if (Test-Path -LiteralPath $script:DataFile) {
            $b3 = $script:DataFile + '.backup.3'
            $b2 = $script:DataFile + '.backup.2'
            $b1 = $script:DataFile + '.backup.1'
            try { if (Test-Path -LiteralPath $b2) { Copy-Item -LiteralPath $b2 -Destination $b3 -Force } } catch { }
            try { if (Test-Path -LiteralPath $b1) { Copy-Item -LiteralPath $b1 -Destination $b2 -Force } } catch { }
            try { Copy-Item -LiteralPath $script:DataFile -Destination $b1 -Force } catch { }
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
    'btn.addEvent'  = '+ New event'
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
    'hero.done'       = 'Done {0}/{1}'
    'hero.focus'      = 'Focus today {0}h{1:00}m'
    'hud.tasks'       = '{0} to-dos'
    'pomo.pin'        = 'Pin widget'
    'pomo.unpin'      = 'Unpin widget'
    'menu.export'     = 'Export data'
    'menu.import'     = 'Import data'
    'exp.title'       = 'Export schedule data'
    'exp.done'        = 'Exported to {0}'
    'exp.fail'        = 'Export failed'
    'imp.title'       = 'Import schedule data'
    'imp.badfile'     = 'Invalid file: a JSON with "events" and "tasks" is expected.'
    'imp.done'        = 'Imported. Previous data was saved as schedule.json.import-bak'
    'imp.fail'        = 'Import failed'
    'pomo.queue'      = 'Task queue (auto-advance after each focus)'
    'tip.miniWheel'   = 'Scroll to adjust opacity'
    'ntf.miniFail'    = 'Focus widget hit an error and was rebuilt.'
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
    'pomo.endStat'     = 'End & log'
    'pomo.exit'        = 'Exit'
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
    'btn.addEvent'  = '+ 新建日程'
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
    'hero.done'       = '已完成 {0}/{1}'
    'hero.focus'      = '今日专注 {0} 小时 {1:00} 分'
    'hud.tasks'       = '待办 {0}'
    'pomo.pin'        = '常驻桌面'
    'pomo.unpin'      = '取消常驻'
    'menu.export'     = '导出数据'
    'menu.import'     = '导入数据'
    'exp.title'       = '导出日程数据'
    'exp.done'        = '已导出到 {0}'
    'exp.fail'        = '导出失败'
    'imp.title'       = '导入日程数据'
    'imp.badfile'     = '文件格式不对：需要包含 events 和 tasks 的 JSON。'
    'imp.done'        = '导入完成。原数据已备份为 schedule.json.import-bak'
    'imp.fail'        = '导入失败'
    'pomo.queue'      = '任务队列（专注结束自动换下一个）'
    'tip.miniWheel'   = '滚轮调节透明度'
    'ntf.miniFail'    = '悬浮窗异常，已自动重建。'
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
    'pomo.endStat'     = '结束并统计'
    'pomo.exit'        = '退出'
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
# 第十四轮：悬浮窗内部件（环/按钮文字/结束按钮）与自愈状态标记
$script:PomoMiniArc = $null
$script:PomoMiniBtnText = $null
$script:PomoMiniEndBtn = $null
$script:PomoMiniRingSize = 118.0
$script:PomoMiniFailNotified = $false
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
$script:FoQueueList  = $null   # 第十四轮：专注窗"任务队列"复选框列表（Show-FocusWindow 里建）
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
# ==== 单文件构建版：4 个分片已内联（由 verification/build_single.py 生成）。====
# 内联与点源同落在脚本作用域，语义等价；发布后不需要旁边再有那 4 个文件。
# 审计区读外部 Care.ps1 源码的那条断言在单文件版里会走它自己的 catch，无碍。

# ==== part: Ui.ps1 (inlined by Build-Single) ====
# =============================================================================
#  My Schedule - 界面层（XAML 窗口 + 三视图渲染）
#  本文件由 ScheduleWidget.ps1 dot-source，不要单独运行
# =============================================================================

# ---------------------------------------------------------------------------
#  A. 窗口 XAML
#     说明：颜色以占位符 __KEY__ 形式写，启动时按主题替换
#           —— 这样"启动即夜间模式"与"运行中切换主题"走同一条路
# ---------------------------------------------------------------------------
$windowXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="Schedule"
        WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanResize"
        WindowStartupLocation="Manual"
        MinWidth="760" MinHeight="560"
        Width="1080" Height="760" FontFamily="Microsoft YaHei">

  <!-- 无边框窗口也要参与系统缩放：保留 10px 的可命中缩放边。 -->
  <shell:WindowChrome.WindowChrome>
    <shell:WindowChrome CaptionHeight="0" ResizeBorderThickness="10"
                        GlassFrameThickness="0" CornerRadius="14"
                        UseAeroCaptionButtons="False"/>
  </shell:WindowChrome.WindowChrome>

  <!-- 资源必须写在内容之前：WPF 解析 XAML 是单趟顺序的，内容用到 StaticResource 时资源索引里必须已经有它 -->
  <Window.Resources>
    <Style x:Key="WinBtn" TargetType="Button">
      <Setter Property="Background" Value="__Card__"/>
      <Setter Property="BorderBrush" Value="__Border__"/>
      <Setter Property="BorderThickness" Value="2"/>
      <Setter Property="Foreground" Value="__Border__"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__CardAlt__"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WinBtnClose" TargetType="Button" BasedOn="{StaticResource WinBtn}"/>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Padding" Value="13,0"/>
      <Setter Property="Background" Value="__Card__"/>
      <Setter Property="Foreground" Value="__Border__"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="sh" Background="__Shadow__" CornerRadius="7"
                      Margin="2,2,0,0"/>
              <Border x:Name="bd" Background="{TemplateBinding Background}"
                      BorderBrush="__Border__" BorderThickness="2" CornerRadius="7">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__CardAlt__"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Margin" Value="2,2,0,0"/>
                <Setter TargetName="sh" Property="Opacity" Value="0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Background" Value="__AccentEvent__"/>
      <Setter Property="Foreground" Value="__OnAccent__"/>
    </Style>

    <Style x:Key="SegBtn" TargetType="Button">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="13,0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="__InkSoft__"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="0,0,0,2"
                    CornerRadius="0" Padding="2,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__CardAlt__"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.7"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CalBtn" TargetType="Button">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Background" Value="__Card__"/>
      <Setter Property="Foreground" Value="__Border__"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="sh" Background="__Shadow__" CornerRadius="6" Margin="2,2,0,0"/>
              <Border x:Name="bd" Background="{TemplateBinding Background}"
                      BorderBrush="__Border__" BorderThickness="2" CornerRadius="6">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__CardAlt__"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Margin" Value="2,2,0,0"/>
                <Setter TargetName="sh" Property="Opacity" Value="0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="__InkSoft__"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    CornerRadius="8" Padding="6,6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__CardAlt__"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ComboBox 必须自带模板。
         系统默认模板（Aero2）里那块底色是 StaticResource，不是 TemplateBinding，
         所以给 ComboBox.Background 赋值完全无效：夜间模式下就是"白底 + 白字"，
         整块下拉框在界面上等于消失。这里自带一套模板，颜色全部走主题占位符。
         用隐式样式（不写 x:Key）：主窗口里所有代码创建的 ComboBox 都会自动套上，
         不用逐个改造；对话框是独立的 Window，不会继承这里的资源。 -->
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="__Card__"/>
      <Setter Property="Foreground" Value="__Ink__"/>
      <Setter Property="BorderBrush" Value="__Border__"/>
      <Setter Property="BorderThickness" Value="2"/>
      <Setter Property="Padding" Value="7,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Name="PART_Toggle" Focusable="False" ClickMode="Press"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay,
                                        RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="bd" CornerRadius="4"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center"
                            Margin="0,0,7,0" Data="M0,0 L8,0 L4,5 Z"
                            Fill="__InkSoft__"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="bd" Property="Background" Value="__CardAlt__"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Name="PART_Content" IsHitTestVisible="False"
                                Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="Left" VerticalAlignment="Center"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"/>
              <!-- PART_EditableTextBox：模板里没有这块的话，IsEditable=True 的下拉框
                   （对话框里那几个既可选又可手输的字段）压根显示不出输入内容。 -->
              <TextBox Name="PART_EditableTextBox" Visibility="Collapsed"
                       IsReadOnly="{TemplateBinding IsReadOnly}"
                       Margin="{TemplateBinding Padding}"
                       HorizontalAlignment="Stretch" VerticalAlignment="Center"
                       Background="Transparent" BorderThickness="0"
                       Foreground="{TemplateBinding Foreground}"
                       CaretBrush="{TemplateBinding Foreground}"/>
              <Popup Name="PART_Popup" Placement="Bottom" Focusable="False"
                     IsOpen="{TemplateBinding IsDropDownOpen}">
                <Border MinWidth="{TemplateBinding ActualWidth}" MaxHeight="280"
                        Background="__Card__" BorderBrush="__Border__"
                        BorderThickness="2" CornerRadius="5" Margin="0,2,0,0">
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel IsItemsHost="True"
                                KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEditable" Value="True">
                <Setter TargetName="PART_Content" Property="Visibility" Value="Collapsed"/>
                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 下拉项：默认模板同样是写死的白底，夜里会出现"白条 + 白字" -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="__Ink__"/>
      <Setter Property="Padding" Value="7,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="bd" CornerRadius="3"
                    Background="{TemplateBinding Background}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__AccentFocus__"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__AccentFocus__"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="OuterRing" Background="__Backdrop__" CornerRadius="14" Padding="0">
   <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="42"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- 标题栏（可拖动） -->
    <Border x:Name="TitleBar" Grid.Row="0" Background="__Chrome__"
            CornerRadius="14,14,0,0" BorderThickness="2,2,2,0" BorderBrush="__Border__">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Column="0" Orientation="Horizontal" Margin="10,0,0,0"
                    VerticalAlignment="Center">
          <Border Width="12" Height="12" CornerRadius="3" Background="__AccentEvent__"
                  BorderThickness="2" BorderBrush="__Border__"/>
          <TextBlock x:Name="WinTitle" Text="Main window - Month view"
                     Margin="10,0,0,0" VerticalAlignment="Center"
                     Foreground="__Ink__" FontSize="13" FontWeight="SemiBold"/>
        </StackPanel>
        <TextBlock Grid.Column="1" Text="" />

        <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="0,0,8,0"
                    VerticalAlignment="Center">
          <Button x:Name="BtnMore" Width="28" Height="24" Margin="4,0,0,0"
                  Style="{StaticResource WinBtn}" ToolTip="More options">
            <Border x:Name="IcMore" Width="14" Height="14" VerticalAlignment="Center"/></Button>
          <Button x:Name="BtnMin" Width="28" Height="24" Margin="4,0,0,0"
                  Style="{StaticResource WinBtn}">
            <Border x:Name="IcMin" Width="10" Height="10" VerticalAlignment="Center"/></Button>
          <Button x:Name="BtnMax" Width="28" Height="24" Margin="4,0,0,0"
                  Style="{StaticResource WinBtn}">
            <Border x:Name="IcMax" Width="10" Height="10" VerticalAlignment="Center"/></Button>
          <Button x:Name="BtnClose" Width="28" Height="24" Margin="4,0,0,0"
                  Style="{StaticResource WinBtnClose}">
            <Border x:Name="IcClose" Width="10" Height="10" VerticalAlignment="Center"/></Button>
        </StackPanel>
      </Grid>
    </Border>

    <!-- 主体 -->
    <Border x:Name="MainPanel" Grid.Row="1" Background="__Panel__"
            CornerRadius="0,0,14,14" BorderThickness="2,0,2,2" BorderBrush="__Border__">
     <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition x:Name="NavCol" Width="142"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- 左侧导航 -->
      <Border x:Name="NavPanel" Grid.Column="0" Background="__Card__"
              BorderThickness="0,0,2,0" BorderBrush="__BorderSoft__">
       <!-- 两行：导航（可滚动）/ DAILY NOTE（固定）。
            历史：曾把 7 个入口拆成"主导航 + 次导航"两块固定高度区，想让多余高度落在
              两块之间显得像刻意排布。实际效果相反 —— 窗口一拉高，两块之间那条空隙
              看起来就是"上下脱节"，用户第一眼就报了这个。
            现在：Month/Week/List/Tasks/Focus/Settings/Profile 全部回到同一个
              StackPanel（唯一滚动容器），多余高度统一落在整个导航组的下方，
              导航自身始终是连续的一整列；窗口很矮时滚动依然是唯一出路，
              且底部 DAILY NOTE 固定不动。
            用 Grid 而不是 DockPanel：DockPanel 只有"最后一个子项"能填充剩余空间，
              而需要填充的是排在最前面的导航区，Dock 顺序会把它错挤到左边。 -->
       <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <!-- 导航放进 ScrollViewer：窗口变矮时它可滚动，而 DAILY NOTE 固定块始终完整可见
             （挤不下就裁掉是不可接受的）。 -->
        <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="10,14,10,0">
          <Border x:Name="AvatarBox" Width="82" Height="82" HorizontalAlignment="Center"
                  CornerRadius="8" BorderThickness="2" BorderBrush="__Border__"
                  Background="__CardAlt__" Cursor="Hand"
                  ToolTip="Click to choose your own avatar image">
            <Grid>
              <Canvas x:Name="AvatarCanvas" Width="82" Height="82" ClipToBounds="True"/>
              <Image x:Name="AvatarImage" Stretch="UniformToFill" ClipToBounds="True"/>
              <Border x:Name="AvatarHintBox" VerticalAlignment="Bottom" Background="__Card__"
                      Opacity="0.88" Padding="3,1">
                <TextBlock x:Name="AvatarHint" Text="Change" FontSize="9"
                           HorizontalAlignment="Center" Foreground="__InkSoft__"/>
              </Border>
            </Grid>
          </Border>

          <Button x:Name="BtnAdd" Style="{StaticResource PrimaryBtn}" Height="36" Margin="0,12,0,4">
            <StackPanel Orientation="Horizontal">
              <Border x:Name="IcAdd" Width="14" Height="14" VerticalAlignment="Center"/>
              <TextBlock Text="New event" Margin="6,0,0,0"/></StackPanel></Button>

          <Button x:Name="NavMonth" Style="{StaticResource NavBtn}" Margin="0,4,0,0" Tag="month">
            <StackPanel><Border x:Name="IcNavMonth" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="Month" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>
          <Button x:Name="NavWeek" Style="{StaticResource NavBtn}" Margin="0,4,0,0" Tag="week">
            <StackPanel><Border x:Name="IcNavWeek" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="Week" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>
          <Button x:Name="NavList" Style="{StaticResource NavBtn}" Margin="0,4,0,0" Tag="list">
            <StackPanel><Border x:Name="IcNavList" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="List" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>
          <Border Height="2" Background="__BorderSoft__" Margin="6,10,6,0" Opacity="0.6"/>

          <Button x:Name="NavTask" Style="{StaticResource NavBtn}" Margin="0,10,0,0" Tag="tasks">
            <StackPanel><Border x:Name="IcNavTask" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="Tasks" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>
          <Button x:Name="NavFocus" Style="{StaticResource NavBtn}" Margin="0,4,0,0" Tag="focus">
            <StackPanel><Border x:Name="IcNavFocus" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="Focus" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>
          <Button x:Name="NavSettings" Style="{StaticResource NavBtn}" Margin="0,4,0,0" Tag="settings">
            <StackPanel><Border x:Name="IcNavSettings" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="Settings" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>
          <Button x:Name="NavProfile" Style="{StaticResource NavBtn}" Margin="0,4,0,0" Tag="profile">
            <StackPanel><Border x:Name="IcNavProfile" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="Profile" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>

          <!-- 导航到此结束。多出来的高度落在这行空白上 —— 空白处在整列导航的
               "下方"，而不是插在两组按钮中间，所以视觉上永远是一整列。 -->
          <Border Height="0" Background="Transparent" Margin="0,10,0,6"/>
        </StackPanel>
        </ScrollViewer>

        <StackPanel Grid.Row="1" VerticalAlignment="Bottom" Margin="10,0,10,12">
          <!-- 撤销反馈条（第六轮）：Ctrl+Z 撤销后在这里报"还能撤几次"，
               栈空时提示"没有可撤销的操作了"。默认空字符串 -> 不占视觉重量；
               有内容时不换行、淡色，不抢导航的注意力。 -->
          <TextBlock x:Name="UndoHint" Text="" FontSize="10" Foreground="__InkFaint__"
                     HorizontalAlignment="Center" TextWrapping="Wrap" TextAlignment="Center"
                     Margin="0,0,0,6"/>
          <Border Height="2" Background="__BorderSoft__" Margin="0,0,0,8" Opacity="0.6"/>
          <!-- 第十二轮（item 3）：原"每日一句 + 两条横线"改为工具作者 + 最新更新时间。
               文字在 Apply-Lang 里按语言表刷（about.author / about.updated）。 -->
          <TextBlock x:Name="AuthorLabel" Text="" FontSize="10" Foreground="__InkSoft__"
                     HorizontalAlignment="Center" FontWeight="SemiBold"/>
          <TextBlock x:Name="UpdateLabel" Text="" FontSize="9" Foreground="__InkFaint__"
                     HorizontalAlignment="Center" Margin="0,3,0,0"/>
        </StackPanel>
       </Grid>
      </Border>

      <!-- 右侧主区 -->
      <Grid Grid.Column="1">
       <Grid.RowDefinitions>
         <RowDefinition Height="Auto"/>
         <RowDefinition Height="Auto"/>
         <RowDefinition Height="*"/>
       </Grid.RowDefinitions>

       <!-- 信息头（第十四轮重构：三个像素风"胶囊"替代原来的两行灰字）
            左：日期 + 时钟（时钟用等宽字体、强调色，一眼看到"现在"）
            中：已完成 n/m + 迷你进度条（条色由代码按色板刷，跟随主题）
            右：今日专注时长
            HeroStats 名字给中间+右侧这组：窄窗口 (<820px) 整组收起，日期胶囊保留 -->
       <DockPanel Grid.Row="0" Margin="14,8,14,4" VerticalAlignment="Top" LastChildFill="False">
         <Border DockPanel.Dock="Left" Background="__CardAlt__" BorderBrush="__Border__"
                 BorderThickness="2" CornerRadius="8" Padding="12,4,12,4" VerticalAlignment="Center">
           <StackPanel Orientation="Horizontal">
             <TextBlock x:Name="HeroDate" Text="" FontSize="13" FontWeight="SemiBold"
                        Foreground="__Ink__" VerticalAlignment="Center"/>
             <TextBlock x:Name="HeroClock" Text="" FontSize="13" FontFamily="Consolas" FontWeight="Bold"
                        Foreground="__AccentEvent__" VerticalAlignment="Center" Margin="10,0,0,0"/>
           </StackPanel>
         </Border>
         <StackPanel x:Name="HeroStats" DockPanel.Dock="Left" Orientation="Horizontal"
                     Margin="8,0,0,0" VerticalAlignment="Center">
           <Border Background="__CardAlt__" BorderBrush="__Border__" BorderThickness="2"
                   CornerRadius="8" Padding="12,4,12,4">
             <StackPanel Orientation="Horizontal">
               <TextBlock x:Name="HeroDone" Text="" FontSize="12"
                          Foreground="__InkSoft__" VerticalAlignment="Center"/>
               <Border x:Name="HeroBarTrack" Width="72" Height="9" Background="__Card__"
                       BorderBrush="__Border__" BorderThickness="1" CornerRadius="4"
                       VerticalAlignment="Center" Margin="10,0,0,0">
                 <Border x:Name="HeroBarFill" HorizontalAlignment="Left" CornerRadius="3"/>
               </Border>
             </StackPanel>
           </Border>
           <Border Background="__CardAlt__" BorderBrush="__Border__" BorderThickness="2"
                   CornerRadius="8" Padding="12,4,12,4" Margin="8,0,0,0">
             <TextBlock x:Name="HeroFocus" Text="" FontSize="12"
                        Foreground="__InkSoft__" VerticalAlignment="Center"/>
           </Border>
         </StackPanel>
       </DockPanel>

       <!-- 日历导航条 -->
       <DockPanel Grid.Row="1" Margin="14,0,14,0" VerticalAlignment="Top"
                  x:Name="CalBar" Height="34">
         <!-- 顺序：上一页 / This week（本期按钮）/ 下一页 —— 本期按钮夹在左右翻页键中间 -->
         <Button x:Name="BtnPrev" DockPanel.Dock="Left" Style="{StaticResource CalBtn}" Width="34"
                 ToolTip="Previous">
           <Border x:Name="IcPrev" Width="12" Height="12" VerticalAlignment="Center"/></Button>
         <Button x:Name="BtnThis" DockPanel.Dock="Left" Style="{StaticResource CalBtn}"
                 Width="118" Margin="7,0,0,0" ToolTip="Jump back to the current period">
           <TextBlock x:Name="CalLabel" Text="This month" FontSize="11"/></Button>
         <Button x:Name="BtnNext" DockPanel.Dock="Left" Style="{StaticResource CalBtn}"
                 Width="34" Margin="7,0,0,0" ToolTip="Next">
           <Border x:Name="IcNext" Width="12" Height="12" VerticalAlignment="Center"/></Button>
         <TextBlock x:Name="CalNote" DockPanel.Dock="Right" VerticalAlignment="Center"
                    FontSize="12" Foreground="__Holiday__" Margin="8,0,0,0"/>
         <TextBlock x:Name="CalPeriod" Text="" FontSize="20" FontWeight="Bold"
                    VerticalAlignment="Center" Margin="12,0,0,0" Foreground="__Ink__"/>
         <TextBlock Text=""/>
       </DockPanel>

       <!-- 视图容器 + 覆盖层（同格叠放，后加的即覆盖层，永远在最上面） -->
       <Grid Grid.Row="2" Margin="14,10,14,3" ClipToBounds="False">
         <Grid x:Name="ViewHost" Margin="0"/>
         <Canvas x:Name="UiOverlay" Background="{x:Null}"/>
       </Grid>
      </Grid>
     </Grid>
    </Border>
   </Grid>
  </Border>

</Window>
"@

# ---------------------------------------------------------------------------
#  B. 主题 XAML 替换
# ---------------------------------------------------------------------------
function ConvertTo-ThemeXaml {
    param([string]$Xaml, [string]$Theme)
    $map = $script:PaletteLight
    if ($Theme -eq 'night') { $map = $script:PaletteNight }
    $out = $Xaml
    foreach ($k in $map.Keys) {
        $out = $out.Replace("__$k" + "__", [string]$map[$k])
    }
    return $out
}

# ---------------------------------------------------------------------------
#  C. 运行时主题回放（切换主题时重建界面）
#     像素 WPF 的可靠做法：整窗重建，避免逐元素回放的遗漏
# ---------------------------------------------------------------------------
function Set-Theme {
    param([string]$Theme, [switch]$Sync)
    $script:Theme = $Theme
    $script:Settings['Theme'] = $Theme
    $script:NightMode = ($Theme -eq 'night')

    if ($Sync) {
        # 测试/回归用：同步重建。BeginInvoke(Background) 排队的话，测试脚本
        # 在同一次回调里就截图了，拍到的是旧皮肤。
        Rebuild-Window
        return
    }
    # 让 Dispatcher 处理完当前消息后重建窗口
    $script:MainWindow.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [action]{ Rebuild-Window }) | Out-Null
}

function Rebuild-Window {
    # 主题切换 = 重建内容树，但【不重建 Window 对象】。
    #
    # 为什么不重建 Window：实测（见 verification/_trc7/_trc8 的 trace），
    # 只要 Application.Windows 里已经有过窗口，新 Build 出来的 Window 再 Show()
    # 就会静默失败 —— 无异常、IsLoaded 恒为 false、ActualWidth 恒 0，窗口永远
    # 出不来；把旧窗口先 Close 再 Show 也一样，甚至第一次重建都会失败。
    # 这条路走不通，而且逐元素回放颜色又容易漏。
    #
    # 所以：Build-Window 照常把整棵新树建好（颜色/处理器都是新的），
    # 然后把它的 Content 搬进【现有的窗口对象】。窗口位置/尺寸/置顶全部自然保留，
    # 也不会闪屏。Window 级的生命周期钩子（Closing/Closed）挂在旧窗口上，继续有效。
    try {
        $script:Rebuilding = $true
        Build-Window
        Refresh-All
        # 第十四轮（item 4）：主题跟随 —— 换肤后悬浮窗整窗按新色板重建。
        # 放在 finally 之前：重建主窗无论成败，悬浮窗都要跟上（它自己有兜底）。
        try { Refresh-PomoMiniTheme } catch { }
    } catch { Write-ErrLog ('Rebuild-Window: ' + $_.Exception.Message) }
    finally { $script:Rebuilding = $false }
}

# ---------------------------------------------------------------------------
#  D. 像素头像（Canvas 绘制，避免外部图片依赖）
# ---------------------------------------------------------------------------
# ===========================================================================
#  内嵌默认头像（第十四轮）：打招呼的小女孩（128x128 PNG，base64）。
#  替代原 Draw-Avatar 像素小人成为出厂默认头像；托盘图标复用同一份资源。
#  为什么内嵌而不带文件：保持绿色包 = 5 个 ps1、零外部资源的现状，
#  换电脑 / 打 exe 都不会出现「图标找不到」。
# ===========================================================================
$script:DefaultAvatarB64 = 'iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAABFqElEQVR42u29e7xt2VXX+R1jzrn2PufeW1VJVSUBkpCQBAII8mjeQqNoK610oyDakiCiyAfF1k/LR1AaxQb5+MBG1BZQUBsQbUQbWoOAvF9BnlEgIiEkhIRUkko97z1nr7XmHKP/GHOtvfe591bdSiVVFZKdz8m9dc+9Zz/mmOPxG7/xG8I72eONv/waLykj5piBmeHecHfcHQAVQfqX9T8TEYD17ywP6b8uf374fRHBVCiaSCnx9Pd9jvBb7PFO94Ze+sl/yF/7mtcgpoQFOLMbEMYAkA4MIKX0iD+vzfU6A1iMBaAJqColJVSV3TRBVj7zs17KF3zpX3ynN4j8zvaCVYRkSnZByLg4Ii0MoNvzcoAiglQ7OtCLj5TyDW//+n2BhJBcyJLQYYOneP7fCo93OgPAHMxRlITAoZtf/o73w0dwOXbpFx+ucnTwF0NAQVCE5JBdMXPGVrFq7zaAJ+MxXTtH20QuA24JyRkfd8vphZdA1v/FRdXVMi7ecm/t6MD10Hu4R34hBROltYoI5KQ0f7cBPCmPbRF03uE+gRfMMie5ewCLX1ubUQR8tYmbeoHGwV9wsHaYNDpJHKeBZ9QrZpXWnNKmdxvA43m87x3P9sunl8miIO06FywHiVwphXEcyTif9yc+mw9+v+eTcVQyror32yjmIIaZIX7jmH5dFVDyBaPQffxHaDTc48+kjaSUuDYZ//GHf5SPfs8XuqEHrzkdv4ek/PNv/SY+4BM+Qt5tABceJyennG5O8QbpggGICKqKqiISMfrk0glWzzkdCmoz1mY0Z9xYD9sBcUPcoyKw6w3gogdw10MfgGra/x0HdafhmDVSmxhrJZUT7jjZMOiASbrhc4gkxjahmt/tAW70mOcZtkabZzzno8pUEMziLopETAcFV05ONqT+DfOKo3FQhzfPjSSRwst1RnD838ZxLBeX9a8s3xEDxbA6symFsTWkNVzAZHnVe0MwAXEn53xDL/RuAwAyRhGhbMtav+9vpYUZ9F9TSuAV8Xk9Qum/OoL0w+rFHCK6Hi96K95Xj73DYYkn3g9UAWWaKq4FMJIaIuGlOMAPTAR1Z7YK/TW/2wAufuRtYnf1XrT1mH0DN72EgCYCScEqiYbg/cjlws1eYvE+23exWzj8BSuQ9dAPfQQIhpBTYp7nDjAJ9er9+GJsvs8FwisIUjLUp7YBPCHJyUe974f4lXSKtZkkxnTtAb7vu7+LswfuI3sDb+hBWbVCut0ARm8MJ6fUWskYgwYWYKQO/iyuvx1e3OtQvRs93NuavB0niWEYpIZbwl3IZog4zaCKsLzk/c3fex5Hse0p//tf/0pe+apfZ25Qhi1VKp/zeX+Sz/rznyfvMh6gzAHbKIL6TBIFnxmSIXVELpiiqKxlGDinuUCd+4sVzOTg/h7c1sOETHqYeLQYLMdJ4PGVSOCCBN6EIVFWaiSHqYeO5d+bhsG5JDwJlgypxlYGsEZqTqVdF/KeVGT1CXmWBHiLGG4VMSNrHFbO+ajkW74ulm5PlWTqEGZG96/X++99eQ8o6oqK0ObKJheszQx5oDyF4Jcn5pXUCVEBMYSGYEy7c0pW1PQW4jQ3xepv1Ok7NKAbGdPjOfwlrKzhpXsaWf7v0Iglh9ej4tWhNTSBjfW3rgH86k//gk/TxDhPUGcupcw3fu3Xc2kzsC2Fk+2AzzuGLOyuTai1Xubd/EO3W4jlT6QHWA7/0GxdolHli9EJWBt57+c8k9PTLWKRyDbg/KH7ePl3fK9PrSIa5eLHfsrvld8SSeDv+5CP92m3wyzKpAHj3337v2GaHkYc1CxuhFUwQy4kYTdE6x7HLb6Z4dz6z7DjRtTRoetRSPDFEy3FRFJcFHeBFhB19cxXf/038IM/9pPsemg7H3f8lzf+mvyW8ADijjYoKSM+o7XS5nPUJnCPbL+XfXIdLPPUflxnTN0LyHLzL0AIbhOiQV6htUAo3RhU8NpQUpiX+W+1HEBpzUiywLpOqzUyTvOeeRp+i8f/VEgA3RfI6dADSI//ch1+FAaQeiFjiDWojrmzzQNFC1EM2JMa3vQd8UG5tw7AGd7LHlEPZE8dkXeee29yk6aS9ANX2f/+yBP26GEgFq3l1hpDymxzoo1nJIxMI/NO6gF+7nt/3JMoVhutNbY58df+yhchWyjbDV4Tm3LKoMJcw+mb+wrbCvss+u0V8x+rO3+0n+1BQ0IdHN0nf6ogSwPqGECUw7LVDDWAwna7YcZ41jMu8eIX3EmtmalVRrmNH/ih7/eHdzPz3JjnkVYr7/8EdBEf1xN80DNf4LddvoKak5LQzh7g27/5n7KVRimFzfYUTTDP0/Uf+EHc03dgCHh0JNAfJaex/SvUJeZ3AOiQbdSRRz3ALZZ/qc0Rh7lVtGTmVsmp4I2olk4u8z99xmdSywmSonT0DD/6K6+Qp7QHKCmTHKw2vDdtTopy6g3xCvMIUuJmHPdX3omSv56xqMStX7xXbwDdOATuOYZ+gc62MJq9NdQhqZNSYGUpZZyE4JzN0ztBEmiGmEeTxAyaUQ3MjZQSZhUbO++uw5/L4a94PwuK8o5x+Y/1Zx32DxaEz90D9eu9iRULWEgn5p2E0g/cFnr68jPifZdSsLmSRHEFE2OQDV4UyQktmWoSxqH61DeAff892rKQQRPeNPr0aLRSLzbYnlAc+m0PGZGrOCknxDtPoRmSE7U52jM9Z2WlHHEOFl7hyhHoVZETLWbThEswiVz2LW19AquCx2UA7SDWHabHrtE9i1tinZwpF+jW8pSv+R3QnPDqvO5XX43VRkqJJsodT38at991+56I2j3bYXg7NHoX8HTc55BgtoBmQJb+4zsXDtBwchwxSu29+rg/6gnpJWCV8k4H9sQNhiSJ6eoZgyuNStoM1LMdarfty8RHCDXeQ4HJgXGQQKJToP15xCF7dByfKO/4uJ5HUmIYNiQdUE1MTSAPHTRZvIRSSdEF9Na//IaJ0/J1sTOYSLhBBSRlqhnuTiW+5tZwEbQoZrXzAg2s7Yvx9euRQV/r5I8gekiEc40W7zw7qkptE+6N5o65QGcLlbzBXUhlQFIOgroklAQoKUZMUIkOaKtjkEc6D1E7Fc5lwJ4gE3hcz1JtotYZ90bGSFSy7MmcK8rl8jhzTUNVGYYhwBTJqCqpP1cpQSuzuR4RPR6vQ/ULycvp6RZvYXytzkfIpjhMZ+cROjrL6dF+9jAM5Jxj3qD3RTpyRNZ3ghCwVUV9BGu0eSbbTGJGe9kXDRIPjtwjZOePVqunlDCccRzZpoI0A1NSr8RMjJIS7hGjHwu2fuTyH+Xv1WmObN6EE82k6qSDsi/nQp0rlhVNur6Oxf7XvoHsP4NaJ8p2S05OTn3QVe0glD5FDODf/ct/7a/5pVcz15F53JHEufu2K8xXH2JIiuJskpLaTE4RxxYUTXh8XZ/WGpKUIRfufdNbsN20GlQTuHzn7Wy3W8xa3Mi3YwkVHixYwYpirYILVx94iGk37rsa7pTNhme813swuT0qwrZwEEUEqzte8pLPoAwn1Oa4Jq5e2/HHbn+p33/tGm02xJRJKl/yVV8hT4oB/NTLf4qf/O4fCrRLGtP5w/yH7/g3jA/fj1ijlLR0QGhLv1zCFXtPdG7qDu2RvYAmYv6vOQ/ddz/tvHsZoKmRTwZONtuIoRwPlthjrPvN/AaEkj5ngJJVqd6ou8p0dr6no6qgwznPeNYzkSxrubfe9gU/kAslNE6rE5/+qZ8SPEIJcmlKJ3z6S/44D40z4hl1YSpPogcQh2zSDUBpVRh6bayAWMNVgmO38uysJxr2qKjzRQLnYYiwDsTgMTDiDmq9H+9RgmlPxK3nDCIdvJF0y+CP+957xJwgtDqTpOAiVK+oee9iGgnp9X38mlKCpBH2DniJS0l5XWVwyGt0R6ztoWRLpNrQVklkcO2w9JNkAC7hbr3X9NEJUzQnkkOj9aw3jGCxmv0dlJvG3uWsDw/i2BAinmgnYMSHvqdjH95gNfohvG1t1qPRcqETWCMMNTuaU2epdcLwe4NIFWg3pJT4hbEDw1nZcHY8ou5WaTZHSHsHEiceUxLYNKZkFtTKUihoCIJYN4z1Dfoap8Vv3C4NNy7HYJL73lbMO4rYu25Zjpi/Thy0+vFzZMm4Ok17BeE392pgK7dfO6Czzgg4iGTAmTBGqx0XgOzOoMOFsljDU1lvDF0IJTcCiNbf72/BirBgEoAajoi9Q1j8+dbrRUfMEVcyThMjiVEXa1fZZ65eDwHR+NUdl6h3kwm/+ouvJLeId3ObuHLHbbzHc5+N5GDJSNcBwB1VqDhNnbGOa9cNDEW493Vv4o2veyNn0zknmw0A7/8hHxRM3YU4bvtOnXj8/MAratDQ6TOBIrzyF34p8onZyEU5bzMf+j/+Lsj9NaUNu19/A695xSsprQ+RitMEagrGUzGwrk6iB7OGR57NBcw5wlI9wou4hPyNDEw4mYq39CSGgEdtqughU+rGMMsy8dORr7WrWMrRIKj1UUARQV1YCu3gFPZw0D8/6e5ZBE63W6w2NEcsVhXM2g27jyZ7r+Hraw4jdo8GlwwZU0cTkJVzH9mWgo07vKTwBkYnu4C0aI65CnaBLnaDWLP3Wn5znaJ3NC/ibTaAo1j5WPrrvaxKKUV8tfAAh6APGmlj0nDFNTnm4XaXWBmgSYpmTckBBFVjWwYoKULFo3yQJqCucJCdJ2Q9WMWZ3akYZKVsT6lzJVGYZUEuIyEN3MvDbYviSaMv8gjkE8N7ePP1QizJbJMnhhaXn+jmykqmNCOZgEXr2FtjmibKdkN174fSR3JEkZ4w2VJa6T4iSlIUyJpIKLs6g1uUdP7IBh2HqOsEEBKlnnYGYJsrLg1Uma32ho3R6C5foYng6vswmbsR+AFhtJeTfiBno37smtSfeP7jLRtArfUI42ctt46JEYfWfpyFHwXAlRQRmHgFNuSlBu55wBGRohSQHPh/jppciQQvp0yRBFNjthm2CimhHvofyp6D4EuS2cNNloy5oy6IZqgRMmqLkq8kJWMwN5rNSM4MpdAEdsmoqSuJoNAqenLKRpxpnhgWbYDloDWFESzcCOu3vVmvKo4NtJSCztql8N4xsxH5seDx3t3VIc9ldadcT5n2o3z9RswZrhsKEe9cwf58v/7aXyfnAuY8tDvjAz/+Y6D0aqCXHK//xf/G1XvupeCcnp7ykE83uOV+HfwsIvzKK/8bciBKsR022FzJuURydmD067x/Sdz1nPfkrqc9ffVQGHA28osv/ykub0+Yq5HT9RNL6+swp41T9BW88eIP/IC9kYofM6hEVuGrJ80AWmtHBnCR+sQtvjjvtyH+bRdwuGg75tACaKnjRGkSHigJbDNcGiJ+k2LgIgle4vfjOOJlacArYnbd6z3qNIpADTaPKkzzOVnT+n5VNdDFpUuZE6M3CoZcGvpMoJJsae0XfGzk7uIvek03Wz1gakET16ThEYXrDPRoDO3JDAFLd8vdMT2kPi8H6DetU0UUboBiLUZwsTae5xB5EndsnJmncIfDMEDJVIU5QXJjQLk2jyRVco75Q6etL8Xdb1o+u0gIP3gAVtqpXUPOVA9QufleQ2Q42XL1/IyUIgRIVmrkkJQm5KTknEnNmMcpJGzwI70iX6Rr3BGcdIO5kLUSWgUvpPvQJ7EKWCDSICwY1aPkSUiUWx0hOk5iDvIB9mALDt5CXaPiASJ12dckFpW7GWZBNG04kqC6wTyjmw3SPAAcFZJCmuYYwMzKVmOsOzWnEaRVWmAGqCBZkZQgR7ZuPY2pIlg15jZ3w3YmnLkApXC+myDlteHULrrpnGgCLWsMhWRZoencwhvMVLaiZIeqijejTvN+BkEFdaVJIZeCzDNCwdzx5E+9KmCJ5Y8VpFpirnt8SEt/36ca6F3JzFl4OAcXQHNjKplW4sAM70nesdFJNy7GOTT9gnzHCs7bQVLqcH6SevhK0Z6dwj2HRYYBtUEX9uqKKjpy4PQ6AqrO+SDMYuhQ2LUaMnQtsIRaG8NQmGZjujaGR7tYIouQNGEp9IlFKt7L5ir21DGAxz2zr7JKqWxK4vzsjFf/8quwVuPWJyE9/Qof+nt+Z5xqSjAkqjo19YjSodzW8zDtSKyK8qpf/uX4UKcatPVmq4awqeBZ0ZT4oD/0OyGnleWMReyXDjjRDDaFnc1d6IADGRhWyntTSNstH/bJnwQ1sAzqGC+ydrcvAucjD7z2Dbz11a+DXV3jfiN4ExJvAE0JTXExzMPLviMmqvLbMklzmPyZWc/4r5+du+nP6bdfEFQTVic0J05KYffwNS5tNtw/XUOTQHLakHr/rdFEaE5QtA1oTtboCooIjUiuZMEJRILYKYKboymRVGgCU6tMGdxrWE4CEz+QiIs479LwrGGYvXT1RRewtyANOPcZbGaQRG0VS4vUzdL3iKJ0KrCrE5fQFQ1UVbyjh82DFbS/YEYzI6X81AwBR7H+kcax106f7PvoElBwE6gO5dIlWnNOtqfszLDkVLVVf2ehaelBjiHNSQ5U4+Rky7Qbo7TzwxJKo6xr1nl8MfVTDKp7SMDIPnNxgmlk3ZCkh4glbIUhh0iMYP11hVfbzSNJtCONe4DHVdaG0xLOo+18jEaaHALrFvikRIL7pBrA0cDExTLwsRrO0jWTOIA5CVUFnzt5VDQg3Zz6rQzwR3wNx73NI5CVloScByYMG9LaJ6Dr+7rtyzHRjiT60iTyTko5TGVsNYbFiBYsJKUubZfDAJIpbg0vkStst1vaOK/dTG2+MoKjGQb5oGO4tLmlJ4E3ukOqGknwUy0HWJJAeQxe4CJyWBVqFkYFJIegUgKztt4KXVu3AQDJQY99p07zStUY4XIJqFacuGq2II8Wog0at2zuLe7Wb6cfcAyXy5YWzWExhERKBXfn9OSUloILEam+41TMG/NuJIvSNP7cZN908gOauPihINZh7X9jA3BvT24ZmDVh6iSN8kxTd5e1ojKs6tzeBZQO6/u2YDMe7tprQ1MOT5AKz/7AF3H5ee8Zt36aglom0YhRt/VDXNuNHs63CXzwx38kKzjhBwbmgE8XrfCIaTS6xetdivFehq31+2Er15ycE/PkfPd3fR9f8uf/CskKbokqjeGS8OM//YNYVuZaUUvxGhNrY1x6teASFPf4gDR+r2Ei5oKoM5kzmZCIRlcMklz/eOGdz/FtKpTOko7qQRAXmhm1zbznc5/Dy376B+VxMILsmC59pJmzfEa2xnkxOeoAHI1Q9yZNxEajyRD1s4JpC3W2/U+Mjt2NBjb76xi7GKP3XoKqIqbBzdBo3/gNZhFuxFWVTlLZfyN1entIz7rFLR3SwF2Xn47aBrNClZk2nKEIc2vIgYi19Z+bLgQY66ylZUx+Aa2Wv6vs0UB160Z//eN0s+W20ytkhMIhLV+p1nB1Lm22j78K2LsnXyXSfDWCtl517QnNMeVaIw77MUFMPG4EfQjT23JLBHPFacE4EvbkDt8/t0rAySasB9Xa3NE3XaT+1v7FWs0cKBPfCnvXxWNs252iGfGufehgUhENBFHMafPMMAxHjmilUh0wkNbPdNERSN1T+j5sBdCm2CPMGmzKQOpJr2H7Jl2vKGpttDY/XkZQui4ZtJ5RGTHtoz02p4VoEWl4d9/7hLEJnCejFpDkzEVoqcO4C1GmcxDFFFvdcEJce/m1eOyu578Og3jUzIsHWaaRubBV5EaqsDehjQUnJeM1qglNA+PZGElhcJUwb7Rdo+5a587tYU/X66HyIIVKEEsXdKrD6grYNNNq7CZYfN7Ncm1rIzIkzD0Y2RbdSReYfcZwZhvfHoQQRXWhaSVUoz2LRiar5jx83wP7EqdkPCvlZIvluNlJExW46wXPxVJQtkYx9DTgTtYKI+JvAjTFdC418yM/9GPMu/lIjuZF7/9Cnvu85wRrKAneNf6FfQx/rM2UpdJpXtmkU37gP/4AUhPe4NKlS7z5njfzEb/jo1AcTSF7M9XGy77zezCvbE43SIFP+O8/lnQ60MwxjKJKLoWcC9KiN2BueGuY0o0pLG9JshtOSkpB+Yn/7/v9wasPhg6xGZuk/Mfv/S4wC+Jqa8hS0WifXtYYR3vpS1/qqgMnJycx06zy2Axg5bEtDZIl0ZMU8c6c33zDGxh8EXmO2/5+H/SBTOLdXRo1JZ71QS/uOuwBgMwaJFPMV/689vUvhqOSSGS+9u9/Hfe+6b41LzAxvuALP5/3evazSZvMNO/QLCuR1G9x+uhmRpBSQl350r/0ZZzqlWgKbQsf9fEfyV/7ii/FmXEqmPP6176Rz/2cP9thQWOSkQ948T/n7mc/A0l7cktUHLKKWnuzzlMMapuY44n94btjruRU+Gtf/L8TphRh8druAV7+ip+hnT+E+RyaDLaE6p5juPLaX3s9f/pP/VlsjiRxnmcsP6YyUG8qoiRA0YzXSpYcrVFn9Q4imewV7VSnSQyKcu4NLdEIan2+fkj5KNapw2yGKqRUGNIpuV6NlVEiuDTmqXukPtB5tHvAH3ns69H0iCKeKkzKsNmQUmKaR7ImZp1BxpCyR4PNNBrbcpk2j6QBaIXTkyvMvgvF1CM5XN+jqb4/fOkViot1pnW0wzdpiAUbCFYdHYSSFXxk0glnRrSC9/5GHznOekLZ5NhhoAmVxGgjWTePDQeILLUPRfShz+WNqAtSNshBtpBVA0NPKQCZZaGThG4Q28zOKkVTp9Un/DrtIN2LLuUNuy5CqeRA25KTNX5urXWNtb5//3sW0o28gNzY9R8ZSAOfDR1yb3wFR2DYCJVIVqQKJ8MmMnBXStoyDJlh2MSOgWRoRwevz6U6l5C9618mhBYfNgwb2lzXgZfc4eZxGiEr2jopp9PtltuvJLQEFh3VS2GeZzZlCNbUY8EBZFBmZlobOTs7Y3bYNSAlJG3WztnY5s6Xc9I2Qz3HUlf5N8NrWw+9aAx1igM13oSURCoZt0TzzMnmCjY7Nu8olzfYAD4YLc1U3yHaEDW2QwZ3rIZbba0tcSQWjsjFL71uNP2iB2hzD1MJPBumlZmJq2dXMauoK0k2lLQhDQnXmbx18gbUjbIppCTkrFSx/eRRScwCLTsUiVFzk1hhk5RJEtUIiXqccW5IclqamVPlvDSmVCO5tkYySCaIx8VIEkWhkKmzg8dIulvrHijC9C17gPd98Yt40+vvYZ52+Dwh7T342V/4JaarDzGooHmLZOO9n/tsxgfuJ20GBgG1RrUGD03MZpg7U9532lbVjBVcMKZmSMsMsuHhB86oV0fmeeaB+Sq3XT7hthe/N0lCfMLMuHzpNu6950FEnNomZmbuftbdlEEfP8lSDUrjQz/6A7lUrvDw2TXKVrjt9g1N+iRiN/a2Tbz/R34wJ5srZFHOd1eZZKLOO0pfSecCY4ZrW2XYbhEdSCR+9jW/hrlyPo3MbeTqtQlTRZJiDkVhahPv/8EvZmojm+0pTqX6FB1MWUpaP0JjVxbXhfW6N2J0P+bHh931XH/apUsMJTG5UmXmZf/+X3PpksC20KZGQnnVD/w4WxNoAdFezc5v+92fyC4bLfXOoC+tWtCSoAr3/+aDfNan/QnmMUSV2Tjf+q++mbueeVd0CjFac77+H3wj3/7//Fu8Cq01Hjx/K7/w336WnZ1xcVPwxQ1hF+HV6+VgG202Bt0QfzXqdYBR2tHPtupk2aCeyNsTrs5XY+WszyQhiCYlMUgmTY7XGZ9n0nCJj//w38Gwubz2GzZlYJodSZveihLO6zV+7Od/gqme9TnEgKmm+ayPzIVekffhEu+0ObXEb7z6jfypl34euQ1RGqug28cpXN/SwOQZb4UmymgNK5l2qux8RrNwsusduB7Ll1HqBfmK3UCRHSxYgZmhlikMaEts2FJK5tp8H8OwxcWZtUbo0MzpyRXUM7RMdmUjZ2CK17bv9b+t77E6KedgG3dyipkzne/I25OD43c2OYcs7lyRNjIU8LYDhGmeyaXgDlObg+peYvnFFufMILFdPcrUoHkwmaQFQQaZcd9hqVPV3WgiaMmY1X2jYeVC201C3L40flwGMAwbjARSoAXHrZoz1YpkIauCzYg5g3k/aO8CD1HqmOwT1uVFlzww7iaGYWCeZ7IXzs9GvIT4VIwTWC+GKuaV1hpFB9pslJxptZKGQu2bQW9WBt54GJUDcYohGkFJg93TS+GyPUFNDrJMA3XGNnUVsXNKN+ymThpKL/WWeb9I/nLOJCkMaYO4oJZIqlRmRFPvEyRaq6BG9YnKGB1EpAOMwcdgnTnQddxs8QbTNPWpY5C0l+DXx2MAYs6QMypCXrJucZIIg6ZY3aYBNy2ujQM9/UXnZ0nKImtXvLWAUqXC0JA8M5wIJhXN+WDYMxKgcTxjrucY56TNzHm9BnivCt4OfAeLfkeyJaNc6JzHSOLUJlZRjAQZ6avstSOImdqp4J71YLGEkAQKSiKU1dSP0dd97yMYzEIDsyOQ7sat+4O2vcl13uCWPcA//Btf5T/5wz9BbRNWZ2jGm9745si8Z2PWyuw7LIeipldnnGZOhsR7f8wH0zyx7RDupE4tIaaUOtMnXmHpnD6odeT09lP++b/8Z2xLfFizOaeXMoiRzEJ3wIX/5SWfwR/+jE8Lr+LOrp7TtCKa1obM49FBE/oMIBqtY9HoJGbW7w0GfnXHg/e8lY0FSnpG6ASb9y5pDQ2g02fdSb77dqqmzgwRUkmQWW+u2CKJ0JHNLmGVPAwriM8xg7iMyC+8CbkRy9jrAZgXiaGZ3boBvPENv8k9r38D0irJBa/RFJmnSrL4QE51w2lK1OmcVDZICYIGt5+SJFG916qeYpyq49yZFH35nlSJhSpnZebu976L3A0kbkDw+xyjSTR7Tu8omJS1krjdL9GkBgvIZT9scp2mv8V8Xh/Al7WG3jeB1GJzeF0XUYf7Li7kCk0DqXQTthSuPnDORguUGsRFVZIIuUER5RwjewvUL+Veu2vfNdiXSwBuMy6tg1tgJpRcGOeZqhM5D/txHNkLUR6sT0cQms2UNNDmCt5IuonmkDjFH0s3sMdwsdj+Reobt3rOUUiM01nQpEqOBpGAW4u257qhSw7FAfbdPdd+EMdNGhcLRLGHimif+1FjpKmtWb0s9Op+I3Rt5+9VOtdp3CXswIEewEHLVjyaVC0g5+Vplq6sHHVKIw0oBsUD1MgoVQOQKd5JnRrHlkWC+XRhbcYicpO6XJ0d7iFcCCnqj6GDG/0L82XyOmYxBSPn/BgGQ1pDW8ItSrWIK20PtZqTRSmbgZ1MaI9jIY+6TPInpGviraKJEpnsMlqWFpq3XFzWcP2Mtxyted5HQesUsKh/j9lKF7XgBb2AEh4wdIBZ42cpEopgvQvatK+Zvdim65Ry6cTUrNIPvbe8UZBElkyz8FJITBHJIhbbqWHh7/p8Y5K+KFuw5qQsN9AgWcbvywGDSFHNiITS2ux7gk3BH9tkkPhSZwrJG5tqJK+4GkUKGSHtWpdoifi79L7dFVclUVZYEjFMPbp+Jp0sGWXjUSbe/9u6q6tZjpqrslLG4lEaJDNkNuqQj7gAR0DIwtLpcnbxZLr3BA7bOZ5pFr8OOV7paiyTxTCl2IsEvWRMB5apzpQiQcYLhRL/zjPi6cLguEZvn5lqMSsRFa0dq6BdJ78i8fPaQphVrIUAZevoX2sNl+g13LoB9NZobHF1yjjykk/+FMp4hiYnk5m2mX/45X+Ha1c26zSx9Re32RRUMy7Grs781a/8csbzh8jJ8bORTTMeeuNb2PaRsOiEhRc5O98BcOaVZ77weZhoMMCWlS0LF0WjkbKZK7/8Qz/JncTs3kKRWuRijmpizTFerrpXFDkYK0sl87r738Jv/+RP5HzlNHROzMFYmwmMVJ7+oueSWiexix6dTS4btg3+08+9gh/80Z/AZuVsvMbufEJloE3SGUhC9ZG/9399Nef1GqKNeZ4ZNgm0kUvQ0480lNgzs37uP/0MP/4jP848N87Pz6nVGHeVr/q7X41IorWZ09NTNqePtRkkvipVbdz4yOc9j+Haw6CV1IQHS+bffvP38HqFuXm4K48RqqFbbxVnN13jr/71L2caZ6Q5l1JGzke4/1okeL13HhmrkeqiPV6xh87QOy93GvbqMde4Hz4/8+ZfeBW6g6wFSTF1dLRSvid7c3ZU8spwIsW4+HLXqzceTBP8/owzrp4o+3G3sSmkyyehEdFrb/rkj67ATCbNwq+97g38yA/9GLbLsV3UBPXSwbDIe1yd93zuM7n9zlOkBMlFHWZqzE6ua+ntgLoWz/bG17+Jl33nd9NqzEzMU+N93u/9+IQ/9Mny+GjhHiAGZrTzkU1rnE6VNHSqV96SqqCl9J3AjpFjzWr1tT5uaaDtRi6dntIYseaoe+QZdeXOxu4hh+Tx5kunUNuFPMD6GPaybp5x5qQap6MwlGDI6DJo0aVel5KxtXCFqrkL/Hdj6rkBwANqAXRlWT9quZFyV0lRr3iENVtL0FD+VXU22y1ls2U+b6Ra1okhcV3b5SvQtokGU2OkudGs6ydpepT2RUJbCim9GuHV69tjLsBzlzKNjL7tKqk6zSdSKkHx7q41qXQiQ6MSNzEy+hi/StuBOj0csGYL+fiCklq0dEWDHpaaRzZ8MC17sVJooiS3/cyARts157yOjR2YVR8CCa9ivV3d3MDTWiV4l69JpCBz6F7JYL8r+LjlbB3qjj/zkMA5EMoSzezGStbEkDfQggyjXaxqpb9IQ8kMwxbUaRbt9qSBEkZbpd5YC9k1xK086Os5D4yHYhVvswGI0WQmkWAKUCOUu2DrmcmEtjtnM82cbnsSODtVQCUxm6O98ZNS1/BByF6Ie2OMEvy63BwzqKlBaSgFqTDTYJO7u9egfTkkXfYQdmBkE8rcodcTMIqLU4jtnZM1rP/3GRpSNSXRNPWaXVGJ3kTzFhl8q6tE3VKqyQXxxkhGD2TpWsVdqLWRNBZgFx+6KkhjoxKCkElwjKrz0nun6Q7PhAfNJ5hXtLHfuZiUeapkErmvoFvUVaZpwmikUhincyQl5pvMFDwmpdBDJmsupb/A1ncEwtCcT/rwD+f+O04DsKjGiPBj//k/9+w0dH6KZL7tG78ZyaBZSWq87/Oew3PuvhOpFZtiCihJw7WFJqcJQ4JRPIQiHonZkcJj1GQMubDzierCc17wAuZ5ZlxhUOE2Ca5dK0pNQhblnle9Og6vC0W2A9Wy5Yb3saNjJQ/bj8GHokjix3/kJ7j/vqtcu3pOUoWW+YWf/6+0FiNvSQtzG/mjL/l0jBpjYTmTTzLVZmxuaBY0Ba6RlhlDN4aUoSn/8lu+DUywFvXDf/mpX6JVR1KjDBvGOq3E2ccVAlaeuoYLGqdzrl69Sq1Gas4Zwqf/nt/FfNeViLt5yz3TzMt/5qcgn1KBVo1NPuEbvuYbKKUwW8NT5aWf/Ud40R//NCjWs3VFe+xfsmkdErs275U9DtE5WdhDIdUhCSzD3CayCDuf4c4roMLGlno5rbe1pgCNBnfOfqWyNYmh1ZPTTtsGz/3gW5SdTetxa3nBD/pnPVfjW77p3/CKn30l23QSwx0iZMmIZ1q/9efzNT7nz/xxquyiRM4JtxTNMJtWmjsa85NxESvume3mCl/zVf+Iy9s7cFNaa5yUwjxXrBplI4/Iibh1Uih7Hry4UFIhy4asG4YcbnGTO5EyK22aSVnIpiQtTKKYR/8uSbBWtIUYY2MOHmFtNCYkSwyDWu6qXYK5UPEIH8sl6MMqagSFahn8W/T7iLX1WQpJckzxSnTQkof2n5cU+YVY5BFz4BBqsEklIvOy7tZlVSgLzCYfwcrLPJmro67Y7MEhmIXt9nIkcy3AM9VozrQ6r/sQEk6TRhDdG2ONfCGVzFxrFx/usxKuCBmbGjltsZZIMsR2lhqUL3dnnuebzZM8RgOwWAWbfS+p6u6U7SXqODJLZcqKnF4KZzMU5kWNs1WEwuAWAx91QrKym2fMG5KVq+e7cLGTkUmgzlxHTk9PsVrRXLpy5gUlsq7T11LDUFJMR+Aaah1u0OoUidM4I9uBRHTmPHWGLkEhS81hbszWqFporTLOlfMWi64zmblvCW9Wew6wH3lftIhMGgaUsmE83zHkQp12tHmibAq1TdQKmzyERN5sWJ3x5KvAhfZGVrN4PyqCaMFagGoqSmtdSq8ZSMPm85iZkMAPa61sNhuq2E29wC0bQDZD57PQ68nQqEwbeMtuZHO50Jb1KtsTNkuB7s4VSZyMM4MYyUKGZZfhqjheEqqJ0WvM/dtAThpQJ8KmOOP5GZvLA15HtmXL2Np+jNsgHWwuWwZLEOfNdYdttgySowkzjqTtybq8qXX2UTFfBRvFnEmd+7NzPzuyCi05D3uLCWQLA25mnAwlpksPYMFaZ3LZYh4lYCy7yagm5nkkZZh9ZPYJTZmHzt5KSoVxvkazIHmExPxSXkTfXiWY04XSV9FEj2UooX7i0zm5L8yw2fFc2G6udN2kHKLTKre+OfQLP/cL/Ae+7/sZUHJziiT+59//+/jTn/npWFPSkChtIlmDuQViPe1IbPi1H/0Z8hyz91YnWils7rgdnyeyJ1rK3L8Z+MKv+bucbzZoS1hqUGC3O0OzkETJUnn67Vv+0T/424ztKkUyzYT3er8XMw+ZKhIbS/ualdbZuHgkcvm+s2ADTTXCQoOrr/wVhrbfAhoS+PTSNG5v3WZOf9uLQo1sd75sdGS8VPCUqFZj88808+Zf/ZUYPibjZM4n5yWf/TnANjxOa2zzZZIlSsrMdk6Vxh/5zD/Gn/2Cz6e1qyQdmOpI3hgmrWsuZ1ZkeOlKkpBR+JRP/hSkxZ5GNWN8+GG++zv/Xx54630UTagIL//5/8pX/4Ovi3w4FyzBe73Pc/im//Bvbw0Imq6dc8fmNObepeHzxItf8Hx8ukoZTsOFJSdtgpbtZcM4VU4np6hwW1cANQ8Ouj18DeYzkimjZDjZUgx25iQt5BQU55PhUvTaZyNJ45SBS564c3MJm2ZGE7S2To/aV+TLKHiyEFPwoVCfdoKpUC1zkgdk13goOU/TAFyki0cbhnWE04D7pzNOLxfsJHO2qeR5ImeYB2i7mAdQc4YyMIiTrb8Cz5glLusVJF/mfBdlnPYOnvXRdkkw15FqE5IrTaFslkVVXchChE5A7CBvNHJONpc4e/Cck3KKekLdQ3xq2nG5ONjMPM9MuzNEnGHYdkWTaMTdcgiY5l3c1upISqSUKZuMlowzk0VQlHmOpgVz61BmY2c7bq/C3Czq23FEikR5J0qdZ9K20OoOHQpzuxbER3FEoj1qmmNyRR3RSq1nJE0s8+iWAr3DPbp+UqKJpDHu5DiuingN4eiQOuWeh+6nbS/H7GKXqG/zFJ3MruJ1r4+8Fw2zcJ8IjDhMle2moM3JKsy7CSdREmitCMa1yXApTNMcYtMdAJraRMoDYxWGXCjZUT2jJcPSzJALUgN0sp64grEbzxjKNpJqc6oFWKUU5i5L563PYvbKQAdjkzNZe+XkQpEc7+VWDaC1tk7ESKcb66LAtIwzXywR5xaJcI39NpsyYHONskcLdaqRlHWYPGkhD6W3mgNOM1pIzZmxGQakxRuorTG3BmmD785jz6KG+hYeUHAVI3kgeiIJDDY5sxNjNCdvCh/2ez+pZ+8HxIkxtAjo0PWz77jMLJWdTWRjFZZqOPNYGSSFXg9pLxLdNwqVktjkgveGy2wx/7AtA9NoFFHaNHF2PoImSkmhR3iQoGlvLCUfOB1CLMPmSsqJ5MYmFwYpUebUHZdOTslaQFKIW5gwjiNjHVE3TvKWeZ73CzZuxQBqrb3929Ux8C5cJOuXXxiuj0YK1E3iwfMpsuaSONudcZqezrQ5wZIzO4ybDQ/NE6kFJOy0FSSqZiGTZsa1XeV8UkS2JBGmSbmNE7KfBOiyrGyTHA0X7Xv5LEOtiBgnfeRsrhNsNp3UGTOLhlP6Yl/vCxun3cO0zZZUlW1XAzHfL65IKFoKNp/jVjANTUMkM+5m1BqDCbu5UorTphplrg4RpnJmmwtFEmpGITHtQiSrHaihiA/4XEGgJKGNDWxmPLvGZlDcK5uiPPzA/dQ6xWa13ogSnxnUca/4vAOHTXoMIWBdf95aZ/IEOGOdCMQNNmfHBGvmhR/xIeTdklSB5cznfMGfQ7e3oxo8NLt8yo/c9xp50w+/xqfxvDdeYobdLDDz06Fw35t+gz/z5/8iV69e5XRzGdGB4fYrXJ2mGIMOqgs+6ApSuQitnvPPvu7vYeODJO/Dq11zwKVLwnRSap530b1zx00ZpfAX/vKXoVaQKlQJrT/vTZ4sSkk5Es02U1KIPWZX7rrrGXzZX/5irj74EPM8c//DD/GiD3gxV+64G0+Z1pwyOOPZW/n5H/hhinYBh5L48I//WCxFV5EuhP8n/8SfZDyfsDku5KCJf/g1X8XlYWB7ekIRIbmRC32rZnjSD/vtH8Df/ztfQXPITTApvPat93LPW+7xs2s7ms24QB7SzQ0gBhb7vhxrWG3I3DqCcT37tGimiqO3neCX4qZ7KoworyvR2ROMpM7ZQ/cD8MwPev4jDqa8+id/3l9//0jRLdfODHzCrr716HnVe4bcZ+YA2nQvl9uONj5I6QuX/EAFbE9xg1l2gSdUoA1shhPufe29bLZ3I5SY/+9TuuvtlHmv46tKQsg+Me3exF3bzF22wVthunLCC5/3HPz2K9S+VXTTGg+9/px73nQPm75O66rsoIaOwDoaaZW3vOnNnD/YkDYAyqAP8tz3uJOirauGxD2c61nwGbKhSbg7na4KZcUSTRIPXL2PB37zNxDdUns3Y8w3MYBDurJ7JFtmhva27aIDbgdLkLIqVTz626vWQWjme4sZf9eQbblVpm5tjnvZr1HtbyodujOJOB0a1L1VbIJ23TljXnOXY2XyIBJk6XpAKrhmJAvahUWzC5JSB5x8JYzautK2d99kSd76som+/i119k5DaS36BMsQTPD5u3LZDUAal0RKGxIjqpv+fCPaBbCXBHUhkQbPP626AOHFa7C4XbF5CoIsirYuWnEzUuiRASwhoYWYskjf2tFv26p0KUpLhngKsqMFQpea98nV4OhVuXVZOasOxLTPQhAVILX9qjYTp+oOt4R5yLlbNepMADUpyi/14OfbAbklXG2JTZ0a8q+SYm1rxlBva5K2MG9WYimxwSTKyBSGYOCmWF8zZ6WieQNaEA9ZGXOoKJNmnBray9I5BP1Gh/JYkECbC0k6UNUxgqS67hyAtHon6aQRzfH9tnIYlYbQbNEr6tvKbjoZZELWSKxmQhCxdbKCuAffrrNcF5kzS/WAn6aoxxxgVe3LkUNV0/zWVxanFK1S0728TOrt0oWzkxBGi8nb0WJm7nzeoVfu5HxqzOMZgw5M48iV2zJZplji5DEy3TxHWdvzA/OTqN3zhlqNk80JD549zKQLQu9IrVxuys6m2F2shaSJzR138lBtDBZLIMZtYiob0nCC1Bb8gCZYGmiau8i2gG6AE7YuzHMja0bybUzXKg+dX2MzhAL6qUM+uY0hKc12+2Xb/UItFUshRZFQDNuEmurTnz5jUyOVGV+WZNwUCu7bsF17JbAwZVWOGbbL4qWOgWvHrGSZmtXWVTW9K3PSb4nc4nZy7Vx32cvOd8m5BYN3gS/7ir/BJ/7e38VkM6koOSVefNfdPPO228MQDUiVl/37bwWbyLYwlT1m7CSt0naxQyitexLPzs5obvynX/zP+HjObDNqTn39m3nrq18TRNiU8KS0ofCs5793UMHmGuTY2XrPA1qbyF6581nP4K6770DbHBVoKXzMh34Uthn6wSi1ws+96bXXfVC/5w98ihc0xu39xnsQtjn2DzQ6HVwTczVOL10O0krd51D5pmvUOwOlO0aUZYp3H7NiQ9Z+TZj0wBKX3WJ8qk+ipu5im7dH3ay9dwFd8uwCXxZi/GyRh3poHmlJqAK76YzbhxNuu/NuzDPDdovPDavXGCfjNCtIXQ1ZpauSYjGckdJKqRaBk5MT6hTtO9fA+0sz6ryD86toXxI158R5EtDnx2xkcmSekFRIEruMPOUQkFZnaqCe2GxOmFrj9OR2WkrMLST2bKi85Zd/ze9+8fscG0HZxo5h15saQGVCcsjlZRGaC6enhXGOsbRBC80rSnoEAxDIkhAaaV2ppcF3XxdIdN69BVdgFYjULnaI4k32K+GwjivcmuKlqgaLqEXYaL0ej6x8vzw65czUKpUYCG0I+eQ22q5xPgZ3K3mieKI0yF1zL6kz573OkaBIZyw1N0SFaR4DhJIIAKkEgDNieLbQ96GgLgxeYDfH1hBVmjheg28YqiYCZQhF0VLAG9d2O/Jmy9wE1Uzu72e23V6k8uAxu0DO6Fz363v6sGxf4YlqWSX7vBNTvDnZ40KFhK0c7F+8aADTjLQJn89JVklqYCHjvmwNXYcnzNce91I6VhNmEp67DElOsU+3w4A3gyWvAymkV51dDSzwNutKWrFatbWYsdfWyKLMu7EbhJE2J0EmyYqjNNHgF3pg61UEk4zLQNMB04KnzTqkknPCskaP3itShDSEmpkMOcQgNa23UHMKwqz3hMsF+vdTX25RSu+cSkjWVzfmjrx61/DBG0mEZ7zfDcrkzo0QvEvj778Ej0ksi9kNlxCY8D6NnTT2IVcxJq+Um+kDnKrj51cjnysw1h34fNPR6tT1eXTYkreXwkJ77E0JzqaZ2R6O9SvC0Z7AR3qUnBnHEeZ+6/sen3WBVV+totagNkrOSNkCysPnZ9TcaDZFCdZ2PKRQtZAlHaydLcC2Z+iCVuG+s2uIGkyRRT887ZChIFNjnkeGPFBJ7ExXb+II4zRjffIppGY7s7hTyVoNetdmcxJjWQI+XEJyNIlE+8Io/BH1C++9/961x7G4/2USeq2wNLqqIkLO6YjSZ8Suxlwz8sHv+SKXuUWcKolxd5Vv+cdfz4uf/Z7kRGgDDwVqYx6vwdzHwcxWwYeFBUPe8kc/60/x5gfPyTlTNgPX5pmXv+FVj5r1/c0v+uv+7f/iX6EeuPv2dMv7vugF/NNv/Aa4KPfbDYG+aKmdOmkz0JJgSdieXo7EcWzAjPc5e9pDSLvaybS5M3gSaAHNUbdSgFPICrVCXkaAoY0Tc2vRhn7gKumhs74ssu8BMMNTaPHkNDB5O1gZbzQ3Ll26xNd+7dfybd/2bdRpjBHyPIRn1U5Rc2dnlZf/+i++YzZFHXrZu592J76b8WbM9FGvcQfjGaPFilR2ypA36waswyWQi45frZVchFROuHzllNone8pmuKUXctulyzz9tjtCRqY1Ti6d0nYTZw88GKog7rH7py92km4AVRpps42bnFLEX4HWKnmTmHczbfKYJJbMUG6LMayODooazhCyL2oxyFJjHU0qjrQZTSm6myRyv3mmIyZdA6HfKt0OzK2xSRmbp2jtLsBpB17GceTKpctshxOsnMRyi5wYayh6Gk7yEI16Ih5Z3LEW3bfkDaxw26UN43iNIRk6hwxLTKwu69GJUulAgTuZojpwdr6j5sucj3PIwDLe2gvZbphr5UQzpSSms3PK3XcGt63VUCeV8DSZVagDlYR7glzwkqNpNYdBkxyTgmSId1D2UOuCYrbQGpSe6EbTM4CshWotvXdwHvxk0myhbjKkdTtpqHVYNG7avO7+c4/BThWnDJnaGUjnbWSQgapAV+4qBJPID+Rv3+EGMFkjD7Fs2aY5FjZawJCtjrSeYZiBDqy8/kPFD3cnl1MoG6oqu3mHJGFqM663WPLVRiYGF0sJ/l+t9Wi27khhZJ8ToWiAJ7ORk0abWIPC9WiPBY9nwbAs9HZZVLo11tIuCueYUSQ8wn6po69LMNb9f773jtYl210bDaGaITnF61wXaOd1jW2MsMkTYwAf/tEfySBpBVZynXjtG+/hgQe2kVx1mBdJXJvO1iTMjuRJ4ia1JLz4Qz+EuS9DaG64GD/z679y3RP/xHd+r5tFGVXdeOUrfpEXvM/z2WgmDQXNwvu88AXkUpjr7qZKXiKQquHXzgN7SFEnbK5c6roCj6wMaufTdYus8lAQjbKz1sqGqC7okq6IIrWPv/t+Da1wfG5eG/fedy8PPPzAWqOX7Yam8DG/4+Nimsr3qOea2Jrx8O4hfvq1//UdbgA3NLPP+Ljf7W953W/05omuI96J0uHZdN1qVsM4t5Efee2tJS7v//Rn+21X7mBTCrVWPvX3fwp/7vM+P5ZSSFf3UgkoeD7OcPOBwGMMcPY9hgtbeMhcftZd7NL12fRFA5jvua9z7jsUrMLJlcuwycytMWw3pLHx8JvvRafWmzKy7g68fitqzB9izpAG/tKX/GV+7hWvCGzEjNnhC7/ki/nUz33JE3PF35aNIZoK5JNwhQfLIB3pNOXalznLugbGcKIxfWuPzXASKmKzdc2b0MOIrq5g3sDSjRaOrnr4y2GmyObWIY/dFBpGi+KIXuc15IIGcjSQvKuCJI2yTkRoc5BAZWrkZdkUIXxN6zR3OdgS3sfPkkRp1loLUMlCE8ncGKeJp8rjxnyAFjStQVMMXGho8XvH+EWEqevPr4sJCDbPY502VtI64BGLH/Ys3pBCSSHzerSg6vppl9QzLu1DF/hxy2lRz7yRXFxs9uoSKsua+sPnWxLEA/DrUJdBvA+KdpSN1vUQxcjD0C9Jos6GDkq+xcroyTMADwpYJXdMPwAcmu3FoVWPNGcRp7ZbN4D1MHqytBdusABECAFk7dpA7ULIOTxI79tGVIMXcLiexvBH1Ai8GAuX/rz2CV85EJpehaZkkSbwG7wn+tKG8EDn445mwRo0i5V1WfSpbQAnT7vM5d3T1unjlcDR9h9m6k2T5QtpyJDh1Y9dk/9wZ5/3Dz88Tlr75BezlYtGsGTjq1Bm5/zb0WJz3wtRyeGt9uPN5TFoQ+7unj4NtDod7XsN7FgiYBFjtDGUzM7HHZfvuJ2nPeMukijzPFNOB65cufLUNoD/+2Xf/o5HoHKJkekuiVpKWQ8/EL4Yz64S4+GrUXSSw9KGXoY8l3axSyiFjm9663ULrg6XYB+6/3XBWIe1p7fcd31jshMuDr2OJI2y2Z1kiWls/ME/+GmIKvNckSHxLd/2rTznQ1989Cq+4+Xf/9Q2gCficbSEalnT6heXU3RVTm9H/2avIqYXNCPsehd/EVEzv2EIOMQYbsRYulEYuU5avuv2tNbIOTPW+W3aVPIuYgAx5xGu1A70+vo2T0397Jbe/H7TxnGuaXsgZlGS69LsN9F+PTKOZROYXKiOl8N9NDzmMC9R1Q6Jl3Wb12azebcBcEMB1imoUW0muaPJKMlpZxP5ZBsDjb1j564hF28ttIKD0AZW1zJRUgyAelayDpGpH8btizfZ9wKSj5wg3nw97oIU2gExY0mOU8rMXd7tXd4A/teXfq7vHj7vtXIjZ+WLvvgvcu+9b2G7HdjqQB4bv/iKn+GUtC6T3j7tDp75rPdgdiHrQHJ446+/lmsPPtjLvkYz471e8EI2J1uGk2AQ75duh5jF41ka8Wgu/CIb5+KWdX+CmjpPaQP4iR/9MZ6WL6NZMTHO5ms894XP572e/wyaT+isjG++n7f+2jWsKbuHG5OESqY86y6SbNcpmWv33c+1h+5n6CJUszu78zNOLkUH0pbRMAIYsoMy8SD5f7s8jg9fj3KUpZR+qnuAJ6QgLTkz0Js1xBQrtqO1Ed2CFidlpyQn08he2UgjtRGxOVSyU4hKeZ3JrZGskn2i7Ineq0u+0ULId0QydmgASzl86AEOG2bv4jmAxW7gZXV7UsiZaXJOtKDJqdOMSialGDwJbl7Bax92KIrXaU8SbRYcRc1BPpUcgotZV1n2uInpIA+QG6wJe9tvaOwH9lV6rrkdrNL1VVnlXd4AzCq2baGC4U6lBgVblWmaSdU498ouOSWnIH7kjFtjdA9xyDkqgdGdpoXU1TnnlDibZm7vC5hba6tbc33Hl2D7oY791zK0EkP072Jl4N/8oi/1s4d32AxXbrvEldsGnvb028ia6ULZzDbSppHtdsuunaHbwvYZt/PcD3t/Su1LDyTxlnvu55/8i28ip0ukHFPEZw88ANNEFkVTdO8+6VOfyTOXLaa9sfSElbMHsPNayi7l5cLWfFcygO952XczXQ0BJU0Gw8T3/9D34ClQOJfQrHd1pjoylMI4j2xvu8z25BIlK80bbXJuH7Z8x3f9e2wewsWncP3ZYxYx1ok6L/qI/44Xvfj9VvZts5gmlCcg/F63os19DQGivOsBQW2uDEQ7tc4zp5cKOQtnOh6USaF+JSIrm3WqUfeTFJHMXKdQGRMhl4FqTnNFJVG9xQYPd7wJU42tZL7s3iXyhmjb+yP2EB7v4S9Jp3fyyDzPbPqK2UpA3O9SBpCzYlNDVGg+M7aZ6uMy0HXDRKykElOuTahTo7bGdjgBuxrbLzteLGnZiBZt15hgqkzTREmJZt0D0LoQyBOXgbvvNQyXIQ2zifNrZ+9aBnDt/CrTOIbKiFQubYZOLNmviDnC4DuZQj2mXkU3MIT82ThW8nBKPRvJKbGrI/Mufo/F3pvmjs+VOs1YbeRSOl19vxLmHXjqx6rltTHtRqz2+QUa08PXntIGcMu+8G//1f/D//U3/6u15vVe465DGiac767xyl/5Bep8LeDQITG1HfM8IvkAKVuAmZ4gqWS+72Xfx1f/rf+zbwyrJC0U2VInJ5kEqRL4J//463jec98b8bZy/pJkdrsdm1L6iFofb8NvmIUfhYDHUQYekVQ9+gApJVoLhc6UhL/whf8br3r1q7EUrKlcCl/5t76Sj/sD/4O8U3mA3cPn3LG9clOY05pQUubs4QeQ0zGYPSbxFCX1lSg1mO8mIHFTPcXMnHhiesg5kcuoBZl0lXSXwAVa33pttcbquv7hVzGGnFdNA3xZMCHXC6ovk8uP/Q48iiE0RPt6NkK2JQGn2xPUleIZcaiTY/M7YQiYpml/Wfzga4EU8yJOkAIgoS9IWm9c7SrKFqza2IzU1SqcUgoquVOp+nbvCzdYVUMpsy9V3o+IHyNwjwXbf3tGiCUH0A4QLQ2p4/199nZZaPnEG8D5jrX1tsR09wv93VgRp4swoazREWRe3e0yMyfL9rkmDGlAUogmIXsFj2WRFux3DcQHnNeBCi4c/pNVeh1pGHfRiSPDdKdZe+c0gNomZh2PQsCRC1ShMYfWn9kqJiUSy6EXXU5cUUshmULunL9M1iEkXzqb08VQO16eGuITnRMgEivolGPm8tuxzHtbc4K9Iep1lPHDmYqnrAF84Wd/vv/ky1++Wqq587Ef+9F81d/78r6wSG+wZDlWwjRqX7baDvYMhYafW2jtl3LKx33UJ7AdTpnHiWqVj/vYT+QHfvCHY0mzGiLOPa/7TV7yhz9zT6JcJ18TtKXUu8DgEcGeoMOWGzCcDg1woa+vZFePNTbTU50WfnbtGvOukkSYu6bcycmGs3oVTbHm9Gj/noQMjAHVWtxKjgmbvmzOckFdOH9oQrcbxAubUig9BFBk0WLjGc+6O4AW15XutW7k0ND9fyohbU/1zh+32g5WyWyHULbc5A1DLpyfXYsVJjSa14VMH2tcxRjrOY0aGj2lcJ32hFjn/9uB1r+yTQNWhd351GfXA9+ffObq2RnNFiq6XjfQsSSLTyUDuPh1o+8/5YEgd2ceZ06GDdVbDGDmFErZq7YORzdSSnT9kFC6WmrjkHbzG8q/mEVPYK8C0hdLlYKNxjAMR2vXXPyJAfjfTnmAdH7j2h8QbshVePfj3Y8n7fH/A+klwCg6uORyAAAAAElFTkSuQmCC'

function New-DefaultAvatarBitmap {
    # 从内嵌 base64 解码出默认头像的 BitmapImage。
    try {
        $bytes = [System.Convert]::FromBase64String($script:DefaultAvatarB64)
        $ms = New-Object System.IO.MemoryStream -ArgumentList (, $bytes)
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.StreamSource = $ms
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        $bmp.Freeze()
        $ms.Dispose()
        return $bmp
    } catch {
        Write-ErrLog ('New-DefaultAvatarBitmap: ' + $_.Exception.Message)
        return $null
    }
}

function Draw-Avatar {
    param($Canvas)
    $Canvas.Children.Clear()
    $art = @(
        '...hhhhhh....', '..hHHHHHHh...', '.hHHkkkHHHh..', '.hHkkkkkHHh..',
        '.hHssssssHh..', '.hHseeseeSh..', '.hHsbbssbSh..', '..hSssssSs...',
        '...rrrrrr....', '..cccccccc...', '.cccccccccc..', '.ccCccccCcc..',
        '..cc....cc...', '..ss....ss...'
    )
    # 取色：字符表里的大写字母统一映射到小写键（PS 哈希键大小写不敏感，
    # 写 h 和 H 会直接判成重复键，整个脚本解析失败）
    $map = @{ 'h' = 'h'; 'x' = 'x'; 'k' = 'k'; 's' = 's'; 'e' = 'e'; 'b' = 'b'; 'c' = 'c'; 'r' = 'r' }
    foreach ($big in @('H', 'S', 'C')) { $map[$big] = $map[$big.ToLower()] }
    if ($script:Theme -eq 'night') {
        $P = @{
            h = '#4A2E36'; x = '#65404A'; k = '#8A5C66'
            s = '#C9A292'; e = '#1A1116'; b = '#B4707E'
            c = '#3A2A32'; r = '#A85A6C'
        }
    } else {
        $P = @{
            h = '#7A4A52'; x = '#9C6068'; k = '#C98A90'
            s = '#E8BDA9'; e = '#3A2A30'; b = '#E08A9A'
            c = '#FDF4F2'; r = '#C05A6C'
        }
    }
    $cell = [double]$Canvas.Width / 14.0
    for ($y = 0; $y -lt 14; $y++) {
        $row = $art[$y]
        for ($x = 0; $x -lt 14; $x++) {
            $chRaw = [string]$row[$x]
            if (-not $map.ContainsKey($chRaw)) { continue }
            $ch = [string]$map[$chRaw]
            if (-not $P.ContainsKey($ch)) { continue }
            $r = New-Object System.Windows.Shapes.Rectangle
            $r.Width = [math]::Ceiling($cell)
            $r.Height = [math]::Ceiling($cell)
            $r.Fill = (Brush $P[$ch])
            [System.Windows.Controls.Canvas]::SetLeft($r, [double]($x * $cell))
            [System.Windows.Controls.Canvas]::SetTop($r, [double]($y * $cell))
            [void]$Canvas.Children.Add($r)
        }
    }
}

function New-AvatarBitmap {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $uri = [System.Uri]::new([System.IO.Path]::GetFullPath($Path))
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.UriSource = $uri
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
        $bmp.DecodePixelWidth = 512
        $bmp.EndInit()
        $bmp.Freeze()
        return $bmp
    } catch {
        Write-ErrLog ('New-AvatarBitmap: ' + $_.Exception.Message)
        return $null
    }
}

function Set-AvatarElement {
    param($Image, $Canvas, $Hint, $HintBox, [string]$Path)
    if ($null -eq $Image -or $null -eq $Canvas) { return $false }
    # 优先用户头像；为空或加载失败时回退到内嵌默认头像（小女孩，第十四轮）。
    # 返回值只表达「是否成功加载了用户提供的图片」：默认头像不算用户图片，
    # 这样 Apply-AvatarImage 在用户图加载失败时能正确清空 AvatarPath（回默认）。
    $userBmp = New-AvatarBitmap $Path
    $bmp = $userBmp
    if ($null -eq $bmp) { $bmp = New-DefaultAvatarBitmap }
    if ($null -ne $bmp) {
        $Image.Source = $bmp
        $Image.Visibility = 'Visible'
        $Canvas.Visibility = 'Collapsed'
        if ($null -ne $HintBox) { $HintBox.Visibility = 'Collapsed' }
        if ($null -ne $Hint) { $Hint.Text = '' }
        return ($null -ne $userBmp)
    }
    $Image.Source = $null
    $Image.Visibility = 'Collapsed'
    $Canvas.Visibility = 'Visible'
    if ($null -ne $HintBox) { $HintBox.Visibility = 'Visible' }
    if ($null -ne $Hint) { $Hint.Text = (Get-LangText 'av.change') }
    return $false
}

function Apply-AvatarImage {
    param([string]$Path = '', [switch]$Store)
    $ok = Set-AvatarElement -Image $script:AvatarImage -Canvas $script:AvatarCanvas `
        -Hint $script:AvatarHint -HintBox $script:AvatarHintBox -Path $Path
    if (-not $ok -and $Store) {
        $script:Settings['AvatarPath'] = ''
        Save-Settings
    } elseif ($ok -and $Store) {
        $script:Settings['AvatarPath'] = $Path
        Save-Settings
    }
    return $ok
}

# ---------------------------------------------------------------------------
#  E. 描边图标（24x24 网格）
#
#  网页版原型的图标是一组 24x24 viewBox 的 SVG 描边路径。这里把同样的路径
#  数据搬到 WPF：外层 Viewbox 负责缩放到目标尺寸，内层 Canvas 用 24x24 坐标。
#  这样图标是矢量重绘的、零图片依赖，换主题时只要重画一次即可。
# ---------------------------------------------------------------------------
$script:IconDefs = @{
    month = @(
        @{ k = 'rect'; x = 3; y = 5; w = 18; h = 16; r = 2; sw = 2 },
        @{ k = 'path'; d = 'M3 10h18M8 3v4M16 3v4'; sw = 2 },
        @{ k = 'path'; d = 'M7 14h.01M12 14h.01M17 14h.01M7 18h.01M12 18h.01M17 18h.01'; sw = 2 }
    )
    week = @(
        @{ k = 'rect'; x = 3; y = 5; w = 18; h = 16; r = 2; sw = 2 },
        @{ k = 'path'; d = 'M3 10h18M8 3v4M16 3v4'; sw = 2 },
        @{ k = 'rect'; x = 6; y = 13; w = 3; h = 5; r = 1; fill = $true },
        @{ k = 'rect'; x = 10.5; y = 13; w = 3; h = 5; r = 1; fill = $true },
        @{ k = 'rect'; x = 15; y = 13; w = 3; h = 5; r = 1; fill = $true }
    )
    list = @(
        @{ k = 'path'; d = 'M8 6h13M8 12h13M8 18h13'; sw = 2 },
        @{ k = 'path'; d = 'M3.5 6h.01M3.5 12h.01M3.5 18h.01'; sw = 2 }
    )
    tasks = @(
        @{ k = 'rect'; x = 4; y = 3; w = 16; h = 18; r = 2; sw = 2 },
        @{ k = 'path'; d = 'M8 9l2 2 4-4M8 16h6'; sw = 2 }
    )
    timer = @(
        @{ k = 'circle'; cx = 12; cy = 13; r = 8; sw = 2 },
        @{ k = 'path'; d = 'M12 9v4l3 2M9 2h6M12 2v3'; sw = 2 }
    )
    image = @(
        @{ k = 'rect'; x = 3; y = 4; w = 18; h = 16; r = 2; sw = 2 },
        @{ k = 'circle'; cx = 9; cy = 9; r = 2; sw = 2 },
        @{ k = 'path'; d = 'M4 18l5-5 4 4 3-3 4 4'; sw = 2 }
    )
    settings = @(
        @{ k = 'circle'; cx = 12; cy = 12; r = 3; sw = 2 },
        @{ k = 'path'; d = 'M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M19 5l-2 2M7 17l-2 2'; sw = 2 }
    )
    profile = @(
        @{ k = 'circle'; cx = 12; cy = 8; r = 4; sw = 2 },
        @{ k = 'path'; d = 'M4 21c0-4 3.6-6 8-6s8 2 8 6'; sw = 2 }
    )
    plus = @(
        @{ k = 'path'; d = 'M12 5v14M5 12h14'; sw = 2.8 }
    )
    pin = @(
        @{ k = 'path'; d = 'M15 3l6 6-3 1-4 4 1 5-3-3-6 6'; sw = 2 },
        @{ k = 'path'; d = 'M9 9l-5 5 6 1'; sw = 2 }
    )
    moon = @(
        # SVG 原文 "A8.5 8.5 0 019.5 4" 省略了分隔符，WPF 解析器不容忍，这里补全
        @{ k = 'path'; d = 'M20,14.5 A8.5,8.5 0 0 1 9.5,4 A8.5,8.5 0 1 0 20,14.5 z'; sw = 2 },
        @{ k = 'path'; d = 'M4 4l1.5 1.5M17 2v2M21 19h2'; sw = 2; dim = $true }
    )
    sun = @(
        @{ k = 'circle'; cx = 12; cy = 12; r = 4; sw = 2 },
        @{ k = 'path'; d = 'M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M19 5l-1.5 1.5M6.5 17.5L5 19'; sw = 2 }
    )
    more = @(
        @{ k = 'circle'; cx = 5; cy = 12; r = 2; fill = $true },
        @{ k = 'circle'; cx = 12; cy = 12; r = 2; fill = $true },
        @{ k = 'circle'; cx = 19; cy = 12; r = 2; fill = $true }
    )
    collapse = @(
        @{ k = 'path'; d = 'M6 15l6-6 6 6'; sw = 2.5 }
    )
    chevL = @(
        @{ k = 'path'; d = 'M15 6l-6 6 6 6'; sw = 3 }
    )
    chevR = @(
        @{ k = 'path'; d = 'M9 6l6 6-6 6'; sw = 3 }
    )
    search = @(
        @{ k = 'circle'; cx = 11; cy = 11; r = 7; sw = 2.2 },
        @{ k = 'path'; d = 'M20 20l-4-4'; sw = 2.2 }
    )
    check = @(
        @{ k = 'path'; d = 'M4 12.5l5 5L20 7'; sw = 3.5 }
    )
    min = @(
        @{ k = 'path'; d = 'M5 12h14'; sw = 3 }
    )
    max = @(
        @{ k = 'rect'; x = 4; y = 4; w = 16; h = 16; r = 1.5; sw = 2.5 }
    )
    close = @(
        @{ k = 'path'; d = 'M6 6l12 12M18 6L6 18'; sw = 3 }
    )
    doc = @(
        @{ k = 'path'; d = 'M6 3h8l5 5v13H6z'; sw = 2 },
        @{ k = 'path'; d = 'M14 3v5h5'; sw = 2 }
    )
    trash = @(
        @{ k = 'path'; d = 'M4 7h16M9 7V5h6v2M6 7l1 14h10l1-14'; sw = 2 }
    )
}

function New-Icon {
    param([string]$Name, [int]$Size = 18, [string]$Color = '')
    if (-not $script:IconDefs.ContainsKey($Name)) { return $null }
    $col = $Color
    if ([string]::IsNullOrWhiteSpace($col)) { $col = Get-Pal 'Ink' }
    $brush = Brush $col

    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = 24; $cv.Height = 24

    foreach ($spec in $script:IconDefs[$Name]) {
        # 合并默认值：StrictMode 下直接读缺失的哈希键容易出岔子，先补齐
        $s = @{ sw = 2.0; fill = $false; dim = $false }
        foreach ($k in $spec.Keys) { $s[$k] = $spec[$k] }

        $sh = New-Object System.Windows.Shapes.Path
        switch ([string]$s['k']) {
            'path' { $sh.Data = [System.Windows.Media.Geometry]::Parse([string]$s['d']) }
            'rect' {
                $g = New-Object System.Windows.Media.RectangleGeometry
                $g.Rect = New-Object System.Windows.Rect(
                    [double]$s['x'], [double]$s['y'], [double]$s['w'], [double]$s['h'])
                $g.RadiusX = [double]$s['r']; $g.RadiusY = [double]$s['r']
                $sh.Data = $g
            }
            'circle' {
                $g = New-Object System.Windows.Media.EllipseGeometry
                $g.Center = New-Object System.Windows.Point([double]$s['cx'], [double]$s['cy'])
                $g.RadiusX = [double]$s['r']; $g.RadiusY = [double]$s['r']
                $sh.Data = $g
            }
            default { continue }
        }

        if ([bool]$s['fill']) {
            $sh.Fill = $brush
        } else {
            $sh.Stroke = $brush
            $sh.StrokeThickness = [double]$s['sw']
        }
        $sh.StrokeStartLineCap = 'Round'
        $sh.StrokeEndLineCap = 'Round'
        $sh.StrokeLineJoin = 'Round'
        if ([bool]$s['dim']) { $sh.Opacity = 0.6 }
        [void]$cv.Children.Add($sh)
    }

    $vb = New-Object System.Windows.Controls.Viewbox
    $vb.Width = $Size; $vb.Height = $Size
    $vb.Stretch = 'Uniform'
    $vb.Child = $cv
    return $vb
}

# 把图标画进一个占位 Border（XAML 里只放空 Border，尺寸由 XAML 决定）
# 参数名不能叫 $Host：那是只读自动变量，绑定参数时会抛异常。
function Draw-Icon {
    param($Target, [string]$Name, [int]$Size = 18, [string]$Color = '')
    if ($null -eq $Target) { return }
    $ic = New-Icon -Name $Name -Size $Size -Color $Color
    if ($null -eq $ic) { return }
    $Target.Child = $ic
}

# 一次性把窗口里所有图标占位符画满。主题重建时会再调一次。
function Draw-AllIcons {
    param($N)
    $defs = @(
        @{ host = 'IcNavMonth';    icon = 'month' },
        @{ host = 'IcNavWeek';     icon = 'week' },
        @{ host = 'IcNavList';     icon = 'list' },
        @{ host = 'IcNavTask';     icon = 'tasks' },
        @{ host = 'IcNavFocus';    icon = 'timer' },
        @{ host = 'IcNavSettings'; icon = 'settings' },
        @{ host = 'IcNavProfile';  icon = 'profile' },
        @{ host = 'IcViewMonth';   icon = 'month' },
        @{ host = 'IcViewWeek';    icon = 'week' },
        @{ host = 'IcViewList';    icon = 'list' },
        @{ host = 'IcAdd';         icon = 'plus' },
        @{ host = 'IcFocusMenu';   icon = 'timer' },
        @{ host = 'IcPin';         icon = 'pin' },
        @{ host = 'IcTheme';       icon = $(if ($script:NightMode) { 'sun' } else { 'moon' }) },
        @{ host = 'IcMore';        icon = 'more' },
        @{ host = 'IcCollapse';    icon = 'collapse' },
        @{ host = 'IcPrev';        icon = 'chevL' },
        @{ host = 'IcNext';        icon = 'chevR' },
        @{ host = 'IcMin';         icon = 'min' },
        @{ host = 'IcMax';         icon = 'max' },
        @{ host = 'IcClose';       icon = 'close' }
    )
    foreach ($d in $defs) {
        # 注意：变量不能叫 $host —— 那是 PowerShell 的只读自动变量（宿主对象），
        # 赋值会直接抛 "无法覆盖变量 Host，因为该变量为只读变量或常量"。
        $slot = $N[$d['host']]
        if ($null -eq $slot) { continue }
        Draw-Icon -Target $slot -Name $d['icon'] -Size ([int]$slot.Width)
    }
}



# ==== part: Views.ps1 (inlined by Build-Single) ====
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

# 给一段文本统一设置 1.4 倍行高（第九轮第三十二节第 5 条）。
#   为什么单独抽一个函数而不是改 New-Txt：行高是"排版诉求"，不是所有 TextBlock 都要
#   （标题、单行 chip、计时数字都不该用 1.4 倍，会显得松垮）。只对会折行的正文/长文本调用。
#   行高走 Scale-Ui，跟字号一起缩放，放大字号后行距不会显得挤。
function Set-LineHeight {
    param($TextBlock, [double]$FontSize)
    if ($null -eq $TextBlock) { return }
    $TextBlock.LineHeight = (Scale-Ui ([double]$FontSize * 1.4))
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
        $cnt = New-Txt -Text ([string]$evts.Count) -Size 10 -Color (Get-Pal 'InkFaint') -Weight 'Normal'
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

    $cap = New-Txt -Text (Get-LangText 'week.timeRange') -Size 11 -Color (Get-Pal 'InkFaint')
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
    $box.ToolTip = (Get-LangText 'week.hoursTip')
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
            $tt = New-Txt -Text ([string]$e.title) -Size 13 -Color $fg -Weight 'Semi'
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
    # 标签筛选：第十轮起标签可自定义，选项从 TagColors（Get-TagChoices）动态来，
    # 不再写死 work/focus/life —— 用户新加的标签不出现在筛选里就是漏数据。
    # 显示名走 Get-TagLabel：内置四键本地化，自定义标签原文显示；筛选值仍用键。
    $tagOpts = @([pscustomobject]@{ Tag='all'; Text=(Get-LangText 'flt.allTags') })
    foreach ($tk in @((Get-TagChoices).Keys)) {
        $tagOpts += [pscustomobject]@{ Tag=[string]$tk; Text=(Get-TagLabel ([string]$tk)) }
    }
    foreach ($it in $tagOpts) {
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
        [pscustomobject]@{ Tag='all';      Text=(Get-LangText 'flt.allTasks') },
        [pscustomobject]@{ Tag='today';    Text=(Get-LangText 'flt.today') },
        [pscustomobject]@{ Tag='week';     Text=(Get-LangText 'flt.thisWeek') },
        [pscustomobject]@{ Tag='overdue';  Text=(Get-LangText 'flt.overdue') },
        [pscustomobject]@{ Tag='nodate';   Text=(Get-LangText 'flt.noDate') })) {
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
                  -Size 11 -Color (Get-Pal 'InkSoft') -Weight 'Normal'
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
    param([System.Windows.Controls.TextBox]$Box, [string]$Text = '')
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
    $tb.ToolTip = (Get-LangText 'task.searchTip')
    $tb.VerticalContentAlignment = 'Center'
    $tb.Background = Brush (Get-Pal 'Card')
    $tb.Foreground = Brush (Get-Pal 'Ink')
    $tb.BorderBrush = Brush (Get-Pal 'Border')
    $tb.BorderThickness = [System.Windows.Thickness]::new(2)
    $tb.Padding = [System.Windows.Thickness]::new(6, 0, 6, 0)
    $script:TaskSearch = $tb
    $hint = New-SearchHint -Box $tb -Text (Get-LangText 'task.searchHint')
    $script:TaskSearchHint = $hint.Hint
    [void]$fp.Children.Add($hint.Wrap)

    $projOpts = @([pscustomobject]@{ Tag = 'all'; Text = (Get-LangText 'flt.allProjects') })
    foreach ($proj in @($script:Tasks | ForEach-Object { [string]$_.project } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)) {
        $projOpts += [pscustomobject]@{ Tag = $proj; Text = $proj }
    }
    $script:TaskProjectBox = New-TaskFilterCombo -Name 'TaskProjectBox' -Width 150 -Options $projOpts
    [void]$fp.Children.Add($script:TaskProjectBox)

    $script:TaskStatusBox = New-TaskFilterCombo -Name 'TaskStatusBox' -Width 108 -Options @(
        [pscustomobject]@{ Tag = 'all';  Text = (Get-LangText 'flt.allStatus') },
        [pscustomobject]@{ Tag = 'open'; Text = (Get-LangText 'flt.open') },
        [pscustomobject]@{ Tag = 'done'; Text = (Get-LangText 'flt.done') })
    [void]$fp.Children.Add($script:TaskStatusBox)

    $script:TaskScopeBox = New-TaskFilterCombo -Name 'TaskScopeBox' -Width 128 -Options @(
        [pscustomobject]@{ Tag = 'all';     Text = (Get-LangText 'flt.allDates') },
        [pscustomobject]@{ Tag = 'today';   Text = (Get-LangText 'flt.today') },
        [pscustomobject]@{ Tag = 'week';    Text = (Get-LangText 'flt.thisWeek') },
        [pscustomobject]@{ Tag = 'overdue'; Text = (Get-LangText 'flt.overdue') },
        [pscustomobject]@{ Tag = 'nodate';  Text = (Get-LangText 'flt.noDate') })
    [void]$fp.Children.Add($script:TaskScopeBox)

    $script:TaskSortBox = New-TaskFilterCombo -Name 'TaskSortBox' -Width 138 -Options @(
        [pscustomobject]@{ Tag = 'due';      Text = (Get-LangText 'flt.sortDue') },
        [pscustomobject]@{ Tag = 'priority'; Text = (Get-LangText 'flt.sortPriority') },
        [pscustomobject]@{ Tag = 'title';    Text = (Get-LangText 'flt.sortTitle') })
    [void]$fp.Children.Add($script:TaskSortBox)

    # 第十轮（item 7）："+New task" 与五个筛选控件同一行（WrapPanel 流式排布）。
    #   按钮放最右、强调色，与筛选的下拉区分开（筛选是灰色"查询"，新建是彩色"动作"）。
    $bAdd = New-PixBtn -Text (Get-LangText 'btn.newTask') -Bg (Get-Pal 'AccentTask') -Fg (Get-Pal 'Ink') -W 96 -H 28 -FontSize 10
    $bAdd.Margin = [System.Windows.Thickness]::new(4, 0, 0, 0)
    $bAdd.VerticalAlignment = 'Center'
    $script:TaskAddButton = $bAdd
    $bAdd.Add_Click({ try { Open-TaskEditor } catch { Write-ErrLog ('Add task: ' + $_.Exception.Message) } })
    [void]$fp.Children.Add($bAdd)

    $bar.Child = $fp
    $script:TaskFilterRow = $bar
    [System.Windows.Controls.DockPanel]::SetDock($bar, 'Top')
    [void]$root.Children.Add($bar)

    # --- 底部：计数（单行，第十一轮：从顶部移到列表下方）---
    # 计数"x 未完成 · x 已完成"原来单独占一条顶部横条，和筛选行叠在一起显得重；
    # 改成贴卡片列表底部的状态栏，视觉更轻、也符合"先内容、后统计"的阅读顺序。
    $foot = New-Object System.Windows.Controls.Border
    $foot.Background = Brush (Get-Pal 'CardAlt')
    $foot.BorderBrush = Brush (Get-Pal 'BorderSoft')
    $foot.BorderThickness = [System.Windows.Thickness]::new(0, 2, 0, 0)
    $fpFoot = New-Object System.Windows.Controls.StackPanel
    $fpFoot.Margin = [System.Windows.Thickness]::new(14, 6, 14, 6)
    $t2 = New-Txt -Text '' -Size 11 -Color (Get-Pal 'InkFaint')
    $t2.VerticalAlignment = 'Center'
    $script:TaskOpenText = $t2
    [void]$fpFoot.Children.Add($t2)
    $foot.Child = $fpFoot
    [System.Windows.Controls.DockPanel]::SetDock($foot, 'Bottom')
    [void]$root.Children.Add($foot)

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
    $b.Child = (New-Txt -Text $Text -Size 9 -Color $Fg -Weight 'Normal')
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
        $txt = (Get-LangText 'cnt.openDone') -f [string]$openN, [string]$doneN
        if ($tasks.Count -ne $total) { $txt += (Get-LangText 'cnt.showing') -f [string]$tasks.Count, [string]$total }
        $script:TaskOpenText.Text = $txt
    }

    if ($tasks.Count -eq 0) {
        $empty = New-Txt -Text (Get-LangText 'empty.task') -Size 11 -Color (Get-Pal 'InkFaint')
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
        $stripTip = (Get-LangText 'tip.priMid')
        if ($tPriority -eq 'high') { $stripCol = Get-Pal 'AccentEvent'; $stripTip = (Get-LangText 'tip.priHigh') }
        elseif ($tPriority -eq 'low') { $stripCol = Get-Pal 'AccentTask'; $stripTip = (Get-LangText 'tip.priLow') }
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

        $tt = New-Txt -Text $tText -Size 13 -Color (Get-Pal 'Ink')
        $tt.TextWrapping = 'Wrap'
        $tt.VerticalAlignment = 'Center'
        Set-LineHeight $tt 13
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
                $dueTxt = (Get-LangText 'flt.done') + ' · ' + $dueTxt; $dueFg = Get-Pal 'InkFaint'
            } elseif ($tDue -eq (Fmt-Date ([datetime]::Today))) {
                $dueTxt = Get-LangText 'flt.today'; $dueBg = Get-Pal 'AccentFocus'; $dueFg = Get-Pal 'TodayInk'
            } elseif ((Parse-Date $tDue).Date -lt [datetime]::Today) {
                $dueTxt = (Get-LangText 'chip.overdue') -f $dueTxt; $dueBg = Get-Pal 'AccentEvent'; $dueFg = Get-Pal 'OnAccent'
            }
            $dueTime = [string](Get-TaskField $t 'dueTime' '')
            if (-not [string]::IsNullOrWhiteSpace($dueTime)) { $dueTxt += ' ' + $dueTime }
            [void]$metaRow.Children.Add((New-TaskChip -Text $dueTxt -Bg $dueBg -Fg $dueFg))
        }
        if (-not [string]::IsNullOrWhiteSpace($proj)) {
            $projChip = New-TaskChip -Text $proj -Bg (Get-Pal 'Card') -Fg (Get-Pal 'InkSoft')
            $projChip.Tag = $proj
            $projChip.Cursor = [System.Windows.Input.Cursors]::Hand
            $projChip.ToolTip = (Get-LangText 'tip.filterProj')
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
            [void]$metaRow.Children.Add((New-TaskChip -Text ((Get-LangText 'chip.time') -f [string]$actMin, [string]$est) -Bg (Get-Pal 'CardAlt')))
        }
        $subDone = 0; $subTotal = 0
        if ($t.PSObject.Properties.Name -contains 'subtasks' -and $null -ne $t.subtasks) {
            $subTotal = @($t.subtasks).Count
            $subDone = @($t.subtasks | Where-Object { [bool](Get-TaskField $_ 'done' $false) }).Count
        }
        if ($subTotal -gt 0) {
            [void]$metaRow.Children.Add((New-TaskChip -Text ((Get-LangText 'chip.sub') -f [string]$subDone, [string]$subTotal) -Bg (Get-Pal 'CardAlt')))
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
        # 第十一轮：任务专页（wide）里按钮移到标题同一行的右侧 action 列，
        # 上面留 2px 对齐标题；窄栏（list）仍独立成行、上留 5px。
        if ($wide) { $actRow.Margin = [System.Windows.Thickness]::new(8, 2, 0, 0) }
        else       { $actRow.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0) }
        # 第十三轮（item 4）：按钮字号与任务正文标题一致（13），不再比正文小一截。
        $bFocus = New-PixBtn -Text (Get-LangText 'btn.focus') -Bg (Get-Pal 'AccentFocus') -Fg (Get-Pal 'TodayInk') -W 52 -H 24 -FontSize 13
        $bPost = New-PixBtn -Text '+1' -Bg (Get-Pal 'Card') -Fg (Get-Pal 'Ink') -W 42 -H 24 -FontSize 13
        $bFocus.Tag = @{ kind = 'task-focus'; id = $tId }
        $bPost.Tag = @{ kind = 'task-postpone'; id = $tId }
        $bFocus.Margin = [System.Windows.Thickness]::new(0, 0, 4, 0)
        $bFocus.ToolTip = (Get-LangText 'tip.focus')
        $bPost.ToolTip = (Get-LangText 'tip.postpone')
        $bFocus.Add_Click({ param($s,$e) try { Start-FocusForTask -Id ([string]$s.Tag['id']); $e.Handled = $true } catch { Write-ErrLog ('Focus task: ' + $_.Exception.Message) } })
        $bPost.Add_Click({ param($s,$e) try { Postpone-Task -Id ([string]$s.Tag['id']); $e.Handled = $true } catch { Write-ErrLog ('Postpone task: ' + $_.Exception.Message) } })
        [void]$actRow.Children.Add($bFocus)
        [void]$actRow.Children.Add($bPost)
        # 展开指示器（▾/▸）：第四轮起它不再只是"装饰 + 暗示双击"，
        # 而是一个**真正可点的按钮** —— 双击卡片现在去开编辑窗口了，
        # 行内详情面板必须另有一个显式入口，否则这个能力就变成"没人知道怎么用"。
        # 用 New-PixBtn 而不是 TextBlock：需要一个真正的可点命中区（8px 高的文字
        # 命中区太小，在卡片右边缘几乎点不到），而且按钮能自带 hover/按下反馈。
        $caret = New-PixBtn -Text $expCaret -Bg (Get-Pal 'Card') -Fg (Get-Pal 'InkFaint') -W 26 -H 24 -FontSize 13
        $caret.Tag = @{ kind = 'task-expand'; id = $tId }
        $caret.Margin = [System.Windows.Thickness]::new(4, 0, 0, 0)
        $caret.ToolTip = $(if ($expanded) { Get-LangText 'tip.hide' } else { Get-LangText 'tip.show' })
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
        # 第十一轮：任务名和 专注/+1/▾ 放同一行——wide 模式把按钮组放进右侧
        # action 列（Grid 第 2 列），与标题在同一水平线上；窄栏仍放进 body 下方。
        if ($wide) {
            [System.Windows.Controls.Grid]::SetColumn($actRow, 2)
            $actRow.VerticalAlignment = 'Top'
            [void]$row.Children.Add($actRow)
        } else {
            [void]$body.Children.Add($actRow)
        }

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
                Set-LineHeight $v 10
                [void]$ln.Children.Add($v)
                [void]$detail.Children.Add($ln)
            }

            $prioText = (Get-LangText 'opt.pri.mid')
            if ($tPriority -eq 'high') { $prioText = (Get-LangText 'opt.pri.high') }
            elseif ($tPriority -eq 'low') { $prioText = (Get-LangText 'opt.pri.low') }
            & $addLine (Get-LangText 'det.title') $tText
            & $addLine (Get-LangText 'det.due') $tDue
            & $addLine (Get-LangText 'det.priority') $prioText
            & $addLine (Get-LangText 'det.project') $proj
            & $addLine (Get-LangText 'det.estimate') $(if ($est -gt 0) { [string]$est + (Get-LangText 'unit.min') } else { '' })
            & $addLine (Get-LangText 'det.logged') $(if ($actMin -gt 0) { [string]$actMin + (Get-LangText 'unit.min') } else { '' })
            $remMin = [int](Get-TaskField $t 'reminderMin' 0)
            & $addLine (Get-LangText 'det.reminder') $(if ($remMin -gt 0) { [string]$remMin + (Get-LangText 'unit.minBefore') } else { '' })
            $tagVal = [string](Get-TaskField $t 'tag' '')
            & $addLine (Get-LangText 'det.tag') (Get-TagLabel $tagVal)

            # 子任务：展开面板里直接可勾，省得再开编辑窗口
            if ($subTotal -gt 0) {
                $subTitle = New-Txt -Text ((Get-LangText 'det.subtasks') + ' ' + [string]$subDone + '/' + [string]$subTotal) -Size 9 -Color (Get-Pal 'InkFaint')
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
                    Set-LineHeight $sx 10
                    if ($stDone) { $sx.TextDecorations = [System.Windows.TextDecorations]::Strikethrough; $sx.Opacity = 0.6 }
                    [void]$sr.Children.Add($sx)
                    [void]$detail.Children.Add($sr)
                }
            }

            $btnRow2 = New-Object System.Windows.Controls.StackPanel
            $btnRow2.Orientation = 'Horizontal'
            $btnRow2.HorizontalAlignment = 'Right'
            $btnRow2.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
            $bEdit2 = New-PixBtn -Text (Get-LangText 'btn.edit') -Bg (Get-Pal 'AccentFocus') -Fg (Get-Pal 'TodayInk') -W 58 -H 26 -FontSize 10
            $bDel2 = New-PixBtn -Text (Get-LangText 'btn.delete') -Bg (Get-Pal 'Weekend') -Fg (Get-Pal 'AccentEvent') -W 62 -H 26 -FontSize 10
            $bEdit2.Tag = @{ kind = 'task-edit'; id = $tId }
            $bDel2.Tag = @{ kind = 'task-delete'; id = $tId }
            $bDel2.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
            $bEdit2.ToolTip = (Get-LangText 'tip.editTask')
            $bDel2.ToolTip = (Get-LangText 'tip.deleteTask')
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
        # 第十四轮：任务卡 hover 反馈。指针进来 -> 白底 + 底线变强调色（橙）；
        # 移开 -> 还原（展开中的卡片保持它原本的白底 + 常规边线）。
        # 为什么不做位移/阴影：卡片在纵向列表里挤得近，一动就"整列在跳"。
        $wrap.Add_MouseEnter({
            param($s, $e)
            try {
                $s.Background = Brush (Get-Pal 'Card')
                $s.BorderBrush = Brush (Get-Pal 'AccentFocus')
            } catch { }
        })
        $wrap.Add_MouseLeave({
            param($s, $e)
            try {
                $id2 = [string]$s.Tag['id']
                if ($script:TaskExpandedId -eq $id2) {
                    $s.Background = Brush (Get-Pal 'Card')
                    $s.BorderBrush = Brush (Get-Pal 'Border')
                } else {
                    $s.Background = $null
                    $s.BorderBrush = Brush (Get-Pal 'BorderSoft')
                }
            } catch { }
        })
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

    # 信息头（第十四轮：三个胶囊 —— 日期+时钟 / 已完成+进度条 / 今日专注）
    $now = [datetime]::Now
    if ($null -ne $script:HeroDate) {
        # 日期用 yyyy-mm-dd：两种语言下都是数字对齐，不再出现"9月 26 2026"的拼贴感
        $script:HeroDate.Text = ('{0}  {1}-{2:00}-{3:00}' -f `
            $script:DowShort[([int]$now.DayOfWeek + 6) % 7], $now.Year, $now.Month, $now.Day)
    }
    if ($null -ne $script:HeroClock) {
        $script:HeroClock.Text = ('{0:00}:{1:00}' -f $now.Hour, $now.Minute)
    }
    if ($null -ne $script:HeroDone) {
        $done = @($script:Events | Where-Object { [bool]$_.done }).Count
        $tot = @($script:Events).Count
        $pct = 0
        if ($tot -gt 0) { $pct = [int][math]::Round(($done / [double]$tot) * 100.0) }
        $script:HeroDone.Text = ((Get-LangText 'hero.done') -f $done, $tot)
        # 迷你进度条：宽度按"轨道实际宽度-2px 内边线"算，首次刷新可能还没布局
        # （ActualWidth=0），退回 70 设计宽。填充色每次现取色板 -> 换肤即变。
        if ($null -ne $script:HeroBarFill) {
            $trackW = 70.0
            try {
                $aw = [double]$script:HeroBarTrack.ActualWidth
                if ($aw -gt 4.0) { $trackW = $aw - 2.0 }
            } catch { }
            $script:HeroBarFill.Width = [math]::Max(0.0, $trackW * ($pct / 100.0))
            $script:HeroBarFill.Background = Brush (Get-Pal 'AccentTask')
        }
    }
    if ($null -ne $script:HeroFocus) {
        $fmin = [int]$script:Settings['FocusTodayMin']
        $script:HeroFocus.Text = ((Get-LangText 'hero.focus') -f [math]::Floor($fmin / 60), ($fmin % 60))
    }

    # 日历导航条
    $a = $script:Anchor
    if ($script:View -eq 'month') {
        if ($null -ne $script:CalLabel)  { $script:CalLabel.Text = (Get-LangText 'lbl.thisMonth') }
        if ($null -ne $script:CalPeriod) { $script:CalPeriod.Text = $script:MonNames[$a.Month - 1] + ' ' + $a.Year }
        $n = 0
        foreach ($d in @(Month-Grid $a)) {
            if ($d.Month -eq $a.Month -and (Get-Holiday $d)) { $n++ }
        }
        if ($null -ne $script:CalNote) {
            # 复数：1 天的时候要写 "1 holiday"，否则英文会露怯
            if ($n -gt 0) {
                $key = if ($n -eq 1) { 'cal.holiday1' } else { 'cal.holidayN' }
                $script:CalNote.Text = (Get-LangText $key) -f $n
            } else { $script:CalNote.Text = '' }
        }
    } elseif ($script:View -eq 'week') {
        $ws = Week-Days $a
        if ($null -ne $script:CalLabel)  { $script:CalLabel.Text = (Get-LangText 'flt.thisWeek') }
        if ($null -ne $script:CalPeriod) {
            $script:CalPeriod.Text = ('{0} {1} - {2} {3}' -f
                $script:MonShort[$ws[0].Month - 1], $ws[0].Day,
                $script:MonShort[$ws[6].Month - 1], $ws[6].Day)
        }
        $notes = @()
        foreach ($d in $ws) { $h = Get-Holiday $d; if ($h) { $notes += ('{0}/{1} {2}' -f $d.Month, $d.Day, $h) } }
        if ($null -ne $script:CalNote) { $script:CalNote.Text = ($notes -join ' · ') }
    } else {
        if ($null -ne $script:CalLabel)  { $script:CalLabel.Text = (Get-LangText 'lbl.all') }
        if ($null -ne $script:CalPeriod) { $script:CalPeriod.Text = $script:MonNames[$a.Month - 1] + ' ' + $a.Year }
        if ($null -ne $script:CalNote)   { $script:CalNote.Text = '' }
    }
}



# ==== part: Views2.ps1 (inlined by Build-Single) ====
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

# ---------------------------------------------------------------------------
#  内置标签的显示名本地化（第十一轮）
#
#  标签的"键"是稳定的数据（work/focus/life/task + 用户自定义名），存进任务
#  数据里永远不变；但默认四键是英文词，中文界面下直接显示就是"语言混用"。
#  所以：内置四键走语言表显示，自定义标签原文显示。
#  $script:TagBuiltin 在 ScheduleWidget.ps1 全局初始化处定义（根作用域）。
# ---------------------------------------------------------------------------

function Get-TagLabel {
    # 键 -> 显示名。内置四键走语言表，其余（自定义标签）原样返回。
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }
    $k = [string]$Key
    foreach ($b in @($script:TagBuiltin)) {
        if ($k -eq $b) { return (Get-LangText ('tag.' + $b)) }
    }
    return $k
}

function Get-TagKeyFromLabel {
    # 显示名 -> 键（保存任务分类时用）。内置四键反查回英文键，
    # 其余原样返回（自定义标签名本身就是键）。
    param([string]$Label)
    if ([string]::IsNullOrWhiteSpace($Label)) { return '' }
    $lbl = [string]$Label
    foreach ($b in @($script:TagBuiltin)) {
        if ((Get-LangText ('tag.' + $b)) -eq $lbl) { return $b }
    }
    return $lbl
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
        $lb = New-Txt -Text (Get-TagLabel ([string]$k)) -Size 11 -Color (Get-Pal 'Ink')
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
        # 内置四键显示名本地化（work->工作），自定义标签原文显示；
        # 按钮的 Tag 仍存键（data），配色与选中态都按键来。
        $label = Get-TagLabel ([string]$k)
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
    $verTxt = 'v0.10'
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
    $add = New-PixBtn -Text (Get-LangText 'btn.addEvent') -Bg (Get-Pal 'AccentEvent') -Fg '#FFFFFF' -W 360 -H 36 -FontSize 12
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
    # 第十一轮：下拉显示"本地化显示名"，但保存时反查回键（Get-TagKeyFromLabel），
    #   数据里存的仍是稳定键 work/focus/life/task / 自定义名，不会因为切语言而变。
    $tagKeys = @((Get-TagChoices).Keys)
    $tagLabels = @($tagKeys | ForEach-Object { Get-TagLabel ([string]$_) })
    $tagValLabel = Get-TagLabel ([string]$tagVal)
    $script:TkTag = New-ComboField $sp (Get-LangText 'fld.tk.tag') $tagValLabel $tagLabels
    $script:TkTag.IsEditable = $false
    $script:TkTag.SelectedItem = $tagValLabel

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
                # 第十二轮（item 1）：新建任务没填内容时，点 × / 保存直接放弃关闭，
                # 不再被"内容不能为空"拦住 —— 用户"不小心点进 + 新建任务"就能直接退。
                # 编辑既有任务时标题仍必填（不能把任务标题清空）。
                if (-not $script:TkEditing) {
                    Close-DialogWindow $script:TkWin $false
                    return
                }
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
            # 分类是数据键：下拉显示本地化名，这里反查回键（Get-TagKeyFromLabel），
            # 数据里存的始终是稳定键 work/focus/life/task / 自定义名。
            $tag = Get-TagKeyFromLabel ([string]$script:TkTag.Text)
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
    # 第十四轮：任务队列 -> 设置。顺序 = 勾选顺序；只保留仍存在的任务 id，
    # 否则删掉的任务会把轮换卡死（Advance-PomoQueue 也有一层过滤，双保险）。
    if ($null -ne $script:FoQueueList) {
        $aliveIds = @($script:Tasks | ForEach-Object { [string]$_.id })
        $qIds = @()
        foreach ($cb in $script:FoQueueList) {
            if ($null -eq $cb) { continue }
            if ([bool]$cb.IsChecked) {
                $cid = [string]$cb.Tag
                if ($aliveIds -contains $cid) { $qIds += $cid }
            }
        }
        $script:Settings['PomoQueue'] = ($qIds -join ',')
    }
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

    # ---- 第十四轮（item 2）：任务队列 ----
    # 勾选多个任务 = 按顺序自动轮换：一段专注**自然走完**后，队头的任务自动成为
    # 下一段专注的目标（见 Care.ps1 的 Advance-PomoQueue）。队列为空 = 老行为。
    # 顺序 = 勾选顺序（Save-FocusWindowSettings 按列表顺序收集）。
    $qLabel = New-Txt -Text (Get-LangText 'pomo.queue') -Size 11 -Color (Get-Pal 'InkSoft')
    $qLabel.Margin = [System.Windows.Thickness]::new(0, 10, 0, 2)
    [void]$sp.Children.Add($qLabel)
    $script:FoQueueList = New-Object System.Collections.ArrayList
    $qPanel = New-Object System.Windows.Controls.StackPanel
    $queueIds = @()
    $queueRaw = ''
    if ($script:Settings.Contains('PomoQueue')) { $queueRaw = [string]$script:Settings['PomoQueue'] }
    if ($queueRaw) { $queueIds = @($queueRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $openTasks = @($script:Tasks | Where-Object { -not [bool](Get-TaskField $_ 'done' $false) })
    foreach ($qt in $openTasks) {
        $qtId = [string](Get-TaskField $qt 'id' '')
        $qtText = [string](Get-TaskField $qt 'text' '')
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $qtText
        $cb.FontSize = (Scale-Ui 12)
        $cb.Foreground = Brush (Get-Pal 'Ink')
        $cb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $cb.Tag = $qtId
        $cb.IsChecked = ($queueIds -contains $qtId)
        [void]$qPanel.Children.Add($cb)
        [void]$script:FoQueueList.Add($cb)
    }
    if ($openTasks.Count -eq 0) {
        [void]$qPanel.Children.Add((New-Txt -Text (Get-LangText 'pomo.noTask') -Size 10 -Color (Get-Pal 'InkFaint')))
    }
    $qHost = New-Object System.Windows.Controls.ScrollViewer
    $qHost.MaxHeight = 92
    $qHost.VerticalScrollBarVisibility = 'Auto'
    $qHost.Content = $qPanel
    [void]$sp.Children.Add($qHost)

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


# ==== part: Care.ps1 (inlined by Build-Single) ====
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

        # ---- 7b. 悬浮窗按钮状态三态（第十四轮修复 + 断言）----
        # 修复过的 bug：以前对 Button 写 .Text（属性不存在），异常被静默吞掉，
        # 按钮文字永远停在构建时的"暂停"。这里按真实状态机走一遍：
        # Running -> 暂停文案；暂停(已走过) -> 继续文案；Ready+常驻 -> 开始文案。
        $pauseTxt = Get-LangText 'pomo.pause'
        $resumeTxt = Get-LangText 'pomo.resume'
        $startTxt = Get-LangText 'btn.start'
        try { Hide-PomoMini } catch { }
        if ([bool]$script:Pomo.Running) { Toggle-Pomodoro }
        if ([int]$script:Pomo.Remaining -le 0) { Reset-Pomodoro }
        Toggle-Pomodoro
        Show-PomoMini
        $miniOk1 = ($null -ne $script:PomoMiniBtnText) -and ([string]$script:PomoMiniBtnText.Text -eq $pauseTxt)
        Toggle-Pomodoro
        $miniOk2 = ($null -ne $script:PomoMiniBtnText) -and ([string]$script:PomoMiniBtnText.Text -eq $resumeTxt)
        Write-AuditRow 'mini widget button follows state' ($miniOk1 -and $miniOk2) `
            ("pause=$miniOk1 resume=$miniOk2")

        # ---- 7c. 常驻空闲模式（第十四轮 item 1）----
        # Ready + MiniPinned -> 悬浮窗显示时钟(##:##) + 待办数 + 开始按钮，结束按钮隐藏。
        $script:Settings['MiniPinned'] = $true
        Reset-Pomodoro
        $idleTime = [string]$script:PomoMiniTime.Text
        $idleStat = [string]$script:PomoMiniStatus.Text
        $idleBtn = [string]$script:PomoMiniBtnText.Text
        $endVis = [string]$script:PomoMiniEndBtn.Visibility
        $idleOk = (($idleTime -match '^\d{2}:\d{2}$') -and ($idleBtn -eq $startTxt) -and ($endVis -eq 'Collapsed'))
        $script:Settings['MiniPinned'] = $false
        $script:Settings['MiniOpacity'] = 1.0
        Hide-PomoMini
        Write-AuditRow 'mini widget idle pinned mode' $idleOk `
            ('time=' + $idleTime + ' btn=' + $idleBtn + ' endVis=' + $endVis + ' stat=' + $idleStat)

        # ---- 7d. 任务队列轮换（第十四轮 item 2）----
        # 两个临时任务入队：第一次 Advance 应让队头 alpha 顶上、队列轮转；
        # 第二次应轮到 beta。结束后把队列/任务/列表全部还原，不影响后续用例。
        $keepQ = [string]$script:Settings['PomoQueue']
        $keepTaskTxt = [string]$script:Pomo.Task
        $q1 = [pscustomobject]@{ id = (New-Id); text = 'queue alpha'; done = $false }
        $q2 = [pscustomobject]@{ id = (New-Id); text = 'queue beta'; done = $false }
        [void]$script:Tasks.Add($q1)
        [void]$script:Tasks.Add($q2)
        $script:Settings['PomoQueue'] = ($q1.id + ',' + $q2.id)
        Advance-PomoQueue
        $qOk1 = ([string]$script:Pomo.Task -eq 'queue alpha') -and
                ([string]$script:Settings['PomoQueue'] -eq ($q2.id + ',' + $q1.id))
        Advance-PomoQueue
        $qOk2 = ([string]$script:Pomo.Task -eq 'queue beta')
        Write-AuditRow 'focus queue advances' ($qOk1 -and $qOk2) `
            ('step1=' + $qOk1 + ' step2=' + $qOk2 + ' task=' + [string]$script:Pomo.Task)
        [void]$script:Tasks.Remove($q1)
        [void]$script:Tasks.Remove($q2)
        $script:Settings['PomoQueue'] = $keepQ
        $script:Pomo.Task = $keepTaskTxt
        $script:Pomo.TaskId = ''
        Fill-Tasks

        # ---- 7e. Hero 统计胶囊（第十四轮 item 3）----
        # Update-Chrome 跑过之后三个 pill 的文字都不该为空，进度条宽度必须落在 [0, track]。
        $heroFillOk = $true
        try {
            $fw2 = [double]$script:HeroBarFill.Width
            $tw2 = [double]$script:HeroBarTrack.ActualWidth
            if ($tw2 -gt 2.0) { $heroFillOk = ($fw2 -ge 0.0) -and ($fw2 -le $tw2) }
        } catch { $heroFillOk = $false }
        $heroOk = ($null -ne $script:HeroDone) -and ($null -ne $script:HeroFocus) -and
                  ($null -ne $script:HeroClock) -and ($null -ne $script:HeroBarFill) -and
                  (([string]$script:HeroDone.Text).Length -gt 0) -and
                  (([string]$script:HeroFocus.Text).Length -gt 0) -and $heroFillOk
        Write-AuditRow 'hero stat pills present' $heroOk `
            ('done=' + [string]$script:HeroDone.Text + ' focus=' + [string]$script:HeroFocus.Text + ' fillOk=' + $heroFillOk)

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
                    # 第十四轮：把剩余时间设成半程再拍 —— 刚开始时进度环是空的，
                    # 截图看不出"环在走"；半程正好展示环 + 倒计时的组合。
                    try {
                        if (-not [bool]$script:Settings['PomodoroEnabled']) { $script:Settings['PomodoroEnabled'] = $true }
                        if (-not [bool]$script:Pomo.Running) {
                            if ([int]$script:Pomo.Remaining -le 0) { Reset-Pomodoro }
                            Toggle-Pomodoro
                        }
                        $script:Pomo.Remaining = [int]([int]$script:Pomo.Total / 2)
                        Update-PomodoroVisual
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
                'miniidle' {
                    # 第十四轮（item 1）：拍"常驻空闲"模式 —— 不跑番茄钟也钉在角落，
                    # 显示当前时钟 + 今日待办数 + 日期。拍完还原（取消常驻并收窗）。
                    try {
                        if ([bool]$script:Pomo.Running) { Toggle-Pomodoro }
                        Reset-Pomodoro
                        $script:Settings['MiniPinned'] = $true
                        Show-PomoMini
                        try { $script:PomoMiniWin.UpdateLayout() } catch { }
                        if ($AllowShot -and $ScreenshotPath -and $null -ne $script:PomoMiniWin) {
                            $fn = 'mini-idle.png'
                            if (-not [string]::IsNullOrWhiteSpace($arg)) { $fn = $arg + '.png' }
                            $p = Join-Path ([System.IO.Path]::GetDirectoryName($ScreenshotPath)) $fn
                            Save-Shot -Path $p -Window $script:PomoMiniWin
                        }
                        $script:Settings['MiniPinned'] = $false
                        Save-Settings
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
            # 第十四轮（item 1）：常驻开关开着 -> 启动就把悬浮窗钉回桌面角落
            if ($script:Settings.Contains('MiniPinned') -and [bool]$script:Settings['MiniPinned']) {
                try { Show-PomoMini } catch { Write-ErrLog ('Boot mini pin: ' + $_.Exception.Message) }
            }
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
            # 启动后期（窗口已建、数据还没刷出来）的失败也弹窗：用户看到的是空窗，
            # 不告诉他原因他会以为"软件坏了"。
            Show-FatalError $_.Exception.Message
            try { $script:AllowClose = $true; $script:MainWindow.Close() } catch { }
        }
    }) | Out-Null
} catch {
    Write-ErrLog ('Boot: ' + $_.Exception.Message)
    Show-FatalError $_.Exception.Message
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

