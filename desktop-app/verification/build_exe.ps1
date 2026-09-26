$ErrorActionPreference='Continue'
$root='C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$out = @()
try {
    Import-Module ps2exe
    Invoke-ps2exe `
        -inputFile  ($root + '\dist-build\MySchedule-single.ps1') `
        -outputFile ($root + '\dist-build\MySchedule.exe') `
        -iconFile   ($root + '\dist-build\app.ico') `
        -title 'My Schedule' -description 'Pixel-style desktop schedule tool' `
        -company 'PuTao' -product 'MyScheduleWidget' -version 1.0.0.0 `
        -noConsole -requireAdmin:$false -DPIAware | Out-String | ForEach-Object { $out += $_ }
    if (Test-Path ($root + '\dist-build\MySchedule.exe')) {
        $out += ('exe size: ' + (Get-Item ($root + '\dist-build\MySchedule.exe')).Length + ' bytes')
    } else { $out += 'exe NOT created' }
} catch { $out += ('compile failed: ' + $_.Exception.Message) }
[System.IO.File]::WriteAllLines($root + '\verification\_ps2exe_build.txt', $out)
