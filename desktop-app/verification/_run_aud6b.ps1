$ErrorActionPreference = 'Continue'
$root = 'C:/Users/lenovo/WorkBuddy/2026-09-23-15-30-45/desktop-app'
$out = New-Object System.Collections.Generic.List[string]
try {
    $p = Join-Path $root 'verification\RunAudit.ps1'
    $sb = [scriptblock]::Create([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8))
    $out.Add('sb created')
    & $sb -Tag 'r6b' -AutoClose 0
    $out.Add('runner returned')
} catch {
    $out.Add('OUTER CATCH :: ' + $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message)
    $out.Add('  at : ' + $(try { $_.InvocationInfo.PositionMessage } catch { '?' }))
}
$out.Add('exit')
[System.IO.File]::WriteAllText((Join-Path $root 'verification\_r6b_out.txt'), ($out -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
