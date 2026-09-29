<#
.SYNOPSIS
    Create Desktop & Start Menu Shortcuts for DataControl
.DESCRIPTION
    Generates desktop and start menu shortcuts directly targeting DataControl.exe.
#>

$wsh = New-Object -ComObject WScript.Shell
$AppDir = Split-Path -Parent $PSScriptRoot
if (-not $AppDir -or -not (Test-Path (Join-Path $AppDir "DataControl.exe"))) {
    $AppDir = (Get-Location).Path
}
$exePath = Join-Path $AppDir "DataControl.exe"

# 1. Desktop Shortcut
$desktop = [Environment]::GetFolderPath("Desktop")
$desktopLnk = Join-Path $desktop "DataControl.lnk"
$sc1 = $wsh.CreateShortcut($desktopLnk)
$sc1.TargetPath = $exePath
$sc1.WorkingDirectory = $AppDir
$sc1.Description = "DataControl - Windows 11 Data Control System"
$sc1.IconLocation = "$exePath,0"
$sc1.Save()
Write-Host "Created Desktop Shortcut: $desktopLnk" -ForegroundColor Green

# 2. Start Menu Programs Shortcut
$programs = [Environment]::GetFolderPath("Programs")
$startLnk = Join-Path $programs "DataControl.lnk"
$sc2 = $wsh.CreateShortcut($startLnk)
$sc2.TargetPath = $exePath
$sc2.WorkingDirectory = $AppDir
$sc2.Description = "DataControl - Windows 11 Data Control System"
$sc2.IconLocation = "$exePath,0"
$sc2.Save()
Write-Host "Created Start Menu Shortcut: $startLnk" -ForegroundColor Green
