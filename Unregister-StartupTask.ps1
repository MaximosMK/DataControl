<#
.SYNOPSIS
    Unregister DataControl Startup Task
.DESCRIPTION
    Removes the DataControl Scheduled Task from Windows Task Scheduler.
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

try {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "DataControl startup task '$TaskName' successfully removed." -ForegroundColor Green
    } else {
        Write-Host "DataControl startup task was not registered." -ForegroundColor Yellow
    }
} catch {
    Write-Error "Failed to unregister scheduled task: $_"
}
