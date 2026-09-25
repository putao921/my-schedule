$h    = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification'
$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$dbg  = New-Object System.Collections.Generic.List[string]
try {
    $sb = [scriptblock]::Create([IO.File]::ReadAllText("$h\RunAudit.ps1", [Text.Encoding]::UTF8))
    & $sb -Tag 'r9b' -AutoClose 0
    $dbg.Add('RunAudit returned normally')
} catch {
    $dbg.Add('WRAPPER CAUGHT: ' + $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message)
    $dbg.Add('  line: ' + $(try { $_.InvocationInfo.ScriptLineNumber } catch { '?' }))
    $dbg.Add('  pos : ' + $(try { $_.InvocationInfo.PositionMessage } catch { '?' }))
}
$dbg.Add('host exit-ish; checking latest rundata')
$dirs = Get-ChildItem "$root\verification\rundata" -Directory | Sort-Object LastWriteTime -Descending
if ($dirs.Count -gt 0) {
    $d = $dirs[0].FullName
    $dbg.Add('latest = ' + $dirs[0].Name)
    foreach ($f in @('audit.txt', 'errors.log')) {
        $p = Join-Path $d $f
        $dbg.Add('--- ' + $f + ' exists=' + (Test-Path $p))
        if (Test-Path $p) {
            $raw = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
            $dbg.Add('  bytes=' + $raw.Length)
        }
    }
}
[IO.File]::WriteAllText("$h\_dbg9.txt", ($dbg -join "`r`n"), [Text.UTF8Encoding]::new($false))
