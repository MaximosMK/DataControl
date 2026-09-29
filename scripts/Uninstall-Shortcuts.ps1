<#
.SYNOPSIS
    Remove Desktop & Start Menu Shortcuts for DataControl
.DESCRIPTION
    Cleanly removes desktop and start menu shortcuts for DataControl.
#>

$desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "DataControl.lnk"
if (Test-Path $desktopLnk) {
    Remove-Item $desktopLnk -Force
    Write-Host "Removed Desktop Shortcut: $desktopLnk" -ForegroundColor Yellow
}

$startLnk = Join-Path ([Environment]::GetFolderPath("Programs")) "DataControl.lnk"
if (Test-Path $startLnk) {
    Remove-Item $startLnk -Force
    Write-Host "Removed Start Menu Shortcut: $startLnk" -ForegroundColor Yellow
}
