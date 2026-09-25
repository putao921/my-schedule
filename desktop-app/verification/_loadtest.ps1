$h    = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$out  = "$h\verification\_loadtest.txt"
$log  = New-Object System.Collections.Generic.List[string]
foreach ($part in @('Ui.ps1', 'Views.ps1', 'Views2.ps1', 'Care.ps1')) {
    $p = Join-Path $h $part
    $log.Add('=== ' + $part)
    try {
        $src = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
        $log.Add('  read OK, chars=' + $src.Length)
        $sb = [scriptblock]::Create($src)
        $log.Add('  scriptblock create OK')
    } catch {
        $log.Add('  THREW: ' + $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message)
        $log.Add('  line: ' + $(try { $_.InvocationInfo.ScriptLineNumber } catch { '?' }))
        $log.Add('  text: ' + $(try { $_.InvocationInfo.Line.Trim() } catch { '?' }))
    }
}
[IO.File]::WriteAllText($out, ($log -join "`r`n"), [Text.UTF8Encoding]::new($false))
