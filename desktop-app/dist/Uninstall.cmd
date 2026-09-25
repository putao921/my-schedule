@echo off
rem ASCII only: batch files are decoded with the OEM codepage.
rem Removes the desktop shortcut. Data in %APPDATA%\MyScheduleWidget is kept
rem unless you answer Y to the second question.
setlocal
set "HERE=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$desk = [Environment]::GetFolderPath('Desktop'); $p = Join-Path $desk 'My Schedule.lnk'; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Host ('Removed ' + $p) } else { Write-Host 'No desktop shortcut found.' }"
echo.
set /p WIPE="Also delete MY saved data (%APPDATA%\MyScheduleWidget)? [y/N]: "
if /I "%WIPE%"=="y" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p = Join-Path $env:APPDATA 'MyScheduleWidget'; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force; Write-Host ('Deleted ' + $p) } else { Write-Host 'No data folder found.' }"
) else (
  echo Data kept.
)
echo Uninstall finished.
pause
endlocal
