param([string]$Tag = 'shots6', [int]$AutoClose = 2, [string]$Size = '1080x720')
$ErrorActionPreference = 'Continue'
$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$stamp = (Get-Date).ToString('HHmmss') + '-' + (Get-Random -Minimum 100 -Maximum 999)
$runTag = $Tag + '__' + $stamp
$dataDir = Join-Path $root ('verification\rundata\' + $runTag)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$shotDir = Join-Path $root 'shots'
if (-not (Test-Path -LiteralPath $shotDir)) { New-Item -ItemType Directory -Force -Path $shotDir | Out-Null }
$shot = Join-Path $shotDir ($runTag + '.png')

# 一次运行拍完 6 张：WPF 一个进程只能 Run 一个 Application，
# 所以靠脚本串起来，而不是跑 6 个进程。
$spec = @(
    'view:month', 'tick', 'shot:month-light',
    'theme:night', 'view:month', 'tick', 'shot:month-night',
    'theme:light', 'view:week', 'tick', 'shot:week-light',
    'theme:night', 'view:week', 'tick', 'shot:week-night',
    'theme:light', 'view:list', 'tick', 'shot:list-light',
    'theme:night', 'view:list', 'tick', 'shot:list-night'
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
[System.IO.File]::WriteAllText((Join-Path $root ('verification\_' + $runTag + '.txt')), ($log -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
