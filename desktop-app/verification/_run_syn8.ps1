$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$p = Join-Path $root 'verification\SyntaxCheck.ps1'
$rep = Join-Path $root 'verification\_syn8.txt'
$sb = [scriptblock]::Create([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8))
& $sb -Report $rep
