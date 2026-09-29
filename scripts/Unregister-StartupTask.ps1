<#
.SYNOPSIS
    Unregister DataControl Elevated Startup Task
.DESCRIPTION
    Removes the DataControl background monitor task from Windows Task Scheduler.
#>

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Administrator elevation required to unregister scheduled task. Elevating..."
    $scriptFile = $PSCommandPath
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptFile`"") -Verb RunAs
    exit
}

$TaskName = "DataControl_Monitor"

try {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "Successfully removed scheduled task '$TaskName'." -ForegroundColor Yellow
    } else {
        Write-Host "Scheduled task '$TaskName' does not exist." -ForegroundColor Cyan
    }
} catch {
    Write-Error "Failed to unregister scheduled task: $_"
}
