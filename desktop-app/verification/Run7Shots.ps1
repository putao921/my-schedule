param([string]$Tag = 'r7shots', [int]$AutoClose = 2, [string]$Size = '1200x820')
$ErrorActionPreference = 'Continue'
$root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app'
$stamp = (Get-Date).ToString('HHmmss') + '-' + (Get-Random -Minimum 100 -Maximum 999)
$runTag = $Tag + '__' + $stamp
$dataDir = Join-Path $root ('verification\rundata\' + $runTag)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$shotDir = Join-Path $root 'shots'
if (-not (Test-Path -LiteralPath $shotDir)) { New-Item -ItemType Directory -Force -Path $shotDir | Out-Null }
$shot = Join-Path $shotDir ($runTag + '.png')

# ---------------------------------------------------------------------------
#  第七轮截图覆盖点（用户第七轮指令 1-8）：
#   ① 任务视图：Tasks 标题已删、+New task 独占一行（第 4 条）
#   ② 期间选择窗：翻月后的月份标签（第 1 条）、标题栏只有 x（第 2 条）
#   ③ Focus 窗：mm:ss 滚轮 + Start / End & log / Reset 三按钮（第 5、6 条）
#   ④ 设置窗-窗口页：提示条停留时长选项（第 8.5 条）
#  ASCII only in messages: PS 5.1 reads non-BOM files as GBK.
# ---------------------------------------------------------------------------
$today = (Get-Date).ToString('yyyy-MM-dd')
$spec = @(
    # --- ① 任务视图（第 4 条）---
    'size:1200x820', 'layout', 'view:tasks', 'tick', 'shot:r7-tasks-header',

    # --- ② 期间选择窗：翻两月再截（第 1 条）；标题栏无 Save / 底部无 Cancel（第 2 条）---
    #   注意：pickershot 每次都重新 Show-PeriodPickerWindow，会按 $script:Anchor 重置
    #   月份 —— 所以必须"先翻月再截"，不能截一次再翻（那样第二张又被重置了）。
    'pickershot:r7-period-picker-open',
    'pickflip:next', 'pickflip:next', 'tick', 'pickershot:r7-period-picker-flipped',

    # --- ③ Focus 窗（第 5、6 条）---
    'focusshot:r7-dialog-focus',

    # --- ④ 设置-窗口页（第 8.5 条：提示条停留时长）---
    'settingstabshot:window|r7-settings-window'
) -join ','

$log = New-Object System.Collections.Generic.List[string]
$log.Add('tag     = ' + $runTag)
$log.Add('spec    = ' + $spec)
$t0 = Get-Date
try {
    $appSrc = [System.IO.File]::ReadAllText((Join-Path $root 'ScheduleWidget.ps1'), [System.Text.Encoding]::UTF8)
    Push-Location -LiteralPath $root
    try {
        & ([scriptblock]::Create($appSrc)) -TestMode -DataDir $dataDir -Script $spec `
            -AutoCloseSeconds $AutoClose -ScreenshotPath $shot -SizeOverride $Size
    } finally { Pop-Location }
} catch { $log.Add('CATCH :: ' + $_.Exception.Message) }
$log.Add('elapsed = ' + [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) + 's')
$tp = Join-Path $dataDir 'testlog.txt'
if (Test-Path -LiteralPath $tp) {
    $log.Add('--- testlog ---')
    foreach ($ln in ([System.IO.File]::ReadAllText($tp, [System.Text.Encoding]::UTF8) -split "`r?`n")) {
        if ($ln.Trim()) { $log.Add('  ' + $ln.Trim()) }
    }
}
$ep = Join-Path $dataDir 'errors.log'
$log.Add('--- errors.log ---')
if (Test-Path -LiteralPath $ep) {
    $raw = [System.IO.File]::ReadAllText($ep, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { $log.Add('  (empty)') }
    else { foreach ($ln in ($raw -split "`r?`n")) { if ($ln.Trim()) { $log.Add('  ' + $ln.Trim()) } } }
} else { $log.Add('  (none)') }
$shots = @(Get-ChildItem -LiteralPath $shotDir -Filter 'r7-*.png' | Sort-Object Name)
$log.Add('--- png count ---')
$log.Add('  ' + $shots.Count + ' r7 files in shots/')
[System.IO.File]::WriteAllText((Join-Path $root ('verification\_' + $runTag + '.txt')),
    ($log -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
