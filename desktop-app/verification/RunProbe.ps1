param([string]$Tag='probe', [string]$Spec='size:1200x820,view:month,layout,shot:probe-main')
$ErrorActionPreference='Continue'
$root='C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$stamp=(Get-Date).ToString('HHmmss')
$runTag=$Tag+'__'+$stamp
$dataDir=Join-Path $root ('verification\rundata\'+$runTag)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$shotDir=Join-Path $root 'shots'
if(-not(Test-Path -LiteralPath $shotDir)){New-Item -ItemType Directory -Force -Path $shotDir|Out-Null}
$shot=Join-Path $shotDir ($runTag+'.png')
$log=New-Object System.Collections.Generic.List[string]
try{
 $appSrc=[System.IO.File]::ReadAllText((Join-Path $root 'ScheduleWidget.ps1'),[System.Text.Encoding]::UTF8)
 Push-Location -LiteralPath $root
 try{
   & ([scriptblock]::Create($appSrc)) -TestMode -DataDir $dataDir -Script $Spec -AutoCloseSeconds 2 -ScreenshotPath $shot -SizeOverride '1200x820'
 }finally{Pop-Location}
}catch{$log.Add('CATCH :: '+$_.Exception.Message)}
$tp=Join-Path $dataDir 'testlog.txt'
if(Test-Path -LiteralPath $tp){
  foreach($ln in ([System.IO.File]::ReadAllText($tp,[System.Text.Encoding]::UTF8) -split "`r?`n")){ if($ln.Trim()){$log.Add($ln.Trim())} }
}
$ep=Join-Path $dataDir 'errors.log'
if(Test-Path -LiteralPath $ep){
  $raw=[System.IO.File]::ReadAllText($ep,[System.Text.Encoding]::UTF8)
  if(-not[string]::IsNullOrWhiteSpace($raw)){ $log.Add('--- errors ---'); foreach($ln in ($raw -split "`r?`n")){ if($ln.Trim()){$log.Add('  '+$ln.Trim())} } }
}
[System.IO.File]::WriteAllText((Join-Path $root ('verification\_'+$runTag+'.txt')),($log -join "`r`n"),(New-Object System.Text.UTF8Encoding($false)))
Write-Output ('RUNTAG='+$runTag)
