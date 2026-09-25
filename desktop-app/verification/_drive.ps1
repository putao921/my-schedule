param([string]$Script, [string]$Out, [Parameter(ValueFromRemainingArguments=$true)]$Rest)
# 通用驱动器：一律以 [scriptblock]::Create + ReadAllText(UTF8) 方式加载目标脚本，
# 避免 5.1 按 GBK 解码无 BOM 的 .ps1（中文注释会吃掉引号，脚本直接变形）。
# 用法: _drive.ps1 -Script <要跑的.ps1> -Out <日志文件> [-Tag x]
$ErrorActionPreference = 'Continue'
$log = New-Object System.Collections.Generic.List[string]
try {
    $src = [IO.File]::ReadAllText($Script, [Text.Encoding]::UTF8)
    $sb  = [scriptblock]::Create($src)
    $log.Add('loaded ' + $Script + ' (' + $src.Length + ' chars)')
    if ($Rest -and $Rest.Count -gt 0) {
        & $sb @Rest
    } else {
        & $sb
    }
    $log.Add('RETURNED NORMALLY')
} catch {
    $log.Add('CAUGHT: ' + $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message)
    $log.Add('  line: ' + $(try { $_.InvocationInfo.ScriptLineNumber } catch { '?' }))
    $log.Add('  text: ' + $(try { $_.InvocationInfo.Line.Trim() } catch { '?' }))
}
[IO.File]::WriteAllText($Out, ($log -join "`r`n"), [Text.UTF8Encoding]::new($false))
