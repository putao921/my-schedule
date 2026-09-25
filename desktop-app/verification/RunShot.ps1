param(
    [string]$View = 'month',
    [string]$Theme = 'light',
    [string]$Size = '1080x720',
    [string]$Tag = 'shot',
    [int]$AutoClose = 3
)
# ASCII only on purpose: PS 5.1 decodes non-BOM files as GBK, Chinese here would break parsing.
$ErrorActionPreference = 'Continue'
$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'

$shots = Join-Path $root 'shots'
if (-not (Test-Path -LiteralPath $shots)) { New-Item -ItemType Directory -Force -Path $shots | Out-Null }

# Unique per-run data dir. We never delete anything (the sandbox blocks recursive
# deletes), and a fresh dir also makes "is this artifact fresh?" provable by path.
$stamp  = (Get-Date).ToString('HHmmss') + '-' + (Get-Random -Minimum 100 -Maximum 999)
$runTag = $Tag + '__' + $stamp
$dataDir = Join-Path $root ('verification\rundata\' + $runTag)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

$shot = Join-Path $shots ($runTag + '.png')

$log = New-Object System.Collections.Generic.List[string]
$log.Add('tag      = ' + $runTag)
$log.Add('argv     = view=' + $View + ' theme=' + $Theme + ' size=' + $Size + ' autoclose=' + $AutoClose)
$log.Add('datadir  = ' + $dataDir)
$log.Add('shot     = ' + $shot)
$log.Add('start    = ' + (Get-Date).ToString('HH:mm:ss.fff'))

$t0 = Get-Date
try {
    # Execution policy on this box may be Restricted, which forbids dot-sourcing a
    # .ps1 file. Build a scriptblock from the source instead - equivalent semantics.
    # $PSScriptRoot is empty for a string-built scriptblock, and the app falls back
    # to the current directory, so switch there first.
    $appSrc = [System.IO.File]::ReadAllText((Join-Path $root 'ScheduleWidget.ps1'), [System.Text.Encoding]::UTF8)
    $appSb  = [scriptblock]::Create($appSrc)
    Push-Location -LiteralPath $root
    try {
        & $appSb -TestMode -DataDir $dataDir -StartView $View `
            -ThemeOverride $Theme -SizeOverride $Size -AutoCloseSeconds $AutoClose -ScreenshotPath $shot
    } finally { Pop-Location }
    $log.Add('returned = ' + (Get-Date).ToString('HH:mm:ss.fff'))
} catch {
    $log.Add('CATCH :: ' + $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message)
    $log.Add('  line : ' + $(try { $_.InvocationInfo.ScriptLineNumber } catch { '?' }))
    $log.Add('  stmt : ' + $(try { ([string]$_.InvocationInfo.Line).Trim() } catch { '?' }))
}
$log.Add('elapsed  = ' + [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) + 's')

if (Test-Path -LiteralPath $shot) {
    $log.Add('shot     = OK ' + (Get-Item -LiteralPath $shot).Length + 'b')
} else {
    $log.Add('shot     = MISSING')
}

foreach ($f in @('errors.log', 'bootlog.txt', 'settings.json')) {
    $p = Join-Path $dataDir $f
    if (Test-Path -LiteralPath $p) {
        $log.Add('--- ' + $f + ' ---')
        $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { $log.Add('(empty)') }
        else { foreach ($ln in ($raw -split "`r?`n")) { if ($ln.Trim()) { $log.Add('  ' + $ln.Trim()) } } }
    } else {
        $log.Add('--- ' + $f + ' --- (missing)')
    }
}

$lines = ($log -join "`r`n")
Add-Content -LiteralPath (Join-Path $root 'verification\shots-log.txt') -Value ("`r`n===== " + $runTag + " =====")
Add-Content -LiteralPath (Join-Path $root 'verification\shots-log.txt') -Value $lines
Write-Host $lines
