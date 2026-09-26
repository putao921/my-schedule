param([string]$Tag = 'r13shots', [int]$AutoClose = 2, [string]$Size = '1200x820')
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
# 第十三轮截图覆盖点（第三十九节）：
#  ① 番茄钟迷你悬浮窗（新增 结束并统计 / 退出 两个按钮）
#  ② 任务视图主窗（专注/+1/▾ 按钮字号与正文一致）
# ASCII only in messages: PS 5.1 reads non-BOM files as GBK.
# ---------------------------------------------------------------------------
$spec = @(
    'size:1200x820',
    'minishot:r13-pomo-mini',
    'view:tasks', 'layout', 'shot:r13-tasks-actions'
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
$shots = @(Get-ChildItem -LiteralPath $shotDir -Filter 'r13-*.png' | Sort-Object Name)
$log.Add('--- png count ---')
$log.Add('  ' + $shots.Count + ' r13 files in shots/')
[System.IO.File]::WriteAllText((Join-Path $root ('verification\_' + $runTag + '.txt')),
    ($log -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
