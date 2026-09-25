param([string]$Tag = 'trc', [int]$AutoClose = 3, [string]$ScriptSpec = 'audit')
$ErrorActionPreference = 'Continue'
$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$stamp = (Get-Date).ToString('HHmmss') + '-' + (Get-Random -Minimum 100 -Maximum 999)
$runTag = $Tag + '__' + $stamp
$dataDir = Join-Path $root ('verification\rundata\' + $runTag)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$log = New-Object System.Collections.Generic.List[string]
$log.Add('tag = ' + $runTag)
try {
    $appSrc = [System.IO.File]::ReadAllText((Join-Path $root 'ScheduleWidget.ps1'), [System.Text.Encoding]::UTF8)
    Push-Location -LiteralPath $root
    try {
        & ([scriptblock]::Create($appSrc)) -TestMode -DataDir $dataDir -Script $ScriptSpec -AutoCloseSeconds $AutoClose -Trace
    } finally { Pop-Location }
} catch { $log.Add('CATCH :: ' + $_.Exception.Message) }
$log.Add('--- errors.log (trace) ---')
$ep = Join-Path $dataDir 'errors.log'
if (Test-Path -LiteralPath $ep) {
    foreach ($ln in ([System.IO.File]::ReadAllText($ep, [System.Text.Encoding]::UTF8) -split "`r?`n")) {
        if ($ln.Trim()) { $log.Add('  ' + $ln.Trim()) }
    }
} else { $log.Add('  (missing)') }
$log.Add('--- bootlog ---')
$bp = Join-Path $dataDir 'bootlog.txt'
if (Test-Path -LiteralPath $bp) { $log.Add([System.IO.File]::ReadAllText($bp, [System.Text.Encoding]::UTF8)) }
else { $log.Add('  (missing)') }
[System.IO.File]::WriteAllText((Join-Path $root ('verification\_' + $runTag + '.txt')), ($log -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
