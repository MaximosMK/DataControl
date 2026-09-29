<#
.SYNOPSIS
    DataControl Configuration & History Storage Manager
.DESCRIPTION
    Handles local JSON persistence for configuration settings, interface traffic history,
    and cumulative per-application usage leaderboards.
#>

function Init-StoragePaths ($baseDir) {
    $script:AppDir = $baseDir
    $script:ConfigFile = Join-Path $baseDir "config.json"
    $script:HistoryFile = Join-Path $baseDir "data_history.json"
    $script:AppHistoryFile = Join-Path $baseDir "app_history.json"
    $script:IconPath = Join-Path $baseDir "assets\DataControl.ico"
    if (-not (Test-Path $script:IconPath)) {
        $script:IconPath = Join-Path $baseDir "DataControl.ico"
    }
    $script:TaskName = "DataControl_Monitor"
}

function Load-AppConfig {
    if (Test-Path $script:ConfigFile) {
        try {
            $raw = Get-Content -Path $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $raw.daily_limit_gb) { $raw | Add-Member -MemberType NoteProperty -Name "daily_limit_gb" -Value 2.0 -Force }
            if (-not $raw.daily_warning_gb) { $raw | Add-Member -MemberType NoteProperty -Name "daily_warning_gb" -Value 1.7 -Force }
            if ($null -eq $raw.auto_disconnect_daily) { $raw | Add-Member -MemberType NoteProperty -Name "auto_disconnect_daily" -Value $true -Force }
            return $raw
        } catch {}
    }
    return [PSCustomObject]@{
        target_adapter         = "Wi-Fi"
        daily_limit_gb         = 2.0
        daily_warning_gb       = 1.7
        monthly_limit_gb       = 16.0
        warning_threshold_gb   = 14.0
        auto_disconnect        = $true
        auto_disconnect_daily  = $true
        poll_frequency_seconds = 3
    }
}

function Save-AppConfig ($cfg) {
    try {
        $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $script:ConfigFile -Encoding UTF8
    } catch {
        Write-Warning "Failed to save configuration: $_"
    }
}

function Load-DataHistory {
    if (Test-Path $script:HistoryFile) {
        try {
            $raw = Get-Content -Path $script:HistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $raw.last_raw_total_bytes) { $raw | Add-Member -MemberType NoteProperty -Name "last_raw_total_bytes" -Value 0 -Force }
            if (-not $raw.daily) { $raw | Add-Member -MemberType NoteProperty -Name "daily" -Value (New-Object PSCustomObject) -Force }
            if (-not $raw.monthly) { $raw | Add-Member -MemberType NoteProperty -Name "monthly" -Value (New-Object PSCustomObject) -Force }
            if (-not $raw.yearly) { $raw | Add-Member -MemberType NoteProperty -Name "yearly" -Value (New-Object PSCustomObject) -Force }
            return $raw
        } catch {}
    }
    return [PSCustomObject]@{
        last_raw_total_bytes = 0
        daily                = [PSCustomObject]@{}
        monthly              = [PSCustomObject]@{}
        yearly               = [PSCustomObject]@{}
    }
}

function Save-DataHistory ($hist) {
    try {
        $hist | ConvertTo-Json -Depth 6 | Set-Content -Path $script:HistoryFile -Encoding UTF8
    } catch {
        Write-Warning "Failed to save data history: $_"
    }
}

function Load-AppHistory {
    if (Test-Path $script:AppHistoryFile) {
        try {
            $raw = Get-Content -Path $script:AppHistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
            return $raw
        } catch {}
    }
    return (New-Object PSCustomObject)
}

function Save-AppHistory ($appHist) {
    try {
        $appHist | ConvertTo-Json -Depth 6 | Set-Content -Path $script:AppHistoryFile -Encoding UTF8
    } catch {}
}

function Format-Bytes ([double]$bytes) {
    if ($bytes -ge 1GB) {
        return "$([math]::Round($bytes / 1GB, 2)) GB"
    } elseif ($bytes -ge 1MB) {
        return "$([math]::Round($bytes / 1MB, 2)) MB"
    } elseif ($bytes -ge 1KB) {
        return "$([math]::Round($bytes / 1KB, 1)) KB"
    } else {
        return "$([math]::Round($bytes, 0)) B"
    }
}

function Test-StartupTaskEnabled {
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    return ($null -ne $task)
}

function Set-StartupTaskEnabled ([bool]$enable) {
    if ($enable) {
        $exePath = Join-Path $script:AppDir "DataControl.exe"
        if (Test-Path $exePath) {
            $action = New-ScheduledTaskAction -Execute $exePath -Argument "-StartMinimized"
        } else {
            $scriptPath = Join-Path $script:AppDir "DataControl.ps1"
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
                -TaskName $script:TaskName `
                -Action $action `
                -Trigger $trigger `
                -Principal $principalTask `
                -Settings $settings `
                -Description "DataControl Autonomous Network Metering & Quota Enforcement Sentry" `
                -Force | Out-Null
            return $true
        } catch {
            return $false
        }
    } else {
        try {
            Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
            return $true
        } catch {
            return $false
        }
    }
}
