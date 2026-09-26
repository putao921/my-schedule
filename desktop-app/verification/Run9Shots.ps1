param([string]$Tag = 'r9shots', [int]$AutoClose = 2, [string]$Size = '1200x820')
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
#  第九轮截图覆盖点（第三十二节 1/2/4）：
#   ① 任务视图：标题 13px 层级（第 1 条）
#   ② 设置窗-外观页：新增 medium 档位（第 2 条）
#   ③ Focus 窗：混排基线 + 快捷 chip（第 4 条）
#  ASCII only in messages: PS 5.1 reads non-BOM files as GBK.
# ---------------------------------------------------------------------------
$spec = @(
    'size:1200x820',
    'view:tasks', 'layout', 'shot:r9-tasks-hierarchy',
    'view:month', 'layout',
    'settingstabshot:appear|r9-settings-medium',
    'focusshot:r9-focus-baseline'
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
$shots = @(Get-ChildItem -LiteralPath $shotDir -Filter 'r9-*.png' | Sort-Object Name)
$log.Add('--- png count ---')
$log.Add('  ' + $shots.Count + ' r9 files in shots/')
[System.IO.File]::WriteAllText((Join-Path $root ('verification\_' + $runTag + '.txt')),
    ($log -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
