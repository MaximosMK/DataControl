<#
.SYNOPSIS
    DataControl Dual Quota Enforcement Engine
.DESCRIPTION
    Evaluates current daily and monthly consumption against configured thresholds.
    Dispatches warning notifications and executes automated network adapter cutoffs.
#>

function Check-EnforcementRules {
    $now = Get-Date
    $dayKey = $now.ToString("yyyy-MM-dd")
    $monthKey = $now.ToString("yyyy-MM")

    $dayBytes = 0.0
    if ($script:DataHistory.daily.PSObject.Properties[$dayKey]) {
        $dayBytes = [double]$script:DataHistory.daily.$dayKey
    }

    $monthBytes = 0.0
    if ($script:DataHistory.monthly.PSObject.Properties[$monthKey]) {
        $monthBytes = [double]$script:DataHistory.monthly.$monthKey
    }

    $dayGB = $dayBytes / 1GB
    $monthGB = $monthBytes / 1GB

    $dailyLimitGB = [double]$script:AppConfig.daily_limit_gb
    $dailyWarnGB  = [double]$script:AppConfig.daily_warning_gb
    $monthlyLimitGB = [double]$script:AppConfig.monthly_limit_gb
    $monthlyWarnGB  = [double]$script:AppConfig.warning_threshold_gb
    $targetAdapter = [string]$script:AppConfig.target_adapter

    # 1. Daily Warning Alert
    if ($dayGB -ge $dailyWarnGB -and $dayGB -lt $dailyLimitGB) {
        if (-not $script:DailyWarningNotified) {
            $NotifyIcon.ShowBalloonTip(
                4000,
                "DataControl: Daily Warning Threshold Reached",
                "Today's data consumption has reached $([math]::Round($dayGB, 2)) GB (Warning: $dailyWarnGB GB / Limit: $dailyLimitGB GB).",
                [System.Windows.Forms.ToolTipIcon]::Warning
            )
            $script:DailyWarningNotified = $true
        }
    } elseif ($dayGB -lt $dailyWarnGB) {
        $script:DailyWarningNotified = $false
    }

    # 2. Daily Hard Limit Exceeded & Auto-Cutoff
    if ($dayGB -ge $dailyLimitGB) {
        if (-not $script:DailyLimitNotified) {
            if ($script:AppConfig.auto_disconnect_daily) {
                try {
                    Disable-NetAdapter -Name $targetAdapter -Confirm:$false -ErrorAction SilentlyContinue
                } catch {}

                $NotifyIcon.ShowBalloonTip(
                    6000,
                    "DataControl: Daily Quota Limit Reached!",
                    "Daily limit of $dailyLimitGB GB reached! Automated shutoff disabled adapter '$targetAdapter' to protect your data.",
                    [System.Windows.Forms.ToolTipIcon]::Error
                )
            } else {
                $NotifyIcon.ShowBalloonTip(
                    5000,
                    "DataControl: Daily Quota Reached!",
                    "You have used $([math]::Round($dayGB, 2)) GB today (Daily Limit: $dailyLimitGB GB).",
                    [System.Windows.Forms.ToolTipIcon]::Warning
                )
            }
            $script:DailyLimitNotified = $true
        }
    } else {
        $script:DailyLimitNotified = $false
    }

    # 3. Monthly Warning Alert
    if ($monthGB -ge $monthlyWarnGB -and $monthGB -lt $monthlyLimitGB) {
        if (-not $script:MonthlyWarningNotified) {
            $NotifyIcon.ShowBalloonTip(
                4000,
                "DataControl: Monthly Warning Threshold Reached",
                "Monthly usage has reached $([math]::Round($monthGB, 2)) GB (Warning: $monthlyWarnGB GB / Limit: $monthlyLimitGB GB).",
                [System.Windows.Forms.ToolTipIcon]::Warning
            )
            $script:MonthlyWarningNotified = $true
        }
    } elseif ($monthGB -lt $monthlyWarnGB) {
        $script:MonthlyWarningNotified = $false
    }

    # 4. Monthly Hard Limit Exceeded & Auto-Cutoff
    if ($monthGB -ge $monthlyLimitGB) {
        if (-not $script:MonthlyLimitNotified) {
            if ($script:AppConfig.auto_disconnect) {
                try {
                    Disable-NetAdapter -Name $targetAdapter -Confirm:$false -ErrorAction SilentlyContinue
                } catch {}

                $NotifyIcon.ShowBalloonTip(
                    6000,
                    "DataControl: Monthly Quota Limit Exceeded!",
                    "Monthly limit of $monthlyLimitGB GB reached! Automated shutoff disabled adapter '$targetAdapter' to avoid overages.",
                    [System.Windows.Forms.ToolTipIcon]::Error
                )
            } else {
                $NotifyIcon.ShowBalloonTip(
                    5000,
                    "DataControl: Monthly Quota Exceeded!",
                    "Monthly usage reached $([math]::Round($monthGB, 2)) GB (Limit: $monthlyLimitGB GB).",
                    [System.Windows.Forms.ToolTipIcon]::Warning
                )
            }
            $script:MonthlyLimitNotified = $true
        }
    } else {
        $script:MonthlyLimitNotified = $false
    }
}
