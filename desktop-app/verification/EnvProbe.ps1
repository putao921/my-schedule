$ErrorActionPreference = 'Continue'
$log = New-Object System.Collections.Generic.List[string]
$log.Add("start " + (Get-Date).ToString('HH:mm:ss.fff'))
$log.Add("PSVersion " + $PSVersionTable.PSVersion.ToString())
$log.Add("STA " + [System.Threading.Thread]::CurrentThread.GetApartmentState())

$step = 'Add-Type PresentationFramework'
try {
    Add-Type -AssemblyName PresentationFramework
    $log.Add("OK   $step")
} catch { $log.Add("FAIL $step :: " + $_.Exception.Message) }

$step = 'Add-Type PresentationCore'
try {
    Add-Type -AssemblyName PresentationCore
    $log.Add("OK   $step")
} catch { $log.Add("FAIL $step :: " + $_.Exception.Message) }

$step = 'Add-Type WindowsBase'
try {
    Add-Type -AssemblyName WindowsBase
    $log.Add("OK   $step")
} catch { $log.Add("FAIL $step :: " + $_.Exception.Message) }

$step = 'type System.Windows.Controls.ColumnDefinition'
try {
    $t = [System.Windows.Controls.ColumnDefinition]
    $log.Add("OK   $step -> " + $t.FullName + " in " + $t.Assembly.GetName().Name)
} catch { $log.Add("FAIL $step :: " + $_.Exception.Message) }

$step = 'New-Object ColumnDefinition + GridLength'
try {
    $cd = New-Object System.Windows.Controls.ColumnDefinition
    $cd.Width = [System.Windows.GridLength]::new(1, 'Star')
    $log.Add("OK   $step -> width=" + $cd.Width)
} catch { $log.Add("FAIL $step :: " + $_.Exception.Message) }

$step = 'create Application + Window'
try {
    $app = New-Object System.Windows.Application
    $w = New-Object System.Windows.Window
    $w.Width = 320; $w.Height = 200
    $log.Add("OK   $step")
} catch { $log.Add("FAIL $step :: " + $_.Exception.Message) }

$log.Add("end")
[System.IO.File]::WriteAllText("C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification\_env.txt",
    ($log -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
'MARKER-OK' | Set-Content -Path "C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification\_env_marker.txt" -Encoding UTF8
