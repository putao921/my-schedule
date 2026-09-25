Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
$log = New-Object System.Collections.Generic.List[string]
$m = New-Object System.Windows.Input.MouseButtonEventArgs(
    [System.Windows.Input.Mouse]::PrimaryDevice, 0,
    [System.Windows.Input.MouseButton]::Left)
$log.Add('0 ctor                        cc=' + [string]$m.ClickCount)
$p = $m.GetType().GetProperty('ClickCount')
$p.SetValue($m, 2, $null)
$log.Add('1 after SetValue(2)           cc=' + [string]$m.ClickCount)
$m.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
$log.Add('2 after RoutedEvent=...       cc=' + [string]$m.ClickCount)
# Source 需要一个 DependencyObject 才能赋；这里用最小 Window 充当
$w = New-Object System.Windows.Window
$bd = New-Object System.Windows.Controls.Border
$w.Content = $bd
$m.Source = $bd
$log.Add('3 after Source=Border         cc=' + [string]$m.ClickCount)
$log.Add('   Source is Border = ' + [string][object]::ReferenceEquals($m.Source, $bd))
$bd.RaiseEvent($m)
$log.Add('4 after RaiseEvent            cc=' + [string]$m.ClickCount)
[IO.File]::WriteAllText('C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification\_clickcount_probe2.txt', ($log -join "`r`n"), [Text.UTF8Encoding]::new($false))
