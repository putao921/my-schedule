@echo off
rem ASCII only on purpose: cmd batch files are decoded with the OEM codepage,
rem Chinese here would turn into mojibake on most machines.
rem Launch the WPF app detached so this console closes immediately.
setlocal
set "APPDIR=%~dp0MySchedule"
if not exist "%APPDIR%\ScheduleWidget.ps1" (
  echo [My Schedule] Missing MySchedule\ScheduleWidget.ps1 next to this file.
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%APPDIR%\ScheduleWidget.ps1"
endlocal
