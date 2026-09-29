<#
.SYNOPSIS
    Create Desktop & Start Menu Shortcuts for DataControl
.DESCRIPTION
    Generates desktop and start menu shortcuts with custom icon and silent background execution.
#>

$wsh = New-Object -ComObject WScript.Shell
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $AppDir) { $AppDir = (Get-Location).Path }
$vbsPath = Join-Path $AppDir "Start-DataControl.vbs"
$icoPath = Join-Path $AppDir "DataControl.ico"

# 1. Desktop Shortcut
$desktop = [Environment]::GetFolderPath("Desktop")
$desktopLnk = Join-Path $desktop "DataControl.lnk"
$sc1 = $wsh.CreateShortcut($desktopLnk)
$sc1.TargetPath = "wscript.exe"
$sc1.Arguments = "`"$vbsPath`""
$sc1.WorkingDirectory = $AppDir
$sc1.Description = "DataControl - Windows 11 Data Control System"
if (Test-Path $icoPath) { $sc1.IconLocation = "$icoPath,0" }
$sc1.Save()
Write-Host "Created Desktop Shortcut: $desktopLnk" -ForegroundColor Green

# 2. Start Menu Programs Shortcut
$programs = [Environment]::GetFolderPath("Programs")
$startLnk = Join-Path $programs "DataControl.lnk"
$sc2 = $wsh.CreateShortcut($startLnk)
$sc2.TargetPath = "wscript.exe"
$sc2.Arguments = "`"$vbsPath`""
$sc2.WorkingDirectory = $AppDir
$sc2.Description = "DataControl - Windows 11 Data Control System"
if (Test-Path $icoPath) { $sc2.IconLocation = "$icoPath,0" }
$sc2.Save()
Write-Host "Created Start Menu Shortcut: $startLnk" -ForegroundColor Green
