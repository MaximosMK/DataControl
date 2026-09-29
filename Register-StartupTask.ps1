<#
.SYNOPSIS
    Register DataControl as an Elevated Windows Startup Task
.DESCRIPTION
    Creates a Windows Scheduled Task that automatically starts DataControl
    in the background at user logon with highest (Administrator) privileges,
    preventing repeated UAC prompts.
#>

# Privilege check
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $script = $PSCommandPath
    if (-not $script) { $script = (Get-Item $MyInvocation.MyCommand.Definition).FullName }
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$script`"") -Verb RunAs
    exit
}

$TaskName = "DataControl_Monitor"
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $AppDir) { $AppDir = (Get-Location).Path }
$ExePath = Join-Path $AppDir "DataControl.exe"

if (-not (Test-Path $ExePath)) {
    Write-Error "DataControl.exe not found in $AppDir"
    exit 1
}

# Define Task Components
$action = New-ScheduledTaskAction `
    -Execute $ExePath `
    -Argument "-StartMinimized"

$trigger = New-ScheduledTaskTrigger -AtLogOn

$principal = New-ScheduledTaskPrincipal `
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
        -Principal $principal `
        -Settings $settings `
        -Description "DataControl Autonomous Network Metering & Quota Enforcement Sentry" `
        -Force | Out-Null

    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host " SUCCESS: DataControl has been registered as a startup task!" -ForegroundColor Green
    Write-Host " Task Name: $TaskName" -ForegroundColor Cyan
    Write-Host " Privilege: Highest (Administrator, no UAC prompts on logon)" -ForegroundColor Cyan
    Write-Host " Target: $ExePath -StartMinimized" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Green
} catch {
    Write-Error "Failed to register scheduled task: $_"
    exit 1
}
