param([string]$Tag = 'shots11', [int]$AutoClose = 2, [string]$Size = '1200x820')
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
#  第五轮截图覆盖点（用户最新指令："先按照你的建议做外观"）：
#   ① 语言统一：同一屏不再混用 Mon/Tue/Wed 与 提交读书报告（zh / en 各一张）
#   ② 夜间层级差：表头与内容能看出层次（CardAlt/Panel 各拉开 12 级）
#   ③ 强调色的明度分层：Event 更深 / Focus 更亮 / Task 居中
#   ④ 周视图密度三档：Compact 28 / Normal 40 / Roomy 56
#   ⑤ 空状态：列表无结果时给出"文案 + 可点按钮"，而不是纯空白
#   ⑥ 删除撤销提示条（5 秒内可撤销）
#  ASCII only in messages: PS 5.1 reads non-BOM files as GBK.
# ---------------------------------------------------------------------------
$today = (Get-Date).ToString('yyyy-MM-dd')
$anchorBack = 'anchor:' + $today
$spec = @(
    # --- ① 语言 zh：整屏中文框架 ---
    'size:1200x820', 'layout', 'lang:zh', 'view:month', $anchorBack, 'tick', 'shot:r7-lang-zh-month',
    'view:week', 'weekrange:8-20', 'tick', 'shot:r7-lang-zh-week',
    'view:list', 'tick', 'shot:r7-lang-zh-list',
    'view:tasks', 'tick', 'shot:r7-lang-zh-tasks',

    # --- ① 语言 en：整屏英文框架 ---
    'lang:en', 'view:month', $anchorBack, 'tick', 'shot:r7-lang-en-month',
    'view:week', 'weekrange:8-20', 'tick', 'shot:r7-lang-en-week',
    'lang:zh', 'view:month', $anchorBack, 'tick',

    # --- ②③ 夜间：层级差 + 强调色分层 ---
    'theme:night', 'view:week', 'weekrange:8-20', 'tick', 'shot:r7-night-week',
    'view:month', $anchorBack, 'tick', 'shot:r7-night-month',
    'theme:light', 'tick',

    # --- ③ 浅色强调色分层 ---
    'view:week', 'weekrange:8-20', 'tick', 'shot:r7-light-week',

    # --- ④ 三档密度 ---
    'density:28', 'tick', 'shot:r7-density-compact',
    'density:56', 'tick', 'shot:r7-density-roomy',
    'density:40', 'tick', 'shot:r7-density-normal',

    # --- ⑥ 删除 + 撤销提示条 ---
    'view:tasks', 'tick', 'shot:r7-tasks-before',
    'undodemo', 'tick', 'shot:r7-undo-toast', 'toastshot:r7-undo-toast-window',
    'undo', 'tick', 'shot:r7-undo-restored',

    # --- ⑤ 空状态（筛选后无结果）---
    'view:list', 'tick', 'emptydemo', 'tick', 'shot:r7-empty-state',
    'clearfilter', 'tick', 'shot:r7-list-restored'
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
