param(
    [string]$Root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app',
    [string]$Report
)
$ErrorActionPreference = 'Continue'
$lines = New-Object System.Collections.Generic.List[string]
function W { param([string]$t) $lines.Add($t) }

$files = @('ScheduleWidget.ps1', 'Ui.ps1', 'Views.ps1', 'Views2.ps1', 'Care.ps1',
           'verification\RegressionHarness.ps1', 'verification\RunApp.ps1',
           'verification\SyntaxCheck.ps1')
$errTotal = 0
W ("Root: " + $Root)
W ("Time: " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
W ''

foreach ($name in $files) {
    $p = Join-Path $Root $name
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($p)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors)
    $fn = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)).Count
    $bad = @($errors).Count
    $errTotal += $bad
    $flag = if ($bad -eq 0 -and $bom) { 'OK  ' } else { 'BAD ' }
    W ("[{0}] {1}" -f $flag, $name)
    W ("      BOM={0}  bytes={1}  funcs={2}  parseErrors={3}" -f $bom, $bytes.Length, $fn, $bad)
    foreach ($e in @($errors)) {
        W ("      L{0}: {1}" -f $e.Extent.StartLineNumber, $e.Message)
    }
}

# 嵌入的 XAML 单独做一次 XML 校验（PowerShell 解析器看不见它）
W ''
$uiPath = Join-Path $Root 'Ui.ps1'
$uiText = [System.IO.File]::ReadAllText($uiPath)
$m = [regex]::Match($uiText, '(?s)<Window xmlns=.*?</Window>')
if ($m.Success) {
    try {
        $null = [xml]$m.Value
        W '[OK  ] Ui.ps1 内嵌 XAML 是合法 XML'
    } catch {
        W '[BAD ] Ui.ps1 内嵌 XAML 解析失败: ' + $_.Exception.Message
        $errTotal++
    }
} else {
    W '[BAD ] Ui.ps1 里找不到 <Window ...> XAML 块'
    $errTotal++
}

# 静态一致性断言：主题映射表新旧两套色键必须一一对应
W ''
# 仅检查 `__Key__` 形态的占位符（Ui.ps1 里同时有 PowerShell 的 `__` 语法，
# 所以必须排除 __FILE__ / __LINE__ 这类全大写内建变量）
$keysA = @([regex]::Matches($uiText, '(?<!_)__([A-Za-z][A-Za-z0-9]*)__(?!_)') |
    ForEach-Object { $_.Groups[1].Value } |
    Where-Object { $_ -cne ($_.ToUpper()) } |
    Sort-Object -Unique)
$swPath = Join-Path $Root 'ScheduleWidget.ps1'
$swText = [System.IO.File]::ReadAllText($swPath)
$lightBlock = [regex]::Match($swText, '(?s)\$script:PaletteLight = \[ordered\]@\{(.*?)\n\}')
$nightBlock = [regex]::Match($swText, '(?s)\$script:PaletteNight = \[ordered\]@\{(.*?)\n\}')
$lightKeys = @([regex]::Matches($lightBlock.Groups[1].Value, '(?m)^\s*([A-Za-z]+)\s*=') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$nightKeys = @([regex]::Matches($nightBlock.Groups[1].Value, '(?m)^\s*([A-Za-z]+)\s*=') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
W ("浅色板键 {0} 个 · 夜间板键 {1} 个" -f $lightKeys.Count, $nightKeys.Count)
$missingNight = @($lightKeys | Where-Object { $nightKeys -notcontains $_ })
$missingLight = @($nightKeys | Where-Object { $lightKeys -notcontains $_ })
if (@($missingNight).Count -eq 0 -and @($missingLight).Count -eq 0) {
    W '[OK  ] 两套色板键一一对应'
} else {
    W ('[BAD ] 色板键不匹配 夜间缺: ' + ($missingNight -join ',') + ' 浅色缺: ' + ($missingLight -join ','))
    $errTotal++
}
# 占位符必须都能在色板里找到
$unresolved = @($keysA | Where-Object { $lightKeys -notcontains $_ })
if (@($unresolved).Count -eq 0) {
    W ("[OK  ] XAML 里 {0} 个 __Key__ 占位符全部能在色板里解析" -f $keysA.Count)
} else {
    W ('[BAD ] 无法解析的占位符: ' + ($unresolved -join ','))
    $errTotal++
}
# 裸色值 / 非法注释：都要在"占位符已经被替换掉的原始模板"上找——
# 替换之后每个 __Border__ 都变成了 #7D4550，那是正常结果，不是硬编码。
$rawXaml = [regex]::Match($uiText, '(?s)<Window xmlns=.*?</Window>').Value
$bareHex = @([regex]::Matches($rawXaml, '"#[0-9A-Fa-f]{6}\b') | ForEach-Object { $_.Value } | Sort-Object -Unique)
if (@($bareHex).Count -eq 0) {
    W '[OK  ] XAML 里没有硬编码色值（全部走 __Key__ 占位符）'
} else {
    W ('[BAD ] XAML 里有硬编码色值: ' + ($bareHex -join ' '))
    $errTotal++
}
# 逐条注释单独扫（整块正则会吃掉内部换行，"第一个 -- 在正文里"会误报）
$badComment = @()
foreach ($cm in [regex]::Matches($rawXaml, '<!--[\s\S]*?-->')) {
    $body = $cm.Value.Substring(4, $cm.Value.Length - 7)
    if ($body -match '--') { $badComment += $body.Trim() }
}
if (@($badComment).Count -eq 0) {
    W '[OK  ] XAML 注释里没有非法的双横线'
} else {
    W ('[BAD ] XAML 注释含非法 "--" 共 ' + @($badComment).Count + ' 处')
    $errTotal++
}
# 严禁 [string]$x.Method() 写法（成员访问优先于类型转换，结果恒为 "True"/"False"）
$perm = @([regex]::Matches($swText, '\[(string|int|bool|double|datetime)\]\$[A-Za-z_]\w*\.[A-Za-z_]+\('))
if (@($perm).Count -eq 0) {
    W '[OK  ] 没有 [string]$x.Method() 这类恒真写法'
} else {
    W ('[BAD ] 发现恒真写法 ' + @($perm).Count + ' 处: ' + (($perm | ForEach-Object { $_.Value }) -join ' | '))
    $errTotal++
}
# StrictMode 下读哈希表里不存在的键会抛 PropertyNotFoundException。
# 本项目唯一的自定义哈希表就是 $script:Holidays 和 $script:Settings，
# 只对这两个做 dot 访问扫描，避免把正常的 [pscustomobject] 属性访问误判成问题。
$hashDot = @()
foreach ($ln in ($swText -split "`r?`n")) {
    if ($ln -match '^\s*#') { continue }
    if ($ln -match '\$(script:)?(Holidays|Settings)\.[A-Za-z_]' -and
        $ln -notmatch '\.(Keys|Values|Count|Add|Remove|Clear|Contains|ContainsKey|GetEnumerator)\b') {
        $hashDot += $ln.Trim()
    }
}
if (@($hashDot).Count -eq 0) {
    W '[OK  ] $script:Holidays / $script:Settings 没有裸 dot 访问（读键都走 Contains）'
} else {
    W ('[BAD ] 散列表裸 dot 访问 ' + @($hashDot).Count + ' 处:')
    foreach ($l in $hashDot) { W ('      ' + $l) }
    $errTotal++
}
# $script:Settings 是 OrderedDictionary，没有 ContainsKey！写 .ContainsKey() 会抛
#   "方法调用失败，因为 [System.Collections.OrderedDictionary] 不包含名为 ContainsKey 的方法"
# 而这行以前被上面的白名单明确放过了（白名单里同时写了 .Contains 和 ContainsKey），
# 于是同一个坑踩了两次。这里把它单列成硬错误。
$ckBad = @()
foreach ($ln in ($swText -split "`r?`n")) {
    if ($ln -match '^\s*#') { continue }
    if ($ln -match '\$(script:)?(Holidays|Settings)\.ContainsKey\s*\(') { $ckBad += $ln.Trim() }
}
if (@($ckBad).Count -eq 0) {
    W '[OK  ] $script:Settings.Holidays 没有非法的 .ContainsKey()（OrderedDictionary 只有 Contains）'
} else {
    W ('[BAD ] 对 OrderedDictionary 用了 .ContainsKey() ' + @($ckBad).Count + ' 处:')
    foreach ($l in $ckBad) { W ('      ' + $l) }
    $errTotal++
}

# --------------------------------------------------------------------------
#  禁止 .GetNewClosure()
#  坑（第三轮实测，不是推测）：GetNewClosure() 会把脚本块复制进一个新的**动态模块**，
#  而动态模块的函数表只有 global 作用域 —— 本脚本作用域里的函数（Get-Pal / New-Txt）
#  在闭包里一律 CommandNotFoundException。症状极隐蔽，三个条件叠在一起才暴露：
#    ① 未展开时根本走不到那段代码 → 平时一切正常；
#    ② 只有双击展开任务卡才炸；
#    ③ 抛出点在 Fill-Tasks 的 Children.Clear() 之后 → 任务列被清空且没重建，
#       用户看到的是"双击没反应，而且整列任务都消失了"。
#  ClosureScan 的头注释**早就写了**"GetNewClosure() 不能用"，但没有断言拦着，
#  于是同一个坑又被写了一次。知识没有被强制执行 = 知识不存在。这里补成硬错误。
# --------------------------------------------------------------------------
W ''
$gncBad = @()
# 只扫 5 个应用文件：不能把 SyntaxCheck.ps1 自己算进去 ——
# 它下面那两行 W '...GetNewClosure()...' 的诊断文案本身就含这个字面量，
# 会永久把自己判成 BAD（第一次写这条规则时就踩到了，报"3 处"）。
foreach ($name in @('ScheduleWidget.ps1', 'Ui.ps1', 'Views.ps1', 'Views2.ps1', 'Care.ps1')) {
    $p = Join-Path $Root $name
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $txt = [System.IO.File]::ReadAllText($p)
    $n = 0
    foreach ($ln in ($txt -split "`r?`n")) {
        $n++
        if ($ln -match '^\s*#') { continue }
        if ($ln -match 'GetNewClosure\s*\(') { $gncBad += ($name + ':' + $n + '  ' + $ln.Trim()) }
    }
}
if (@($gncBad).Count -eq 0) {
    W '[OK  ] 没有 .GetNewClosure()（它会另起模块作用域，闭包里找不到脚本作用域的函数）'
} else {
    W ('[BAD ] 用了 .GetNewClosure() ' + @($gncBad).Count + ' 处:')
    foreach ($l in $gncBad) { W ('      ' + $l) }
    $errTotal++
}

# --------------------------------------------------------------------------
#  禁止把函数参数命名为 $Args / $args
#  坑（第三轮实测，见 verification\_args_probe.txt）：$args 是 PowerShell 的自动变量
#  （未绑定参数数组），参数名一旦取成 $Args，**入口处会被绑定器覆盖成 @()** ——
#  实参明明传进来了，函数体里读到的却是一个空数组：
#      param($Args) 读 .ClickCount -> 在此对象上找不到属性（StrictMode 2.0 下硬抛）
#      param($X)    读 .ClickCount -> 2
#  于是所有 try/catch 的写法都会**静默降级**成"兜底值"，测试还全绿。
#  本项目实际后果：Get-MouseClickCount 永远返回 1（所有双击分支失效）、
#  Get-EventSourceOf 永远走不到 OriginalSource、Test-ClickOnButton 永远返回 $false。
#  修法：参数改名（$Evt）。这条规则就是防止它被写回来。
# --------------------------------------------------------------------------
W ''
$paBad = @()
foreach ($name in @('ScheduleWidget.ps1', 'Ui.ps1', 'Views.ps1', 'Views2.ps1', 'Care.ps1')) {
    $p = Join-Path $Root $name
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $txt = [System.IO.File]::ReadAllText($p)
    $n = 0
    $inParam = $false
    foreach ($ln in ($txt -split "`r?`n")) {
        $n++
        if ($ln -match '^\s*#') { continue }
        if (-not $inParam -and $ln -match 'param\s*\(') { $inParam = $true }
        if ($inParam) {
            if ($ln -match '\$\s*[Aa]rgs\b') { $paBad += ($name + ':' + $n + '  ' + $ln.Trim()) }
            if ($ln -match '\)') { $inParam = $false }
        }
    }
}
if (@($paBad).Count -eq 0) {
    W '[OK  ] 没有把函数参数命名为 $Args（会与自动变量 $args 冲突、被覆盖成 @()）'
} else {
    W ('[BAD ] 有函数参数叫 $Args ' + @($paBad).Count + ' 处:')
    foreach ($l in $paBad) { W ('      ' + $l) }
    $errTotal++
}

# --------------------------------------------------------------------------
#  XAML 名字必须被"接走"
#  坑：XAML 里 x:Name 写了，Build-Window 的 $n[] 里也写了，但忘了赋值给
#      $script:Xxx —— 静态看不出、启动到那行才炸"检索不到变量"。
#      这里把三件事对齐：XAML 声明 → $n['X'] 取用 → $script:X 赋值。
# --------------------------------------------------------------------------
W ''
$careText = [System.IO.File]::ReadAllText((Join-Path $Root 'Care.ps1'))
# 只取宿主窗口自己的名字（样式模板里的 bd/sh 不算）
$xamlNames = @([regex]::Matches($rawXaml, 'x:Name="([A-Za-z][A-Za-z0-9_]*)"') |
    ForEach-Object { $_.Groups[1].Value } |
    Where-Object { $_ -ne 'bd' -and $_ -ne 'sh' } |
    Sort-Object -Unique)
# 模式一律用单引号字符串：双引号里 $n 会被 PowerShell 当变量展开，
# 展开成空串后剩下的模式看着"平衡"却再也匹配不上（曾因此报出"取用 0 个"的假数据）。
$drained = @()
$assigned = @()
try {
    $drained = @([regex]::Matches($careText, '\$n\[''([A-Za-z][A-Za-z0-9_]*)''\]') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $assigned = @([regex]::Matches($careText, '\$script:([A-Za-z][A-Za-z0-9_]*)\s*=\s*\$n\[') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
} catch {
    W ('[BAD ] 取用/赋值扫描失败: ' + $_.Exception.Message)
    $errTotal++
}
$notDrained = @($xamlNames | Where-Object { $drained -notcontains $_ })
# 已知的"引用名 -> 变量名"不一致（历史命名），不算漏赋值
# ViewHost 是 XAML 里的视图宿主，代码里统一叫 $script:NodeHost
$nameAlias = @{ 'ViewHost' = 'NodeHost' }
$notAssigned = @($drained | Where-Object {
    if ($assigned -contains $_) { return $false }
    if ($nameAlias.ContainsKey($_) -and ($assigned -contains $nameAlias[$_])) { return $false }
    return $true
})
W ("XAML x:Name {0} 个 · 取用 {1} 个 · 赋值给 `$script: {2} 个" -f `
    $xamlNames.Count, $drained.Count, $assigned.Count)
if (@($notDrained).Count -eq 0) {
    W '[OK  ] XAML 里每个 x:Name 都被 $n[] 取用'
} else {
    W ('[WARN] 有 x:Name 没被取用（可能是不需要操作的纯装饰元素）: ' + ($notDrained -join ','))
}
if (@($notAssigned).Count -eq 0) {
    W '[OK  ] 每个取用的名字都赋值给了 $script:（不会出现"检索不到变量"）'
} else {
    W ('[BAD ] 取了却忘了赋值给 $script: 共 ' + @($notAssigned).Count + ' 个: ' + ($notAssigned -join ','))
    $errTotal++
}

# --------------------------------------------------------------------------
#  函数体里的 $script: 不查
#  这批函数全部是"由 Build-Window 之后才调用"的（Refresh-All / Update-Chrome /
#  Update-PomodoroVisual …）。静态按行序扫会把它们的读操作误判成"未定义就使用"。
#  所以扫描时跳过 function { ... } 区间，只查顶层（脚本级）语句。
# --------------------------------------------------------------------------
$topLevel = @{}
foreach ($name in @('ScheduleWidget.ps1', 'Ui.ps1', 'Views.ps1', 'Views2.ps1', 'Care.ps1')) {
    $p = Join-Path $Root $name
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $toks = $null; $perr = $null
    $past = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$toks, [ref]$perr)
    # 注意：局部变量名不能叫 $lines —— 那会盖住上面报告用的 $lines 列表
    $keep = @{}
    # 更稳的做法：先把所有函数定义体的行号区间收集起来，反选
    $fnRanges = @()
    foreach ($f in $past.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $fnRanges += , @($f.Extent.StartLineNumber, $f.Extent.EndLineNumber)
    }
    $ln = 0
    foreach ($line in ([System.IO.File]::ReadAllText($p) -split "`r?`n")) {
        $ln++
        $inside = $false
        foreach ($r in $fnRanges) { if ($ln -ge $r[0] -and $ln -le $r[1]) { $inside = $true; break } }
        if (-not $inside) { $keep[$ln] = $line }
    }
    $topLevel[$name] = $keep
}

# --------------------------------------------------------------------------
#  $script: 变量必须先定义后使用
#  按文件顺序扫，遇到 "= 赋值" 或 $n['..'] 赋值就登记，遇到 $script:X 读数
#  但从未登记过就报错。这里做的是跨文件的宽松检查：只看"读得比写得早"。
# --------------------------------------------------------------------------
W ''
$ordered = @('ScheduleWidget.ps1', 'Ui.ps1', 'Views.ps1', 'Views2.ps1', 'Care.ps1')
$defined = New-Object System.Collections.Generic.HashSet[string]
# 这些是宿主留给我们的、由 ScheduleWidget.ps1 顶部 param 或脚本级变量定义的
foreach ($k in @('View', 'Theme', 'Anchor', 'Selected', 'Events', 'Tasks', 'Settings', 'Holidays',
                 'DowShort', 'MonNames', 'Skeleton', 'TestMode', 'DataDir', 'DataFile',
                 'PaletteLight', 'PaletteNight', 'OverlayOpen', 'ViewWrap', 'AllowClose',
                 'CloseToTray', 'TrayIcon', 'PomoTimer', 'WindowClosed', 'SuppressSave',
                 'HourHeight', 'WeekGutter', 'Fill', 'DlgLayout', 'ListStack', 'TaskStack',
                 'ListSearch', 'ListTagBox', 'ListScopeBox', 'WeekCanvas', 'WeekOverlay',
                 'MainWindow', 'TopmostOn', 'Pomo', 'MousePos', 'DragStart')) {
    [void]$defined.Add($k)
}
$early = @()
foreach ($name in $ordered) {
    if (-not $topLevel.ContainsKey($name)) { continue }
    $map = $topLevel[$name]
    foreach ($ln in ($map.Keys | Sort-Object)) {
        $line = $map[$ln]
        $trim = $line.Trim()
        if ($trim.StartsWith('#')) { continue }
        # 本行里所有被赋值的 $script: 名字都先登记（同行的读也算已定义）
        foreach ($a in [regex]::Matches($line, '\$script:([A-Za-z][A-Za-z0-9_]*)\s*=')) {
            [void]$defined.Add($a.Groups[1].Value)
        }
        # 再检查本行读到的名字是否都已定义过
        foreach ($r in [regex]::Matches($line, '\$script:([A-Za-z][A-Za-z0-9_]*)')) {
            $k = $r.Groups[1].Value
            if ($defined.Contains($k)) { continue }
            # 本行左侧就是它在赋值 -> 已登记，跳过（双保险）
            if ($line -match ('\$script:' + [regex]::Escape($k) + '\s*=')) { continue }
            $early += ($name + ':' + $ln + '  ' + $trim)
        }
    }
}
if (@($early).Count -eq 0) {
    W '[OK  ] 没有"用了还没定义"的 $script: 变量（跨文件顺序扫描）'
} else {
    W ('[BAD ] 可能未定义就使用的 $script: 变量 ' + @($early).Count + ' 处:')
    foreach ($l in $early) { W ('      ' + $l) }
    $errTotal++
}

W ''
W '--- 汇总 ---'
W ("  语法错误总数: " + $errTotal)
W ("  结论: " + $(if ($errTotal -eq 0) { 'PASS' } else { 'FAIL' }))

if (-not $Report) { $Report = Join-Path $Root 'verification\syntax.txt' }
# 写 UTF-8 且不带 BOM：带 BOM 时 Read 工具偶尔会把它当二进制而拒绝显示
[System.IO.File]::WriteAllText($Report, ($lines -join [Environment]::NewLine),
    (New-Object System.Text.UTF8Encoding($false)))
