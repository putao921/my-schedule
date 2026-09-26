# -*- coding: utf-8 -*-
import io, base64

ROOT = r"C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app"
B64 = open(ROOT + r"\verification\_avatar_b64.txt", encoding="ascii").read().strip()

def read(p):
    return open(p, encoding="utf-8-sig").read()

def write(p, s):
    open(p, "w", encoding="utf-8-sig", newline="").write(s)

# ---------- Ui.ps1: default avatar resource + loader + Set-AvatarElement ----------
ui = read(ROOT + r"\Ui.ps1")

anchor = "function Draw-Avatar {\n    param($Canvas)"
inject = (
    "# ===========================================================================\n"
    "#  内嵌默认头像（第十四轮）：打招呼的小女孩（128x128 PNG，base64）。\n"
    "#  替代原 Draw-Avatar 像素小人成为出厂默认头像；托盘图标复用同一份资源。\n"
    "#  为什么内嵌而不带文件：保持绿色包 = 5 个 ps1、零外部资源的现状，\n"
    "#  换电脑 / 打 exe 都不会出现「图标找不到」。\n"
    "# ===========================================================================\n"
    "$script:DefaultAvatarB64 = '" + B64 + "'\n\n"
    "function New-DefaultAvatarBitmap {\n"
    "    # 从内嵌 base64 解码出默认头像的 BitmapImage。\n"
    "    try {\n"
    "        $bytes = [System.Convert]::FromBase64String($script:DefaultAvatarB64)\n"
    "        $ms = New-Object System.IO.MemoryStream -ArgumentList (, $bytes)\n"
    "        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage\n"
    "        $bmp.BeginInit()\n"
    "        $bmp.StreamSource = $ms\n"
    "        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad\n"
    "        $bmp.EndInit()\n"
    "        $bmp.Freeze()\n"
    "        $ms.Dispose()\n"
    "        return $bmp\n"
    "    } catch {\n"
    "        Write-ErrLog ('New-DefaultAvatarBitmap: ' + $_.Exception.Message)\n"
    "        return $null\n"
    "    }\n"
    "}\n\n"
)
assert anchor in ui, "anchor Draw-Avatar not found"
ui = ui.replace(anchor, inject + anchor, 1)

old_set = (
    "function Set-AvatarElement {\n"
    "    param($Image, $Canvas, $Hint, $HintBox, [string]$Path)\n"
    "    if ($null -eq $Image -or $null -eq $Canvas) { return $false }\n"
    "    $bmp = New-AvatarBitmap $Path\n"
    "    if ($null -ne $bmp) {\n"
    "        $Image.Source = $bmp\n"
    "        $Image.Visibility = 'Visible'\n"
    "        $Canvas.Visibility = 'Collapsed'\n"
    "        if ($null -ne $HintBox) { $HintBox.Visibility = 'Collapsed' }\n"
    "        if ($null -ne $Hint) { $Hint.Text = '' }\n"
    "        return $true\n"
    "    }\n"
    "    $Image.Source = $null\n"
    "    $Image.Visibility = 'Collapsed'\n"
    "    $Canvas.Visibility = 'Visible'\n"
    "    if ($null -ne $HintBox) { $HintBox.Visibility = 'Visible' }\n"
    "    if ($null -ne $Hint) { $Hint.Text = (Get-LangText 'av.change') }\n"
    "    return $false\n"
    "}\n"
)
new_set = (
    "function Set-AvatarElement {\n"
    "    param($Image, $Canvas, $Hint, $HintBox, [string]$Path)\n"
    "    if ($null -eq $Image -or $null -eq $Canvas) { return $false }\n"
    "    # 优先用户头像；为空或加载失败时回退到内嵌默认头像（小女孩，第十四轮）。\n"
    "    # 返回值只表达「是否成功加载了用户提供的图片」：默认头像不算用户图片，\n"
    "    # 这样 Apply-AvatarImage 在用户图加载失败时能正确清空 AvatarPath（回默认）。\n"
    "    $userBmp = New-AvatarBitmap $Path\n"
    "    $bmp = $userBmp\n"
    "    if ($null -eq $bmp) { $bmp = New-DefaultAvatarBitmap }\n"
    "    if ($null -ne $bmp) {\n"
    "        $Image.Source = $bmp\n"
    "        $Image.Visibility = 'Visible'\n"
    "        $Canvas.Visibility = 'Collapsed'\n"
    "        if ($null -ne $HintBox) { $HintBox.Visibility = 'Collapsed' }\n"
    "        if ($null -ne $Hint) { $Hint.Text = '' }\n"
    "        return ($null -ne $userBmp)\n"
    "    }\n"
    "    $Image.Source = $null\n"
    "    $Image.Visibility = 'Collapsed'\n"
    "    $Canvas.Visibility = 'Visible'\n"
    "    if ($null -ne $HintBox) { $HintBox.Visibility = 'Visible' }\n"
    "    if ($null -ne $Hint) { $Hint.Text = (Get-LangText 'av.change') }\n"
    "    return $false\n"
    "}\n"
)
assert old_set in ui, "Set-AvatarElement old not found"
ui = ui.replace(old_set, new_set, 1)
write(ROOT + r"\Ui.ps1", ui)
print("Ui.ps1 updated")

# ---------- Care.ps1: tray icon ----------
care = read(ROOT + r"\Care.ps1")

anchor2 = "function New-TrayIcon {"
inject2 = (
    "function New-AppIcon {\n"
    "    # 托盘图标（第十四轮）：从内嵌默认头像生成 32x32 Icon。\n"
    "    # 之前用 SystemIcons.Application（灰色通用图标）辨识度差，换成小女孩。\n"
    "    try {\n"
    "        $bytes = [System.Convert]::FromBase64String($script:DefaultAvatarB64)\n"
    "        $ms = New-Object System.IO.MemoryStream -ArgumentList (, $bytes)\n"
    "        $src = New-Object System.Drawing.Bitmap($ms)\n"
    "        $bmp = New-Object System.Drawing.Bitmap($src, 32, 32)\n"
    "        # 保活：HICON 依赖 bitmap，别让 GC 提前回收导致托盘图标变白。\n"
    "        $script:AppIconBitmap = $bmp\n"
    "        $script:AppIcon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())\n"
    "        $src.Dispose()\n"
    "        $ms.Dispose()\n"
    "        return $script:AppIcon\n"
    "    } catch {\n"
    "        Write-ErrLog ('New-AppIcon: ' + $_.Exception.Message)\n"
    "        return $null\n"
    "    }\n"
    "}\n\n"
)
assert anchor2 in care, "anchor New-TrayIcon not found"
care = care.replace(anchor2, inject2 + anchor2, 1)

old_icon = (
    "    $ni = New-Object System.Windows.Forms.NotifyIcon\n"
    "    try {\n"
    "        $ni.Icon = [System.Drawing.SystemIcons]::Application\n"
    "    } catch { }\n"
)
new_icon = (
    "    $ni = New-Object System.Windows.Forms.NotifyIcon\n"
    "    try {\n"
    "        $ni.Icon = New-AppIcon\n"
    "        if ($null -eq $ni.Icon) { $ni.Icon = [System.Drawing.SystemIcons]::Application }\n"
    "    } catch {\n"
    "        $ni.Icon = [System.Drawing.SystemIcons]::Application\n"
    "    }\n"
)
assert old_icon in care, "tray icon old not found"
care = care.replace(old_icon, new_icon, 1)
write(ROOT + r"\Care.ps1", care)
print("Care.ps1 updated")
