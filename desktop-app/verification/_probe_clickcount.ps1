Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
$log = New-Object System.Collections.Generic.List[string]
try {
    $m = New-Object System.Windows.Input.MouseButtonEventArgs(
        [System.Windows.Input.Mouse]::PrimaryDevice, 0,
        [System.Windows.Input.MouseButton]::Left)
    $log.Add('ctor ok')
    $log.Add('read ClickCount via property = ' + [string]$m.ClickCount)
    $p = $m.GetType().GetProperty('ClickCount')
    $log.Add('prop found = ' + [string]($null -ne $p))
    if ($null -ne $p) {
        $log.Add('canWrite = ' + [string]$p.CanWrite)
        try { $p.SetValue($m, 2, $null); $log.Add('SetValue(2) ok') }
        catch { $log.Add('SetValue threw: ' + $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message) }
        $log.Add('after SetValue, read ClickCount = ' + [string]$m.ClickCount)
    }
    # 再试参数名 / 非公有属性
    $p2 = $m.GetType().GetProperty('ClickCount', [System.Reflection.BindingFlags]'Instance,NonPublic,Public')
    $log.Add('nonpublic prop found = ' + [string]($null -ne $p2))
    # 走 e.Source / OriginalSource 的行为
    $m.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
    $log.Add('after RoutedEvent: Source = ' + [string]($null -eq $m.Source) + ' (True=null)')
} catch {
    $log.Add('FATAL: ' + $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message)
}
[IO.File]::WriteAllText('C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification\_clickcount_probe.txt', ($log -join "`r`n"), [Text.UTF8Encoding]::new($false))
