# ---------------------------------------------------------------------------
#  ClosureScan v2 - 找出"处理器里用了、但真正触发时看不见"的变量
#
#  规则（由 ClosureProbe 实测得出，不是推测）：
#    * PowerShell 脚本块【不是闭包】，变量是动态作用域、顺着调用栈找。
#    * 处理器触发时，创建它的那个函数早已返回、局部作用域已销毁 —— 局部变量读不到，
#      在 Set-StrictMode 2.0 下是硬抛异常（不是静默 $null），常被 catch{} 吞掉。
#    * $script: / $global: 限定名可见；脚本顶层的变量（含 param）可见。
#    * 函数查找（命令查找）是会话级的，处理器里能调用自定义函数。
#    * GetNewClosure() 不能用：它会另起模块作用域，闭包里连脚本作用域的函数都找不到
#      （见 ClosureProbe2）。
#
#  v1 的两个假阳性来源，v2 已修：
#    1) 把 "$btn.Add_Click({" 这行本身算进了处理器体 → $btn 被误报
#    2) param($s, $e) 的正则只吃掉第一个 → $e 被误报
#
#  ASCII only in messages: PS 5.1 reads non-BOM files as GBK.
# ---------------------------------------------------------------------------
$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$files = @('ScheduleWidget.ps1', 'Ui.ps1', 'Views.ps1', 'Views2.ps1', 'Care.ps1')

$auto = @('_', 'args', 'this', 'PSItem', 'PSScriptRoot', 'PSCommandPath', 'PSVersionTable',
          'MyInvocation', 'input', 'Matches', 'Error', 'sender', 'Host', 'PID',
          'ErrorActionPreference', 'null', 'true', 'false')

$all = New-Object System.Collections.Generic.List[string]

# 这些 .ps1 是被点源进同一个脚本作用域的，所以"主脚本的 param"在分片文件里
# 也是脚本顶层变量 —— 先做一遍全局收集，否则 $TestMode 会被误报成未知变量。
$globalTopVars = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($f in $files) {
    $pp = Join-Path $root $f
    if (-not (Test-Path -LiteralPath $pp)) { continue }
    $tt = [System.IO.File]::ReadAllText($pp, [System.Text.Encoding]::UTF8)
    $mm = [regex]::Match($tt, '(?m)^\s*param\s*\(')
    if (-not $mm.Success) { continue }
    $d3 = 0; $b3 = New-Object System.Text.StringBuilder
    for ($k = $mm.Index; $k -lt $tt.Length; $k++) {
        $c = $tt[$k]
        if ($c -eq '(') { $d3++ }
        elseif ($c -eq ')') { $d3--; if ($d3 -le 0) { break } }
        [void]$b3.Append($c)
    }
    foreach ($pm in [regex]::Matches($b3.ToString(), '\$([A-Za-z_][A-Za-z0-9_]*)')) {
        [void]$globalTopVars.Add($pm.Groups[1].Value)
    }
}

foreach ($f in $files) {
    $path = Join-Path $root $f
    if (-not (Test-Path -LiteralPath $path)) { $all.Add("MISSING $f"); continue }
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $lines = $text -split "`r?`n"

    # ---- 1) 先切出每个 function 的行区间，以及"脚本顶层"行集合 ----
    $funcRanges = New-Object System.Collections.Generic.List[object]
    $inFunc = $false
    $curName = ''
    $curStart = 0
    $depth = 0
    $topLevel = New-Object 'System.Collections.Generic.HashSet[int]'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        $fm = [regex]::Match($l, '^\s*function\s+([A-Za-z0-9_\-]+)\s*\{?')
        if (-not $inFunc -and $fm.Success) {
            $inFunc = $true; $curName = $fm.Groups[1].Value; $curStart = $i
            $depth = 0
        }
        if ($inFunc) {
            foreach ($ch in $l.ToCharArray()) {
                if ($ch -eq '{') { $depth++ }
                elseif ($ch -eq '}') { $depth-- }
            }
            if ($depth -le 0 -and $i -gt $curStart) {
                $funcRanges.Add([pscustomobject]@{ Name = $curName; Start = $curStart; End = $i })
                $inFunc = $false
            }
        } else {
            [void]$topLevel.Add($i)
        }
    }

    # 每个函数的局部变量（param + 函数体内所有赋值），以及脚本顶层变量
    $funcLocals = @{}
    foreach ($fr in $funcRanges) {
        $h = New-Object 'System.Collections.Generic.HashSet[string]'
        $seg = $lines[$fr.Start..$fr.End] -join "`n"
        foreach ($mm in [regex]::Matches($seg, 'param\s*\(([^)]*)\)')) {
            foreach ($pm in [regex]::Matches($mm.Groups[1].Value, '\$([A-Za-z_][A-Za-z0-9_]*)')) {
                [void]$h.Add($pm.Groups[1].Value)
            }
        }
        foreach ($mm in [regex]::Matches($seg, '\$([A-Za-z_][A-Za-z0-9_]*)\s*(?:=[^=]|\+=|-=)')) {
            [void]$h.Add($mm.Groups[1].Value)
        }
        # switch / foreach / for / catch 里声明的
        foreach ($mm in [regex]::Matches($seg, '(?:foreach|for|catch)\s*\(\s*\$([A-Za-z_][A-Za-z0-9_]*)')) {
            [void]$h.Add($mm.Groups[1].Value)
        }
        $funcLocals[$fr.Name] = $h
    }
    $topVars = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($i in $topLevel) {
        foreach ($mm in [regex]::Matches($lines[$i], '\$([A-Za-z_][A-Za-z0-9_]*)\s*(?:=[^=]|\+=|-=)')) {
            [void]$topVars.Add($mm.Groups[1].Value)
        }
    }
    # 脚本顶层 param 块。注意不能用 [^)]* 抓：带 [Parameter(...)] 特性时会在第一个
    # 右括号就截断（$TestMode 就是这样被漏掉的）。改成括号配对。
    $tm = [regex]::Match($text, '(?m)^\s*param\s*\(')
    if ($tm.Success) {
        $d2 = 0; $buf2 = New-Object System.Text.StringBuilder
        for ($k = $tm.Index; $k -lt $text.Length; $k++) {
            $c = $text[$k]
            if ($c -eq '(') { $d2++ }
            elseif ($c -eq ')') { $d2--; if ($d2 -le 0) { break } }
            [void]$buf2.Append($c)
        }
        foreach ($pm in [regex]::Matches($buf2.ToString(), '\$([A-Za-z_][A-Za-z0-9_]*)')) {
            [void]$topVars.Add($pm.Groups[1].Value)
        }
    }

    # ---- 2) 逐个处理器 ----
    $nHandler = 0
    $rows = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], '(?:add|Add)_([A-Za-z]+)\s*\(\s*(\$?[A-Za-z0-9_]*\s*,\s*)?\{')
        if (-not $m.Success) { continue }
        $nHandler++

        # 从 "{" 开始做花括号配对（不再把调用行前缀算进来）
        $openIdx = $lines[$i].IndexOf('{', $m.Index)
        $depth = 0
        $bodyLines = New-Object System.Collections.Generic.List[string]
        $first = $lines[$i].Substring($openIdx)
        $bodyLines.Add($first)
        $closed = $false
        foreach ($ch in $first.ToCharArray()) { if ($ch -eq '{') { $depth++ } elseif ($ch -eq '}') { $depth-- } }
        if ($depth -le 0) { $closed = $true }
        for ($j = $i + 1; (-not $closed) -and $j -lt $lines.Count; $j++) {
            $bodyLines.Add($lines[$j])
            foreach ($ch in $lines[$j].ToCharArray()) { if ($ch -eq '{') { $depth++ } elseif ($ch -eq '}') { $depth-- } }
            if ($depth -le 0) { $closed = $true }
        }
        $body = $bodyLines -join "`n"

        # 限定名（$script: / $global: / $using: ...）不需要处理，原样保留，
        # 下面用带分组的正则一次性识别并跳过，避免把 "script" 当成变量名（v1 的老毛病）。
        $bodyClean = $body
        # 处理器自己的 param()
        $params = New-Object 'System.Collections.Generic.HashSet[string]'
        $pm2 = [regex]::Match($bodyClean, 'param\s*\(([^)]*)\)')
        if ($pm2.Success) {
            foreach ($pp in [regex]::Matches($pm2.Groups[1].Value, '\$([A-Za-z_][A-Za-z0-9_]*)')) {
                [void]$params.Add($pp.Groups[1].Value)
            }
        }
        # 处理器体内自己赋值的（自足，不算违规）
        $selfSet = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($mm in [regex]::Matches($bodyClean, '\$([A-Za-z_][A-Za-z0-9_]*)\s*(?:=[^=]|\+=|-=)')) {
            [void]$selfSet.Add($mm.Groups[1].Value)
        }
        # foreach / for 的循环变量也是"处理器体内的临时变量"，不是外层作用域泄漏。
        # 漏了这两条会把 `foreach ($row in ...)` 误报成 REAL（实测 Views2.ps1 任务保存）。
        foreach ($mm in [regex]::Matches($bodyClean, 'foreach\s*\(\s*\$([A-Za-z_][A-Za-z0-9_]*)\s+in\b')) {
            [void]$selfSet.Add($mm.Groups[1].Value)
        }
        foreach ($mm in [regex]::Matches($bodyClean, 'for\s*\(\s*\$([A-Za-z_][A-Za-z0-9_]*)\s*=')) {
            [void]$selfSet.Add($mm.Groups[1].Value)
        }

        # 所在函数
        $fn = '(top-level)'
        foreach ($fr in $funcRanges) { if ($i -ge $fr.Start -and $i -le $fr.End) { $fn = $fr.Name; break } }

        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($mm in [regex]::Matches($bodyClean, '\$(?:(script|global|using|private|local):)?([A-Za-z_][A-Za-z0-9_]*)')) {
            if ($mm.Groups[1].Success) { continue }   # 限定名：可见，无需处理
            $v = $mm.Groups[2].Value
            if ($auto -contains $v) { continue }
            if ($params.Contains($v)) { continue }
            if ($selfSet.Contains($v)) { continue }
            if ($bad.Contains('$' + $v)) { continue }
            $bad.Add('$' + $v)
        }
        if ($bad.Count -gt 0) {
            # 分类：函数局部 → 真违规；脚本顶层 → 安全；都不是 → 未知
            $cls = New-Object System.Collections.Generic.List[string]
            $anyReal = $false
            foreach ($b in $bad) {
                $nm = $b.TrimStart('$')
                if ($fn -ne '(top-level)' -and $funcLocals.ContainsKey($fn) -and $funcLocals[$fn].Contains($nm)) {
                    $cls.Add($b + '<LOCAL>'); $anyReal = $true
                } elseif ($topVars.Contains($nm) -or $globalTopVars.Contains($nm)) {
                    $cls.Add($b + '<script-ok>')
                } else {
                    $cls.Add($b + '<?'); $anyReal = $true
                }
            }
            if ($anyReal) {
                $rows.Add(('REAL  {0}:{1}  {2}  Add_{3}  ->  {4}' -f $f, ($i + 1), $fn, $m.Groups[1].Value, ($cls -join ' ')))
            } else {
                $rows.Add(('ok    {0}:{1}  {2}  Add_{3}  ->  {4}' -f $f, ($i + 1), $fn, $m.Groups[1].Value, ($cls -join ' ')))
            }
        }
    }
    $all.Add("=== $f : handlers=$nHandler")
    foreach ($r in $rows) { $all.Add('  ' + $r) }
}

$outPath = Join-Path $root 'verification\_closure_scan.txt'
[System.IO.File]::WriteAllLines($outPath, $all, (New-Object System.Text.UTF8Encoding($false)))
