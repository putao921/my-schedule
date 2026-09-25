# ---------------------------------------------------------------------------
#  闭包可见性探针（v2）
#
#  v1 的结论是错的：它在"创建处理器的那个函数还没返回"时就 RaiseEvent，
#  函数局部作用域还挂在调用栈上，于是局部变量当然读得到——PowerShell 是
#  动态作用域，变量查找是顺着栈往上找的。
#
#  真实场景是：Build-Window / Show-EventEditorWindow 早就返回了，用户在几十秒
#  后才点按钮、定时器才 Tick。那时候创建它的作用域已经销毁。所以本探针必须：
#      在函数里建好窗口/按钮/定时器并挂 $script: → 函数返回 → 顶层再触发。
#
#  三个待测问题：
#    Q1 按钮 Click 处理器能否读到【创建函数的局部变量】？
#    Q2 同上，读 $script: 变量？
#    Q3 DispatcherTimer 的 Tick 处理器能否读到【创建函数的局部变量】？
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$out = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification\_closure_probe.txt'
if (Test-Path -LiteralPath $out) { [System.IO.File]::Delete($out) }
$script:Log = New-Object System.Collections.ArrayList

function Log-Line { param([string]$m) [void]$script:Log.Add([string]$m) }

# 处理器内部只用 .NET 方法调用，不调自定义函数：万一函数查找也不可见，
# catch 分支里的 Log-Line 会二次抛错，把真正的结论盖掉。
function Build-Probe {
    # 刻意留在函数局部作用域，不进 $script:
    $localText = 'FROM-LOCAL-SCOPE'
    $localObj  = New-Object System.Windows.Controls.TextBox
    $localObj.Text = 'FROM-LOCAL-OBJECT'
    $localTick = 'FROM-LOCAL-TICK'

    $win = New-Object System.Windows.Window
    $win.Width = 340; $win.Height = 180
    $win.WindowStyle = 'None'
    $win.ShowInTaskbar = $false
    $sp = New-Object System.Windows.Controls.StackPanel
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = 'go'
    $sp.Children.Add($btn)
    $win.Content = $sp

    $btn.Add_Click({
        param($s, $e)
        try { [void]$script:Log.Add('Q1 local string : ' + $localText) }
        catch { [void]$script:Log.Add('Q1 local string : THROW -> ' + $_.Exception.Message) }
        try { [void]$script:Log.Add('Q1 local object : ' + [string]$localObj.Text) }
        catch { [void]$script:Log.Add('Q1 local object : THROW -> ' + $_.Exception.Message) }
        try { [void]$script:Log.Add('Q2 script var   : ' + [string]$script:ProbeScriptVar) }
        catch { [void]$script:Log.Add('Q2 script var   : THROW -> ' + $_.Exception.Message) }
    })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(40)
    $timer.Add_Tick({
        if ([bool]$script:TickDone) { return }
        $script:TickDone = $true
        try { [void]$script:Log.Add('Q3 local tick   : ' + $localTick) }
        catch { [void]$script:Log.Add('Q3 local tick   : THROW -> ' + $_.Exception.Message) }
        try {
            $timer.Stop()
            [void]$script:Log.Add('Q3 timer stop   : ok (local $timer visible)')
        } catch { [void]$script:Log.Add('Q3 timer stop   : THROW -> ' + $_.Exception.Message) }
        try { [void]$script:Log.Add('Q3 script var   : ' + [string]$script:ProbeScriptVar) }
        catch { [void]$script:Log.Add('Q3 script var   : THROW -> ' + $_.Exception.Message) }
    })

    # ---- Q4：候选通用解法 GetNewClosure() ----
    # PowerShell 的脚本块默认不是闭包（动态作用域，顺着调用栈找变量）。
    # GetNewClosure() 会把此刻的局部变量"冻"进一个新建的模块作用域。
    # 如果它有效，那么全项目 30 多处"处理器引用局部变量"的写法只要加这一个后缀即可修好，
    # 不必逐个把变量搬到 $script:。
    $btn2 = New-Object System.Windows.Controls.Button
    $btn2.Content = 'go2'
    $sp.Children.Add($btn2)
    $sbQ4 = {
        param($s, $e)
        try { [void]$script:Log.Add('Q4 closure str : ' + $localText) }
        catch { [void]$script:Log.Add('Q4 closure str : THROW -> ' + $_.Exception.Message) }
        try { [void]$script:Log.Add('Q4 closure obj : ' + [string]$localObj.Text) }
        catch { [void]$script:Log.Add('Q4 closure obj : THROW -> ' + $_.Exception.Message) }
        try { [void]$script:Log.Add('Q4 script var  : ' + [string]$script:ProbeScriptVar) }
        catch { [void]$script:Log.Add('Q4 script var  : THROW -> ' + $_.Exception.Message) }
    }.GetNewClosure()
    $btn2.Add_Click($sbQ4)

    # 交给顶层用；本函数马上返回
    $script:PWin   = $win
    $script:PBtn   = $btn
    $script:PBtn2  = $btn2
    $script:PTimer = $timer
    $win.Show()
    $win.UpdateLayout()
    [void]$script:Log.Add('build          : window built (local scope now about to die)')
}

# --------------------------------------------------------------------------
#  1) 在函数里建，函数返回
# --------------------------------------------------------------------------
Build-Probe
$script:ProbeScriptVar = 'FROM-SCRIPT-SCOPE'
$script:TickDone = $false
[void]$script:Log.Add('build          : Build-Probe returned; scope is gone')

# --------------------------------------------------------------------------
#  2) 顶层触发按钮 Click（此刻创建函数已返回）
# --------------------------------------------------------------------------
try {
    $script:PBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs(
        [System.Windows.Controls.Button]::ClickEvent)))
    Log-Line 'raiseEvent     : ok'
} catch {
    Log-Line ('raiseEvent     : THROW -> ' + $_.Exception.Message)
}

try { Log-Line ('diag PBtn     : ' + [string]$script:PBtn) } catch { Log-Line 'diag PBtn     : UNSET' }
try { Log-Line ('diag PBtn2    : ' + [string]$script:PBtn2) } catch { Log-Line 'diag PBtn2    : UNSET' }
try { Log-Line ('diag PWin     : ' + [string]$script:PWin) } catch { Log-Line 'diag PWin     : UNSET' }
try {
    $script:PBtn2.RaiseEvent((New-Object System.Windows.RoutedEventArgs(
        [System.Windows.Controls.Button]::ClickEvent)))
} catch {
    Log-Line ('Q4 raiseEvent  : THROW -> ' + $_.Exception.Message)
}

# --------------------------------------------------------------------------
#  3) 顶层启动定时器并泵消息，让 Tick 在函数返回后真正触发
# --------------------------------------------------------------------------
$script:PTimer.Start()
$script:ProbeDeadline = [datetime]::Now.AddSeconds(3)
$frame = New-Object System.Windows.Threading.DispatcherFrame
$watch = New-Object System.Windows.Threading.DispatcherTimer
$watch.Interval = [TimeSpan]::FromMilliseconds(120)
$watch.Add_Tick({
    if ([bool]$script:TickDone -or [datetime]::Now -gt $script:ProbeDeadline) {
        $script:PFrame.Continue = $false
    }
})
$script:PFrame = $frame
$watch.Start()
[System.Windows.Threading.Dispatcher]::PushFrame($frame)
$watch.Stop()
Log-Line ('tick done      : ' + [string]$script:TickDone)

try { $script:PWin.Close() } catch { }

[System.IO.File]::WriteAllLines($out, $script:Log, (New-Object System.Text.UTF8Encoding($false)))
