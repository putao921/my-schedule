param([string]$Tag = 'shots9', [int]$AutoClose = 2, [string]$Size = '1200x820')
$ErrorActionPreference = 'Continue'
$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$stamp = (Get-Date).ToString('HHmmss') + '-' + (Get-Random -Minimum 100 -Maximum 999)
$runTag = $Tag + '__' + $stamp
$dataDir = Join-Path $root ('verification\rundata\' + $runTag)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$shotDir = Join-Path $root 'shots'
if (-not (Test-Path -LiteralPath $shotDir)) { New-Item -ItemType Directory -Force -Path $shotDir | Out-Null }
$shot = Join-Path $shotDir ($runTag + '.png')

# 第三轮截图覆盖点（每一条都对应一个用户提出的问题，不是"随便拍几张"）：
#   ① 双击任务 → 行内详情面板里的 Edit / Delete（用户第 1 条）
#   ② Focus 浮窗里的 Session length / Break length 能填 0-99（用户第 2 条）
#   ③ 侧栏上下不再脱节、番茄钟整块已移除（用户第 3、4 条）
#   ④ 点标题弹出的日期选择器（用户第 5 条）
#   ⑤ 四个视图的常规回归（确认前四项没把别的地方弄坏）
$today = (Get-Date).ToString('yyyy-MM-dd')
$anchorBack = 'anchor:' + $today
$spec = @(
    # --- ① Tasks 独立视图：收起态 vs 双击展开态（昼夜各一）---
    'size:1200x820', 'layout', 'view:tasks', 'tick',
    'shot:r5-tasks-collapsed',
    'dbltask:*', 'tick', 'shot:r5-task-expanded',
    'theme:night', 'tick', 'shot:r5-task-expanded-night',
    'theme:light', 'tick',
    # --- ③ 侧栏：月视图全窗口（左栏上下连续 + 已无番茄钟块）---
    'view:month', $anchorBack, 'tick', 'shot:r5-month-sidebar',
    'theme:night', 'tick', 'shot:r5-month-sidebar-night',
    'theme:light', 'tick',
    # --- ④ 日期选择器（点标题那一下弹出来的那个）---
    'pickershot:r5-period-picker',
    'theme:night', 'tick', 'pickershot:r5-period-picker-night',
    'theme:light', 'tick',
    # --- ② Focus 浮窗：0-99 的时长输入 ---
    'focusshot:r5-focus-window',
    # --- ⑤ 回归：周 / 列表 / 窄窗口 ---
    'view:week', 'weekrange:8-20', 'tick', 'shot:r5-week',
    'view:list', 'tick', 'shot:r5-list',
    'size:820x620', 'layout', 'view:tasks', 'tick', 'shot:r5-tasks-narrow',
    'dbltask:*', 'tick', 'shot:r5-task-expanded-narrow',
    'size:1200x820', 'layout', 'view:month', $anchorBack, 'tick', 'shot:r5-main-final'
) -join ','

$log = New-Object System.Collections.Generic.List[string]
$log.Add('tag     = ' + $runTag)
$log.Add('spec    = ' + $spec)
$t0 = Get-Date
try {
    $appSrc = [System.IO.File]::ReadAllText((Join-Path $root 'ScheduleWidget.ps1'), [System.Text.Encoding]::UTF8)
    Push-Location -LiteralPath $root
    try {
        & ([scriptblock]::Create($appSrc)) -TestMode -DataDir $dataDir -Script $spec `
            -AutoCloseSeconds $AutoClose -ScreenshotPath $shot -SizeOverride $Size
    } finally { Pop-Location }
} catch { $log.Add('CATCH :: ' + $_.Exception.Message) }
$log.Add('elapsed = ' + [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) + 's')
$tp = Join-Path $dataDir 'testlog.txt'
if (Test-Path -LiteralPath $tp) {
    $log.Add('--- testlog ---')
    foreach ($ln in ([System.IO.File]::ReadAllText($tp, [System.Text.Encoding]::UTF8) -split "`r?`n")) {
        if ($ln.Trim()) { $log.Add('  ' + $ln.Trim()) }
    }
}
$ep = Join-Path $dataDir 'errors.log'
$log.Add('--- errors.log ---')
if (Test-Path -LiteralPath $ep) {
    $raw = [System.IO.File]::ReadAllText($ep, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { $log.Add('(empty)') } else { $log.Add($raw) }
} else { $log.Add('(none)') }
[System.IO.File]::WriteAllText((Join-Path $root ('verification\_' + $runTag + '.txt')), ($log -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
