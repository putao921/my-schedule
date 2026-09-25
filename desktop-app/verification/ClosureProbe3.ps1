# ---------------------------------------------------------------------------
#  闭包可见性探针 v3 —— 只问一件事：
#    处理器里【不带限定名】读"脚本顶层变量"（含脚本 param），看不看得见？
#
#  为什么必须问：项目里有 `$w.Add_Closing({ ... -not $TestMode ... })` 这种写法，
#  $TestMode 是脚本顶层 param。如果处理器的作用域链根是【全局】而不是【脚本】，
#  那么不带 $script: 前缀就读不到，关闭逻辑会在测试模式下永远弹确认框。
#  同理还有 $ScreenshotPath。
#
#  日志路径硬编码，全程不读任何脚本变量，避免"记录器本身不可用掩盖结论"。
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$outFile = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification\_closure_probe3.txt'
[System.IO.File]::WriteAllText($outFile, '', (New-Object System.Text.UTF8Encoding($false)))

$TopPlain = 'PLAIN-SCRIPT-VAR'      # 脚本顶层普通变量
$script:TopQual = 'QUAL-SCRIPT-VAR'  # 脚本顶层 $script: 变量

function Build-Probe3 {
    $win = New-Object System.Windows.Window
    $win.Width = 300; $win.Height = 120
    $win.WindowStyle = 'None'; $win.ShowInTaskbar = $false
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = 'go'
    $win.Content = $btn
    $btn.Add_Click({
        param($s, $e)
        try { [System.IO.File]::AppendAllText($outFile, 'plain  : ' + $TopPlain + "`r`n") }
        catch { [System.IO.File]::AppendAllText($outFile, 'plain  : THROW ' + $_.Exception.Message + "`r`n") }
        try { [System.IO.File]::AppendAllText($outFile, 'qual   : ' + [string]$script:TopQual + "`r`n") }
        catch { [System.IO.File]::AppendAllText($outFile, 'qual   : THROW ' + $_.Exception.Message + "`r`n") }
    })
    $script:P3Win = $win
    $script:P3Btn = $btn
    $win.Show(); $win.UpdateLayout()
}

Build-Probe3
[System.IO.File]::AppendAllText($outFile, "---- Build-Probe3 returned ----`r`n")
$script:P3Btn.RaiseEvent((New-Object System.Windows.RoutedEventArgs(
    [System.Windows.Controls.Button]::ClickEvent)))
try { $script:P3Win.Close() } catch { }
