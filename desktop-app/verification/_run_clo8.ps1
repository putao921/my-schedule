$h    = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification'
$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
try {
    $sb = [scriptblock]::Create([IO.File]::ReadAllText("$h\ClosureScan.ps1", [Text.Encoding]::UTF8))
    & $sb -Root $root
} catch {
    [IO.File]::WriteAllText("$h\_clo8_err.txt", $_.Exception.Message, [Text.UTF8Encoding]::new($false))
}
