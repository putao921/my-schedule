$out = @()
try {
    $nuget = Get-PackageProvider -ListAvailable | Where-Object { $_.Name -eq 'NuGet' }
    if (-not $nuget) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
        $out += "nuget provider installed"
    } else { $out += ("nuget provider present: " + $nuget[0].Version) }
} catch { $out += ("nuget install failed: " + $_.Exception.Message) }
try {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    $m2 = Get-Module -ListAvailable -Name ps2exe
    if ($m2) { $out += ("ps2exe installed: " + $m2.Version) } else { $out += "install reported ok but module not found" }
} catch { $out += ("ps2exe install failed: " + $_.Exception.Message) }
[System.IO.File]::WriteAllLines('C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification\_ps2exe.txt', $out)
