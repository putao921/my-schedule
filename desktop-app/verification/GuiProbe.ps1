$ErrorActionPreference = 'Stop'
# ASCII only: PS 5.1 reads non-BOM files as GBK and mangles non-ASCII.
$out = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification\_guiprobe.txt'
[System.IO.File]::WriteAllText($out, '', (New-Object System.Text.UTF8Encoding($false)))
$script:logPath = $out

function L {
    param([string]$t)
    $line = ((Get-Date).ToString('HH:mm:ss.fff') + '  ' + $t)
    Add-Content -LiteralPath $script:logPath -Value $line -Encoding UTF8
}

L ('PSVersion=' + $PSVersionTable.PSVersion.ToString())
L ('Apartment=' + [System.Threading.Thread]::CurrentThread.GetApartmentState().ToString())
L ('Interactive=' + [System.Environment]::UserInteractive)
try { L ('ConsoleSession=' + (Get-Process -Id $PID).SessionId) } catch { L 'ConsoleSession=?' }

L 'A: loading assemblies'
foreach ($a in @('PresentationFramework','PresentationCore','WindowsBase','System.Xaml')) {
    try { [void][System.Reflection.Assembly]::LoadWithPartialName($a); L ('  loaded ' + $a) }
    catch { L ('  FAIL ' + $a + ' :: ' + $_.Exception.Message) }
}

L 'B: new Application'
$script:app = $null
try { $script:app = New-Object System.Windows.Application; L '  app ok' }
catch { L ('  app FAIL :: ' + $_.Exception.Message) }
L ('  Current null? ' + ($null -eq [System.Windows.Application]::Current))

L 'C: build Window'
$script:w = $null
try {
    $script:w = New-Object System.Windows.Window
    $script:w.Width = 320; $script:w.Height = 200; $script:w.Title = 'probe'
    $script:w.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
    $script:w.Left = 40; $script:w.Top = 40
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = 'probe ok'
    $tb.FontSize = 20
    $script:w.Content = $tb
    L '  window built'
} catch { L ('  window FAIL :: ' + $_.Exception.Message) }

L 'D: Show()'
try {
    $script:w.Show()
    L ('  shown, actual=' + [int]$script:w.ActualWidth + 'x' + [int]$script:w.ActualHeight)
} catch { L ('  Show FAIL :: ' + $_.Exception.Message) }

L 'E: UpdateLayout'
try {
    $script:w.UpdateLayout()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [System.Windows.Threading.DispatcherPriority]::Render, [action]{})
    L ('  laid out, actual=' + [int]$script:w.ActualWidth + 'x' + [int]$script:w.ActualHeight)
} catch { L ('  layout FAIL :: ' + $_.Exception.Message) }

L 'F: RenderTargetBitmap'
try {
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(320, 200, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($script:w)
    L '  rendered'
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [System.IO.File]::Create($out + '.png')
    try { $enc.Save($fs) } finally { $fs.Dispose() }
    L ('  png saved ' + (Get-Item ($out + '.png')).Length + 'b')
} catch { L ('  render FAIL :: ' + $_.Exception.Message) }

L 'G: close'
try { $script:w.Close(); L '  closed' } catch { L ('  close FAIL :: ' + $_.Exception.Message) }
try { if ($null -ne $script:app) { $script:app.Shutdown() }; L '  shutdown' } catch { L ('  shutdown FAIL :: ' + $_.Exception.Message) }
L 'Z: done'
