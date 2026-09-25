param([string]$Tag = 'r8shots', [int]$AutoClose = 2, [string]$Size = '1200x820')
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
#  第六轮截图覆盖点（用户第六轮指令）：
#   ① 任务卡左侧勾选方块：未勾 / 已勾 两种形态（第 2 条 bug 的可视证据）
#   ② 弹窗标题栏只留 Save + ×（第 3 条：Cancel 已删）
#   ③ 设置窗字段（用于确认字段名与控件都在）
#   ④ 任务卡展开态
#   ⑤ 多级撤销：连删 3 条后侧栏提示条显示 "(3)"，逐级回退，栈空时给提示
#  ASCII only in messages: PS 5.1 reads non-BOM files as GBK.
# ---------------------------------------------------------------------------
$today = (Get-Date).ToString('yyyy-MM-dd')
$anchorBack = 'anchor:' + $today
$spec = @(
    # --- ① 任务视图：任务卡左侧勾选方块（第 2 条 bug 的可视证据）---
    'size:1200x820', 'layout', 'view:tasks', 'tick', 'shot:r8-tasks-unchecked',
    # 勾选第一张卡（走真实点击链路），再截"已勾"状态
    'tick', 'taskcheck', 'tick', 'shot:r8-tasks-checked',

    # --- ② 弹窗标题栏只留 Save + ×（第 3 条：Cancel 已删）---
    'eventshot:r8-dialog-event',
    'taskshot:r8-dialog-task',
    'settingshot:r8-dialog-settings',
    'focusshot:r8-dialog-focus',
    'avatarshot:r8-dialog-avatar',

    # --- ③ 设置窗口分页：四页各拍一张（第 1 条）---
    'settingstabshot:appear|r8-settings-appear',
    'settingstabshot:window|r8-settings-window',
    'settingstabshot:data|r8-settings-data',
    'settingstabshot:about|r8-settings-about',

    # --- ④ 任务卡展开态（确认勾选方块与 caret 不打架）---
    'caretshot:*',

    # --- ⑤ 多级撤销（第 1 条第 4 项）：连删 3 条 -> 侧栏提示条显示 "(3)" ---
    'view:tasks', 'tick', 'undodemo:3', 'tick', 'shot:r8-undo-depth3',
    # 连按 2 次撤销，条上应显示还剩 1 次
    'undodepth:2', 'tick', 'shot:r8-undo-depth1',
    # 再撤一次 -> 栈空，侧栏应出现"没有可撤销的操作了"
    'undodepth:1', 'tick', 'shot:r8-undo-empty',

    # --- ⑥ 提示条角落（第 1 条第 5 项）：默认右下角那条撤销提示条 ---
    'undodemo:2', 'tick', 'toastshot:r8-toast-br'
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
$shots = @(Get-ChildItem -LiteralPath $shotDir -Filter 'r8-*.png' | Sort-Object Name)
$log.Add('--- png count ---')
$log.Add('  ' + $shots.Count + ' r8 files in shots/')
[System.IO.File]::WriteAllText((Join-Path $root ('verification\_' + $runTag + '.txt')),
    ($log -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
