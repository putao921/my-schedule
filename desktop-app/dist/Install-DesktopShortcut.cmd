@echo off
rem ASCII only: batch files are decoded with the OEM codepage.
rem Creates a desktop shortcut that runs Start-MySchedule.cmd.
setlocal
set "HERE=%~dp0"
if not exist "%HERE%Start-MySchedule.cmd" (
  echo [My Schedule] Start-MySchedule.cmd not found next to this file.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ws = New-Object -ComObject WScript.Shell; $desk = [Environment]::GetFolderPath('Desktop'); $lnk = $ws.CreateShortcut((Join-Path $desk 'My Schedule.lnk')); $lnk.TargetPath = '%HERE%Start-MySchedule.cmd'; $lnk.WorkingDirectory = '%HERE%'; $lnk.IconLocation = '%%SystemRoot%%\System32\SHELL32.dll,44'; $lnk.Description = 'My Schedule - pixel schedule widget'; $lnk.Save(); Write-Host ('OK -> ' + (Join-Path $desk 'My Schedule.lnk'))"
echo.
echo Done. A "My Schedule" shortcut is now on your desktop.
pause
endlocal
