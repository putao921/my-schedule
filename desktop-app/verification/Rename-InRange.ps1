# ---------------------------------------------------------------------------
#  在指定行区间内做"整词"变量改名
#
#  为什么需要它：把处理器要用的局部变量提升到 $script: 作用域，必须在
#  【同一个函数内部】把所有出现处一起改掉；但 $win 这类短名在别的函数里还有别的
#  含义，全局替换会误伤。行区间 + 整词匹配是最稳的做法。
#
#  两个坑：
#   1) Regex.Replace 的 replacement 参数里 $ 是分组引用，必须写成 $$ 才是字面量
#   2) 用 MatchEvaluator 脚本块计数的话，脚本块里改 $script: 变量同样受作用域限制
#      —— 所以先用 Matches 计数，再单独替换
# ---------------------------------------------------------------------------
param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][int]$Start,
    [Parameter(Mandatory = $true)][int]$End,
    [Parameter(Mandatory = $true)][string]$Old,
    [Parameter(Mandatory = $true)][string]$New,
    [switch]$DryRun
)
$logPath = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification\_rename.txt'
$text = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8)
$lines = $text -split "`r?`n"
if ($Start -lt 1 -or $End -gt $lines.Count -or $Start -gt $End) {
    [System.IO.File]::WriteAllText($logPath, "RANGE ERROR file=$File start=$Start end=$End total=$($lines.Count)")
    return
}
$pat = '(?<![A-Za-z0-9_:])' + [regex]::Escape($Old) + '(?![A-Za-z0-9_])'
$lit = $New.Replace('$', '$$')   # 字面量 $：.NET 里要写成 $$
$n = 0
for ($i = $Start - 1; $i -le $End - 1; $i++) {
    $n += [regex]::Matches($lines[$i], $pat).Count
    $lines[$i] = [regex]::Replace($lines[$i], $pat, $lit)
}
if (-not $DryRun) {
    [System.IO.File]::WriteAllText($File, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
}
[System.IO.File]::WriteAllText($logPath,
    "renamed $n x '$Old' -> '$New' in '$File' lines $Start..$End (dryRun=$DryRun)",
    (New-Object System.Text.UTF8Encoding($false)))
