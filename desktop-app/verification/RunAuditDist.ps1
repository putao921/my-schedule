# ---------------------------------------------------------------------------
#  RunAuditDist - 对 dist 交付包副本跑同一套运行时审计
#
#  为什么要单独一个脚本：RunAudit.ps1 里 $root 是写死的（源码目录），
#  而 dist\MySchedule 下没有 verification 目录，报告得写回源码侧的
#  verification，不能污染交付包。其余逻辑与 RunAudit.ps1 完全一致。
#
#  ASCII only in messages: PS 5.1 reads non-BOM files as GBK.
# ---------------------------------------------------------------------------
param([string]$Tag = 'dist', [int]$AutoClose = 3)
$ErrorActionPreference = 'Continue'
$srcRoot = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$root    = Join-Path $srcRoot 'dist\MySchedule'
$stamp = (Get-Date).ToString('HHmmss') + '-' + (Get-Random -Minimum 100 -Maximum 999)
$runTag = $Tag + '__' + $stamp
$dataDir = Join-Path $srcRoot ('verification\rundata\' + $runTag)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

$log = New-Object System.Collections.Generic.List[string]
$log.Add('root   = ' + $root)
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

$repDir = Join-Path $srcRoot 'verification'
[System.IO.File]::WriteAllText((Join-Path $repDir ('_' + $runTag + '.txt')), ($log -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
