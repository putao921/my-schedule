param([string]$Tag = 'shots8', [int]$AutoClose = 2, [string]$Size = '1080x720')
$ErrorActionPreference = 'Continue'
$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$stamp = (Get-Date).ToString('HHmmss') + '-' + (Get-Random -Minimum 100 -Maximum 999)
$runTag = $Tag + '__' + $stamp
$dataDir = Join-Path $root ('verification\rundata\' + $runTag)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$shotDir = Join-Path $root 'shots'
if (-not (Test-Path -LiteralPath $shotDir)) { New-Item -ItemType Directory -Force -Path $shotDir | Out-Null }
$shot = Join-Path $shotDir ($runTag + '.png')

# 本轮（r4）截图覆盖点：
#   ① 窗口拉高时侧栏与周视图是否填满（"底部一大片空白"的修复）
#   ② 月视图首尾空位是否用浅色日期格补齐
#   ③ 新的 Tasks 独立视图（含功能按键）
#   ④ Focus 弹窗可拖动（位置记忆）
$today = (Get-Date).ToString('yyyy-MM-dd')
$anchorBack = 'anchor:' + $today
$spec = @(
    # --- 高大窗口：侧栏 + 周视图自适应 ---
    'size:1200x820', 'layout', 'view:week', 'weekrange:8-20', 'tick',
    'shot:r4-tall-week-0820',
    'view:list', 'tick', 'shot:r4-tall-list',
    # --- 月视图补齐格（9 月首尾有空格；2027-02 一格不差）---
    'size:1080x720', 'layout', 'view:month', $anchorBack, 'tick',
    'shot:r4-month-pad',
    'anchor:2027-02-01', 'tick', 'shot:r4-month-nopad',
    'anchor:2026-08-01', 'tick', 'shot:r4-month-aug',
    $anchorBack, 'tick',
    # --- Tasks 独立视图 ---
    'view:tasks', 'tick', 'shot:r4-tasks-light',
    'theme:night', 'tick', 'shot:r4-tasks-night',
    'theme:light', 'tick',
    # --- 其它视图回归 ---
    'view:list', 'tick', 'shot:r4-list-noaside',
    'view:month', 'tick', 'shot:r4-month-light',
    'size:820x620', 'layout', 'view:tasks', 'tick', 'shot:r4-tasks-narrow',
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
