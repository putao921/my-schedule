$ErrorActionPreference = 'Continue'
$root  = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$files = @('ScheduleWidget.ps1','Ui.ps1','Views.ps1','Views2.ps1','Care.ps1')

# ---- 1. 收集所有函数定义的行区间（AST，只取区间，不做递归遍历） ----
$fnRanges = @{}          # file -> list of @(start,end)
foreach ($f in $files) {
    $p = Join-Path $root $f
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors)
    $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $ranges = New-Object System.Collections.Generic.List[object]
    foreach ($fn in $fns) {
        $ranges.Add([pscustomobject]@{ S = $fn.Extent.StartLineNumber; E = $fn.Extent.EndLineNumber })
    }
    $fnRanges[$f] = $ranges
}

function Test-InFn {
    param([string]$File, [int]$Line)
    if (-not $fnRanges.ContainsKey($File)) { return $false }
    foreach ($r in $fnRanges[$File]) {
        if ($Line -ge $r.S -and $Line -le $r.E) { return $true }
    }
    return $false
}

# ---- 2. 按行扫描 $script:NAME ----
$topAssign = @{}    # name -> list "file:line"
$fnAssign  = @{}
$reads     = @{}

foreach ($f in $files) {
    $p = Join-Path $root $f
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($p)) {
        $n++
        $inFn = Test-InFn $f $n
        # 赋值：  $script:NAME =   （排除 ==, -eq 等比较）
        foreach ($m in [regex]::Matches($line, '\$script:([A-Za-z_][A-Za-z0-9_]*)\s*(?<op>=|\+=|-=)\s')) {
            $name = $m.Groups[1].Value
            $tbl = if ($inFn) { $fnAssign } else { $topAssign }
            if (-not $tbl.ContainsKey($name)) { $tbl[$name] = New-Object System.Collections.Generic.List[string] }
            $tbl[$name].Add("$f`:$n")
        }
        # 读取：所有 $script:NAME 出现处（含赋值行，后面会剔除纯赋值）
        foreach ($m in [regex]::Matches($line, '\$script:([A-Za-z_][A-Za-z0-9_]*)')) {
            $name = $m.Groups[1].Value
            if (-not $reads.ContainsKey($name)) { $reads[$name] = New-Object System.Collections.Generic.List[string] }
            $reads[$name].Add("$f`:$n")
        }
    }
}

$L = New-Object System.Collections.Generic.List[string]
$L.Add('根作用域赋值变量: ' + @($topAssign.Keys).Count + ' 个')
$L.Add('仅函数体内赋值变量: ' + @($fnAssign.Keys).Count + ' 个')
$L.Add('')
$L.Add('=== 风险：仅在函数体内赋值（读它可能先于赋值） ===')
$onlyFn = @($fnAssign.Keys | Sort-Object | Where-Object { -not $topAssign.ContainsKey($_) })
if ($onlyFn.Count -eq 0) { $L.Add('  (无)') }
foreach ($k in $onlyFn) {
    $L.Add(("  `$script:{0}" -f $k))
    $L.Add(('      赋值点: ' + (@($fnAssign[$k]) -join ', ')))
    $rd = @($reads[$k] | Where-Object { $_ -notmatch ('^' + [regex]::Escape($k)) })
    $L.Add(('      读取点: ' + (@($reads[$k]) -join ', ')))
}
$L.Add('')
$L.Add('=== 仅根作用域初始化、函数内读取的（安全，仅列出便于核对） ===')
$L.Add('  共 ' + @($topAssign.Keys).Count + ' 个，略')

[System.IO.File]::WriteAllText((Join-Path $root 'verification\_vars.txt'), ($L -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
'DONE' | Set-Content -LiteralPath (Join-Path $root 'verification\_vars_marker.txt') -Encoding UTF8
