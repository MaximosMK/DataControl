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

    # Global total bytes across all connections
    $totalDayBytes = 0.0
    if ($script:DataHistory.daily.PSObject.Properties[$dayKey]) {
        $totalDayBytes = [double]$script:DataHistory.daily.$dayKey
    }

    $totalMonthBytes = 0.0
    if ($script:DataHistory.monthly.PSObject.Properties[$monthKey]) {
        $totalMonthBytes = [double]$script:DataHistory.monthly.$monthKey
    }

    $totalDayGB = $totalDayBytes / 1GB
    $totalMonthGB = $totalMonthBytes / 1GB

    $globalDailyLimitGB = [double]$script:AppConfig.daily_limit_gb
    $globalDailyWarnGB  = [double]$script:AppConfig.daily_warning_gb
    $globalMonthlyLimitGB = [double]$script:AppConfig.monthly_limit_gb
    $globalMonthlyWarnGB  = [double]$script:AppConfig.warning_threshold_gb
    $targetAdapter = [string]$script:AppConfig.target_adapter

    $activeProf = Get-ActiveNetworkProfile
    $netName = $activeProf.Name

    # -------------------------------------------------------------------------
    # Level 1: Per-Network SSID / Adapter Limiter
    # -------------------------------------------------------------------------
    if (-not $activeProf.IsUnlimited -and $netName) {
        $netDailyLimit = [double]$activeProf.DailyLimitGB
        $netMonthlyLimit = [double]$activeProf.MonthlyLimitGB
        $netAutoCutoffDaily = [bool]$activeProf.AutoDisconnectDaily
        $netAutoCutoffMonthly = [bool]$activeProf.AutoDisconnectMonthly

        $netDayBytes = 0.0
        $netMonthBytes = 0.0
        if ($script:DataHistory.networks -and $script:DataHistory.networks.PSObject.Properties[$netName]) {
            $nObj = $script:DataHistory.networks.$netName
            if ($nObj.daily -and $nObj.daily.PSObject.Properties[$dayKey]) {
                $netDayBytes = [double]$nObj.daily.$dayKey
            }
            if ($nObj.monthly -and $nObj.monthly.PSObject.Properties[$monthKey]) {
                $netMonthBytes = [double]$nObj.monthly.$monthKey
            }
        }

        $netDayGB = $netDayBytes / 1GB
        $netMonthGB = $netMonthBytes / 1GB

        # Per-Network Daily Limit
        if ($netDailyLimit -gt 0) {
            if ($netDayGB -ge $netDailyLimit) {
                if (-not $script:NetDailyLimitNotified) {
                    if ($netAutoCutoffDaily) {
                        try {
                            Disable-NetAdapter -Name $targetAdapter -Confirm:$false -ErrorAction SilentlyContinue
                        } catch { $null = $_ }

                        $NotifyIcon.ShowBalloonTip(
                            6000,
                            "DataControl: Network Daily Quota Reached!",
                            "Daily limit of $netDailyLimit GB reached on '$netName'! Adapter '$targetAdapter' disabled to protect metered data.",
                            [System.Windows.Forms.ToolTipIcon]::Error
                        )
                    } else {
                        $NotifyIcon.ShowBalloonTip(
                            5000,
                            "DataControl: Network Daily Limit Warning",
                            "Daily usage on '$netName' has reached $([math]::Round($netDayGB, 2)) GB (Limit: $netDailyLimit GB).",
                            [System.Windows.Forms.ToolTipIcon]::Warning
                        )
                    }
                    $script:NetDailyLimitNotified = $true
                }
            } else {
                $script:NetDailyLimitNotified = $false
            }
        }

        # Per-Network Monthly Limit
        if ($netMonthlyLimit -gt 0) {
            if ($netMonthGB -ge $netMonthlyLimit) {
                if (-not $script:NetMonthlyLimitNotified) {
                    if ($netAutoCutoffMonthly) {
                        try {
                            Disable-NetAdapter -Name $targetAdapter -Confirm:$false -ErrorAction SilentlyContinue
                        } catch { $null = $_ }

                        $NotifyIcon.ShowBalloonTip(
                            6000,
                            "DataControl: Network Monthly Quota Reached!",
                            "Monthly limit of $netMonthlyLimit GB reached on '$netName'! Adapter '$targetAdapter' disabled.",
                            [System.Windows.Forms.ToolTipIcon]::Error
                        )
                    } else {
                        $NotifyIcon.ShowBalloonTip(
                            5000,
                            "DataControl: Network Monthly Limit Warning",
                            "Monthly usage on '$netName' reached $([math]::Round($netMonthGB, 2)) GB (Limit: $netMonthlyLimit GB).",
                            [System.Windows.Forms.ToolTipIcon]::Warning
                        )
                    }
                    $script:NetMonthlyLimitNotified = $true
                }
            } else {
                $script:NetMonthlyLimitNotified = $false
            }
        }
    } else {
        $script:NetDailyLimitNotified = $false
        $script:NetMonthlyLimitNotified = $false
    }

    # -------------------------------------------------------------------------
    # Level 2: Total Limiter (Aggregate Across All Networks)
    # -------------------------------------------------------------------------
    if (Test-IsCurrentNetworkUnlimited) {
        # Current connection is explicitly unlimited (e.g. fiber LAN or unmetered Wi-Fi)
        $script:DailyWarningNotified = $false
        $script:DailyLimitNotified = $false
        $script:MonthlyWarningNotified = $false
        $script:MonthlyLimitNotified = $false
        return
    }

    # 1. Total Daily Warning Alert
    if ($globalDailyLimitGB -gt 0 -and $totalDayGB -ge $globalDailyWarnGB -and $totalDayGB -lt $globalDailyLimitGB) {
        if (-not $script:DailyWarningNotified) {
            $NotifyIcon.ShowBalloonTip(
                4000,
                "DataControl: Total Daily Warning Threshold",
                "Combined data across all networks reached $([math]::Round($totalDayGB, 2)) GB (Warning: $globalDailyWarnGB GB / Total Limit: $globalDailyLimitGB GB).",
                [System.Windows.Forms.ToolTipIcon]::Warning
            )
            $script:DailyWarningNotified = $true
        }
    } elseif ($totalDayGB -lt $globalDailyWarnGB) {
        $script:DailyWarningNotified = $false
    }

    # 2. Total Daily Hard Limit Exceeded & Auto-Cutoff
    if ($globalDailyLimitGB -gt 0 -and $totalDayGB -ge $globalDailyLimitGB) {
        if (-not $script:DailyLimitNotified) {
            if ($script:AppConfig.auto_disconnect_daily) {
                try {
                    Disable-NetAdapter -Name $targetAdapter -Confirm:$false -ErrorAction SilentlyContinue
                } catch { $null = $_ }

                $NotifyIcon.ShowBalloonTip(
                    6000,
                    "DataControl: Total Daily Limit Reached!",
                    "Combined daily limit of $globalDailyLimitGB GB reached across all networks! Shut off adapter '$targetAdapter'.",
                    [System.Windows.Forms.ToolTipIcon]::Error
                )
            } else {
                $NotifyIcon.ShowBalloonTip(
                    5000,
                    "DataControl: Total Daily Quota Reached!",
                    "Combined usage reached $([math]::Round($totalDayGB, 2)) GB today (Total Limit: $globalDailyLimitGB GB).",
                    [System.Windows.Forms.ToolTipIcon]::Warning
                )
            }
            $script:DailyLimitNotified = $true
        }
    } else {
        $script:DailyLimitNotified = $false
    }

    # 3. Total Monthly Warning Alert
    if ($globalMonthlyLimitGB -gt 0 -and $totalMonthGB -ge $globalMonthlyWarnGB -and $totalMonthGB -lt $globalMonthlyLimitGB) {
        if (-not $script:MonthlyWarningNotified) {
            $NotifyIcon.ShowBalloonTip(
                4000,
                "DataControl: Total Monthly Warning Threshold",
                "Combined monthly usage reached $([math]::Round($totalMonthGB, 2)) GB (Warning: $globalMonthlyWarnGB GB / Total Limit: $globalMonthlyLimitGB GB).",
                [System.Windows.Forms.ToolTipIcon]::Warning
            )
            $script:MonthlyWarningNotified = $true
        }
    } elseif ($totalMonthGB -lt $globalMonthlyWarnGB) {
        $script:MonthlyWarningNotified = $false
    }

    # 4. Total Monthly Hard Limit Exceeded & Auto-Cutoff
    if ($globalMonthlyLimitGB -gt 0 -and $totalMonthGB -ge $globalMonthlyLimitGB) {
        if (-not $script:MonthlyLimitNotified) {
            if ($script:AppConfig.auto_disconnect) {
                try {
                    Disable-NetAdapter -Name $targetAdapter -Confirm:$false -ErrorAction SilentlyContinue
                } catch { $null = $_ }

                $NotifyIcon.ShowBalloonTip(
                    6000,
                    "DataControl: Total Monthly Limit Exceeded!",
                    "Combined monthly limit of $globalMonthlyLimitGB GB reached across all connections! Shut off adapter '$targetAdapter'.",
                    [System.Windows.Forms.ToolTipIcon]::Error
                )
            } else {
                $NotifyIcon.ShowBalloonTip(
                    5000,
                    "DataControl: Total Monthly Quota Exceeded!",
                    "Combined monthly usage reached $([math]::Round($totalMonthGB, 2)) GB (Total Limit: $globalMonthlyLimitGB GB).",
                    [System.Windows.Forms.ToolTipIcon]::Warning
                )
            }
            $script:MonthlyLimitNotified = $true
        }
    } else {
        $script:MonthlyLimitNotified = $false
    }
}
