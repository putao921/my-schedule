param([string]$Tag = 'aud', [int]$AutoClose = 3)
$ErrorActionPreference = 'Continue'
$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$stamp = (Get-Date).ToString('HHmmss') + '-' + (Get-Random -Minimum 100 -Maximum 999)
$runTag = $Tag + '__' + $stamp
$dataDir = Join-Path $root ('verification\rundata\' + $runTag)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

$log = New-Object System.Collections.Generic.List[string]
$log.Add('tag    = ' + $runTag)
$log.Add('start  = ' + (Get-Date).ToString('HH:mm:ss.fff'))
$t0 = Get-Date
try {
    $appSrc = [System.IO.File]::ReadAllText((Join-Path $root 'ScheduleWidget.ps1'), [System.Text.Encoding]::UTF8)
    $appSb = [scriptblock]::Create($appSrc)
    Push-Location -LiteralPath $root
    try {
        & $appSb -TestMode -DataDir $dataDir -Script 'audit' -AutoCloseSeconds $AutoClose
    } finally { Pop-Location }
    $log.Add('returned = ' + (Get-Date).ToString('HH:mm:ss.fff'))
} catch {
    $log.Add('CATCH :: ' + $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message)
    $log.Add('  line : ' + $(try { $_.InvocationInfo.ScriptLineNumber } catch { '?' }))
}
$log.Add('elapsed  = ' + [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) + 's')

foreach ($f in @('audit.txt', 'errors.log', 'bootlog.txt')) {
    $p = Join-Path $dataDir $f
    $log.Add('--- ' + $f + ' ---')
    if (Test-Path -LiteralPath $p) {
        $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { $log.Add('(empty)') }
        else { foreach ($ln in ($raw -split "`r?`n")) { if ($ln.Trim()) { $log.Add('  ' + $ln.Trim()) } } }
    } else { $log.Add('  (missing)') }
}

Add-Content -LiteralPath (Join-Path $root 'verification\shots-log.txt') -Value ("`r`n===== AUDIT " + $runTag + " =====")
Add-Content -LiteralPath (Join-Path $root 'verification\shots-log.txt') -Value ($log -join "`r`n")
[System.IO.File]::WriteAllText((Join-Path $root ('verification\_' + $runTag + '.txt')), ($log -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
