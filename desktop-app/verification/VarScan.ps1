$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$L = New-Object System.Collections.Generic.List[string]
$L.Add('now ' + (Get-Date).ToString('HH:mm:ss'))
try {
    $main = [System.IO.File]::ReadAllText((Join-Path $root 'ScheduleWidget.ps1'), [System.Text.Encoding]::UTF8)
    $L.Add('main len ' + $main.Length)
    $ui   = [System.IO.File]::ReadAllText((Join-Path $root 'Ui.ps1'), [System.Text.Encoding]::UTF8)
    $L.Add('ui len ' + $ui.Length)
    $v1   = [System.IO.File]::ReadAllText((Join-Path $root 'Views.ps1'), [System.Text.Encoding]::UTF8)
    $L.Add('v1 len ' + $v1.Length)
    $v2   = [System.IO.File]::ReadAllText((Join-Path $root 'Views2.ps1'), [System.Text.Encoding]::UTF8)
    $L.Add('v2 len ' + $v2.Length)
    $care = [System.IO.File]::ReadAllText((Join-Path $root 'Care.ps1'), [System.Text.Encoding]::UTF8)
    $L.Add('care len ' + $care.Length)
} catch {
    $L.Add('READ FAIL: ' + $_.Exception.Message)
    [System.IO.File]::WriteAllText((Join-Path $root 'verification\_vars2.txt'), ($L -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    return
}

function Names {
    param([string]$Text)
    $r = [regex]::Matches($Text, '\$script:([A-Za-z_][A-Za-z0-9_]*)')
    $s = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($m in $r) { [void]$s.Add($m.Groups[1].Value) }
    return $s
}

# 所有被读到的名字
$all = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($t in @($main, $ui, $v1, $v2, $care)) {
    foreach ($n in (Names $t)) { [void]$all.Add($n) }
}
$L.Add('')
$L.Add('全部 $script: 名字总数: ' + $all.Count)

# ScheduleWidget.ps1 根区的赋值（含 $script:X = $null 这类显式初始化）
$init = Names $main
$L.Add('ScheduleWidget.ps1 里出现过的名字: ' + $init.Count)

# 在 Views/Views2/Ui/Care 里被赋值、但在 main 里完全没有的名字
$uiNames = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($t in @($ui, $v1, $v2, $care)) {
    foreach ($n in (Names $t)) { [void]$uiNames.Add($n) }
}
$L.Add('Ui/Views/Views2/Care 里出现过的名字: ' + $uiNames.Count)
$L.Add('')
$L.Add('=== 在界面文件里出现、但 ScheduleWidget.ps1 完全没提到的名字 ===')
$L.Add('（这些最可能在 StrictMode 下"先读后写"）')
$miss = New-Object System.Collections.Generic.List[string]
foreach ($n in $uiNames) { if (-not $init.Contains($n)) { $miss.Add($n) } }
$miss.Sort()
foreach ($n in $miss) { $L.Add('  ' + $n) }
$L.Add('  共 ' + $miss.Count + ' 个')

[System.IO.File]::WriteAllText((Join-Path $root 'verification\_vars2.txt'), ($L -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
