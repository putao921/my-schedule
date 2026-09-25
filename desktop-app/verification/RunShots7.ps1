param([string]$Tag = 'shots7', [int]$AutoClose = 2, [string]$Size = '1080x720')
$ErrorActionPreference = 'Continue'
$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$stamp = (Get-Date).ToString('HHmmss') + '-' + (Get-Random -Minimum 100 -Maximum 999)
$runTag = $Tag + '__' + $stamp
$dataDir = Join-Path $root ('verification\rundata\' + $runTag)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$shotDir = Join-Path $root 'shots'
if (-not (Test-Path -LiteralPath $shotDir)) { New-Item -ItemType Directory -Force -Path $shotDir | Out-Null }
$shot = Join-Path $shotDir ($runTag + '.png')

# 一次运行拍完：主题切换必须 -Sync 重建（WPF 一个进程只能 Run 一个 Application）。
# 覆盖点 = 本轮改动：弹窗右上角 ×、月视图每页只画本月（4/5/6 行三种）、任务卡新版式。
$today = (Get-Date).ToString('yyyy-MM-dd')
# 注意：不要写 'anchor:' + $today 直接塞进 @(...) —— 逗号会把拼接表达式再切一刀，
# 结果 spec 里冒出 "anchor:" 和 "2026-09-24" 两个动作，锚点根本回不到今天。
$anchorBack = 'anchor:' + $today
$spec = @(
    'view:month', 'tick', 'shot:r3-month-light',
    'anchor:2027-02-01', 'tick', 'shot:r3-month-feb-4rows',
    'anchor:2026-08-01', 'tick', 'shot:r3-month-aug-6rows',
    $anchorBack, 'tick', 'shot:r3-month-back-today',
    'theme:night', 'view:month', 'tick', 'shot:r3-month-night',
    'theme:light', 'view:list', 'tick', 'shot:r3-list-tasks',
    'theme:night', 'view:list', 'tick', 'shot:r3-list-tasks-night',
    'theme:light',
    'eventshot:r3-dialog-event-light', 'tick',
    'taskshot:r3-dialog-task-light', 'tick',
    'focusshot:r3-dialog-focus-light', 'tick',
    'theme:night', 'tick', 'eventshot:r3-dialog-event-night', 'tick',
    'taskshot:r3-dialog-task-night', 'tick',
    'theme:light', 'tick',
    'view:week', 'weekrange:8-20', 'tick', 'shot:r3-week-0820',
    'weekrange:0-24',
    'size:820x620', 'layout', 'tick', 'view:list', 'tick', 'shot:r3-narrow-list',
    'size:1080x720', 'layout', 'view:month', 'tick'
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
$log.Add('--- shots in ' + $shotDir + ' ---')
foreach ($p in @(Get-ChildItem -Path $shotDir -Filter '*.png' | Sort-Object LastWriteTime)) {
    $log.Add('  ' + $p.Name + '  ' + $p.Length + 'b')
}
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
