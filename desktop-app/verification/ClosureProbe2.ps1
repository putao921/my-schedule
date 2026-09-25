# ---------------------------------------------------------------------------
#  闭包可见性探针 v3 —— 只问一件事：GetNewClosure() 能不能当通用解法？
#
#  v2 已经证明：处理器读不到创建函数的局部变量（Q1/Q3 全 THROW），$script: 可以。
#  候选解法是给每个处理器加 .GetNewClosure()。但它会新建一个"模块作用域"，
#  那么问题来了：处理器里大量使用的 $script:State 到底指向哪儿？
#  如果指向闭包私有副本，那么所有状态变更都被隔离 —— 比现在更糟。
#
#  本探针的日志路径【硬编码字符串】，全程不读任何脚本变量，
#  避免 v2 那种"记录器本身就不可用、结论被掩盖"的自噬问题。
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$outFile = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification\_closure_probe2.txt'
[System.IO.File]::WriteAllText($outFile, '', (New-Object System.Text.UTF8Encoding($false)))

function W { param([string]$m) [System.IO.File]::AppendAllText($outFile, $m + "`r`n") }

function Build-Probe2 {
    $localText = 'FROM-LOCAL-SCOPE'

    $win = New-Object System.Windows.Window
    $win.Width = 300; $win.Height = 140
    $win.WindowStyle = 'None'; $win.ShowInTaskbar = $false
    $sp = New-Object System.Windows.Controls.StackPanel

    # --- A: 普通处理器（对照，已知会失败）---
    $btnA = New-Object System.Windows.Controls.Button
    $btnA.Content = 'A'
    $btnA.Add_Click({
        param($s, $e)
        try { W ('A local        : ' + $localText) }
        catch { W ('A local        : THROW ' + $_.Exception.Message) }
    })

    # --- B: GetNewClosure 处理器 ---
    $btnB = New-Object System.Windows.Controls.Button
    $btnB.Content = 'B'
    $sbB = {
        param($s, $e)
        try { W ('B local        : ' + $localText) }
        catch { W ('B local        : THROW ' + $_.Exception.Message) }
        # $script: 在闭包里指向哪儿？读一下，再写一下，顶层复查有没有传播出去。
        try { W ('B script read  : [' + [string]$script:SVar + ']') }
        catch { W ('B script read  : THROW ' + $_.Exception.Message) }
        try { $script:SVar = 'MUTATED-IN-CLOSURE'; W 'B script write : ok' }
        catch { W ('B script write : THROW ' + $_.Exception.Message) }
        # 顶层能否再次读到闭包写进去的值？闭包自己再读一次看是否生效
        try { W ('B script reread: [' + [string]$script:SVar + ']') }
        catch { W ('B script reread: THROW ' + $_.Exception.Message) }
    }.GetNewClosure()
    $btnB.Add_Click($sbB)

    $sp.Children.Add($btnA)
    $sp.Children.Add($btnB)
    $win.Content = $sp
    $script:P2Win = $win
    $script:P2A = $btnA
    $script:P2B = $btnB
    $win.Show(); $win.UpdateLayout()
}

$script:SVar = 'ORIGINAL'
Build-Probe2
W '---- Build-Probe2 returned (local scope dead) ----'

$script:P2A.RaiseEvent((New-Object System.Windows.RoutedEventArgs(
    [System.Windows.Controls.Button]::ClickEvent)))
$script:P2B.RaiseEvent((New-Object System.Windows.RoutedEventArgs(
    [System.Windows.Controls.Button]::ClickEvent)))

W ('top SVar       : [' + [string]$script:SVar + ']')
W ("expect         : [MUTATED-IN-CLOSURE] 说明闭包里的 `$script:` 就是应用全局")
try { $script:P2Win.Close() } catch { }
