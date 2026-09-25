$h    = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification'
$out  = "$h\_run_result.txt"
$log  = New-Object System.Collections.Generic.List[string]
try {
    $sb = [scriptblock]::Create([IO.File]::ReadAllText("$h\RunAudit.ps1", [Text.Encoding]::UTF8))
    $log.Add('scriptblock created; invoking -Tag r11 -AutoClose 0')
    & $sb -Tag 'r11' -AutoClose 0
    $log.Add('RETURNED NORMALLY')
} catch {
    $log.Add('CAUGHT: ' + $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message)
    $log.Add('  line: ' + $(try { $_.InvocationInfo.ScriptLineNumber } catch { '?' }))
    $log.Add('  text: ' + $(try { $_.InvocationInfo.Line.Trim() } catch { '?' }))
    $log.Add('  pos : ' + $(try { $_.InvocationInfo.PositionMessage } catch { '?' }))
}
$dirs = Get-ChildItem "$h\rundata" -Directory | Sort-Object LastWriteTime -Descending
if ($dirs.Count -gt 0) {
    $log.Add('latest rundata = ' + $dirs[0].Name)
    foreach ($f in @('audit.txt', 'errors.log')) {
        $p = Join-Path $dirs[0].FullName $f
        $log.Add('  ' + $f + ' exists=' + (Test-Path $p) + ' bytes=' + $(if (Test-Path $p) { (Get-Item $p).Length } else { 0 }))
    }
}
[IO.File]::WriteAllText($out, ($log -join "`r`n"), [Text.UTF8Encoding]::new($false))
