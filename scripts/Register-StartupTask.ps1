<#
.SYNOPSIS
    Register DataControl Elevated Startup Task
.DESCRIPTION
    Creates an elevated logon task in Windows Task Scheduler so DataControl
    starts automatically and silently in the background with zero UAC prompts.
#>

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Administrator elevation required to register scheduled task. Elevating..."
    $scriptFile = $PSCommandPath
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptFile`"") -Verb RunAs
    exit
}

$TaskName = "DataControl_Monitor"
$AppDir = Split-Path -Parent $PSScriptRoot
if (-not $AppDir -or -not (Test-Path (Join-Path $AppDir "DataControl.exe"))) {
    $AppDir = (Get-Location).Path
}

$exePath = Join-Path $AppDir "DataControl.exe"
if (Test-Path $exePath) {
    $action = New-ScheduledTaskAction -Execute $exePath -Argument "-StartMinimized"
} else {
    $scriptPath = Join-Path $AppDir "DataControl.ps1"
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -StartMinimized"
}

$trigger = New-ScheduledTaskTrigger -AtLogOn
$principalTask = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit 0 `
    -Priority 4

try {
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principalTask `
        -Settings $settings `
        -Description "DataControl Autonomous Network Metering & Quota Enforcement Sentry" `
        -Force | Out-Null
    Write-Host "Successfully registered scheduled startup task '$TaskName'." -ForegroundColor Green
    Write-Host "DataControl will start automatically at Windows logon silently in the background." -ForegroundColor Cyan
} catch {
    Write-Error "Failed to register scheduled task: $_"
}
