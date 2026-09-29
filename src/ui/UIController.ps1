<#
.SYNOPSIS
    DataControl UI Controller & View-Model Binding (v3.5)
.DESCRIPTION
    Handles workspace navigation, in-app toast alerts, network profile toggles,
    app rules & per-app quota management, list updates, and two-way binding.
#>

function Show-Toast ([string]$message, [string]$colorHex = "#10B981") {
    $script:UI.ToastText.Text = $message
    $script:UI.ToastBanner.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#064E3B"))
    $script:UI.ToastBanner.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($colorHex))
    $script:UI.ToastBanner.Visibility = [System.Windows.Visibility]::Visible

    $toastTimer = New-Object System.Windows.Threading.DispatcherTimer
    $toastTimer.Interval = [TimeSpan]::FromSeconds(3)
    $toastTimer.Add_Tick({
        $script:UI.ToastBanner.Visibility = [System.Windows.Visibility]::Collapsed
        $toastTimer.Stop()
    })
    $toastTimer.Start()
}

function Set-ActiveView ([string]$viewName) {
    $views = @(
        $script:UI.ViewDashboard, $script:UI.ViewAppRules, $script:UI.ViewLiveApps,
        $script:UI.ViewAppHistory, $script:UI.ViewAnalytics, $script:UI.ViewFirewall, $script:UI.ViewSettings
    )
    foreach ($v in $views) { if ($v) { $v.Visibility = [System.Windows.Visibility]::Collapsed } }

    $navButtons = @(
        $script:UI.BtnNavDashboard, $script:UI.BtnNavAppRules, $script:UI.BtnNavLiveApps,
        $script:UI.BtnNavAppHistory, $script:UI.BtnNavAnalytics, $script:UI.BtnNavFirewall, $script:UI.BtnNavSettings
    )
    foreach ($b in $navButtons) {
        if ($b) {
            $b.Background = [System.Windows.Media.Brushes]::Transparent
            $b.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#94A3B8"))
        }
    }

    $activeBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#162035"))
    $activeFg = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F8FAFC"))

    switch ($viewName) {
        "Dashboard" {
            $script:UI.ViewDashboard.Visibility = [System.Windows.Visibility]::Visible
            $script:UI.BtnNavDashboard.Background = $activeBrush
            $script:UI.BtnNavDashboard.Foreground = $activeFg
            $script:UI.WorkspaceTitle.Text = "System Dashboard & Dual Quotas"
            $script:UI.WorkspaceSubtitle.Text = "Autonomous telemetry, context-aware profiles, and outbound traffic governance"
        }
        "AppRules" {
            $script:UI.ViewAppRules.Visibility = [System.Windows.Visibility]::Visible
            $script:UI.BtnNavAppRules.Background = $activeBrush
            $script:UI.BtnNavAppRules.Foreground = $activeFg
            $script:UI.WorkspaceTitle.Text = "Application Network Rules & Per-App Quotas"
            $script:UI.WorkspaceSubtitle.Text = "Manage granular bandwidth allowances, permissions, and zero-trust auto-block policies"
            Refresh-AppRulesList
        }
        "LiveApps" {
            $script:UI.ViewLiveApps.Visibility = [System.Windows.Visibility]::Visible
            $script:UI.BtnNavLiveApps.Background = $activeBrush
            $script:UI.BtnNavLiveApps.Foreground = $activeFg
            $script:UI.WorkspaceTitle.Text = "Live Application Bandwidth Sentry"
            $script:UI.WorkspaceSubtitle.Text = "Real-time per-process socket tracking and instantaneous firewall blocking"
            Refresh-LiveAppsList
        }
        "AppHistory" {
            $script:UI.ViewAppHistory.Visibility = [System.Windows.Visibility]::Visible
            $script:UI.BtnNavAppHistory.Background = $activeBrush
            $script:UI.BtnNavAppHistory.Foreground = $activeFg
            $script:UI.WorkspaceTitle.Text = "Application Consumption Leaderboard"
            $script:UI.WorkspaceSubtitle.Text = "Cumulative historical network usage ledger across all reboots and sessions"
            Refresh-AppHistoryList
        }
        "Analytics" {
            $script:UI.ViewAnalytics.Visibility = [System.Windows.Visibility]::Visible
            $script:UI.BtnNavAnalytics.Background = $activeBrush
            $script:UI.BtnNavAnalytics.Foreground = $activeFg
            $script:UI.WorkspaceTitle.Text = "Usage Analytics & Billing Cycle"
            $script:UI.WorkspaceSubtitle.Text = "Daily, monthly, and yearly historical consumption breakdown and billing renewal reset"
            Refresh-AnalyticsDisplay
        }
        "Firewall" {
            $script:UI.ViewFirewall.Visibility = [System.Windows.Visibility]::Visible
            $script:UI.BtnNavFirewall.Background = $activeBrush
            $script:UI.BtnNavFirewall.Foreground = $activeFg
            $script:UI.WorkspaceTitle.Text = "Windows Defender Firewall Blocker"
            $script:UI.WorkspaceSubtitle.Text = "Manage active outbound block rules and target custom executable binaries"
            Refresh-FirewallRulesList
        }
        "Settings" {
            $script:UI.ViewSettings.Visibility = [System.Windows.Visibility]::Visible
            $script:UI.BtnNavSettings.Background = $activeBrush
            $script:UI.BtnNavSettings.Foreground = $activeFg
            $script:UI.WorkspaceTitle.Text = "Quota Policies & Zero-Trust Daemon"
            $script:UI.WorkspaceSubtitle.Text = "Configure interactive prompt countdowns, network profiles, and Windows startup"
            Refresh-SettingsInputs
        }
    }
}

function Refresh-NetworkProfileStatus {
    $prof = Get-ActiveNetworkProfile
    if ($prof.IsUnlimited) {
        if ($script:UI.BadgeNetworkProfile) {
            $script:UI.BadgeNetworkProfile.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#064E3B"))
        }
        if ($script:UI.DotNetworkProfile) {
            $script:UI.DotNetworkProfile.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
        }
        $script:UI.TxtNetworkProfileName.Text = "$($prof.Name): UNLIMITED"
        $script:UI.TxtNetworkProfileName.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
        $script:UI.BtnToggleNetworkProfile.Content = "Switch to Metered"
        if ($script:UI.DotSidebarSentry) {
            $script:UI.DotSidebarSentry.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
        }
        $script:UI.SidebarSentryStatus.Text = "UNLIMITED MODE (Free)"
        $script:UI.SidebarSentryStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
        if ($script:UI.SidebarNetworkProfile) {
            $script:UI.SidebarNetworkProfile.Text = "Profile: $($prof.Name) (Unlimited)"
        }
    } else {
        if ($script:UI.BadgeNetworkProfile) {
            $script:UI.BadgeNetworkProfile.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#451A03"))
        }
        if ($script:UI.DotNetworkProfile) {
            $script:UI.DotNetworkProfile.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
        }
        $script:UI.TxtNetworkProfileName.Text = "$($prof.Name): METERED"
        $script:UI.TxtNetworkProfileName.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
        $script:UI.BtnToggleNetworkProfile.Content = "Switch to Unlimited"
        if ($script:UI.DotSidebarSentry) {
            $script:UI.DotSidebarSentry.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
        }
        $script:UI.SidebarSentryStatus.Text = "SENTRY ACTIVE"
        $script:UI.SidebarSentryStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
        if ($script:UI.SidebarNetworkProfile) {
            $script:UI.SidebarNetworkProfile.Text = "Profile: $($prof.Name) (Metered)"
        }
    }
}

function Toggle-CurrentNetworkProfileMode {
    $prof = Get-ActiveNetworkProfile
    $newMode = -not $prof.IsUnlimited
    Set-NetworkProfileMode -networkName $prof.Name -isUnlimited $newMode
    Refresh-NetworkProfileStatus
    if ($newMode) {
        Show-Toast "Network '$($prof.Name)' marked as UNLIMITED. Quotas and prompts suspended." "#10B981"
    } else {
        Show-Toast "Network '$($prof.Name)' marked as METERED. Sentry protection engaged." "#F59E0B"
    }
}

function Refresh-GatekeeperStatus {
    $isEnabled = [bool]$script:AppConfig.prompt_on_new_apps

    if ($isEnabled) {
        if ($script:UI.BadgeGatekeeperMode) {
            $script:UI.BadgeGatekeeperMode.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#064E3B"))
        }
        if ($script:UI.TxtGatekeeperMode) {
            $script:UI.TxtGatekeeperMode.Text = "ON (Interactive Sentry Active)"
            $script:UI.TxtGatekeeperMode.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
        }
        if ($script:UI.BtnToggleGatekeeper) {
            $script:UI.BtnToggleGatekeeper.Content = "Turn OFF Prompts"
            $script:UI.BtnToggleGatekeeper.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#334155"))
        }
        if ($script:UI.BadgeGatekeeperHeader) {
            $script:UI.BadgeGatekeeperHeader.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#064E3B"))
        }
        if ($script:UI.DotGatekeeperHeader) {
            $script:UI.DotGatekeeperHeader.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
        }
        if ($script:UI.TxtGatekeeperHeader) {
            $script:UI.TxtGatekeeperHeader.Text = "Prompts: ON"
            $script:UI.TxtGatekeeperHeader.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
        }
    } else {
        if ($script:UI.BadgeGatekeeperMode) {
            $script:UI.BadgeGatekeeperMode.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#1E293B"))
        }
        if ($script:UI.TxtGatekeeperMode) {
            $script:UI.TxtGatekeeperMode.Text = "OFF (Manual / Silent Mode)"
            $script:UI.TxtGatekeeperMode.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#94A3B8"))
        }
        if ($script:UI.BtnToggleGatekeeper) {
            $script:UI.BtnToggleGatekeeper.Content = "Turn ON Prompts"
            $script:UI.BtnToggleGatekeeper.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#0284C7"))
        }
        if ($script:UI.BadgeGatekeeperHeader) {
            $script:UI.BadgeGatekeeperHeader.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#1E293B"))
        }
        if ($script:UI.DotGatekeeperHeader) {
            $script:UI.DotGatekeeperHeader.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#94A3B8"))
        }
        if ($script:UI.TxtGatekeeperHeader) {
            $script:UI.TxtGatekeeperHeader.Text = "Prompts: OFF"
            $script:UI.TxtGatekeeperHeader.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#94A3B8"))
        }
    }

    if ($script:UI.ChkSettingPromptNewApps) {
        $script:UI.ChkSettingPromptNewApps.IsChecked = $isEnabled
    }
}

function Toggle-GatekeeperMode {
    $script:AppConfig.prompt_on_new_apps = -not $script:AppConfig.prompt_on_new_apps
    Save-AppConfig $script:AppConfig
    Refresh-GatekeeperStatus
    if ($script:AppConfig.prompt_on_new_apps) {
        Show-Toast "Zero-Trust Gatekeeper ENABLED. Unrecognized outbound apps will trigger a 30s prompt." "#10B981"
    } else {
        Show-Toast "Zero-Trust Gatekeeper DISABLED. Apps will run quietly without popup alerts." "#38BDF8"
    }
}

function Refresh-AdapterList {
    $script:UI.ComboAdapters.Items.Clear()
    try {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object -Property @{
            Expression = {
                if ($_.PhysicalMediaType -match "802.11" -or $_.MediaType -match "Native 802.11" -or $_.Name -like "*Wi-Fi*") { 0 } else { 1 }
            }
        }, Name

        foreach ($a in $adapters) {
            [void]$script:UI.ComboAdapters.Items.Add($a.Name)
        }

        if ($script:UI.ComboAdapters.Items.Contains($script:AppConfig.target_adapter)) {
            $script:UI.ComboAdapters.SelectedItem = $script:AppConfig.target_adapter
        } elseif ($script:UI.ComboAdapters.Items.Count -gt 0) {
            $script:UI.ComboAdapters.SelectedIndex = 0
            $script:AppConfig.target_adapter = [string]$script:UI.ComboAdapters.SelectedItem
            Save-AppConfig $script:AppConfig
        }
    } catch {
        [void]$script:UI.ComboAdapters.Items.Add("Wi-Fi")
        $script:UI.ComboAdapters.SelectedIndex = 0
    }
}

function Refresh-AdapterStatus {
    $sel = [string]$script:UI.ComboAdapters.SelectedItem
    if (-not $sel) { $sel = $script:AppConfig.target_adapter }

    try {
        $adapter = Get-NetAdapter -Name $sel -ErrorAction SilentlyContinue
        if ($adapter) {
            if ($adapter.Status -eq "Up") {
                if ($script:UI.DotLinkStatus) {
                    $script:UI.DotLinkStatus.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
                }
                $script:UI.TxtLinkStatus.Text = "CONNECTED (UP)"
                $script:UI.TxtLinkStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
                $script:UI.BadgeLinkStatus.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#064E3B"))
                $script:UI.TxtAdapterDetails.Text = "Status: Connected (Up) | Target Adapter: $sel"
            } elseif ($adapter.Status -eq "Disabled") {
                if ($script:UI.DotLinkStatus) {
                    $script:UI.DotLinkStatus.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
                }
                $script:UI.TxtLinkStatus.Text = "DISABLED"
                $script:UI.TxtLinkStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
                $script:UI.BadgeLinkStatus.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#4C0519"))
                $script:UI.TxtAdapterDetails.Text = "Status: Disabled | Network hardware is disabled"
            } else {
                if ($script:UI.DotLinkStatus) {
                    $script:UI.DotLinkStatus.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
                }
                $script:UI.TxtLinkStatus.Text = $adapter.Status.ToUpper()
                $script:UI.TxtLinkStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
                $script:UI.BadgeLinkStatus.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#451A03"))
                $script:UI.TxtAdapterDetails.Text = "Status: $($adapter.Status) on $sel"
            }
        } else {
            if ($script:UI.DotLinkStatus) {
                $script:UI.DotLinkStatus.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
            }
            $script:UI.TxtLinkStatus.Text = "NOT FOUND"
            $script:UI.TxtLinkStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
            $script:UI.BadgeLinkStatus.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#4C0519"))
            $script:UI.TxtAdapterDetails.Text = "Adapter '$sel' was not found on this system."
        }
    } catch {
        if ($script:UI.DotLinkStatus) {
            $script:UI.DotLinkStatus.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
        }
        $script:UI.TxtLinkStatus.Text = "ERROR"
    }
}

function Refresh-UsageDisplay {
    $dateNow = Get-Date
    $dayKey = $dateNow.ToString("yyyy-MM-dd")
    $monthKey = $dateNow.ToString("yyyy-MM")

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

    # Live Throughput
    $rateBps = $script:CurrentThroughputBytesPerSec
    $speedStr = if ($rateBps -ge 1MB) {
        "$([math]::Round($rateBps / 1MB, 2)) MB/s"
    } else {
        "$([math]::Round($rateBps / 1KB, 1)) KB/s"
    }
    $script:UI.TxtLiveSpeedTop.Text = $speedStr
    $script:UI.TxtHeroSpeed.Text = $speedStr

    # 1. Daily Progress & Bar
    $dailyPercent = 0.0
    if ($dailyLimitGB -gt 0) {
        $dailyPercent = [math]::Round(($dayGB / $dailyLimitGB) * 100.0, 1)
    }
    $script:UI.TxtDailyPercent.Text = "$dailyPercent%"
    $script:UI.TxtDailyHero.Text = "$(Format-Bytes $dayBytes) / $dailyLimitGB GB"
    $dailyRemain = [math]::Max(0.0, [math]::Round($dailyLimitGB - $dayGB, 2))
    $script:UI.TxtDailyRemaining.Text = "Remaining Today: $dailyRemain GB (Warning at $dailyWarnGB GB)"

    $dailyClamp = [math]::Min(100.0, [math]::Max(0.0, $dailyPercent))
    $barDailyWidth = [math]::Max(6.0, (380.0 * ($dailyClamp / 100.0)))
    $script:UI.BarDailyFill.Width = $barDailyWidth

    if ($dayGB -ge $dailyLimitGB) {
        $script:UI.TxtDailyPercent.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
        $script:UI.BarDailyFill.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
    } elseif ($dayGB -ge $dailyWarnGB) {
        $script:UI.TxtDailyPercent.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
        $script:UI.BarDailyFill.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
    } else {
        $script:UI.TxtDailyPercent.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#38BDF8"))
        $grad = New-Object System.Windows.Media.LinearGradientBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString("#0284C7"),
            [System.Windows.Media.ColorConverter]::ConvertFromString("#38BDF8"),
            (New-Object System.Windows.Point(0,0)),
            (New-Object System.Windows.Point(1,0))
        )
        $script:UI.BarDailyFill.Background = $grad
    }

    # 2. Monthly Progress & Bar
    $monthlyPercent = 0.0
    if ($monthlyLimitGB -gt 0) {
        $monthlyPercent = [math]::Round(($monthGB / $monthlyLimitGB) * 100.0, 1)
    }
    $script:UI.TxtMonthlyPercent.Text = "$monthlyPercent%"
    $script:UI.TxtMonthlyHero.Text = "$([math]::Round($monthGB, 2)) GB / $monthlyLimitGB GB"
    $monthlyRemain = [math]::Max(0.0, [math]::Round($monthlyLimitGB - $monthGB, 2))
    $script:UI.TxtMonthlyRemaining.Text = "Remaining This Month: $monthlyRemain GB (Warning at $monthlyWarnGB GB)"

    $monthlyClamp = [math]::Min(100.0, [math]::Max(0.0, $monthlyPercent))
    $barMonthlyWidth = [math]::Max(6.0, (380.0 * ($monthlyClamp / 100.0)))
    $script:UI.BarMonthlyFill.Width = $barMonthlyWidth

    if ($monthGB -ge $monthlyLimitGB) {
        $script:UI.TxtMonthlyPercent.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
        $script:UI.BarMonthlyFill.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
    } elseif ($monthGB -ge $monthlyWarnGB) {
        $script:UI.TxtMonthlyPercent.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
        $script:UI.BarMonthlyFill.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
    } else {
        $script:UI.TxtMonthlyPercent.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
        $gradM = New-Object System.Windows.Media.LinearGradientBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString("#059669"),
            [System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"),
            (New-Object System.Windows.Point(0,0)),
            (New-Object System.Windows.Point(1,0))
        )
        $script:UI.BarMonthlyFill.Background = $gradM
    }

    # System Tray Tooltip and Menu Updates
    $prof = Get-ActiveNetworkProfile
    $modeTag = if ($prof.IsUnlimited) { "Unlimited" } else { "Metered ($dailyPercent%)" }
    $trayStr = "DataControl: $(Format-Bytes $dayBytes) / $dailyLimitGB GB - $modeTag"
    if ($trayStr.Length -gt 63) { $trayStr = $trayStr.Substring(0, 63) }
    $NotifyIcon.Text = $trayStr

    $script:TrayItemStatusToday.Text = "Today: $(Format-Bytes $dayBytes) / $dailyLimitGB GB ($dailyPercent%)"
    $script:TrayItemStatusMonth.Text = "Month: $([math]::Round($monthGB, 2)) GB / $monthlyLimitGB GB ($monthlyPercent%)"

    # Dashboard Top Apps Preview Table
    $topApps = $script:ProcStateCache.Values | Sort-Object -Property SpeedBps, SessionBytes -Descending | Select-Object -First 4
    $script:UI.ListDashboardTopApps.Items.Clear()
    foreach ($item in $topApps) {
        $spStr = if ($item.SpeedBps -ge 1MB) { "$([math]::Round($item.SpeedBps / 1MB, 2)) MB/s" } elseif ($item.SpeedBps -ge 1KB) { "$([math]::Round($item.SpeedBps / 1KB, 1)) KB/s" } else { "0.0 KB/s" }
        $script:UI.ListDashboardTopApps.Items.Add([PSCustomObject]@{
            Name         = $item.Name
            PID          = $item.PID
            Speed        = $spStr
            SessionBytes = Format-Bytes $item.SessionBytes
            Sockets      = $item.Connections
            Path         = $item.Path
        }) | Out-Null
    }
}

function Refresh-AppRulesList {
    $filterText = $script:UI.TxtAppRulesSearch.Text.Trim().ToLower()
    $script:UI.ListAppRules.Items.Clear()

    if ($script:AppRules) {
        $props = $script:AppRules.PSObject.Properties | Sort-Object -Property Name

        foreach ($p in $props) {
            $rule = $p.Value
            if ($filterText -and -not ($rule.Name.ToLower().Contains($filterText) -or $rule.Path.ToLower().Contains($filterText))) {
                continue
            }

            $quotaDisp = if ($rule.Status -eq "Quota" -and $rule.QuotaMB -gt 0) { "$($rule.QuotaMB) MB" } else { "Unlimited" }
            $consumedDisp = Format-Bytes ([double]$rule.ConsumedBytes)

            $statusBadge = switch ($rule.Status) {
                "Allowed"     { "[Allowed] Unlimited" }
                "Quota"       { "[Quota] Capped" }
                "Blocked"     { "[Blocked] Firewall Outbound" }
                "AutoBlocked" { "[Auto-Blocked] 30s Timeout" }
                default       { $rule.Status }
            }

            $script:UI.ListAppRules.Items.Add([PSCustomObject]@{
                Name            = $rule.Name
                Status          = $statusBadge
                QuotaDisplay    = $quotaDisp
                ConsumedDisplay = $consumedDisp
                LastUpdated     = $rule.LastUpdated
                Path            = $rule.Path
                RawRule         = $rule
            }) | Out-Null
        }
    }
}

function Refresh-LiveAppsList {
    $filterText = $script:UI.TxtLiveSearch.Text.Trim().ToLower()
    $script:UI.ListLiveApps.Items.Clear()

    $sortedItems = $script:ProcStateCache.Values | Sort-Object -Property SpeedBps, SessionBytes -Descending

    foreach ($item in $sortedItems) {
        if ($filterText -and -not ($item.Name.ToLower().Contains($filterText) -or $item.Path.ToLower().Contains($filterText))) {
            continue
        }

        $speedStr = if ($item.SpeedBps -ge 1MB) {
            "$([math]::Round($item.SpeedBps / 1MB, 2)) MB/s"
        } elseif ($item.SpeedBps -ge 1KB) {
            "$([math]::Round($item.SpeedBps / 1KB, 1)) KB/s"
        } else {
            "0.0 KB/s"
        }

        $script:UI.ListLiveApps.Items.Add([PSCustomObject]@{
            Name         = $item.Name
            PID          = $item.PID
            Speed        = $speedStr
            SessionBytes = Format-Bytes $item.SessionBytes
            Sockets      = $item.Connections
            Path         = $item.Path
        }) | Out-Null
    }
}

function Refresh-AppHistoryList {
    $script:UI.ListAppHistory.Items.Clear()
    if ($script:AppHistory) {
        $props = $script:AppHistory.PSObject.Properties | Sort-Object -Property @{
            Expression = { [double]$_.Value.TotalBytes }
        } -Descending

        foreach ($prop in $props) {
            $val = $prop.Value
            $bytes = [double]$val.TotalBytes
            $path = [string]$val.Path
            $seen = [string]$val.LastSeen

            $script:UI.ListAppHistory.Items.Add([PSCustomObject]@{
                Name       = $prop.Name
                TotalBytes = Format-Bytes $bytes
                LastSeen   = $seen
                Path       = $path
            }) | Out-Null
        }
    }
}

function Refresh-AnalyticsDisplay {
    $dateNow = Get-Date
    $dayKey = $dateNow.ToString("yyyy-MM-dd")
    $monthKey = $dateNow.ToString("yyyy-MM")
    $yearKey = $dateNow.ToString("yyyy")

    $dayBytes = 0.0
    if ($script:DataHistory.daily.PSObject.Properties[$dayKey]) { $dayBytes = [double]$script:DataHistory.daily.$dayKey }
    $monthBytes = 0.0
    if ($script:DataHistory.monthly.PSObject.Properties[$monthKey]) { $monthBytes = [double]$script:DataHistory.monthly.$monthKey }
    $yearBytes = 0.0
    if ($script:DataHistory.yearly.PSObject.Properties[$yearKey]) { $yearBytes = [double]$script:DataHistory.yearly.$yearKey }

    $script:UI.TxtAnalyticsToday.Text = Format-Bytes $dayBytes
    $script:UI.TxtAnalyticsTodaySub.Text = $dayKey
    $script:UI.TxtAnalyticsMonth.Text = Format-Bytes $monthBytes
    $script:UI.TxtAnalyticsMonthSub.Text = $dateNow.ToString("MMMM yyyy")
    $script:UI.TxtAnalyticsYear.Text = Format-Bytes $yearBytes
    $script:UI.TxtAnalyticsYearSub.Text = $yearKey

    $script:UI.ListDailyHistory.Items.Clear()
    if ($script:DataHistory.daily) {
        $props = $script:DataHistory.daily.PSObject.Properties | Sort-Object -Property Name -Descending
        foreach ($prop in $props) {
            $bytes = [double]$prop.Value
            $script:UI.ListDailyHistory.Items.Add([PSCustomObject]@{
                Date       = $prop.Name
                Formatted  = Format-Bytes $bytes
                Raw        = ($bytes.ToString("N0") + " bytes")
            }) | Out-Null
        }
    }
}

function Refresh-FirewallRulesList {
    $script:UI.ListFirewallRules.Items.Clear()
    $rules = Get-DataControlFirewallRules
    foreach ($r in $rules) {
        $script:UI.ListFirewallRules.Items.Add($r) | Out-Null
    }
}

function Refresh-SettingsInputs {
    $script:UI.InputDailyLimit.Text = [string]$script:AppConfig.daily_limit_gb
    $script:UI.InputDailyWarn.Text = [string]$script:AppConfig.daily_warning_gb
    $script:UI.ChkSettingAutoDaily.IsChecked = [bool]$script:AppConfig.auto_disconnect_daily

    $script:UI.InputMonthlyLimit.Text = [string]$script:AppConfig.monthly_limit_gb
    $script:UI.InputMonthlyWarn.Text = [string]$script:AppConfig.warning_threshold_gb
    $script:UI.ChkSettingAutoMonthly.IsChecked = [bool]$script:AppConfig.auto_disconnect

    $script:UI.ChkSettingPromptNewApps.IsChecked = [bool]$script:AppConfig.prompt_on_new_apps
    $script:UI.InputPromptTimeout.Text = [string]$script:AppConfig.prompt_timeout_seconds

    $script:UI.ChkSettingStartWithWindows.IsChecked = Test-StartupTaskEnabled
    $script:UI.InputPollSeconds.Text = [string]$script:AppConfig.poll_frequency_seconds
}

function Toggle-TargetAdapterHardware {
    $target = [string]$script:UI.ComboAdapters.SelectedItem
    if (-not $target) { $target = $script:AppConfig.target_adapter }
    try {
        $cur = Get-NetAdapter -Name $target -ErrorAction SilentlyContinue
        if ($cur.Status -eq "Up") {
            Disable-NetAdapter -Name $target -Confirm:$false -ErrorAction Stop
            Show-Toast "Adapter '$target' disabled." "#F43F5E"
        } else {
            Enable-NetAdapter -Name $target -Confirm:$false -ErrorAction Stop
            Show-Toast "Adapter '$target' enabled." "#10B981"
        }
        Refresh-AdapterStatus
    } catch {
        Show-Toast "Hardware toggle failed: $($_.Exception.Message)" "#F43F5E"
    }
}
