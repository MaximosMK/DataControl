<#
.SYNOPSIS
    DataControl - Windows 11 Data Control System
.DESCRIPTION
    Autonomous network metering, persistent usage tracking, automated shutoff enforcement,
    and outbound application firewall blocker for Windows 10/11.
#>
param (
    [switch]$StartMinimized
)

# ==============================================================================
# Step 2: Privilege Elevation Architecture
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

# Load Required .NET Assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# Paths Configuration
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $AppDir) { $AppDir = (Get-Location).Path }
$ConfigFile = Join-Path $AppDir "config.json"
$HistoryFile = Join-Path $AppDir "data_history.json"
$TaskName = "DataControl_Monitor"

# ==============================================================================
# Helper Functions: Config & History Management
# ==============================================================================
function Load-AppConfig {
    if (Test-Path $ConfigFile) {
        try {
            $raw = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            return $raw
        } catch {}
    }
    # Defaults
    return [PSCustomObject]@{
        target_adapter         = "Wi-Fi"
        monthly_limit_gb       = 16.0
        warning_threshold_gb   = 14.0
        auto_disconnect        = $true
        poll_frequency_seconds = 3
    }
}

function Save-AppConfig ($cfg) {
    try {
        $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
    } catch {
        Write-Warning "Failed to save configuration: $_"
    }
}

function Load-DataHistory {
    if (Test-Path $HistoryFile) {
        try {
            $raw = Get-Content -Path $HistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
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
        $hist | ConvertTo-Json -Depth 6 | Set-Content -Path $HistoryFile -Encoding UTF8
    } catch {
        Write-Warning "Failed to save data history: $_"
    }
}

function Format-Bytes ([double]$bytes) {
    if ($bytes -ge 1GB) {
        return "$([math]::Round($bytes / 1GB, 2)) GB"
    } elseif ($bytes -ge 1MB) {
        return "$([math]::Round($bytes / 1MB, 2)) MB"
    } elseif ($bytes -ge 1KB) {
        return "$([math]::Round($bytes / 1KB, 2)) KB"
    } else {
        return "$([math]::Round($bytes, 0)) B"
    }
}

# Scheduled Task Management
function Test-StartupTaskEnabled {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    return ($null -ne $task)
}

function Set-StartupTaskEnabled ([bool]$enable) {
    if ($enable) {
        $scriptPath = Join-Path $AppDir "DataControl.ps1"
        $action = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -StartMinimized"
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
            return $true
        } catch {
            return $false
        }
    } else {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            return $true
        } catch {
            return $false
        }
    }
}

# Global State Variables
$script:AppConfig = Load-AppConfig
$script:DataHistory = Load-DataHistory
$script:LastPollTime = [DateTime]::UtcNow
$script:WarningNotified = $false
$script:LimitNotified = $false
$script:CurrentThroughputBytesPerSec = 0.0

# ==============================================================================
# Step 3: Network Metering & Persistent Delta Engine
# ==============================================================================
function Update-NetworkMetrics {
    param (
        [string]$AdapterName
    )

    if (-not $AdapterName) {
        $AdapterName = $script:AppConfig.target_adapter
    }

    try {
        $stat = Get-NetAdapterStatistics -Name $AdapterName -ErrorAction SilentlyContinue
        if (-not $stat) {
            $script:CurrentThroughputBytesPerSec = 0
            return
        }

        $now = [DateTime]::UtcNow
        $elapsedSec = ($now - $script:LastPollTime).TotalSeconds
        if ($elapsedSec -le 0) { $elapsedSec = [double]$script:AppConfig.poll_frequency_seconds }
        $script:LastPollTime = $now

        $currentRaw = [double]($stat.ReceivedBytes + $stat.SentBytes)
        $previousRaw = [double]$script:DataHistory.last_raw_total_bytes

        $delta = 0.0
        if ($previousRaw -le 0) {
            $delta = 0.0
        } elseif ($currentRaw -lt $previousRaw) {
            $delta = $currentRaw
        } else {
            $delta = $currentRaw - $previousRaw
        }

        $script:DataHistory.last_raw_total_bytes = $currentRaw

        if ($elapsedSec -gt 0) {
            $script:CurrentThroughputBytesPerSec = $delta / $elapsedSec
        } else {
            $script:CurrentThroughputBytesPerSec = 0.0
        }

        if ($delta -gt 0) {
            $dateNow = Get-Date
            $dayKey = $dateNow.ToString("yyyy-MM-dd")
            $monthKey = $dateNow.ToString("yyyy-MM")
            $yearKey = $dateNow.ToString("yyyy")

            $prevDay = 0.0
            if ($script:DataHistory.daily.PSObject.Properties[$dayKey]) {
                $prevDay = [double]$script:DataHistory.daily.$dayKey
            }
            $script:DataHistory.daily | Add-Member -MemberType NoteProperty -Name $dayKey -Value ($prevDay + $delta) -Force

            $prevMonth = 0.0
            if ($script:DataHistory.monthly.PSObject.Properties[$monthKey]) {
                $prevMonth = [double]$script:DataHistory.monthly.$monthKey
            }
            $script:DataHistory.monthly | Add-Member -MemberType NoteProperty -Name $monthKey -Value ($prevMonth + $delta) -Force

            $prevYear = 0.0
            if ($script:DataHistory.yearly.PSObject.Properties[$yearKey]) {
                $prevYear = [double]$script:DataHistory.yearly.$yearKey
            }
            $script:DataHistory.yearly | Add-Member -MemberType NoteProperty -Name $yearKey -Value ($prevYear + $delta) -Force

            Save-DataHistory $script:DataHistory
        }
    } catch {
        # Keep engine resilient
    }
}

# ==============================================================================
# Step 4: Graphical User Interface Construction
# ==============================================================================

# Palette Definition
$ColorBgDark     = [System.Drawing.ColorTranslator]::FromHtml("#0F172A") # Slate 900
$ColorPanelBg    = [System.Drawing.ColorTranslator]::FromHtml("#1E293B") # Slate 800
$ColorCardBorder = [System.Drawing.ColorTranslator]::FromHtml("#334155") # Slate 700
$ColorAccent     = [System.Drawing.ColorTranslator]::FromHtml("#38BDF8") # Sky 400
$ColorAccentDark = [System.Drawing.ColorTranslator]::FromHtml("#0284C7") # Sky 600
$ColorTextLight  = [System.Drawing.ColorTranslator]::FromHtml("#F8FAFC") # Slate 50
$ColorTextMuted  = [System.Drawing.ColorTranslator]::FromHtml("#94A3B8") # Slate 400
$ColorSuccess    = [System.Drawing.ColorTranslator]::FromHtml("#22C55E") # Emerald 500
$ColorWarning    = [System.Drawing.ColorTranslator]::FromHtml("#F59E0B") # Amber 500
$ColorDanger     = [System.Drawing.ColorTranslator]::FromHtml("#EF4444") # Red 500
$ColorInputBg    = [System.Drawing.ColorTranslator]::FromHtml("#0F172A") # Input dark

$FontHeader = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$FontSub    = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
$FontMetric = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$FontBody   = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
$FontSmall  = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)

# Main Form
$Form = New-Object System.Windows.Forms.Form
$Form.Text = "DataControl - Windows 11 Data Control System"
$Form.ClientSize = New-Object System.Drawing.Size(650, 650)
$Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$Form.MaximizeBox = $false
$Form.BackColor = $ColorBgDark
$Form.ForeColor = $ColorTextLight
$Form.Font = $FontBody

# System Tray Notification Icon & Form Icon
$IconPath = Join-Path $AppDir "DataControl.ico"
$AppCustomIcon = $null
if (Test-Path $IconPath) {
    try {
        $AppCustomIcon = New-Object System.Drawing.Icon($IconPath)
        $Form.Icon = $AppCustomIcon
    } catch {}
}

$NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
if ($AppCustomIcon) {
    $NotifyIcon.Icon = $AppCustomIcon
} else {
    $NotifyIcon.Icon = [System.Drawing.SystemIcons]::Shield
}
$NotifyIcon.Text = "DataControl - Sentry Active"
$NotifyIcon.Visible = $true

# Context Menu for Tray
$TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip

$TrayMenuItemShow = $TrayMenu.Items.Add("Open DataControl")
$TrayMenuItemShow.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$TrayMenuItemShow.Add_Click({
    $Form.Show()
    $Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $Form.ShowInTaskbar = $true
    $Form.Activate()
})

$TrayMenu.Items.Add("-") | Out-Null

$TrayMenuItemStartup = $TrayMenu.Items.Add("Start with Windows (Background)")
$TrayMenuItemStartup.CheckOnClick = $true
$TrayMenuItemStartup.Checked = Test-StartupTaskEnabled
$TrayMenuItemStartup.Add_Click({
    $newState = $TrayMenuItemStartup.Checked
    Set-StartupTaskEnabled $newState | Out-Null
    $ChkStartWithWindows.Checked = $newState
})

$TrayMenuItemToggleWifi = $TrayMenu.Items.Add("Toggle Wi-Fi Interface")
$TrayMenuItemToggleWifi.Add_Click({
    $target = [string]$script:AppConfig.target_adapter
    try {
        $cur = Get-NetAdapter -Name $target -ErrorAction SilentlyContinue
        if ($cur.Status -eq "Up") {
            Disable-NetAdapter -Name $target -Confirm:$false -ErrorAction Stop
        } else {
            Enable-NetAdapter -Name $target -Confirm:$false -ErrorAction Stop
        }
        Refresh-AdapterStatusLabel
    } catch {}
})

$TrayMenu.Items.Add("-") | Out-Null

$TrayMenuItemExit = $TrayMenu.Items.Add("Exit DataControl")
$TrayMenuItemExit.Add_Click({
    $Form.Close()
})
$NotifyIcon.ContextMenuStrip = $TrayMenu

$NotifyIcon.Add_DoubleClick({
    $Form.Show()
    $Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $Form.ShowInTaskbar = $true
    $Form.Activate()
})

# Minimize to Tray handler
$Form.Add_Resize({
    if ($Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $Form.Hide()
        $Form.ShowInTaskbar = $false
    }
})

# Top Header Banner
$HeaderPanel = New-Object System.Windows.Forms.Panel
$HeaderPanel.Location = New-Object System.Drawing.Point(0, 0)
$HeaderPanel.Size = New-Object System.Drawing.Size(650, 56)
$HeaderPanel.BackColor = $ColorPanelBg
$HeaderPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::None

$AppTitleLabel = New-Object System.Windows.Forms.Label
$AppTitleLabel.Text = "DATACONTROL"
$AppTitleLabel.Font = $FontHeader
$AppTitleLabel.ForeColor = $ColorAccent
$AppTitleLabel.Location = New-Object System.Drawing.Point(16, 12)
$AppTitleLabel.AutoSize = $true

$AppSubtitleLabel = New-Object System.Windows.Forms.Label
$AppSubtitleLabel.Text = "Network Quota & Firewall Sentry"
$AppSubtitleLabel.Font = $FontSmall
$AppSubtitleLabel.ForeColor = $ColorTextMuted
$AppSubtitleLabel.Location = New-Object System.Drawing.Point(160, 18)
$AppSubtitleLabel.AutoSize = $true

$HeaderStatusBadge = New-Object System.Windows.Forms.Label
$HeaderStatusBadge.Text = "● ACTIVE"
$HeaderStatusBadge.Font = $FontSub
$HeaderStatusBadge.ForeColor = $ColorSuccess
$HeaderStatusBadge.Location = New-Object System.Drawing.Point(540, 16)
$HeaderStatusBadge.AutoSize = $true

$HeaderPanel.Controls.AddRange(@($AppTitleLabel, $AppSubtitleLabel, $HeaderStatusBadge))
$Form.Controls.Add($HeaderPanel)

# Tab Control
$TabControl = New-Object System.Windows.Forms.TabControl
$TabControl.Location = New-Object System.Drawing.Point(12, 66)
$TabControl.Size = New-Object System.Drawing.Size(626, 570)
$TabControl.Font = $FontBody

# Setup Tab Pages
$Tab1 = New-Object System.Windows.Forms.TabPage
$Tab1.Text = " Dashboard & Live Controls "
$Tab1.BackColor = $ColorBgDark

$Tab2 = New-Object System.Windows.Forms.TabPage
$Tab2.Text = " Usage History & Analytics "
$Tab2.BackColor = $ColorBgDark

$Tab3 = New-Object System.Windows.Forms.TabPage
$Tab3.Text = " Application Firewall Blocker "
$Tab3.BackColor = $ColorBgDark

$TabControl.TabPages.AddRange(@($Tab1, $Tab2, $Tab3))
$Form.Controls.Add($TabControl)

# ==============================================================================
# TAB 1: Dashboard & Live Controls
# ==============================================================================

# Card 1: Live Status & Interface Selection
$CardStatus = New-Object System.Windows.Forms.Panel
$CardStatus.Location = New-Object System.Drawing.Point(12, 10)
$CardStatus.Size = New-Object System.Drawing.Size(594, 84)
$CardStatus.BackColor = $ColorPanelBg
$CardStatus.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblAdapter = New-Object System.Windows.Forms.Label
$LblAdapter.Text = "Target Network Adapter:"
$LblAdapter.Font = $FontSub
$LblAdapter.ForeColor = $ColorTextLight
$LblAdapter.Location = New-Object System.Drawing.Point(12, 10)
$LblAdapter.AutoSize = $true

$ComboAdapters = New-Object System.Windows.Forms.ComboBox
$ComboAdapters.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$ComboAdapters.Location = New-Object System.Drawing.Point(14, 36)
$ComboAdapters.Size = New-Object System.Drawing.Size(220, 26)
$ComboAdapters.BackColor = $ColorInputBg
$ComboAdapters.ForeColor = $ColorTextLight
$ComboAdapters.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

$LblStateTitle = New-Object System.Windows.Forms.Label
$LblStateTitle.Text = "Link State:"
$LblStateTitle.Font = $FontSub
$LblStateTitle.ForeColor = $ColorTextLight
$LblStateTitle.Location = New-Object System.Drawing.Point(260, 10)
$LblStateTitle.AutoSize = $true

$LblStateValue = New-Object System.Windows.Forms.Label
$LblStateValue.Text = "Detecting..."
$LblStateValue.Font = $FontSub
$LblStateValue.ForeColor = $ColorSuccess
$LblStateValue.Location = New-Object System.Drawing.Point(260, 37)
$LblStateValue.AutoSize = $true

$LblLiveSpeedTitle = New-Object System.Windows.Forms.Label
$LblLiveSpeedTitle.Text = "Transfer Rate:"
$LblLiveSpeedTitle.Font = $FontSub
$LblLiveSpeedTitle.ForeColor = $ColorTextLight
$LblLiveSpeedTitle.Location = New-Object System.Drawing.Point(400, 10)
$LblLiveSpeedTitle.AutoSize = $true

$LblLiveSpeedValue = New-Object System.Windows.Forms.Label
$LblLiveSpeedValue.Text = "0.00 KB/s"
$LblLiveSpeedValue.Font = $FontMetric
$LblLiveSpeedValue.ForeColor = $ColorAccent
$LblLiveSpeedValue.Location = New-Object System.Drawing.Point(398, 33)
$LblLiveSpeedValue.AutoSize = $true

$CardStatus.Controls.AddRange(@(
    $LblAdapter, $ComboAdapters, $LblStateTitle, $LblStateValue, $LblLiveSpeedTitle, $LblLiveSpeedValue
))
$Tab1.Controls.Add($CardStatus)

# Card 2: Monthly Quota Progress
$CardQuota = New-Object System.Windows.Forms.Panel
$CardQuota.Location = New-Object System.Drawing.Point(12, 102)
$CardQuota.Size = New-Object System.Drawing.Size(594, 106)
$CardQuota.BackColor = $ColorPanelBg
$CardQuota.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblQuotaHeader = New-Object System.Windows.Forms.Label
$LblQuotaHeader.Text = "Monthly Data Quota Consumption"
$LblQuotaHeader.Font = $FontSub
$LblQuotaHeader.ForeColor = $ColorTextLight
$LblQuotaHeader.Location = New-Object System.Drawing.Point(12, 10)
$LblQuotaHeader.AutoSize = $true

$LblQuotaPercentage = New-Object System.Windows.Forms.Label
$LblQuotaPercentage.Text = "0.0%"
$LblQuotaPercentage.Font = $FontMetric
$LblQuotaPercentage.ForeColor = $ColorAccent
$LblQuotaPercentage.Location = New-Object System.Drawing.Point(510, 6)
$LblQuotaPercentage.AutoSize = $true

$ProgressQuota = New-Object System.Windows.Forms.ProgressBar
$ProgressQuota.Location = New-Object System.Drawing.Point(14, 40)
$ProgressQuota.Size = New-Object System.Drawing.Size(564, 22)
$ProgressQuota.Minimum = 0
$ProgressQuota.Maximum = 1000
$ProgressQuota.Value = 0

$LblQuotaDetail = New-Object System.Windows.Forms.Label
$LblQuotaDetail.Text = "Used: 0.00 GB / Total: 16.00 GB (Remaining: 16.00 GB)"
$LblQuotaDetail.Font = $FontBody
$LblQuotaDetail.ForeColor = $ColorTextMuted
$LblQuotaDetail.Location = New-Object System.Drawing.Point(14, 72)
$LblQuotaDetail.AutoSize = $true

$CardQuota.Controls.AddRange(@($LblQuotaHeader, $LblQuotaPercentage, $ProgressQuota, $LblQuotaDetail))
$Tab1.Controls.Add($CardQuota)

# Card 3: Threshold Configuration & Enforcement Settings
$CardSettings = New-Object System.Windows.Forms.Panel
$CardSettings.Location = New-Object System.Drawing.Point(12, 216)
$CardSettings.Size = New-Object System.Drawing.Size(594, 192)
$CardSettings.BackColor = $ColorPanelBg
$CardSettings.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblSettingsHeader = New-Object System.Windows.Forms.Label
$LblSettingsHeader.Text = "Enforcement & Automation Controls"
$LblSettingsHeader.Font = $FontSub
$LblSettingsHeader.ForeColor = $ColorTextLight
$LblSettingsHeader.Location = New-Object System.Drawing.Point(12, 10)
$LblSettingsHeader.AutoSize = $true

$LblLimitInput = New-Object System.Windows.Forms.Label
$LblLimitInput.Text = "Monthly Quota Limit (GB):"
$LblLimitInput.Font = $FontBody
$LblLimitInput.ForeColor = $ColorTextMuted
$LblLimitInput.Location = New-Object System.Drawing.Point(14, 38)
$LblLimitInput.AutoSize = $true

$NumLimitInput = New-Object System.Windows.Forms.NumericUpDown
$NumLimitInput.Location = New-Object System.Drawing.Point(16, 60)
$NumLimitInput.Size = New-Object System.Drawing.Size(120, 24)
$NumLimitInput.DecimalPlaces = 1
$NumLimitInput.Minimum = 0.5
$NumLimitInput.Maximum = 2000.0
$NumLimitInput.Increment = 0.5
$NumLimitInput.Value = [decimal]$script:AppConfig.monthly_limit_gb
$NumLimitInput.BackColor = $ColorInputBg
$NumLimitInput.ForeColor = $ColorTextLight

$LblWarnInput = New-Object System.Windows.Forms.Label
$LblWarnInput.Text = "Warning Threshold (GB):"
$LblWarnInput.Font = $FontBody
$LblWarnInput.ForeColor = $ColorTextMuted
$LblWarnInput.Location = New-Object System.Drawing.Point(170, 38)
$LblWarnInput.AutoSize = $true

$NumWarnInput = New-Object System.Windows.Forms.NumericUpDown
$NumWarnInput.Location = New-Object System.Drawing.Point(172, 60)
$NumWarnInput.Size = New-Object System.Drawing.Size(120, 24)
$NumWarnInput.DecimalPlaces = 1
$NumWarnInput.Minimum = 0.5
$NumWarnInput.Maximum = 2000.0
$NumWarnInput.Increment = 0.5
$NumWarnInput.Value = [decimal]$script:AppConfig.warning_threshold_gb
$NumWarnInput.BackColor = $ColorInputBg
$NumWarnInput.ForeColor = $ColorTextLight

$ChkAutoDisconnect = New-Object System.Windows.Forms.CheckBox
$ChkAutoDisconnect.Text = "Automated Shutoff: Disable Wi-Fi adapter immediately when quota is reached"
$ChkAutoDisconnect.Font = $FontBody
$ChkAutoDisconnect.ForeColor = $ColorTextLight
$ChkAutoDisconnect.Location = New-Object System.Drawing.Point(16, 94)
$ChkAutoDisconnect.Size = New-Object System.Drawing.Size(560, 22)
$ChkAutoDisconnect.Checked = [bool]$script:AppConfig.auto_disconnect

$ChkStartWithWindows = New-Object System.Windows.Forms.CheckBox
$ChkStartWithWindows.Text = "Run at Windows Startup (Runs silently in background with highest Admin privileges)"
$ChkStartWithWindows.Font = $FontBody
$ChkStartWithWindows.ForeColor = $ColorTextLight
$ChkStartWithWindows.Location = New-Object System.Drawing.Point(16, 120)
$ChkStartWithWindows.Size = New-Object System.Drawing.Size(560, 22)
$ChkStartWithWindows.Checked = Test-StartupTaskEnabled

$BtnSaveSettings = New-Object System.Windows.Forms.Button
$BtnSaveSettings.Text = "Save Quota Settings"
$BtnSaveSettings.Location = New-Object System.Drawing.Point(16, 150)
$BtnSaveSettings.Size = New-Object System.Drawing.Size(160, 28)
$BtnSaveSettings.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnSaveSettings.FlatAppearance.BorderSize = 0
$BtnSaveSettings.BackColor = $ColorAccentDark
$BtnSaveSettings.ForeColor = $ColorTextLight
$BtnSaveSettings.Cursor = [System.Windows.Forms.Cursors]::Hand

$LblSaveStatus = New-Object System.Windows.Forms.Label
$LblSaveStatus.Text = ""
$LblSaveStatus.Font = $FontSmall
$LblSaveStatus.ForeColor = $ColorSuccess
$LblSaveStatus.Location = New-Object System.Drawing.Point(190, 156)
$LblSaveStatus.AutoSize = $true

$CardSettings.Controls.AddRange(@(
    $LblSettingsHeader, $LblLimitInput, $NumLimitInput, $LblWarnInput, $NumWarnInput,
    $ChkAutoDisconnect, $ChkStartWithWindows, $BtnSaveSettings, $LblSaveStatus
))
$Tab1.Controls.Add($CardSettings)

# Card 4: Manual Hardware Sentry Controls
$CardManual = New-Object System.Windows.Forms.Panel
$CardManual.Location = New-Object System.Drawing.Point(12, 416)
$CardManual.Size = New-Object System.Drawing.Size(594, 94)
$CardManual.BackColor = $ColorPanelBg
$CardManual.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblManualHeader = New-Object System.Windows.Forms.Label
$LblManualHeader.Text = "Manual Interface Override"
$LblManualHeader.Font = $FontSub
$LblManualHeader.ForeColor = $ColorTextLight
$LblManualHeader.Location = New-Object System.Drawing.Point(12, 10)
$LblManualHeader.AutoSize = $true

$BtnDisableWifi = New-Object System.Windows.Forms.Button
$BtnDisableWifi.Text = "Disable Wi-Fi"
$BtnDisableWifi.Location = New-Object System.Drawing.Point(16, 40)
$BtnDisableWifi.Size = New-Object System.Drawing.Size(130, 36)
$BtnDisableWifi.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnDisableWifi.FlatAppearance.BorderSize = 0
$BtnDisableWifi.BackColor = $ColorDanger
$BtnDisableWifi.ForeColor = $ColorTextLight
$BtnDisableWifi.Font = $FontSub
$BtnDisableWifi.Cursor = [System.Windows.Forms.Cursors]::Hand

$BtnEnableWifi = New-Object System.Windows.Forms.Button
$BtnEnableWifi.Text = "Enable Wi-Fi"
$BtnEnableWifi.Location = New-Object System.Drawing.Point(156, 40)
$BtnEnableWifi.Size = New-Object System.Drawing.Size(130, 36)
$BtnEnableWifi.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnEnableWifi.FlatAppearance.BorderSize = 0
$BtnEnableWifi.BackColor = $ColorSuccess
$BtnEnableWifi.ForeColor = $ColorTextLight
$BtnEnableWifi.Font = $FontSub
$BtnEnableWifi.Cursor = [System.Windows.Forms.Cursors]::Hand

$LblManualStatus = New-Object System.Windows.Forms.Label
$LblManualStatus.Text = "Target adapter ready for controls."
$LblManualStatus.Font = $FontSmall
$LblManualStatus.ForeColor = $ColorTextMuted
$LblManualStatus.Location = New-Object System.Drawing.Point(300, 50)
$LblManualStatus.AutoSize = $true

$CardManual.Controls.AddRange(@(
    $LblManualHeader, $BtnDisableWifi, $BtnEnableWifi, $LblManualStatus
))
$Tab1.Controls.Add($CardManual)


# ==============================================================================
# TAB 2: Usage History & Analytics
# ==============================================================================

# Metric Cards
$CardToday = New-Object System.Windows.Forms.Panel
$CardToday.Location = New-Object System.Drawing.Point(12, 14)
$CardToday.Size = New-Object System.Drawing.Size(188, 92)
$CardToday.BackColor = $ColorPanelBg
$CardToday.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblTodayTitle = New-Object System.Windows.Forms.Label
$LblTodayTitle.Text = "TODAY"
$LblTodayTitle.Font = $FontSub
$LblTodayTitle.ForeColor = $ColorTextMuted
$LblTodayTitle.Location = New-Object System.Drawing.Point(12, 10)
$LblTodayTitle.AutoSize = $true

$LblTodayValue = New-Object System.Windows.Forms.Label
$LblTodayValue.Text = "0.00 MB"
$LblTodayValue.Font = $FontMetric
$LblTodayValue.ForeColor = $ColorAccent
$LblTodayValue.Location = New-Object System.Drawing.Point(10, 34)
$LblTodayValue.AutoSize = $true

$LblTodaySub = New-Object System.Windows.Forms.Label
$LblTodaySub.Text = (Get-Date).ToString("yyyy-MM-dd")
$LblTodaySub.Font = $FontSmall
$LblTodaySub.ForeColor = $ColorTextMuted
$LblTodaySub.Location = New-Object System.Drawing.Point(12, 66)
$LblTodaySub.AutoSize = $true

$CardToday.Controls.AddRange(@($LblTodayTitle, $LblTodayValue, $LblTodaySub))
$Tab2.Controls.Add($CardToday)

$CardMonth = New-Object System.Windows.Forms.Panel
$CardMonth.Location = New-Object System.Drawing.Point(215, 14)
$CardMonth.Size = New-Object System.Drawing.Size(188, 92)
$CardMonth.BackColor = $ColorPanelBg
$CardMonth.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblMonthTitle = New-Object System.Windows.Forms.Label
$LblMonthTitle.Text = "THIS MONTH"
$LblMonthTitle.Font = $FontSub
$LblMonthTitle.ForeColor = $ColorTextMuted
$LblMonthTitle.Location = New-Object System.Drawing.Point(12, 10)
$LblMonthTitle.AutoSize = $true

$LblMonthValue = New-Object System.Windows.Forms.Label
$LblMonthValue.Text = "0.00 GB"
$LblMonthValue.Font = $FontMetric
$LblMonthValue.ForeColor = $ColorSuccess
$LblMonthValue.Location = New-Object System.Drawing.Point(10, 34)
$LblMonthValue.AutoSize = $true

$LblMonthSub = New-Object System.Windows.Forms.Label
$LblMonthSub.Text = (Get-Date).ToString("MMMM yyyy")
$LblMonthSub.Font = $FontSmall
$LblMonthSub.ForeColor = $ColorTextMuted
$LblMonthSub.Location = New-Object System.Drawing.Point(12, 66)
$LblMonthSub.AutoSize = $true

$CardMonth.Controls.AddRange(@($LblMonthTitle, $LblMonthValue, $LblMonthSub))
$Tab2.Controls.Add($CardMonth)

$CardYear = New-Object System.Windows.Forms.Panel
$CardYear.Location = New-Object System.Drawing.Point(418, 14)
$CardYear.Size = New-Object System.Drawing.Size(188, 92)
$CardYear.BackColor = $ColorPanelBg
$CardYear.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblYearTitle = New-Object System.Windows.Forms.Label
$LblYearTitle.Text = "THIS YEAR"
$LblYearTitle.Font = $FontSub
$LblYearTitle.ForeColor = $ColorTextMuted
$LblYearTitle.Location = New-Object System.Drawing.Point(12, 10)
$LblYearTitle.AutoSize = $true

$LblYearValue = New-Object System.Windows.Forms.Label
$LblYearValue.Text = "0.00 GB"
$LblYearValue.Font = $FontMetric
$LblYearValue.ForeColor = $ColorAccent
$LblYearValue.Location = New-Object System.Drawing.Point(10, 34)
$LblYearValue.AutoSize = $true

$LblYearSub = New-Object System.Windows.Forms.Label
$LblYearSub.Text = (Get-Date).ToString("yyyy")
$LblYearSub.Font = $FontSmall
$LblYearSub.ForeColor = $ColorTextMuted
$LblYearSub.Location = New-Object System.Drawing.Point(12, 66)
$LblYearSub.AutoSize = $true

$CardYear.Controls.AddRange(@($LblYearTitle, $LblYearValue, $LblYearSub))
$Tab2.Controls.Add($CardYear)

# History Data List
$PanelHistoryTable = New-Object System.Windows.Forms.Panel
$PanelHistoryTable.Location = New-Object System.Drawing.Point(12, 120)
$PanelHistoryTable.Size = New-Object System.Drawing.Size(594, 280)
$PanelHistoryTable.BackColor = $ColorPanelBg
$PanelHistoryTable.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblHistoryTableTitle = New-Object System.Windows.Forms.Label
$LblHistoryTableTitle.Text = "Daily Usage Log (Current & Recent Records)"
$LblHistoryTableTitle.Font = $FontSub
$LblHistoryTableTitle.ForeColor = $ColorTextLight
$LblHistoryTableTitle.Location = New-Object System.Drawing.Point(12, 10)
$LblHistoryTableTitle.AutoSize = $true

$ListHistory = New-Object System.Windows.Forms.ListView
$ListHistory.Location = New-Object System.Drawing.Point(12, 36)
$ListHistory.Size = New-Object System.Drawing.Size(568, 230)
$ListHistory.View = [System.Windows.Forms.View]::Details
$ListHistory.FullRowSelect = $true
$ListHistory.GridLines = $true
$ListHistory.BackColor = $ColorInputBg
$ListHistory.ForeColor = $ColorTextLight
$ListHistory.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

[void]$ListHistory.Columns.Add("Date", 160)
[void]$ListHistory.Columns.Add("Data Consumed", 180)
[void]$ListHistory.Columns.Add("Raw Bytes", 200)

$PanelHistoryTable.Controls.AddRange(@($LblHistoryTableTitle, $ListHistory))
$Tab2.Controls.Add($PanelHistoryTable)

# Billing Cycle Reset Card
$CardReset = New-Object System.Windows.Forms.Panel
$CardReset.Location = New-Object System.Drawing.Point(12, 412)
$CardReset.Size = New-Object System.Drawing.Size(594, 94)
$CardReset.BackColor = $ColorPanelBg
$CardReset.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblResetTitle = New-Object System.Windows.Forms.Label
$LblResetTitle.Text = "Billing Cycle Synchronization"
$LblResetTitle.Font = $FontSub
$LblResetTitle.ForeColor = $ColorTextLight
$LblResetTitle.Location = New-Object System.Drawing.Point(12, 10)
$LblResetTitle.AutoSize = $true

$LblResetDesc = New-Object System.Windows.Forms.Label
$LblResetDesc.Text = "Reset the monthly consumption metrics to 0 GB when your ISP / Cellular billing cycle renews."
$LblResetDesc.Font = $FontSmall
$LblResetDesc.ForeColor = $ColorTextMuted
$LblResetDesc.Location = New-Object System.Drawing.Point(12, 34)
$LblResetDesc.AutoSize = $true

$BtnResetMonth = New-Object System.Windows.Forms.Button
$BtnResetMonth.Text = "Reset Current Month"
$BtnResetMonth.Location = New-Object System.Drawing.Point(14, 54)
$BtnResetMonth.Size = New-Object System.Drawing.Size(180, 28)
$BtnResetMonth.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnResetMonth.FlatAppearance.BorderSize = 0
$BtnResetMonth.BackColor = $ColorWarning
$BtnResetMonth.ForeColor = [System.Drawing.Color]::Black
$BtnResetMonth.Font = $FontSub
$BtnResetMonth.Cursor = [System.Windows.Forms.Cursors]::Hand

$LblResetStatus = New-Object System.Windows.Forms.Label
$LblResetStatus.Text = ""
$LblResetStatus.Font = $FontSmall
$LblResetStatus.ForeColor = $ColorSuccess
$LblResetStatus.Location = New-Object System.Drawing.Point(210, 60)
$LblResetStatus.AutoSize = $true

$CardReset.Controls.AddRange(@($LblResetTitle, $LblResetDesc, $BtnResetMonth, $LblResetStatus))
$Tab2.Controls.Add($CardReset)


# ==============================================================================
# TAB 3: Application Firewall Blocker
# ==============================================================================

# Executable Picker Group
$CardFirewallPicker = New-Object System.Windows.Forms.Panel
$CardFirewallPicker.Location = New-Object System.Drawing.Point(12, 14)
$CardFirewallPicker.Size = New-Object System.Drawing.Size(594, 126)
$CardFirewallPicker.BackColor = $ColorPanelBg
$CardFirewallPicker.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblFwTitle = New-Object System.Windows.Forms.Label
$LblFwTitle.Text = "Block Outbound Bandwidth Consumers"
$LblFwTitle.Font = $FontSub
$LblFwTitle.ForeColor = $ColorTextLight
$LblFwTitle.Location = New-Object System.Drawing.Point(12, 10)
$LblFwTitle.AutoSize = $true

$LblFwDesc = New-Object System.Windows.Forms.Label
$LblFwDesc.Text = "Select an executable (.exe) to generate an immediate outbound blocking rule in Windows Defender Firewall."
$LblFwDesc.Font = $FontSmall
$LblFwDesc.ForeColor = $ColorTextMuted
$LblFwDesc.Location = New-Object System.Drawing.Point(12, 34)
$LblFwDesc.AutoSize = $true

$TxtExePath = New-Object System.Windows.Forms.TextBox
$TxtExePath.Location = New-Object System.Drawing.Point(14, 58)
$TxtExePath.Size = New-Object System.Drawing.Size(460, 24)
$TxtExePath.BackColor = $ColorInputBg
$TxtExePath.ForeColor = $ColorTextLight
$TxtExePath.ReadOnly = $true

$BtnBrowseExe = New-Object System.Windows.Forms.Button
$BtnBrowseExe.Text = "Browse..."
$BtnBrowseExe.Location = New-Object System.Drawing.Point(482, 56)
$BtnBrowseExe.Size = New-Object System.Drawing.Size(98, 28)
$BtnBrowseExe.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnBrowseExe.FlatAppearance.BorderSize = 0
$BtnBrowseExe.BackColor = $ColorPanelBg
$BtnBrowseExe.ForeColor = $ColorAccent
$BtnBrowseExe.Cursor = [System.Windows.Forms.Cursors]::Hand

$BtnBlockApp = New-Object System.Windows.Forms.Button
$BtnBlockApp.Text = "Block Outbound Access"
$BtnBlockApp.Location = New-Object System.Drawing.Point(14, 90)
$BtnBlockApp.Size = New-Object System.Drawing.Size(180, 28)
$BtnBlockApp.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnBlockApp.FlatAppearance.BorderSize = 0
$BtnBlockApp.BackColor = $ColorDanger
$BtnBlockApp.ForeColor = $ColorTextLight
$BtnBlockApp.Font = $FontSub
$BtnBlockApp.Cursor = [System.Windows.Forms.Cursors]::Hand

$LblFwActionStatus = New-Object System.Windows.Forms.Label
$LblFwActionStatus.Text = ""
$LblFwActionStatus.Font = $FontSmall
$LblFwActionStatus.ForeColor = $ColorSuccess
$LblFwActionStatus.Location = New-Object System.Drawing.Point(206, 96)
$LblFwActionStatus.AutoSize = $true

$CardFirewallPicker.Controls.AddRange(@(
    $LblFwTitle, $LblFwDesc, $TxtExePath, $BtnBrowseExe, $BtnBlockApp, $LblFwActionStatus
))
$Tab3.Controls.Add($CardFirewallPicker)

# Firewall Rules List Card
$CardFirewallList = New-Object System.Windows.Forms.Panel
$CardFirewallList.Location = New-Object System.Drawing.Point(12, 150)
$CardFirewallList.Size = New-Object System.Drawing.Size(594, 356)
$CardFirewallList.BackColor = $ColorPanelBg
$CardFirewallList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblRulesListTitle = New-Object System.Windows.Forms.Label
$LblRulesListTitle.Text = "Active DataControl Outbound Block Rules"
$LblRulesListTitle.Font = $FontSub
$LblRulesListTitle.ForeColor = $ColorTextLight
$LblRulesListTitle.Location = New-Object System.Drawing.Point(12, 10)
$LblRulesListTitle.AutoSize = $true

$ListFirewallRules = New-Object System.Windows.Forms.ListView
$ListFirewallRules.Location = New-Object System.Drawing.Point(12, 36)
$ListFirewallRules.Size = New-Object System.Drawing.Size(568, 266)
$ListFirewallRules.View = [System.Windows.Forms.View]::Details
$ListFirewallRules.FullRowSelect = $true
$ListFirewallRules.GridLines = $true
$ListFirewallRules.MultiSelect = $false
$ListFirewallRules.BackColor = $ColorInputBg
$ListFirewallRules.ForeColor = $ColorTextLight
$ListFirewallRules.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

[void]$ListFirewallRules.Columns.Add("Rule Display Name", 200)
[void]$ListFirewallRules.Columns.Add("Program Path", 270)
[void]$ListFirewallRules.Columns.Add("Action", 80)

$BtnUnblockApp = New-Object System.Windows.Forms.Button
$BtnUnblockApp.Text = "Unblock Application"
$BtnUnblockApp.Location = New-Object System.Drawing.Point(12, 312)
$BtnUnblockApp.Size = New-Object System.Drawing.Size(160, 30)
$BtnUnblockApp.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnUnblockApp.FlatAppearance.BorderSize = 0
$BtnUnblockApp.BackColor = $ColorSuccess
$BtnUnblockApp.ForeColor = $ColorTextLight
$BtnUnblockApp.Font = $FontSub
$BtnUnblockApp.Cursor = [System.Windows.Forms.Cursors]::Hand

$BtnRefreshRules = New-Object System.Windows.Forms.Button
$BtnRefreshRules.Text = "Refresh Rules"
$BtnRefreshRules.Location = New-Object System.Drawing.Point(182, 312)
$BtnRefreshRules.Size = New-Object System.Drawing.Size(130, 30)
$BtnRefreshRules.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnRefreshRules.FlatAppearance.BorderSize = 0
$BtnRefreshRules.BackColor = $ColorAccentDark
$BtnRefreshRules.ForeColor = $ColorTextLight
$BtnRefreshRules.Cursor = [System.Windows.Forms.Cursors]::Hand

$LblUnblockStatus = New-Object System.Windows.Forms.Label
$LblUnblockStatus.Text = ""
$LblUnblockStatus.Font = $FontSmall
$LblUnblockStatus.ForeColor = $ColorSuccess
$LblUnblockStatus.Location = New-Object System.Drawing.Point(324, 320)
$LblUnblockStatus.AutoSize = $true

$CardFirewallList.Controls.AddRange(@(
    $LblRulesListTitle, $ListFirewallRules, $BtnUnblockApp, $BtnRefreshRules, $LblUnblockStatus
))
$Tab3.Controls.Add($CardFirewallList)


# ==============================================================================
# Dynamic UI Refresh & Data Binding Functions
# ==============================================================================

function Refresh-AdapterList {
    $ComboAdapters.Items.Clear()
    try {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object -Property @{
            Expression = {
                if ($_.PhysicalMediaType -match "802.11" -or $_.MediaType -match "Native 802.11" -or $_.Name -like "*Wi-Fi*") { 0 } else { 1 }
            }
        }, Name

        foreach ($a in $adapters) {
            [void]$ComboAdapters.Items.Add($a.Name)
        }

        if ($ComboAdapters.Items.Contains($script:AppConfig.target_adapter)) {
            $ComboAdapters.SelectedItem = $script:AppConfig.target_adapter
        } elseif ($ComboAdapters.Items.Count -gt 0) {
            $ComboAdapters.SelectedIndex = 0
            $script:AppConfig.target_adapter = [string]$ComboAdapters.SelectedItem
            Save-AppConfig $script:AppConfig
        }
    } catch {
        [void]$ComboAdapters.Items.Add("Wi-Fi")
        $ComboAdapters.SelectedIndex = 0
    }
}

function Refresh-AdapterStatusLabel {
    $sel = [string]$ComboAdapters.SelectedItem
    if (-not $sel) { $sel = $script:AppConfig.target_adapter }
    try {
        $adapter = Get-NetAdapter -Name $sel -ErrorAction SilentlyContinue
        if ($adapter) {
            if ($adapter.Status -eq "Up") {
                $LblStateValue.Text = "Connected (Up)"
                $LblStateValue.ForeColor = $ColorSuccess
                $HeaderStatusBadge.Text = "● CONNECTED"
                $HeaderStatusBadge.ForeColor = $ColorSuccess
            } elseif ($adapter.Status -eq "Disabled") {
                $LblStateValue.Text = "Disabled"
                $LblStateValue.ForeColor = $ColorDanger
                $HeaderStatusBadge.Text = "● DISABLED"
                $HeaderStatusBadge.ForeColor = $ColorDanger
            } else {
                $LblStateValue.Text = "$($adapter.Status)"
                $LblStateValue.ForeColor = $ColorWarning
                $HeaderStatusBadge.Text = "● $($adapter.Status.ToUpper())"
                $HeaderStatusBadge.ForeColor = $ColorWarning
            }
        } else {
            $LblStateValue.Text = "Not Found"
            $LblStateValue.ForeColor = $ColorDanger
            $HeaderStatusBadge.Text = "● ADAPTER MISSING"
            $HeaderStatusBadge.ForeColor = $ColorDanger
        }
    } catch {
        $LblStateValue.Text = "Error"
        $LblStateValue.ForeColor = $ColorDanger
    }
}

function Refresh-UsageDisplay {
    $dateNow = Get-Date
    $dayKey = $dateNow.ToString("yyyy-MM-dd")
    $monthKey = $dateNow.ToString("yyyy-MM")
    $yearKey = $dateNow.ToString("yyyy")

    $dayBytes = 0.0
    if ($script:DataHistory.daily.PSObject.Properties[$dayKey]) {
        $dayBytes = [double]$script:DataHistory.daily.$dayKey
    }

    $monthBytes = 0.0
    if ($script:DataHistory.monthly.PSObject.Properties[$monthKey]) {
        $monthBytes = [double]$script:DataHistory.monthly.$monthKey
    }

    $yearBytes = 0.0
    if ($script:DataHistory.yearly.PSObject.Properties[$yearKey]) {
        $yearBytes = [double]$script:DataHistory.yearly.$yearKey
    }

    $monthGB = $monthBytes / 1GB
    $limitGB = [double]$script:AppConfig.monthly_limit_gb
    $warnGB  = [double]$script:AppConfig.warning_threshold_gb

    $rateBps = $script:CurrentThroughputBytesPerSec
    if ($rateBps -ge 1MB) {
        $rateMB = [math]::Round($rateBps / 1MB, 2)
        $LblLiveSpeedValue.Text = "$rateMB MB/s"
    } else {
        $rateKB = [math]::Round($rateBps / 1KB, 1)
        $LblLiveSpeedValue.Text = "$rateKB KB/s"
    }

    $percent = 0.0
    if ($limitGB -gt 0) {
        $percent = [math]::Round(($monthGB / $limitGB) * 100.0, 1)
    }
    $LblQuotaPercentage.Text = "$percent%"

    $progVal = [int]([math]::Min(100.0, [math]::Max(0.0, $percent)) * 10)
    $ProgressQuota.Value = $progVal

    $remainingGB = [math]::Max(0.0, [math]::Round($limitGB - $monthGB, 2))
    $LblQuotaDetail.Text = "Used: $([math]::Round($monthGB, 2)) GB / Total: $([math]::Round($limitGB, 2)) GB (Remaining: $remainingGB GB)"

    if ($monthGB -ge $limitGB) {
        $LblQuotaPercentage.ForeColor = $ColorDanger
    } elseif ($monthGB -ge $warnGB) {
        $LblQuotaPercentage.ForeColor = $ColorWarning
    } else {
        $LblQuotaPercentage.ForeColor = $ColorAccent
    }

    $LblTodayValue.Text = Format-Bytes $dayBytes
    $LblMonthValue.Text = Format-Bytes $monthBytes
    $LblYearValue.Text = Format-Bytes $yearBytes

    $trayStr = "DataControl: $([math]::Round($monthGB, 2)) GB / $([math]::Round($limitGB, 2)) GB"
    if ($trayStr.Length -gt 63) { $trayStr = $trayStr.Substring(0, 63) }
    $NotifyIcon.Text = $trayStr
}

function Refresh-HistoryTable {
    $ListHistory.BeginUpdate()
    $ListHistory.Items.Clear()

    if ($script:DataHistory.daily) {
        $props = $script:DataHistory.daily.PSObject.Properties | Sort-Object -Property Name -Descending
        foreach ($prop in $props) {
            $bytes = [double]$prop.Value
            $item = New-Object System.Windows.Forms.ListViewItem($prop.Name)
            [void]$item.SubItems.Add((Format-Bytes $bytes))
            [void]$item.SubItems.Add(($bytes.ToString("N0") + " bytes"))
            [void]$ListHistory.Items.Add($item)
        }
    }
    $ListHistory.EndUpdate()
}

function Refresh-FirewallRulesList {
    $ListFirewallRules.BeginUpdate()
    $ListFirewallRules.Items.Clear()
    try {
        $rules = Get-NetFirewallRule -DisplayName "DataControl-Block-*" -ErrorAction SilentlyContinue
        foreach ($r in $rules) {
            $progPath = ""
            try {
                $filter = $r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
                if ($filter -and $filter.Program) { $progPath = $filter.Program }
            } catch {}

            $item = New-Object System.Windows.Forms.ListViewItem($r.DisplayName)
            [void]$item.SubItems.Add($progPath)
            [void]$item.SubItems.Add($r.Action.ToString())
            $item.Tag = $r.DisplayName
            [void]$ListFirewallRules.Items.Add($item)
        }
    } catch {
        Write-Warning "Failed to query firewall rules: $_"
    }
    $ListFirewallRules.EndUpdate()
}

# ==============================================================================
# Step 5: Enforcement Engine & Background Orchestration
# ==============================================================================

function Check-EnforcementRules {
    $monthKey = (Get-Date).ToString("yyyy-MM")
    $monthBytes = 0.0
    if ($script:DataHistory.monthly.PSObject.Properties[$monthKey]) {
        $monthBytes = [double]$script:DataHistory.monthly.$monthKey
    }

    $monthGB = $monthBytes / 1GB
    $limitGB = [double]$script:AppConfig.monthly_limit_gb
    $warnGB  = [double]$script:AppConfig.warning_threshold_gb
    $targetAdapter = [string]$script:AppConfig.target_adapter

    # 1. Warning Threshold Notification
    if ($monthGB -ge $warnGB -and $monthGB -lt $limitGB) {
        if (-not $script:WarningNotified) {
            $NotifyIcon.ShowBalloonTip(
                4000,
                "DataControl: Warning Threshold Reached",
                "Monthly usage has reached $([math]::Round($monthGB, 2)) GB (Warning Threshold: $warnGB GB / Limit: $limitGB GB).",
                [System.Windows.Forms.ToolTipIcon]::Warning
            )
            $script:WarningNotified = $true
        }
    } elseif ($monthGB -lt $warnGB) {
        $script:WarningNotified = $false
    }

    # 2. Hard Monthly Quota Limit Notification & Auto-Disconnect
    if ($monthGB -ge $limitGB) {
        if (-not $script:LimitNotified) {
            if ($script:AppConfig.auto_disconnect) {
                try {
                    Disable-NetAdapter -Name $targetAdapter -Confirm:$false -ErrorAction SilentlyContinue
                    $LblManualStatus.Text = "Automated shutoff executed! Quota exceeded."
                    $LblManualStatus.ForeColor = $ColorDanger
                    Refresh-AdapterStatusLabel
                } catch {
                    $LblManualStatus.Text = "Failed to auto-disable adapter: $_"
                }

                $NotifyIcon.ShowBalloonTip(
                    6000,
                    "DataControl: Quota Limit Exceeded!",
                    "Hard limit of $limitGB GB reached! Automated shutoff has disabled adapter '$targetAdapter' to prevent data overages.",
                    [System.Windows.Forms.ToolTipIcon]::Error
                )
            } else {
                $NotifyIcon.ShowBalloonTip(
                    5000,
                    "DataControl: Monthly Quota Exceeded!",
                    "You have reached $([math]::Round($monthGB, 2)) GB (Limit: $limitGB GB). Automated shutoff is currently disabled in settings.",
                    [System.Windows.Forms.ToolTipIcon]::Warning
                )
            }
            $script:LimitNotified = $true
        }
    } else {
        $script:LimitNotified = $false
    }
}

# Background Poll Timer Setup
$PollTimer = New-Object System.Windows.Forms.Timer
$pollSeconds = [int]$script:AppConfig.poll_frequency_seconds
if ($pollSeconds -lt 1) { $pollSeconds = 3 }
$PollTimer.Interval = $pollSeconds * 1000

$PollTimer.Add_Tick({
    $target = [string]$ComboAdapters.SelectedItem
    if (-not $target) { $target = $script:AppConfig.target_adapter }

    Update-NetworkMetrics -AdapterName $target
    Refresh-AdapterStatusLabel
    Refresh-UsageDisplay
    Check-EnforcementRules
})

# ==============================================================================
# UI Event Handlers
# ==============================================================================

# Adapter ComboBox Selection Changed
$ComboAdapters.Add_SelectedIndexChanged({
    $selected = [string]$ComboAdapters.SelectedItem
    if ($selected -and $selected -ne $script:AppConfig.target_adapter) {
        $script:AppConfig.target_adapter = $selected
        Save-AppConfig $script:AppConfig
        Refresh-AdapterStatusLabel
    }
})

# Save Settings Button Click
$BtnSaveSettings.Add_Click({
    $script:AppConfig.monthly_limit_gb = [double]$NumLimitInput.Value
    $script:AppConfig.warning_threshold_gb = [double]$NumWarnInput.Value
    $script:AppConfig.auto_disconnect = [bool]$ChkAutoDisconnect.Checked
    $selected = [string]$ComboAdapters.SelectedItem
    if ($selected) { $script:AppConfig.target_adapter = $selected }

    # Sync Startup Task status with checkbox
    $isTaskWanted = [bool]$ChkStartWithWindows.Checked
    Set-StartupTaskEnabled $isTaskWanted | Out-Null
    $TrayMenuItemStartup.Checked = $isTaskWanted

    Save-AppConfig $script:AppConfig
    Refresh-UsageDisplay

    $LblSaveStatus.Text = "Settings saved successfully!"
    $LblSaveStatus.ForeColor = $ColorSuccess
    
    $tempTimer = New-Object System.Windows.Forms.Timer
    $tempTimer.Interval = 2500
    $tempTimer.Add_Tick({
        $LblSaveStatus.Text = ""
        $tempTimer.Stop()
        $tempTimer.Dispose()
    })
    $tempTimer.Start()
})

# Manual Disable Wi-Fi Button Click
$BtnDisableWifi.Add_Click({
    $target = [string]$ComboAdapters.SelectedItem
    if (-not $target) { $target = $script:AppConfig.target_adapter }
    try {
        $LblManualStatus.Text = "Disabling $target..."
        $LblManualStatus.ForeColor = $ColorWarning
        [System.Windows.Forms.Application]::DoEvents()
        Disable-NetAdapter -Name $target -Confirm:$false -ErrorAction Stop
        $LblManualStatus.Text = "$target successfully disabled."
        $LblManualStatus.ForeColor = $ColorDanger
    } catch {
        $LblManualStatus.Text = "Error: $($_.Exception.Message)"
        $LblManualStatus.ForeColor = $ColorDanger
    }
    Refresh-AdapterStatusLabel
})

# Manual Enable Wi-Fi Button Click
$BtnEnableWifi.Add_Click({
    $target = [string]$ComboAdapters.SelectedItem
    if (-not $target) { $target = $script:AppConfig.target_adapter }
    try {
        $LblManualStatus.Text = "Enabling $target..."
        $LblManualStatus.ForeColor = $ColorWarning
        [System.Windows.Forms.Application]::DoEvents()
        Enable-NetAdapter -Name $target -Confirm:$false -ErrorAction Stop
        $LblManualStatus.Text = "$target successfully enabled."
        $LblManualStatus.ForeColor = $ColorSuccess
    } catch {
        $LblManualStatus.Text = "Error: $($_.Exception.Message)"
        $LblManualStatus.ForeColor = $ColorDanger
    }
    Refresh-AdapterStatusLabel
})

# Reset Current Month Button Click
$BtnResetMonth.Add_Click({
    $currentMonthName = (Get-Date).ToString("MMMM yyyy")
    $dialogResult = [System.Windows.Forms.MessageBox]::Show(
        "Are you sure you want to reset current month data to 0 GB for $currentMonthName?`n`nThis action is irreversible and recommended when your billing cycle renews.",
        "Confirm Monthly Data Reset",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::Yes) {
        $monthKey = (Get-Date).ToString("yyyy-MM")
        $script:DataHistory.monthly | Add-Member -MemberType NoteProperty -Name $monthKey -Value 0.0 -Force
        Save-DataHistory $script:DataHistory
        $script:WarningNotified = $false
        $script:LimitNotified = $false

        Refresh-UsageDisplay
        Refresh-HistoryTable

        $LblResetStatus.Text = "Monthly metrics reset to 0 GB!"
        $LblResetStatus.ForeColor = $ColorSuccess
    }
})

# Tab Selected Event
$TabControl.Add_SelectedIndexChanged({
    if ($TabControl.SelectedTab -eq $Tab2) {
        Refresh-HistoryTable
    } elseif ($TabControl.SelectedTab -eq $Tab3) {
        Refresh-FirewallRulesList
    }
})

# Browse Executable Button Click
$BtnBrowseExe.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Executable files (*.exe)|*.exe|All files (*.*)|*.*"
    $ofd.Title = "Select Application to Block"
    $ofd.InitialDirectory = [Environment]::GetFolderPath("ProgramFiles")
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $TxtExePath.Text = $ofd.FileName
        $LblFwActionStatus.Text = ""
    }
    $ofd.Dispose()
})

# Block Application Button Click
$BtnBlockApp.Add_Click({
    $exePath = $TxtExePath.Text.Trim()
    if (-not $exePath -or -not (Test-Path $exePath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Please select a valid executable (.exe) file first.",
            "Invalid Executable",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    $fileName = [System.IO.Path]::GetFileName($exePath)
    $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($exePath)
    $ruleName = "DataControl-Block-$cleanName"

    try {
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($existing) {
            Remove-NetFirewallRule -DisplayName $ruleName -Confirm:$false -ErrorAction SilentlyContinue
        }

        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Name $ruleName `
            -Direction Outbound `
            -Program $exePath `
            -Action Block `
            -Profile Any `
            -Description "Blocked by DataControl outbound traffic control" `
            -ErrorAction Stop

        $LblFwActionStatus.Text = "Successfully blocked: $fileName"
        $LblFwActionStatus.ForeColor = $ColorSuccess
        $TxtExePath.Text = ""
        Refresh-FirewallRulesList
    } catch {
        $LblFwActionStatus.Text = "Error: $($_.Exception.Message)"
        $LblFwActionStatus.ForeColor = $ColorDanger
    }
})

# Unblock Application Button Click
$BtnUnblockApp.Add_Click({
    if ($ListFirewallRules.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Please select a firewall rule from the list to unblock.",
            "No Rule Selected",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return
    }

    $selectedItem = $ListFirewallRules.SelectedItems[0]
    $ruleDisplayName = $selectedItem.Text

    try {
        Remove-NetFirewallRule -DisplayName $ruleDisplayName -Confirm:$false -ErrorAction Stop
        $LblUnblockStatus.Text = "Unblocked: $ruleDisplayName"
        $LblUnblockStatus.ForeColor = $ColorSuccess
        Refresh-FirewallRulesList
    } catch {
        $LblUnblockStatus.Text = "Error: $($_.Exception.Message)"
        $LblUnblockStatus.ForeColor = $ColorDanger
    }
})

# Refresh Rules Button Click
$BtnRefreshRules.Add_Click({
    Refresh-FirewallRulesList
    $LblUnblockStatus.Text = "Rules list refreshed."
    $LblUnblockStatus.ForeColor = $ColorTextLight
})

# Form Closing: Resource Cleanup
$Form.Add_FormClosing({
    $PollTimer.Stop()
    $PollTimer.Dispose()
    $NotifyIcon.Visible = $false
    $NotifyIcon.Dispose()
    Save-DataHistory $script:DataHistory
})

# Initial Form Load Preparation
$Form.Add_Load({
    Refresh-AdapterList
    Refresh-AdapterStatusLabel
    Update-NetworkMetrics
    Refresh-UsageDisplay
    Refresh-FirewallRulesList
    $PollTimer.Start()
})

# Handle Start Minimized (Background Boot)
if ($StartMinimized) {
    $Form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
    $Form.ShowInTaskbar = $false
    $Form.Add_Shown({
        $Form.Hide()
        $Form.ShowInTaskbar = $false
        $NotifyIcon.ShowBalloonTip(
            3500,
            "DataControl Sentry Active",
            "DataControl is actively monitoring network quotas in the background. Double-click to open dashboard.",
            [System.Windows.Forms.ToolTipIcon]::Info
        )
    })
}

# Launch Application Form
[System.Windows.Forms.Application]::Run($Form)
