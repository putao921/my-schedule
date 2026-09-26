param([string]$Tag='single')
# Verify the merged single-file build actually boots (no part files present).
$ErrorActionPreference='Continue'
$root='C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$stamp=(Get-Date).ToString('HHmmss')
$dataDir=Join-Path $root ('verification\rundata\single_' + $stamp)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$shot=Join-Path $root ('shots\single-boot.png')
$spec='size:1100x760,layout,shot:single-boot'
try{
  $src=[System.IO.File]::ReadAllText((Join-Path $root 'dist-build\MySchedule-single.ps1'),[System.Text.Encoding]::UTF8)
  Push-Location -LiteralPath ($root + '\dist-build')
  try{
    & ([scriptblock]::Create($src)) -TestMode -DataDir $dataDir -Script $spec -AutoCloseSeconds 2 -ScreenshotPath $shot -SizeOverride '1100x760'
  }finally{Pop-Location}
}catch{ Write-Output ('CATCH :: ' + $_.Exception.Message) }
$ep=Join-Path $dataDir 'errors.log'
if(Test-Path -LiteralPath $ep){
  $raw=[System.IO.File]::ReadAllText($ep,[System.Text.Encoding]::UTF8)
  $real = @($raw -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch 'SHOT ok|App.Exit' })
  if($real.Count -gt 0){ Write-Output ('ERRORS: ' + ($real -join ' | ')) } else { Write-Output 'errors: clean' }
}
Write-Output 'single-file boot test done'
