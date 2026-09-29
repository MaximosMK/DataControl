<#
.SYNOPSIS
    Remove Desktop & Start Menu Shortcuts for DataControl
.DESCRIPTION
    Deletes DataControl shortcuts from the Desktop and Start Menu.
#>

$desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "DataControl.lnk"
$startLnk = Join-Path ([Environment]::GetFolderPath("Programs")) "DataControl.lnk"

if (Test-Path $desktopLnk) {
    Remove-Item $desktopLnk -Force
    Write-Host "Removed Desktop Shortcut: $desktopLnk" -ForegroundColor Green
}

if (Test-Path $startLnk) {
    Remove-Item $startLnk -Force
    Write-Host "Removed Start Menu Shortcut: $startLnk" -ForegroundColor Green
}
