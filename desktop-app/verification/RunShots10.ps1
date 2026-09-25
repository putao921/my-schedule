param([string]$Tag = 'shots10', [int]$AutoClose = 2, [string]$Size = '1200x820')
$ErrorActionPreference = 'Continue'
$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$stamp = (Get-Date).ToString('HHmmss') + '-' + (Get-Random -Minimum 100 -Maximum 999)
$runTag = $Tag + '__' + $stamp
$dataDir = Join-Path $root ('verification\rundata\' + $runTag)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$shotDir = Join-Path $root 'shots'
if (-not (Test-Path -LiteralPath $shotDir)) { New-Item -ItemType Directory -Force -Path $shotDir | Out-Null }
$shot = Join-Path $shotDir ($runTag + '.png')

# ---------------------------------------------------------------------------
#  第四轮截图覆盖点（每一条都对应一个用户提出的问题）：
#   ① 事件编辑弹窗：标题栏有 Save / Cancel / × 三件套（用户第 1 条）
#   ② 任务卡双击 → 任务编辑弹窗（用户第 2 条）
#   ③ 任务卡右端 ▾ 按钮 → 行内详情面板（展开入口从双击搬到按钮）
#   ④ 设置窗口：Appearance（字号 / 主题）+ Window（置顶 / 托盘 / 周时段）（用户第 3 条）
#   ⑤ 窄窗口 vs 宽窗口：字号真的跟着变（用户第 4 条）
#  ASCII only in messages: PS 5.1 reads non-BOM files as GBK.
# ---------------------------------------------------------------------------
$today = (Get-Date).ToString('yyyy-MM-dd')
$anchorBack = 'anchor:' + $today
$spec = @(
    # --- ① 事件编辑弹窗（昼夜各一）---
    'view:month', $anchorBack, 'tick', 'eventshot:r6-event-save-cancel',
    'theme:night', 'tick', 'eventshot:r6-event-save-cancel-night',
    'theme:light', 'tick',

    # --- ④ 设置窗口：新增的 Appearance / Window 两组 ---
    'size:1200x820', 'layout', 'settingshot:r6-settings-appearance',
    'theme:night', 'tick', 'settingshot:r6-settings-appearance-night',
    'theme:light', 'tick',

    # --- ② 任务编辑弹窗（双击进的那个）---
    'view:tasks', 'tick', 'taskshot:r6-task-editor',

    # --- ③ 任务卡 ▾ 展开行内详情面板 ---
    'tick', 'caretshot:*', 'tick', 'shot:r6-task-details-expanded',
    'theme:night', 'tick', 'shot:r6-task-details-expanded-night',
    'theme:light', 'tick',

    # --- ⑤ 响应式：窄窗口（字号自动缩小）vs 宽窗口（自动放大）---
    'size:840x640', 'layout', 'view:month', $anchorBack, 'tick', 'shot:r6-narrow-scale',
    'size:1400x900', 'layout', 'view:month', $anchorBack, 'tick', 'shot:r6-wide-scale',

    # --- 回归：四视图 ---
    'size:1200x820', 'layout',
    'view:week', 'weekrange:8-20', 'tick', 'shot:r6-week',
    'view:list', 'tick', 'shot:r6-list',
    'view:tasks', 'tick', 'shot:r6-tasks',
    'view:month', $anchorBack, 'tick', 'shot:r6-month'
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
    if ([string]::IsNullOrWhiteSpace($raw)) { $log.Add('  (empty)') }
    else { foreach ($ln in ($raw -split "`r?`n")) { if ($ln.Trim()) { $log.Add('  ' + $ln.Trim()) } } }
} else { $log.Add('  (none)') }
$shots = @(Get-ChildItem -LiteralPath $shotDir -Filter '*.png' | Sort-Object Name)
$log.Add('--- png count ---')
$log.Add('  ' + $shots.Count + ' files in shots/')
[System.IO.File]::WriteAllText((Join-Path $root ('verification\_' + $runTag + '.txt')),
    ($log -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
