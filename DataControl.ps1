<#
.SYNOPSIS
    DataControl - Windows 11 Data Control System (v3.5 Modular Architecture)
.DESCRIPTION
    Main application bootstrapper. Orchestrates the network metering engine,
    per-process tracking, firewall isolation, and the Windows 11 Fluent 2 WPF UI.
#>
param (
    [switch]$StartMinimized
)

# ==============================================================================
# Step 1: Privilege Elevation Architecture
# ==============================================================================
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $scriptFile = $PSCommandPath
    if (-not $scriptFile) {
        $scriptFile = (Get-Item $MyInvocation.MyCommand.Definition).FullName
    }
    $argsList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptFile`"")
    if ($StartMinimized) { $argsList += "-StartMinimized" }
    Start-Process -FilePath "powershell.exe" -ArgumentList $argsList -Verb RunAs
    exit
}

# ==============================================================================
# Step 2: Load Required .NET Assemblies
# ==============================================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Resolve Root Application Directory
$AppDir = $PSScriptRoot
if (-not $AppDir) { $AppDir = (Get-Location).Path }

# ==============================================================================
# Step 3: Dot-Source Modular Components
# ==============================================================================
. (Join-Path $AppDir "src\core\NativeMethods.ps1")
. (Join-Path $AppDir "src\storage\ConfigManager.ps1")
. (Join-Path $AppDir "src\core\NetworkProfiles.ps1")
. (Join-Path $AppDir "src\core\PromptManager.ps1")
. (Join-Path $AppDir "src\core\NetworkEngine.ps1")
. (Join-Path $AppDir "src\core\ProcessTracker.ps1")
. (Join-Path $AppDir "src\core\Enforcement.ps1")
. (Join-Path $AppDir "src\firewall\FirewallManager.ps1")
. (Join-Path $AppDir "src\ui\UIController.ps1")

# ==============================================================================
# Step 4: Storage Paths & Global State Initialization
# ==============================================================================
Init-StoragePaths $AppDir

$script:AppConfig = Load-AppConfig
$script:DataHistory = Load-DataHistory
$script:AppHistory = Load-AppHistory
$script:AppRules = Load-AppRules

$script:LastPollTime = [DateTime]::UtcNow
$script:DailyWarningNotified = $false
$script:DailyLimitNotified = $false
$script:MonthlyWarningNotified = $false
$script:MonthlyLimitNotified = $false
$script:CurrentThroughputBytesPerSec = 0.0
$script:AllowRealExit = $false
$script:ProcStateCache = @{}

# ==============================================================================
# Step 5: Load WPF XAML Layout
# ==============================================================================
$xamlFile = Join-Path $AppDir "src\ui\MainWindow.xaml"
if (-not (Test-Path $xamlFile)) {
    [System.Windows.MessageBox]::Show(
        "Could not locate UI template file:`n$xamlFile",
        "DataControl Startup Error",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )
    exit 1
}

$sr = New-Object System.IO.StreamReader($xamlFile, [System.Text.Encoding]::UTF8)
$xr = [System.Xml.XmlReader]::Create($sr)
$Window = [System.Windows.Markup.XamlReader]::Load($xr)
$sr.Close()

# Wire UI elements into a centralized dictionary for UIController
$script:UI = @{}
$elementNames = @(
    "BtnNavDashboard", "BtnNavLiveApps", "BtnNavAppRules", "BtnNavAppHistory", "BtnNavAnalytics", "BtnNavFirewall", "BtnNavSettings",
    "BtnSidebarToggleWifi", "BtnSidebarExit", "DotSidebarSentry", "SidebarSentryStatus", "SidebarNetworkProfile", "SidebarAdapterLabel",
    "WorkspaceTitle", "WorkspaceSubtitle", "DotLinkStatus", "TxtLinkStatus", "BadgeLinkStatus", "TxtLiveSpeedTop", "ToastBanner", "ToastText",
    "BadgeNetworkProfile", "DotNetworkProfile", "TxtNetworkProfileName", "BtnToggleNetworkProfile",
    "BadgeGatekeeperHeader", "DotGatekeeperHeader", "TxtGatekeeperHeader",
    "BadgeGatekeeperMode", "TxtGatekeeperMode", "BtnToggleGatekeeper", "BtnTestPromptModal",
    "TxtManualRulePath", "BtnBrowseManualRule", "BtnAddManualAllow", "BtnAddManualQuota", "BtnAddManualBlock",
    "ViewDashboard", "ViewLiveApps", "ViewAppRules", "ViewAppHistory", "ViewAnalytics", "ViewFirewall", "ViewSettings",
    "ComboAdapters", "TxtAdapterDetails", "TxtHeroSpeed", "BtnDisableWifiHero", "BtnEnableWifiHero",
    "TxtDailyPercent", "TxtDailyHero", "BarDailyFill", "TxtDailyRemaining", "ToggleDailyCutoff",
    "TxtMonthlyPercent", "TxtMonthlyHero", "BarMonthlyFill", "TxtMonthlyRemaining", "ToggleMonthlyCutoff",
    "ListDashboardTopApps", "TxtLiveSearch", "BtnRefreshLive", "ListLiveApps", "BtnBlockLiveApp", "TxtLiveBlockStatus",
    "TxtAppRulesSearch", "BtnRefreshAppRules", "ListAppRules", "BtnRuleAllowFree", "BtnRuleSet500MB", "BtnRuleBlockApp", "BtnDeleteAppRule",
    "BtnResetAppHistory", "ListAppHistory", "BtnBlockHistoryApp", "TxtHistoryBlockStatus",
    "TxtAnalyticsToday", "TxtAnalyticsTodaySub", "TxtAnalyticsMonth", "TxtAnalyticsMonthSub",
    "TxtAnalyticsYear", "TxtAnalyticsYearSub", "BtnResetCurrentMonth", "ListDailyHistory",
    "TxtFirewallExePath", "BtnBrowseExe", "BtnBlockExeManual", "TxtFirewallManualStatus",
    "ListFirewallRules", "BtnUnblockRule", "BtnRefreshRules",
    "InputDailyLimit", "InputDailyWarn", "ChkSettingAutoDaily",
    "InputMonthlyLimit", "InputMonthlyWarn", "ChkSettingAutoMonthly",
    "ChkSettingPromptNewApps", "InputPromptTimeout",
    "ChkSettingStartWithWindows", "InputPollSeconds", "BtnSaveAllSettings"
)

foreach ($name in $elementNames) {
    $script:UI[$name] = $Window.FindName($name)
}

# ==============================================================================
# Step 6: System Tray Integration (Background Resident Sentry)
# ==============================================================================
$NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
if (Test-Path $script:IconPath) {
    try { $NotifyIcon.Icon = New-Object System.Drawing.Icon($script:IconPath) } catch { $null = $_ }
}
if (-not $NotifyIcon.Icon) {
    $NotifyIcon.Icon = [System.Drawing.SystemIcons]::Shield
}
$NotifyIcon.Text = "DataControl - Sentry Active"
$NotifyIcon.Visible = $true

$TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$TrayMenuItemShow = $TrayMenu.Items.Add("Open DataControl Dashboard")
$TrayMenuItemShow.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$TrayMenuItemShow.Add_Click({
    $Window.Show()
    $Window.WindowState = [System.Windows.WindowState]::Normal
    $Window.ShowInTaskbar = $true
    $Window.Activate()
})

$TrayMenu.Items.Add("-") | Out-Null
$script:TrayItemStatusToday = $TrayMenu.Items.Add("Today: Calculating...")
$script:TrayItemStatusMonth = $TrayMenu.Items.Add("Month: Calculating...")
$TrayMenu.Items.Add("-") | Out-Null

$TrayMenuItemToggleWifi = $TrayMenu.Items.Add("Toggle Target Adapter")
$TrayMenuItemToggleWifi.Add_Click({
    Toggle-TargetAdapterHardware
})

$TrayMenu.Items.Add("-") | Out-Null
$TrayMenuItemExit = $TrayMenu.Items.Add("Exit DataControl")
$TrayMenuItemExit.Add_Click({
    $script:AllowRealExit = $true
    $Window.Close()
})
$NotifyIcon.ContextMenuStrip = $TrayMenu

$RestoreAction = {
    $Window.Show()
    $Window.WindowState = [System.Windows.WindowState]::Normal
    $Window.ShowInTaskbar = $true
    $Window.Activate()
}
$NotifyIcon.Add_DoubleClick($RestoreAction)
$NotifyIcon.Add_Click({
    param($evtSender, $e)
    $null = $evtSender
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        & $RestoreAction
    }
})

# ==============================================================================
# Step 7: Wire Event Handlers
# ==============================================================================

# Navigation Handlers
$script:UI.BtnNavDashboard.Add_Click({ Set-ActiveView "Dashboard" })
$script:UI.BtnNavLiveApps.Add_Click({ Set-ActiveView "LiveApps" })
if ($script:UI.BtnNavAppRules) { $script:UI.BtnNavAppRules.Add_Click({ Set-ActiveView "AppRules" }) }
$script:UI.BtnNavAppHistory.Add_Click({ Set-ActiveView "AppHistory" })
$script:UI.BtnNavAnalytics.Add_Click({ Set-ActiveView "Analytics" })
$script:UI.BtnNavFirewall.Add_Click({ Set-ActiveView "Firewall" })
$script:UI.BtnNavSettings.Add_Click({ Set-ActiveView "Settings" })

# Network Profile Toggle Handler
if ($script:UI.BtnToggleNetworkProfile) {
    $script:UI.BtnToggleNetworkProfile.Add_Click({
        Toggle-CurrentNetworkProfileMode
    })
}

# Adapter ComboBox Selection Changed
$script:UI.ComboAdapters.Add_SelectionChanged({
    $selected = [string]$script:UI.ComboAdapters.SelectedItem
    if ($selected -and $selected -ne $script:AppConfig.target_adapter) {
        $script:AppConfig.target_adapter = $selected
        Save-AppConfig $script:AppConfig
        Refresh-AdapterStatus
        Show-Toast "Target adapter set to: $selected"
    }
})

# Hardware Controls
$script:UI.BtnSidebarToggleWifi.Add_Click({ Toggle-TargetAdapterHardware })
$script:UI.BtnDisableWifiHero.Add_Click({
    $target = [string]$script:UI.ComboAdapters.SelectedItem
    if (-not $target) { $target = $script:AppConfig.target_adapter }
    try {
        Disable-NetAdapter -Name $target -Confirm:$false -ErrorAction Stop
        Refresh-AdapterStatus
        Show-Toast "Adapter '$target' disabled." "#F43F5E"
    } catch { Show-Toast "Error: $($_.Exception.Message)" "#F43F5E" }
})
$script:UI.BtnEnableWifiHero.Add_Click({
    $target = [string]$script:UI.ComboAdapters.SelectedItem
    if (-not $target) { $target = $script:AppConfig.target_adapter }
    try {
        Enable-NetAdapter -Name $target -Confirm:$false -ErrorAction Stop
        Refresh-AdapterStatus
        Show-Toast "Adapter '$target' enabled." "#10B981"
    } catch { Show-Toast "Error: $($_.Exception.Message)" "#F43F5E" }
})

# Dashboard Cutoff Toggles
$script:UI.ToggleDailyCutoff.Add_Click({
    $script:AppConfig.auto_disconnect_daily = [bool]$script:UI.ToggleDailyCutoff.IsChecked
    Save-AppConfig $script:AppConfig
})
$script:UI.ToggleMonthlyCutoff.Add_Click({
    $script:AppConfig.auto_disconnect = [bool]$script:UI.ToggleMonthlyCutoff.IsChecked
    Save-AppConfig $script:AppConfig
})

# Live Apps Filtering & Actions
$script:UI.TxtLiveSearch.Add_TextChanged({ Refresh-LiveAppsList })
$script:UI.BtnRefreshLive.Add_Click({ Refresh-LiveAppsList })

$script:UI.BtnBlockLiveApp.Add_Click({
    $item = $script:UI.ListLiveApps.SelectedItem
    if (-not $item) {
        [System.Windows.MessageBox]::Show("Please select an application from the list to block.", "No Selection", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    try {
        $null = Block-ApplicationPath -appPath $item.Path -description "Blocked by DataControl Live Sentry"
        $script:UI.TxtLiveBlockStatus.Text = "Blocked in Firewall: $($item.Name)"
        Show-Toast "Application '$($item.Name)' blocked in Windows Defender Firewall!" "#10B981"
    } catch {
        Show-Toast "Firewall Error: $($_.Exception.Message)" "#F43F5E"
    }
})

# History App Blocking & Reset
$script:UI.BtnBlockHistoryApp.Add_Click({
    $item = $script:UI.ListAppHistory.SelectedItem
    if (-not $item) {
        [System.Windows.MessageBox]::Show("Please select an application from history to block.", "No Selection", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    try {
        $null = Block-ApplicationPath -appPath $item.Path -description "Blocked by DataControl App History"
        $script:UI.TxtHistoryBlockStatus.Text = "Blocked: $($item.Name)"
        Show-Toast "Application '$($item.Name)' blocked in Firewall!" "#10B981"
    } catch {
        Show-Toast "Firewall Error: $($_.Exception.Message)" "#F43F5E"
    }
})

$script:UI.BtnResetAppHistory.Add_Click({
    $res = [System.Windows.MessageBox]::Show("Are you sure you want to reset the per-application consumption history?", "Confirm Reset", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($res -eq [System.Windows.MessageBoxResult]::Yes) {
        $script:AppHistory = New-Object PSCustomObject
        Save-AppHistory $script:AppHistory
        Refresh-AppHistoryList
        Show-Toast "App history ledger reset to zero."
    }
})

# App Rules Filtering & Enforcement Actions
if ($script:UI.TxtAppRulesSearch) {
    $script:UI.TxtAppRulesSearch.Add_TextChanged({ Refresh-AppRulesList })
}
if ($script:UI.BtnRefreshAppRules) {
    $script:UI.BtnRefreshAppRules.Add_Click({ Refresh-AppRulesList })
}

# Gatekeeper Mode Toggle & Test Controls
if ($script:UI.BtnToggleGatekeeper) {
    $script:UI.BtnToggleGatekeeper.Add_Click({
        Toggle-GatekeeperMode
    })
}

if ($script:UI.BtnTestPromptModal) {
    $script:UI.BtnTestPromptModal.Add_Click({
        Test-PromptWindowManual
    })
}

# Manual Rule Creator Controls
if ($script:UI.BtnBrowseManualRule) {
    $script:UI.BtnBrowseManualRule.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Executable files (*.exe)|*.exe|All files (*.*)|*.*"
        $ofd.Title = "Select Application to Add Rule"
        $ofd.InitialDirectory = [Environment]::GetFolderPath("ProgramFiles")
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:UI.TxtManualRulePath.Text = $ofd.FileName
        }
        $ofd.Dispose()
    })
}

if ($script:UI.BtnAddManualAllow) {
    $script:UI.BtnAddManualAllow.Add_Click({
        $path = $script:UI.TxtManualRulePath.Text.Trim()
        if (-not $path -or -not (Test-Path $path)) {
            [System.Windows.MessageBox]::Show("Please enter or browse to a valid .exe path first.", "Invalid Executable", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
        $name = [System.IO.Path]::GetFileName($path)
        Set-AppRule -appName $name -status "Allowed" -quotaMB 0 -path $path | Out-Null
        Unblock-ApplicationRule -ruleName "DataControl-Block-$name"
        $script:UI.TxtManualRulePath.Text = ""
        Refresh-AppRulesList
        Show-Toast "Rule created: $name granted Unlimited access." "#10B981"
    })
}

if ($script:UI.BtnAddManualQuota) {
    $script:UI.BtnAddManualQuota.Add_Click({
        $path = $script:UI.TxtManualRulePath.Text.Trim()
        if (-not $path -or -not (Test-Path $path)) {
            [System.Windows.MessageBox]::Show("Please enter or browse to a valid .exe path first.", "Invalid Executable", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
        $name = [System.IO.Path]::GetFileName($path)
        Set-AppRule -appName $name -status "Quota" -quotaMB 500 -path $path | Out-Null
        Unblock-ApplicationRule -ruleName "DataControl-Block-$name"
        $script:UI.TxtManualRulePath.Text = ""
        Refresh-AppRulesList
        Show-Toast "Rule created: $name assigned 500 MB Micro-Quota." "#38BDF8"
    })
}

if ($script:UI.BtnAddManualBlock) {
    $script:UI.BtnAddManualBlock.Add_Click({
        $path = $script:UI.TxtManualRulePath.Text.Trim()
        if (-not $path -or -not (Test-Path $path)) {
            [System.Windows.MessageBox]::Show("Please enter or browse to a valid .exe path first.", "Invalid Executable", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
        $name = [System.IO.Path]::GetFileName($path)
        Block-ApplicationPath -appPath $path -description "Manually Blocked by User in App Rules" | Out-Null
        Set-AppRule -appName $name -status "Blocked" -quotaMB 0 -path $path | Out-Null
        $script:UI.TxtManualRulePath.Text = ""
        Refresh-AppRulesList
        Show-Toast "Rule created: $name outbound traffic blocked." "#F43F5E"
    })
}

# App Rules List Selection Actions
if ($script:UI.BtnRuleAllowFree) {
    $script:UI.BtnRuleAllowFree.Add_Click({
        $item = $script:UI.ListAppRules.SelectedItem
        if (-not $item) {
            [System.Windows.MessageBox]::Show("Please select an application rule from the list.", "No Selection", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }
        Set-AppRule -appName $item.Name -status "Allowed" -quotaMB 0 -path $item.Path | Out-Null
        Unblock-ApplicationRule -ruleName "DataControl-Block-$($item.Name)"
        Refresh-AppRulesList
        Show-Toast "Rule updated: $($item.Name) granted Unlimited access." "#10B981"
    })
}

if ($script:UI.BtnRuleSet500MB) {
    $script:UI.BtnRuleSet500MB.Add_Click({
        $item = $script:UI.ListAppRules.SelectedItem
        if (-not $item) {
            [System.Windows.MessageBox]::Show("Please select an application rule from the list.", "No Selection", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }
        Set-AppRule -appName $item.Name -status "Quota" -quotaMB 500 -path $item.Path | Out-Null
        Unblock-ApplicationRule -ruleName "DataControl-Block-$($item.Name)"
        Refresh-AppRulesList
        Show-Toast "Rule updated: $($item.Name) assigned 500 MB Micro-Quota." "#38BDF8"
    })
}

if ($script:UI.BtnRuleBlockApp) {
    $script:UI.BtnRuleBlockApp.Add_Click({
        $item = $script:UI.ListAppRules.SelectedItem
        if (-not $item) {
            [System.Windows.MessageBox]::Show("Please select an application rule from the list.", "No Selection", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }
        Set-AppRule -appName $item.Name -status "Blocked" -quotaMB 0 -path $item.Path | Out-Null
        if ($item.Path -and (Test-Path $item.Path)) {
            Block-ApplicationPath -appPath $item.Path -description "Blocked by DataControl App Rule Sentry" | Out-Null
        }
        Refresh-AppRulesList
        Show-Toast "Rule updated: $($item.Name) outbound traffic blocked." "#F43F5E"
    })
}

if ($script:UI.BtnDeleteAppRule) {
    $script:UI.BtnDeleteAppRule.Add_Click({
        $item = $script:UI.ListAppRules.SelectedItem
        if (-not $item) {
            [System.Windows.MessageBox]::Show("Please select an application rule from the list to delete.", "No Selection", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }
        Remove-AppRule -appName $item.Name
        Unblock-ApplicationRule -ruleName "DataControl-Block-$($item.Name)"
        Refresh-AppRulesList
        Show-Toast "Rule removed for: $($item.Name)"
    })
}

# Analytics Monthly Reset
$script:UI.BtnResetCurrentMonth.Add_Click({
    $curMonthName = (Get-Date).ToString("MMMM yyyy")
    $res = [System.Windows.MessageBox]::Show("Reset monthly consumption metrics to 0 GB for $($curMonthName)?`n`nRecommended when your billing cycle renews.", "Confirm Billing Reset", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($res -eq [System.Windows.MessageBoxResult]::Yes) {
        $monthKey = (Get-Date).ToString("yyyy-MM")
        $script:DataHistory.monthly | Add-Member -MemberType NoteProperty -Name $monthKey -Value 0.0 -Force
        Save-DataHistory $script:DataHistory
        $script:MonthlyWarningNotified = $false
        $script:MonthlyLimitNotified = $false
        Refresh-UsageDisplay
        Refresh-AnalyticsDisplay
        Show-Toast "Monthly data usage reset to 0 GB."
    }
})

# Firewall Rules Tab Handlers
$script:UI.BtnBrowseExe.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Executable files (*.exe)|*.exe|All files (*.*)|*.*"
    $ofd.Title = "Select Application to Block"
    $ofd.InitialDirectory = [Environment]::GetFolderPath("ProgramFiles")
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:UI.TxtFirewallExePath.Text = $ofd.FileName
    }
    $ofd.Dispose()
})

$script:UI.BtnBlockExeManual.Add_Click({
    $exePath = $script:UI.TxtFirewallExePath.Text.Trim()
    if (-not $exePath -or -not (Test-Path $exePath)) {
        [System.Windows.MessageBox]::Show("Please select a valid executable (.exe) first.", "Invalid File", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    try {
        $fileName = [System.IO.Path]::GetFileName($exePath)
        Block-ApplicationPath -appPath $exePath -description "Blocked by DataControl Outbound Traffic Blocker" | Out-Null
        $script:UI.TxtFirewallExePath.Text = ""
        Refresh-FirewallRulesList
        Show-Toast "Successfully blocked: $fileName" "#10B981"
    } catch {
        Show-Toast "Firewall Error: $($_.Exception.Message)" "#F43F5E"
    }
})

$script:UI.BtnUnblockRule.Add_Click({
    $item = $script:UI.ListFirewallRules.SelectedItem
    if (-not $item) {
        [System.Windows.MessageBox]::Show("Please select a firewall rule from the list to unblock.", "No Selection", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    try {
        Unblock-ApplicationRule -ruleName $item.RuleName
        Refresh-FirewallRulesList
        Show-Toast "Rule removed: $($item.RuleName)" "#10B981"
    } catch {
        Show-Toast "Error removing rule: $($_.Exception.Message)" "#F43F5E"
    }
})

$script:UI.BtnRefreshRules.Add_Click({
    Refresh-FirewallRulesList
    Show-Toast "Firewall rules refreshed."
})

# Settings Handlers
$script:UI.BtnSaveAllSettings.Add_Click({
    try {
        $dailyLimit = [double]$script:UI.InputDailyLimit.Text
        $dailyWarn  = [double]$script:UI.InputDailyWarn.Text
        $monthlyLimit = [double]$script:UI.InputMonthlyLimit.Text
        $monthlyWarn  = [double]$script:UI.InputMonthlyWarn.Text
        $pollSec = [int]$script:UI.InputPollSeconds.Text

        if ($dailyLimit -gt 0) { $script:AppConfig.daily_limit_gb = $dailyLimit }
        if ($dailyWarn -gt 0) { $script:AppConfig.daily_warning_gb = $dailyWarn }
        if ($monthlyLimit -gt 0) { $script:AppConfig.monthly_limit_gb = $monthlyLimit }
        if ($monthlyWarn -gt 0) { $script:AppConfig.warning_threshold_gb = $monthlyWarn }
        if ($pollSec -gt 0) { $script:AppConfig.poll_frequency_seconds = $pollSec }

        $script:AppConfig.auto_disconnect_daily = [bool]$script:UI.ChkSettingAutoDaily.IsChecked
        $script:AppConfig.auto_disconnect = [bool]$script:UI.ChkSettingAutoMonthly.IsChecked

        if ($script:UI.ChkSettingPromptNewApps) {
            $script:AppConfig.prompt_new_apps = [bool]$script:UI.ChkSettingPromptNewApps.IsChecked
        }
        if ($script:UI.InputPromptTimeout) {
            $pTimeout = [int]$script:UI.InputPromptTimeout.Text
            if ($pTimeout -gt 0) { $script:AppConfig.prompt_timeout_seconds = $pTimeout }
        }

        $isTaskWanted = [bool]$script:UI.ChkSettingStartWithWindows.IsChecked
        Set-StartupTaskEnabled $isTaskWanted | Out-Null

        Save-AppConfig $script:AppConfig
        Refresh-UsageDisplay
        Show-Toast "All settings saved and applied successfully!" "#10B981"
    } catch {
        Show-Toast "Invalid numeric input: $($_.Exception.Message)" "#F43F5E"
    }
})

# Sidebar Exit
$script:UI.BtnSidebarExit.Add_Click({
    $res = [System.Windows.MessageBox]::Show("Do you want to completely exit DataControl?`n`nTo keep monitoring data in the background, click No and simply close the window [X].", "Exit DataControl", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($res -eq [System.Windows.MessageBoxResult]::Yes) {
        $script:AllowRealExit = $true
        $Window.Close()
    }
})

# Window Close [X] -> Hide to Tray
$Window.Add_Closing({
    param($evtSender, $e)
    $null = $evtSender

    if (-not $script:AllowRealExit) {
        $e.Cancel = $true
        $Window.Hide()
        $Window.ShowInTaskbar = $false
        $NotifyIcon.ShowBalloonTip(
            3500,
            "DataControl Sentry Active",
            "DataControl is actively monitoring data in the background. Right-click or double-click the shield icon in your taskbar to open.",
            [System.Windows.Forms.ToolTipIcon]::Info
        )
        return
    }

    $script:PollTimer.Stop()
    $NotifyIcon.Visible = $false
    $NotifyIcon.Dispose()
    Save-DataHistory $script:DataHistory
    Save-AppHistory $script:AppHistory
    Save-AppRules $script:AppRules
    [System.Windows.Application]::Current.Shutdown()
})

# ==============================================================================
# Step 8: Timer Setup & Application Boot
# ==============================================================================
$script:PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollSeconds = [int]$script:AppConfig.poll_frequency_seconds
if ($pollSeconds -lt 1) { $pollSeconds = 3 }
$script:PollTimer.Interval = [TimeSpan]::FromSeconds($pollSeconds)

$script:PollTimer.Add_Tick({
    $target = [string]$script:UI.ComboAdapters.SelectedItem
    if (-not $target) { $target = $script:AppConfig.target_adapter }

    Update-NetworkMetrics -AdapterName $target
    Refresh-AdapterStatus
    Refresh-NetworkProfileStatus
    Refresh-UsageDisplay
    Check-EnforcementRules

    if ($script:UI.ViewLiveApps.Visibility -eq [System.Windows.Visibility]::Visible) {
        Refresh-LiveAppsList
    }
    if ($script:UI.ViewAppRules -and $script:UI.ViewAppRules.Visibility -eq [System.Windows.Visibility]::Visible) {
        Refresh-AppRulesList
    }
})

$Window.Add_SourceInitialized({
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($Window)
    [Win11Native]::ApplyWin11Aesthetics($helper.Handle)
})

$Window.Add_Loaded({
    Refresh-AdapterList
    Refresh-AdapterStatus
    Refresh-NetworkProfileStatus
    Refresh-GatekeeperStatus
    Update-NetworkMetrics
    Refresh-UsageDisplay
    Refresh-LiveAppsList
    Refresh-AppRulesList
    Refresh-AppHistoryList
    Refresh-FirewallRulesList
    Refresh-SettingsInputs

    $script:UI.ToggleDailyCutoff.IsChecked = [bool]$script:AppConfig.auto_disconnect_daily
    $script:UI.ToggleMonthlyCutoff.IsChecked = [bool]$script:AppConfig.auto_disconnect

    Set-ActiveView "Dashboard"
    $script:PollTimer.Start()
})

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

if ($StartMinimized) {
    $Window.WindowState = [System.Windows.WindowState]::Minimized
    $Window.ShowInTaskbar = $false
    $NotifyIcon.ShowBalloonTip(
        3500,
        "DataControl Sentry Active",
        "DataControl started in background. Double-click tray icon to open dashboard.",
        [System.Windows.Forms.ToolTipIcon]::Info
    )
} else {
    $Window.Show()
}

$app.Run($Window)
