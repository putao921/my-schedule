$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework | Out-Null
Add-Type -AssemblyName PresentationCore | Out-Null
Add-Type -AssemblyName WindowsBase | Out-Null

$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$dataDir = Join-Path $root 'verification\probe-appdata'
if (Test-Path -LiteralPath $dataDir) { Remove-Item -LiteralPath $dataDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

$o = New-Object System.Collections.ArrayList
try {
    . (Join-Path $root 'ScheduleWidget.ps1') -TestMode -DataDir $dataDir -AutoCloseSeconds 3 2>&1 |
        ForEach-Object { [void]$o.Add('OUT: ' + [string]$_) }
} catch {
    [void]$o.Add('CATCH: ' + $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message)
    [void]$o.Add('  at line ' + $(try { $_.InvocationInfo.ScriptLineNumber } catch { '?' }))
    [void]$o.Add('  stmt: ' + $(try { ([string]$_.InvocationInfo.Line).Trim() } catch { '?' }))
    [void]$o.Add('  stack: ' + $(try { [string]$_.ScriptStackTrace } catch { '?' }))
}
[void]$o.Add('--- errors.log ---')
$e = Join-Path $dataDir 'errors.log'
if (Test-Path -LiteralPath $e) { [void]$o.Add((Get-Content -LiteralPath $e -Raw -Encoding UTF8)) } else { [void]$o.Add('(none)') }
[void]$o.Add('--- files ---')
Get-ChildItem $dataDir -Force | ForEach-Object { [void]$o.Add($_.Name + ' ' + $_.Length + 'b') }
($o -join "`n") | Set-Content -LiteralPath (Join-Path $root 'verification\probe-out.txt') -Encoding UTF8
