param([string]$Tag='nightmini')
# ASCII only in this file: PS 5.1 reads non-BOM scripts as GBK, and Chinese
# comments here previously corrupted the parse (seed string became empty).
$ErrorActionPreference='Continue'
$root='C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$stamp=(Get-Date).ToString('HHmmss')
$runTag=$Tag+'__'+$stamp
$dataDir=Join-Path $root ('verification\rundata\'+$runTag)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
# Seed: night theme + pinned widget + 0.9 opacity -> verify theme-follow (round 14 item 4)
$settings = '{"Theme":"night","Language":"zh","MiniPinned":true,"MiniOpacity":0.9,"PomodoroEnabled":true,"PomodoroMin":25}'
$p = Join-Path $dataDir 'settings.json'
[System.IO.File]::WriteAllText($p, $settings, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ('seeded: ' + (Get-Content -LiteralPath $p -Raw))
$shot=Join-Path $root ('shots\nightmini-main.png')
$spec='miniidle:r14-night-mini,size:900x700'
try{
 $appSrc=[System.IO.File]::ReadAllText((Join-Path $root 'ScheduleWidget.ps1'),[System.Text.Encoding]::UTF8)
 Push-Location -LiteralPath $root
 try{
   & ([scriptblock]::Create($appSrc)) -TestMode -DataDir $dataDir -Script $spec -AutoCloseSeconds 2 -ScreenshotPath $shot -SizeOverride '900x700'
 }finally{Pop-Location}
}catch{ Write-Output ('CATCH :: ' + $_.Exception.Message) }
Write-Output ('bootlog: ' + (Get-Content -LiteralPath (Join-Path $dataDir 'bootlog.txt') -Raw))
