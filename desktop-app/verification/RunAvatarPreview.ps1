param([string]$Theme='light', [string]$Tag='avatarpv')
# ASCII only: PS 5.1 reads non-BOM scripts as GBK.
# One WPF app per process: run ONE theme per invocation.
$ErrorActionPreference='Continue'
$root='C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$girl=Join-Path $root 'shots\avatar-girl-portrait.png'
$stamp=(Get-Date).ToString('HHmmss')
$dataDir=Join-Path $root ('verification\rundata\avpv_' + $Theme + '_' + $stamp)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$settings = '{"Theme":"' + $Theme + '","Language":"zh","AvatarPath":' + ($girl | ConvertTo-Json) + '}'
[System.IO.File]::WriteAllText((Join-Path $dataDir 'settings.json'), $settings, (New-Object System.Text.UTF8Encoding($false)))
$shotName = 'avatarpv-' + $Theme
$shot=Join-Path $root ('shots\' + $shotName + '.png')
$spec='size:1200x820,layout,shot:' + $shotName
try{
  $appSrc=[System.IO.File]::ReadAllText((Join-Path $root 'ScheduleWidget.ps1'),[System.Text.Encoding]::UTF8)
  Push-Location -LiteralPath $root
  try{
    & ([scriptblock]::Create($appSrc)) -TestMode -DataDir $dataDir -Script $spec -AutoCloseSeconds 2 -ScreenshotPath $shot -SizeOverride '1200x820'
  }finally{Pop-Location}
}catch{ Write-Output ('CATCH :: ' + $_.Exception.Message) }
$ep=Join-Path $dataDir 'errors.log'
if(Test-Path -LiteralPath $ep){
  $raw=[System.IO.File]::ReadAllText($ep,[System.Text.Encoding]::UTF8)
  if(-not[string]::IsNullOrWhiteSpace($raw)){ Write-Output ('errors: ' + $raw) }
}
Write-Output ('done ' + $Theme)
