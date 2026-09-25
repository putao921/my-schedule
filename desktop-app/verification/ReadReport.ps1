# ReadReport.ps1 — 读回检查报告的小工具
# 背景：Write-ResultFile 默认写出的是 UTF-16LE + BOM，Read 工具会当成二进制拒绝显示。
# 这里按实际字节嗅探编码，统一转成 UTF-8 无 BOM，并用 ASCII 安全的方式落盘。
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Out
)

if (-not (Test-Path -LiteralPath $Path)) { "MISSING: $Path"; exit 1 }
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path (Split-Path -Parent $Path) '_read.txt' }

$b = [System.IO.File]::ReadAllBytes($Path)
$txt = $null

if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) {
    $txt = [System.Text.Encoding]::Unicode.GetString($b)
}
elseif ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
    $txt = [System.Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3)
}
else {
    # 无 BOM：先按 UTF8 严解码，失败说明大概率是 GBK
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        $txt = $strict.GetString($b)
    }
    catch {
        $txt = [System.Text.Encoding]::GetEncoding(936).GetString($b)
    }
}

# 去掉 UTF-16 解码可能残留的 BOM 字符
$txt = $txt.TrimStart([char]0xFEFF)

[System.IO.File]::WriteAllText($Out, $txt, (New-Object System.Text.UTF8Encoding($false)))
"OK -> $Out  (srcBytes=$($b.Length), chars=$($txt.Length))"
