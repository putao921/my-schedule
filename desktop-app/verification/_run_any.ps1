param([string]$Script = 'RunAudit.ps1', [string]$Tag = 'x')
$h    = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification'
$out  = "$h\_${Tag}_result.txt"
$log  = New-Object System.Collections.Generic.List[string]
try {
    $sb = [scriptblock]::Create([IO.File]::ReadAllText("$h\$Script", [Text.Encoding]::UTF8))
    $log.Add("invoking $Script -Tag $Tag")
    & $sb -Tag $Tag -AutoClose 3
    $log.Add('RETURNED NORMALLY')
} catch {
    $log.Add('CAUGHT: ' + $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message)
}
$dirs = Get-ChildItem "$h\rundata" -Directory | Sort-Object LastWriteTime -Descending
if ($dirs.Count -gt 0) {
    $log.Add('latest rundata = ' + $dirs[0].Name)
    $ap = Join-Path $dirs[0].FullName 'audit.txt'
    if (Test-Path $ap) {
        $rows = @([IO.File]::ReadAllLines($ap, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() })
        $log.Add('AUDIT pass=' + @($rows | Where-Object { $_ -match '^\s*PASS' }).Count +
                 ' fail=' + @($rows | Where-Object { $_ -match '^\s*FAIL' }).Count)
        foreach ($r in @($rows | Where-Object { $_ -match '^\s*FAIL' })) { $log.Add('  ' + $r.Trim()) }
    }
    $p = Join-Path $dirs[0].FullName 'errors.log'
    $log.Add('--- errors.log ---')
    if (Test-Path $p) {
        foreach ($ln in ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) -split "`r?`n")) {
            if ($ln.Trim()) { $log.Add('  ' + $ln.Trim()) }
        }
    } else { $log.Add('  (missing)') }
}
[IO.File]::WriteAllText($out, ($log -join "`r`n"), [Text.UTF8Encoding]::new($false))
