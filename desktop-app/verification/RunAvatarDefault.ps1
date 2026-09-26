param([string]$Theme='light', [string]$Tag='avdef')
# ASCII only: PS 5.1 reads non-BOM scripts as GBK. One WPF app per process.
$ErrorActionPreference='Continue'
$root='C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$stamp=(Get-Date).ToString('HHmmss')
$dataDir=Join-Path $root ('verification\rundata\avdef_' + $Theme + '_' + $stamp)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
# NO AvatarPath seeded -> default avatar (girl) should show.
$settings = '{"Theme":"' + $Theme + '","Language":"zh"}'
[System.IO.File]::WriteAllText((Join-Path $dataDir 'settings.json'), $settings, (New-Object System.Text.UTF8Encoding($false)))
$shotName = 'avdef-' + $Theme
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
