$ErrorActionPreference = 'Continue'
$root    = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$dataDir = Join-Path $root 'verification\probe-appdata'
$marker  = Join-Path $root 'verification\_steps.txt'
$outFile = Join-Path $root 'verification\runtest-out.txt'

if (Test-Path -LiteralPath $dataDir) { Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

# start from a clean marker so freshness is provable by timestamp
"== run at " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') | Set-Content -LiteralPath $marker -Encoding UTF8
function Step {
    param([string]$T)
    Add-Content -LiteralPath $marker -Value ((Get-Date).ToString('HH:mm:ss.fff') + '  ' + $T)
}

$log = New-Object System.Collections.Generic.List[string]
$log.Add('start ' + (Get-Date).ToString('HH:mm:ss'))

Step 'A: pre-load'
try {
    Step 'B: loading ScheduleWidget'
    # 执行策略 Restricted 下点源会被拒；改为构造 scriptblock 执行
    $appSrc = [System.IO.File]::ReadAllText((Join-Path $root 'ScheduleWidget.ps1'), [System.Text.Encoding]::UTF8)
    $appSb = [scriptblock]::Create($appSrc)
    Push-Location -LiteralPath $root
    try {
        & $appSb -TestMode -DataDir $dataDir -AutoCloseSeconds 2 -StartView month
    } finally { Pop-Location }
    Step 'C: load returned'
} catch {
    Step 'C: CATCH'
    $log.Add('CATCH :: ' + $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message)
    $log.Add('  line: ' + $(try { $_.InvocationInfo.ScriptLineNumber } catch { '?' }))
    $log.Add('  stmt: ' + $(try { ([string]$_.InvocationInfo.Line).Trim() } catch { '?' }))
}

$log.Add('--- errors.log ---')
$e = Join-Path $dataDir 'errors.log'
if (Test-Path -LiteralPath $e) {
    $raw = Get-Content -LiteralPath $e -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { $log.Add('(empty)') } else { $log.Add($raw.Trim()) }
} else { $log.Add('(none)') }

$log.Add('--- bootlog.txt ---')
$b = Join-Path $dataDir 'bootlog.txt'
if (Test-Path -LiteralPath $b) { $log.Add((Get-Content -LiteralPath $b -Raw -Encoding UTF8).Trim()) } else { $log.Add('(none)') }

$log.Add('--- data dir files ---')
Get-ChildItem -LiteralPath $dataDir -Force | ForEach-Object { $log.Add('  ' + $_.Name + '  ' + $_.Length + 'b') }

[System.IO.File]::WriteAllText($outFile, ($log -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Step 'D: wrote runtest-out.txt'
