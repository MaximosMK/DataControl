<#
.SYNOPSIS
    DataControl - Windows 11 Data Control System (v2.0)
.DESCRIPTION
    Autonomous network metering, dual daily/monthly quota enforcement, live per-application
    bandwidth tracking, application consumption history, and Windows Defender Firewall blocker.
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
$AppHistoryFile = Join-Path $AppDir "app_history.json"
$IconPath = Join-Path $AppDir "DataControl.ico"
$TaskName = "DataControl_Monitor"

# Load Native Process IO Tracker
$csharpTracker = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class Win32ProcTracker {
    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessIoCounters(IntPtr hProcess, out IO_COUNTERS counters);

    public static ulong GetProcessBytes(int pid) {
        try {
            using (Process p = Process.GetProcessById(pid)) {
                IO_COUNTERS c;
                if (GetProcessIoCounters(p.Handle, out c)) {
                    return c.ReadTransferCount + c.WriteTransferCount;
                }
            }
        } catch {}
        return 0;
    }
}
'@
Add-Type -TypeDefinition $csharpTracker -ErrorAction SilentlyContinue

# ==============================================================================
# Helper Functions: Config & History Management
# ==============================================================================
function Load-AppConfig {
    if (Test-Path $ConfigFile) {
        try {
            $raw = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            # Set defaults for newly added fields
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

function Load-AppHistory {
    if (Test-Path $AppHistoryFile) {
        try {
            $raw = Get-Content -Path $AppHistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
            return $raw
        } catch {}
    }
    return (New-Object PSCustomObject)
}

function Save-AppHistory ($appHist) {
    try {
        $appHist | ConvertTo-Json -Depth 6 | Set-Content -Path $AppHistoryFile -Encoding UTF8
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

# Scheduled Task Management
function Test-StartupTaskEnabled {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    return ($null -ne $task)
}

function Set-StartupTaskEnabled ([bool]$enable) {
    if ($enable) {
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
$script:AppHistory = Load-AppHistory
$script:LastPollTime = [DateTime]::UtcNow
$script:DailyWarningNotified = $false
$script:DailyLimitNotified = $false
$script:MonthlyWarningNotified = $false
$script:MonthlyLimitNotified = $false
$script:CurrentThroughputBytesPerSec = 0.0

# Per-Process Tracking State Cache (PID -> Stats)
$script:ProcStateCache = @{}

# ==============================================================================
# Network Metering Engine (Overall & Per-Process)
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
    } catch {}

    # Sample Per-Process Bandwidth
    Update-AppProcessMetrics -ElapsedSeconds $elapsedSec
}

function Update-AppProcessMetrics ([double]$ElapsedSeconds) {
    try {
        $tcpConns = Get-NetTCPConnection -State Established, CloseWait, TimeWait -ErrorAction SilentlyContinue
        $udpConns = Get-NetUDPEndpoint -ErrorAction SilentlyContinue
        $pids = @($tcpConns.OwningProcess + $udpConns.OwningProcess | Where-Object { $_ -gt 4 } | Select-Object -Unique)

        $currentPids = @{}
        $nowStr = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $historyUpdated = $false

        foreach ($pidNum in $pids) {
            $p = Get-Process -Id $pidNum -ErrorAction SilentlyContinue
            if (-not $p) { continue }

            $pName = $p.ProcessName + ".exe"
            $pPath = ""
            try { $pPath = $p.Path } catch {}

            $connCount = ($tcpConns | Where-Object { $_.OwningProcess -eq $pidNum }).Count + ($udpConns | Where-Object { $_.OwningProcess -eq $pidNum }).Count

            $rawBytes = [Win32ProcTracker]::GetProcessBytes($pidNum)
            $prevBytes = 0
            $sessionBytes = 0.0
            $speedBps = 0.0

            if ($script:ProcStateCache.ContainsKey($pidNum)) {
                $cacheItem = $script:ProcStateCache[$pidNum]
                $prevBytes = [double]$cacheItem.LastBytes
                $sessionBytes = [double]$cacheItem.SessionBytes

                if ($rawBytes -ge $prevBytes -and $prevBytes -gt 0) {
                    $procDelta = $rawBytes - $prevBytes
                    $sessionBytes += $procDelta
                    if ($ElapsedSeconds -gt 0) { $speedBps = $procDelta / $ElapsedSeconds }
                }
            }

            $currentPids[$pidNum] = @{
                PID          = $pidNum
                Name         = $pName
                Path         = $pPath
                LastBytes    = $rawBytes
                SessionBytes = $sessionBytes
                SpeedBps     = $speedBps
                Connections  = $connCount
                LastSeen     = $nowStr
            }

            # Update App History
            if ($pName) {
                $curHistTotal = 0.0
                if ($script:AppHistory.PSObject.Properties[$pName]) {
                    $curHistTotal = [double]$script:AppHistory.$pName.TotalBytes
                }
                
                $deltaToAdd = 0.0
                if ($rawBytes -gt $prevBytes -and $prevBytes -gt 0) {
                    $deltaToAdd = $rawBytes - $prevBytes
                }

                $record = [PSCustomObject]@{
                    DisplayName = $p.ProcessName
                    Path        = if ($pPath) { $pPath } else { if ($script:AppHistory.PSObject.Properties[$pName]) { $script:AppHistory.$pName.Path } else { "" } }
                    TotalBytes  = ($curHistTotal + $deltaToAdd)
                    LastSeen    = $nowStr
                }
                $script:AppHistory | Add-Member -MemberType NoteProperty -Name $pName -Value $record -Force
                if ($deltaToAdd -gt 0) { $historyUpdated = $true }
            }
        }

        $script:ProcStateCache = $currentPids
        if ($historyUpdated) {
            Save-AppHistory $script:AppHistory
        }
    } catch {}
}

# ==============================================================================
# Step 2: Modern Responsive Windows 11 Slate Dark Theme Styling
# ==============================================================================

# Palette Definition
$ColorBgDark     = [System.Drawing.ColorTranslator]::FromHtml("#0B0F19") # Deep slate/black
$ColorPanelBg    = [System.Drawing.ColorTranslator]::FromHtml("#111827") # Slate 900
$ColorCardInner  = [System.Drawing.ColorTranslator]::FromHtml("#1F2937") # Slate 800
$ColorCardBorder = [System.Drawing.ColorTranslator]::FromHtml("#374151") # Slate 700
$ColorAccent     = [System.Drawing.ColorTranslator]::FromHtml("#38BDF8") # Sky 400
$ColorAccentDark = [System.Drawing.ColorTranslator]::FromHtml("#0284C7") # Sky 600
$ColorTextLight  = [System.Drawing.ColorTranslator]::FromHtml("#F9FAFB") # Slate 50
$ColorTextMuted  = [System.Drawing.ColorTranslator]::FromHtml("#9CA3AF") # Slate 400
$ColorSuccess    = [System.Drawing.ColorTranslator]::FromHtml("#34D399") # Emerald 400
$ColorWarning    = [System.Drawing.ColorTranslator]::FromHtml("#FBBF24") # Amber 400
$ColorDanger     = [System.Drawing.ColorTranslator]::FromHtml("#F87171") # Rose 400
$ColorInputBg    = [System.Drawing.ColorTranslator]::FromHtml("#0B0F19") # Deep dark input

$FontHeader = New-Object System.Drawing.Font("Segoe UI", 13.5, [System.Drawing.FontStyle]::Bold)
$FontSub    = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
$FontMetric = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$FontBody   = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
$FontSmall  = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)

# Main Form (Responsive 780x720)
$Form = New-Object System.Windows.Forms.Form
$Form.Text = "DataControl - Windows 11 Data Control System"
$Form.ClientSize = New-Object System.Drawing.Size(780, 720)
$Form.MinimumSize = New-Object System.Drawing.Size(780, 720)
$Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$Form.BackColor = $ColorBgDark
$Form.ForeColor = $ColorTextLight
$Form.Font = $FontBody

# Load Custom Icon
$AppCustomIcon = $null
if (Test-Path $IconPath) {
    try {
        $AppCustomIcon = New-Object System.Drawing.Icon($IconPath)
        $Form.Icon = $AppCustomIcon
    } catch {}
}

# System Tray Notification Icon
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

# Minimize to Tray Handler
$Form.Add_Resize({
    if ($Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $Form.Hide()
        $Form.ShowInTaskbar = $false
    }
})

# Top Header Banner
$HeaderPanel = New-Object System.Windows.Forms.Panel
$HeaderPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$HeaderPanel.Height = 60
$HeaderPanel.BackColor = $ColorPanelBg

$AppTitleLabel = New-Object System.Windows.Forms.Label
$AppTitleLabel.Text = "DATACONTROL"
$AppTitleLabel.Font = $FontHeader
$AppTitleLabel.ForeColor = $ColorAccent
$AppTitleLabel.Location = New-Object System.Drawing.Point(18, 14)
$AppTitleLabel.AutoSize = $true

$AppSubtitleLabel = New-Object System.Windows.Forms.Label
$AppSubtitleLabel.Text = "Dual Quota Sentry & Per-App Bandwidth Blocker"
$AppSubtitleLabel.Font = $FontSmall
$AppSubtitleLabel.ForeColor = $ColorTextMuted
$AppSubtitleLabel.Location = New-Object System.Drawing.Point(176, 21)
$AppSubtitleLabel.AutoSize = $true

$HeaderStatusBadge = New-Object System.Windows.Forms.Label
$HeaderStatusBadge.Text = "● ACTIVE"
$HeaderStatusBadge.Font = $FontSub
$HeaderStatusBadge.ForeColor = $ColorSuccess
$HeaderStatusBadge.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$HeaderStatusBadge.Location = New-Object System.Drawing.Point(660, 18)
$HeaderStatusBadge.AutoSize = $true

$HeaderPanel.Controls.AddRange(@($AppTitleLabel, $AppSubtitleLabel, $HeaderStatusBadge))
$Form.Controls.Add($HeaderPanel)

# Tab Control
$TabControl = New-Object System.Windows.Forms.TabControl
$TabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
$TabControl.Font = $FontBody

# Setup 5 Dedicated Tabs
$Tab1 = New-Object System.Windows.Forms.TabPage
$Tab1.Text = " Dashboard & Quotas "
$Tab1.BackColor = $ColorBgDark

$Tab2 = New-Object System.Windows.Forms.TabPage
$Tab2.Text = " Live App Sentry "
$Tab2.BackColor = $ColorBgDark

$Tab3 = New-Object System.Windows.Forms.TabPage
$Tab3.Text = " App Usage History "
$Tab3.BackColor = $ColorBgDark

$Tab4 = New-Object System.Windows.Forms.TabPage
$Tab4.Text = " Global Analytics "
$Tab4.BackColor = $ColorBgDark

$Tab5 = New-Object System.Windows.Forms.TabPage
$Tab5.Text = " Firewall Blocker "
$Tab5.BackColor = $ColorBgDark

$TabControl.TabPages.AddRange(@($Tab1, $Tab2, $Tab3, $Tab4, $Tab5))
$Form.Controls.Add($TabControl)
# Ensure Header stays on top
$HeaderPanel.BringToFront()

# ==============================================================================
# TAB 1: Dashboard & Live Controls (Daily & Monthly Dual Control)
# ==============================================================================

# Card 1: Live Status & Interface Selection
$CardStatus = New-Object System.Windows.Forms.Panel
$CardStatus.Location = New-Object System.Drawing.Point(14, 12)
$CardStatus.Size = New-Object System.Drawing.Size(738, 80)
$CardStatus.BackColor = $ColorPanelBg
$CardStatus.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblAdapter = New-Object System.Windows.Forms.Label
$LblAdapter.Text = "Target Adapter:"
$LblAdapter.Font = $FontSub
$LblAdapter.ForeColor = $ColorTextLight
$LblAdapter.Location = New-Object System.Drawing.Point(14, 10)
$LblAdapter.AutoSize = $true

$ComboAdapters = New-Object System.Windows.Forms.ComboBox
$ComboAdapters.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$ComboAdapters.Location = New-Object System.Drawing.Point(16, 36)
$ComboAdapters.Size = New-Object System.Drawing.Size(220, 26)
$ComboAdapters.BackColor = $ColorInputBg
$ComboAdapters.ForeColor = $ColorTextLight
$ComboAdapters.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

$LblStateTitle = New-Object System.Windows.Forms.Label
$LblStateTitle.Text = "Link State:"
$LblStateTitle.Font = $FontSub
$LblStateTitle.ForeColor = $ColorTextLight
$LblStateTitle.Location = New-Object System.Drawing.Point(280, 10)
$LblStateTitle.AutoSize = $true

$LblStateValue = New-Object System.Windows.Forms.Label
$LblStateValue.Text = "Detecting..."
$LblStateValue.Font = $FontSub
$LblStateValue.ForeColor = $ColorSuccess
$LblStateValue.Location = New-Object System.Drawing.Point(280, 37)
$LblStateValue.AutoSize = $true

$LblLiveSpeedTitle = New-Object System.Windows.Forms.Label
$LblLiveSpeedTitle.Text = "Total Speed:"
$LblLiveSpeedTitle.Font = $FontSub
$LblLiveSpeedTitle.ForeColor = $ColorTextLight
$LblLiveSpeedTitle.Location = New-Object System.Drawing.Point(480, 10)
$LblLiveSpeedTitle.AutoSize = $true

$LblLiveSpeedValue = New-Object System.Windows.Forms.Label
$LblLiveSpeedValue.Text = "0.00 KB/s"
$LblLiveSpeedValue.Font = $FontMetric
$LblLiveSpeedValue.ForeColor = $ColorAccent
$LblLiveSpeedValue.Location = New-Object System.Drawing.Point(478, 33)
$LblLiveSpeedValue.AutoSize = $true

$CardStatus.Controls.AddRange(@(
    $LblAdapter, $ComboAdapters, $LblStateTitle, $LblStateValue, $LblLiveSpeedTitle, $LblLiveSpeedValue
))
$Tab1.Controls.Add($CardStatus)

# Card 2: Daily Quota Progress Card
$CardDailyQuota = New-Object System.Windows.Forms.Panel
$CardDailyQuota.Location = New-Object System.Drawing.Point(14, 102)
$CardDailyQuota.Size = New-Object System.Drawing.Size(362, 114)
$CardDailyQuota.BackColor = $ColorPanelBg
$CardDailyQuota.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblDailyHeader = New-Object System.Windows.Forms.Label
$LblDailyHeader.Text = "Daily Quota Consumption"
$LblDailyHeader.Font = $FontSub
$LblDailyHeader.ForeColor = $ColorTextLight
$LblDailyHeader.Location = New-Object System.Drawing.Point(12, 10)
$LblDailyHeader.AutoSize = $true

$LblDailyPercent = New-Object System.Windows.Forms.Label
$LblDailyPercent.Text = "0.0%"
$LblDailyPercent.Font = $FontMetric
$LblDailyPercent.ForeColor = $ColorAccent
$LblDailyPercent.Location = New-Object System.Drawing.Point(280, 8)
$LblDailyPercent.AutoSize = $true

$ProgressDaily = New-Object System.Windows.Forms.ProgressBar
$ProgressDaily.Location = New-Object System.Drawing.Point(14, 44)
$ProgressDaily.Size = New-Object System.Drawing.Size(332, 22)
$ProgressDaily.Minimum = 0
$ProgressDaily.Maximum = 1000
$ProgressDaily.Value = 0

$LblDailyDetail = New-Object System.Windows.Forms.Label
$LblDailyDetail.Text = "Used: 0.00 MB / 2.00 GB"
$LblDailyDetail.Font = $FontBody
$LblDailyDetail.ForeColor = $ColorTextMuted
$LblDailyDetail.Location = New-Object System.Drawing.Point(14, 76)
$LblDailyDetail.AutoSize = $true

$CardDailyQuota.Controls.AddRange(@($LblDailyHeader, $LblDailyPercent, $ProgressDaily, $LblDailyDetail))
$Tab1.Controls.Add($CardDailyQuota)

# Card 3: Monthly Quota Progress Card
$CardMonthlyQuota = New-Object System.Windows.Forms.Panel
$CardMonthlyQuota.Location = New-Object System.Drawing.Point(390, 102)
$CardMonthlyQuota.Size = New-Object System.Drawing.Size(362, 114)
$CardMonthlyQuota.BackColor = $ColorPanelBg
$CardMonthlyQuota.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblMonthlyHeader = New-Object System.Windows.Forms.Label
$LblMonthlyHeader.Text = "Monthly Quota Consumption"
$LblMonthlyHeader.Font = $FontSub
$LblMonthlyHeader.ForeColor = $ColorTextLight
$LblMonthlyHeader.Location = New-Object System.Drawing.Point(12, 10)
$LblMonthlyHeader.AutoSize = $true

$LblMonthlyPercent = New-Object System.Windows.Forms.Label
$LblMonthlyPercent.Text = "0.0%"
$LblMonthlyPercent.Font = $FontMetric
$LblMonthlyPercent.ForeColor = $ColorSuccess
$LblMonthlyPercent.Location = New-Object System.Drawing.Point(280, 8)
$LblMonthlyPercent.AutoSize = $true

$ProgressMonthly = New-Object System.Windows.Forms.ProgressBar
$ProgressMonthly.Location = New-Object System.Drawing.Point(14, 44)
$ProgressMonthly.Size = New-Object System.Drawing.Size(332, 22)
$ProgressMonthly.Minimum = 0
$ProgressMonthly.Maximum = 1000
$ProgressMonthly.Value = 0

$LblMonthlyDetail = New-Object System.Windows.Forms.Label
$LblMonthlyDetail.Text = "Used: 0.00 GB / 16.00 GB"
$LblMonthlyDetail.Font = $FontBody
$LblMonthlyDetail.ForeColor = $ColorTextMuted
$LblMonthlyDetail.Location = New-Object System.Drawing.Point(14, 76)
$LblMonthlyDetail.AutoSize = $true

$CardMonthlyQuota.Controls.AddRange(@($LblMonthlyHeader, $LblMonthlyPercent, $ProgressMonthly, $LblMonthlyDetail))
$Tab1.Controls.Add($CardMonthlyQuota)

# Card 4: Dual Threshold Configuration & Enforcement Settings
$CardSettings = New-Object System.Windows.Forms.Panel
$CardSettings.Location = New-Object System.Drawing.Point(14, 228)
$CardSettings.Size = New-Object System.Drawing.Size(738, 260)
$CardSettings.BackColor = $ColorPanelBg
$CardSettings.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblSettingsHeader = New-Object System.Windows.Forms.Label
$LblSettingsHeader.Text = "Dual Quota Control & Enforcement Rules"
$LblSettingsHeader.Font = $FontSub
$LblSettingsHeader.ForeColor = $ColorTextLight
$LblSettingsHeader.Location = New-Object System.Drawing.Point(14, 12)
$LblSettingsHeader.AutoSize = $true

# Daily Limit Inputs
$LblDailyLimitInput = New-Object System.Windows.Forms.Label
$LblDailyLimitInput.Text = "Daily Limit (GB):"
$LblDailyLimitInput.Font = $FontBody
$LblDailyLimitInput.ForeColor = $ColorTextMuted
$LblDailyLimitInput.Location = New-Object System.Drawing.Point(16, 42)
$LblDailyLimitInput.AutoSize = $true

$NumDailyLimit = New-Object System.Windows.Forms.NumericUpDown
$NumDailyLimit.Location = New-Object System.Drawing.Point(18, 64)
$NumDailyLimit.Size = New-Object System.Drawing.Size(140, 24)
$NumDailyLimit.DecimalPlaces = 1
$NumDailyLimit.Minimum = 0.1
$NumDailyLimit.Maximum = 500.0
$NumDailyLimit.Increment = 0.5
$NumDailyLimit.Value = [decimal]$script:AppConfig.daily_limit_gb
$NumDailyLimit.BackColor = $ColorInputBg
$NumDailyLimit.ForeColor = $ColorTextLight

$LblDailyWarnInput = New-Object System.Windows.Forms.Label
$LblDailyWarnInput.Text = "Daily Warning (GB):"
$LblDailyWarnInput.Font = $FontBody
$LblDailyWarnInput.ForeColor = $ColorTextMuted
$LblDailyWarnInput.Location = New-Object System.Drawing.Point(180, 42)
$LblDailyWarnInput.AutoSize = $true

$NumDailyWarn = New-Object System.Windows.Forms.NumericUpDown
$NumDailyWarn.Location = New-Object System.Drawing.Point(182, 64)
$NumDailyWarn.Size = New-Object System.Drawing.Size(140, 24)
$NumDailyWarn.DecimalPlaces = 1
$NumDailyWarn.Minimum = 0.1
$NumDailyWarn.Maximum = 500.0
$NumDailyWarn.Increment = 0.5
$NumDailyWarn.Value = [decimal]$script:AppConfig.daily_warning_gb
$NumDailyWarn.BackColor = $ColorInputBg
$NumDailyWarn.ForeColor = $ColorTextLight

# Monthly Limit Inputs
$LblMonthlyLimitInput = New-Object System.Windows.Forms.Label
$LblMonthlyLimitInput.Text = "Monthly Limit (GB):"
$LblMonthlyLimitInput.Font = $FontBody
$LblMonthlyLimitInput.ForeColor = $ColorTextMuted
$LblMonthlyLimitInput.Location = New-Object System.Drawing.Point(380, 42)
$LblMonthlyLimitInput.AutoSize = $true

$NumMonthlyLimit = New-Object System.Windows.Forms.NumericUpDown
$NumMonthlyLimit.Location = New-Object System.Drawing.Point(382, 64)
$NumMonthlyLimit.Size = New-Object System.Drawing.Size(140, 24)
$NumMonthlyLimit.DecimalPlaces = 1
$NumMonthlyLimit.Minimum = 0.5
$NumMonthlyLimit.Maximum = 2000.0
$NumMonthlyLimit.Increment = 0.5
$NumMonthlyLimit.Value = [decimal]$script:AppConfig.monthly_limit_gb
$NumMonthlyLimit.BackColor = $ColorInputBg
$NumMonthlyLimit.ForeColor = $ColorTextLight

$LblMonthlyWarnInput = New-Object System.Windows.Forms.Label
$LblMonthlyWarnInput.Text = "Monthly Warning (GB):"
$LblMonthlyWarnInput.Font = $FontBody
$LblMonthlyWarnInput.ForeColor = $ColorTextMuted
$LblMonthlyWarnInput.Location = New-Object System.Drawing.Point(544, 42)
$LblMonthlyWarnInput.AutoSize = $true

$NumMonthlyWarn = New-Object System.Windows.Forms.NumericUpDown
$NumMonthlyWarn.Location = New-Object System.Drawing.Point(546, 64)
$NumMonthlyWarn.Size = New-Object System.Drawing.Size(140, 24)
$NumMonthlyWarn.DecimalPlaces = 1
$NumMonthlyWarn.Minimum = 0.5
$NumMonthlyWarn.Maximum = 2000.0
$NumMonthlyWarn.Increment = 0.5
$NumMonthlyWarn.Value = [decimal]$script:AppConfig.warning_threshold_gb
$NumMonthlyWarn.BackColor = $ColorInputBg
$NumMonthlyWarn.ForeColor = $ColorTextLight

# Checkboxes
$ChkAutoDisconnectDaily = New-Object System.Windows.Forms.CheckBox
$ChkAutoDisconnectDaily.Text = "Automated Cutoff: Disable Wi-Fi immediately when DAILY quota is reached"
$ChkAutoDisconnectDaily.Font = $FontBody
$ChkAutoDisconnectDaily.ForeColor = $ColorTextLight
$ChkAutoDisconnectDaily.Location = New-Object System.Drawing.Point(18, 102)
$ChkAutoDisconnectDaily.Size = New-Object System.Drawing.Size(680, 24)
$ChkAutoDisconnectDaily.Checked = [bool]$script:AppConfig.auto_disconnect_daily

$ChkAutoDisconnectMonthly = New-Object System.Windows.Forms.CheckBox
$ChkAutoDisconnectMonthly.Text = "Automated Cutoff: Disable Wi-Fi immediately when MONTHLY quota is reached"
$ChkAutoDisconnectMonthly.Font = $FontBody
$ChkAutoDisconnectMonthly.ForeColor = $ColorTextLight
$ChkAutoDisconnectMonthly.Location = New-Object System.Drawing.Point(18, 130)
$ChkAutoDisconnectMonthly.Size = New-Object System.Drawing.Size(680, 24)
$ChkAutoDisconnectMonthly.Checked = [bool]$script:AppConfig.auto_disconnect

$ChkStartWithWindows = New-Object System.Windows.Forms.CheckBox
$ChkStartWithWindows.Text = "Run at Windows Startup (Runs silently in background with highest Administrator privileges)"
$ChkStartWithWindows.Font = $FontBody
$ChkStartWithWindows.ForeColor = $ColorTextLight
$ChkStartWithWindows.Location = New-Object System.Drawing.Point(18, 158)
$ChkStartWithWindows.Size = New-Object System.Drawing.Size(680, 24)
$ChkStartWithWindows.Checked = Test-StartupTaskEnabled

$BtnSaveSettings = New-Object System.Windows.Forms.Button
$BtnSaveSettings.Text = "Save All Quota Settings"
$BtnSaveSettings.Location = New-Object System.Drawing.Point(18, 196)
$BtnSaveSettings.Size = New-Object System.Drawing.Size(180, 32)
$BtnSaveSettings.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnSaveSettings.FlatAppearance.BorderSize = 0
$BtnSaveSettings.BackColor = $ColorAccentDark
$BtnSaveSettings.ForeColor = $ColorTextLight
$BtnSaveSettings.Font = $FontSub
$BtnSaveSettings.Cursor = [System.Windows.Forms.Cursors]::Hand

$LblSaveStatus = New-Object System.Windows.Forms.Label
$LblSaveStatus.Text = ""
$LblSaveStatus.Font = $FontBody
$LblSaveStatus.ForeColor = $ColorSuccess
$LblSaveStatus.Location = New-Object System.Drawing.Point(215, 203)
$LblSaveStatus.AutoSize = $true

$CardSettings.Controls.AddRange(@(
    $LblSettingsHeader,
    $LblDailyLimitInput, $NumDailyLimit, $LblDailyWarnInput, $NumDailyWarn,
    $LblMonthlyLimitInput, $NumMonthlyLimit, $LblMonthlyWarnInput, $NumMonthlyWarn,
    $ChkAutoDisconnectDaily, $ChkAutoDisconnectMonthly, $ChkStartWithWindows,
    $BtnSaveSettings, $LblSaveStatus
))
$Tab1.Controls.Add($CardSettings)

# Card 5: Manual Hardware Controls
$CardManual = New-Object System.Windows.Forms.Panel
$CardManual.Location = New-Object System.Drawing.Point(14, 500)
$CardManual.Size = New-Object System.Drawing.Size(738, 86)
$CardManual.BackColor = $ColorPanelBg
$CardManual.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblManualHeader = New-Object System.Windows.Forms.Label
$LblManualHeader.Text = "Manual Hardware Controls"
$LblManualHeader.Font = $FontSub
$LblManualHeader.ForeColor = $ColorTextLight
$LblManualHeader.Location = New-Object System.Drawing.Point(14, 10)
$LblManualHeader.AutoSize = $true

$BtnDisableWifi = New-Object System.Windows.Forms.Button
$BtnDisableWifi.Text = "Disable Wi-Fi"
$BtnDisableWifi.Location = New-Object System.Drawing.Point(18, 36)
$BtnDisableWifi.Size = New-Object System.Drawing.Size(140, 34)
$BtnDisableWifi.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnDisableWifi.FlatAppearance.BorderSize = 0
$BtnDisableWifi.BackColor = $ColorDanger
$BtnDisableWifi.ForeColor = $ColorTextLight
$BtnDisableWifi.Font = $FontSub
$BtnDisableWifi.Cursor = [System.Windows.Forms.Cursors]::Hand

$BtnEnableWifi = New-Object System.Windows.Forms.Button
$BtnEnableWifi.Text = "Enable Wi-Fi"
$BtnEnableWifi.Location = New-Object System.Drawing.Point(168, 36)
$BtnEnableWifi.Size = New-Object System.Drawing.Size(140, 34)
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
$LblManualStatus.Location = New-Object System.Drawing.Point(324, 46)
$LblManualStatus.AutoSize = $true

$CardManual.Controls.AddRange(@(
    $LblManualHeader, $BtnDisableWifi, $BtnEnableWifi, $LblManualStatus
))
$Tab1.Controls.Add($CardManual)


# ==============================================================================
# TAB 2: Live App Sentry (Per-Process Real-Time Bandwidth Monitor)
# ==============================================================================
$PanelLiveApps = New-Object System.Windows.Forms.Panel
$PanelLiveApps.Location = New-Object System.Drawing.Point(14, 12)
$PanelLiveApps.Size = New-Object System.Drawing.Size(738, 574)
$PanelLiveApps.BackColor = $ColorPanelBg
$PanelLiveApps.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblLiveAppsTitle = New-Object System.Windows.Forms.Label
$LblLiveAppsTitle.Text = "Active Network Applications (Real-Time Throughput)"
$LblLiveAppsTitle.Font = $FontSub
$LblLiveAppsTitle.ForeColor = $ColorTextLight
$LblLiveAppsTitle.Location = New-Object System.Drawing.Point(14, 10)
$LblLiveAppsTitle.AutoSize = $true

$TxtAppSearch = New-Object System.Windows.Forms.TextBox
$TxtAppSearch.Location = New-Object System.Drawing.Point(16, 38)
$TxtAppSearch.Size = New-Object System.Drawing.Size(260, 24)
$TxtAppSearch.BackColor = $ColorInputBg
$TxtAppSearch.ForeColor = $ColorTextLight

$LblSearchPlaceholder = New-Object System.Windows.Forms.Label
$LblSearchPlaceholder.Text = "Filter by process name..."
$LblSearchPlaceholder.Font = $FontSmall
$LblSearchPlaceholder.ForeColor = $ColorTextMuted
$LblSearchPlaceholder.Location = New-Object System.Drawing.Point(284, 42)
$LblSearchPlaceholder.AutoSize = $true

$ListLiveApps = New-Object System.Windows.Forms.ListView
$ListLiveApps.Location = New-Object System.Drawing.Point(14, 70)
$ListLiveApps.Size = New-Object System.Drawing.Size(708, 436)
$ListLiveApps.View = [System.Windows.Forms.View]::Details
$ListLiveApps.FullRowSelect = $true
$ListLiveApps.GridLines = $true
$ListLiveApps.MultiSelect = $false
$ListLiveApps.BackColor = $ColorInputBg
$ListLiveApps.ForeColor = $ColorTextLight
$ListLiveApps.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

[void]$ListLiveApps.Columns.Add("Application Name", 160)
[void]$ListLiveApps.Columns.Add("PID", 65)
[void]$ListLiveApps.Columns.Add("Live Speed", 110)
[void]$ListLiveApps.Columns.Add("Session Total", 110)
[void]$ListLiveApps.Columns.Add("Sockets", 65)
[void]$ListLiveApps.Columns.Add("Executable Path", 270)

$BtnBlockLiveApp = New-Object System.Windows.Forms.Button
$BtnBlockLiveApp.Text = "🚫 Block Selected App in Firewall"
$BtnBlockLiveApp.Location = New-Object System.Drawing.Point(14, 520)
$BtnBlockLiveApp.Size = New-Object System.Drawing.Size(240, 34)
$BtnBlockLiveApp.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnBlockLiveApp.FlatAppearance.BorderSize = 0
$BtnBlockLiveApp.BackColor = $ColorDanger
$BtnBlockLiveApp.ForeColor = $ColorTextLight
$BtnBlockLiveApp.Font = $FontSub
$BtnBlockLiveApp.Cursor = [System.Windows.Forms.Cursors]::Hand

$BtnRefreshLiveApps = New-Object System.Windows.Forms.Button
$BtnRefreshLiveApps.Text = "Refresh Processes"
$BtnRefreshLiveApps.Location = New-Object System.Drawing.Point(264, 520)
$BtnRefreshLiveApps.Size = New-Object System.Drawing.Size(150, 34)
$BtnRefreshLiveApps.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnRefreshLiveApps.FlatAppearance.BorderSize = 0
$BtnRefreshLiveApps.BackColor = $ColorAccentDark
$BtnRefreshLiveApps.ForeColor = $ColorTextLight
$BtnRefreshLiveApps.Cursor = [System.Windows.Forms.Cursors]::Hand

$LblLiveAppBlockStatus = New-Object System.Windows.Forms.Label
$LblLiveAppBlockStatus.Text = ""
$LblLiveAppBlockStatus.Font = $FontSmall
$LblLiveAppBlockStatus.ForeColor = $ColorSuccess
$LblLiveAppBlockStatus.Location = New-Object System.Drawing.Point(430, 530)
$LblLiveAppBlockStatus.AutoSize = $true

$PanelLiveApps.Controls.AddRange(@(
    $LblLiveAppsTitle, $TxtAppSearch, $LblSearchPlaceholder, $ListLiveApps,
    $BtnBlockLiveApp, $BtnRefreshLiveApps, $LblLiveAppBlockStatus
))
$Tab2.Controls.Add($PanelLiveApps)


# ==============================================================================
# TAB 3: App Usage History (Cumulative Data Consumed Per Application)
# ==============================================================================
$PanelAppHistory = New-Object System.Windows.Forms.Panel
$PanelAppHistory.Location = New-Object System.Drawing.Point(14, 12)
$PanelAppHistory.Size = New-Object System.Drawing.Size(738, 574)
$PanelAppHistory.BackColor = $ColorPanelBg
$PanelAppHistory.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblAppHistTitle = New-Object System.Windows.Forms.Label
$LblAppHistTitle.Text = "Application Data Consumption Leaderboard (Top Bandwidth Consumers)"
$LblAppHistTitle.Font = $FontSub
$LblAppHistTitle.ForeColor = $ColorTextLight
$LblAppHistTitle.Location = New-Object System.Drawing.Point(14, 10)
$LblAppHistTitle.AutoSize = $true

$LblAppHistSub = New-Object System.Windows.Forms.Label
$LblAppHistSub.Text = "Persistent accounting of data consumed by each application. Select any bandwidth hog to isolate it."
$LblAppHistSub.Font = $FontSmall
$LblAppHistSub.ForeColor = $ColorTextMuted
$LblAppHistSub.Location = New-Object System.Drawing.Point(14, 34)
$LblAppHistSub.AutoSize = $true

$ListAppHistory = New-Object System.Windows.Forms.ListView
$ListAppHistory.Location = New-Object System.Drawing.Point(14, 62)
$ListAppHistory.Size = New-Object System.Drawing.Size(708, 444)
$ListAppHistory.View = [System.Windows.Forms.View]::Details
$ListAppHistory.FullRowSelect = $true
$ListAppHistory.GridLines = $true
$ListAppHistory.MultiSelect = $false
$ListAppHistory.BackColor = $ColorInputBg
$ListAppHistory.ForeColor = $ColorTextLight
$ListAppHistory.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

[void]$ListAppHistory.Columns.Add("Application Name", 180)
[void]$ListAppHistory.Columns.Add("Data Consumed", 140)
[void]$ListAppHistory.Columns.Add("Last Seen", 140)
[void]$ListAppHistory.Columns.Add("Executable Path", 320)

$BtnBlockHistApp = New-Object System.Windows.Forms.Button
$BtnBlockHistApp.Text = "🚫 Block Application in Firewall"
$BtnBlockHistApp.Location = New-Object System.Drawing.Point(14, 520)
$BtnBlockHistApp.Size = New-Object System.Drawing.Size(220, 34)
$BtnBlockHistApp.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnBlockHistApp.FlatAppearance.BorderSize = 0
$BtnBlockHistApp.BackColor = $ColorDanger
$BtnBlockHistApp.ForeColor = $ColorTextLight
$BtnBlockHistApp.Font = $FontSub
$BtnBlockHistApp.Cursor = [System.Windows.Forms.Cursors]::Hand

$BtnClearAppHist = New-Object System.Windows.Forms.Button
$BtnClearAppHist.Text = "Reset App History"
$BtnClearAppHist.Location = New-Object System.Drawing.Point(244, 520)
$BtnClearAppHist.Size = New-Object System.Drawing.Size(150, 34)
$BtnClearAppHist.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnClearAppHist.FlatAppearance.BorderSize = 0
$BtnClearAppHist.BackColor = $ColorWarning
$BtnClearAppHist.ForeColor = [System.Drawing.Color]::Black
$BtnClearAppHist.Font = $FontSub
$BtnClearAppHist.Cursor = [System.Windows.Forms.Cursors]::Hand

$LblAppHistActionStatus = New-Object System.Windows.Forms.Label
$LblAppHistActionStatus.Text = ""
$LblAppHistActionStatus.Font = $FontSmall
$LblAppHistActionStatus.ForeColor = $ColorSuccess
$LblAppHistActionStatus.Location = New-Object System.Drawing.Point(410, 530)
$LblAppHistActionStatus.AutoSize = $true

$PanelAppHistory.Controls.AddRange(@(
    $LblAppHistTitle, $LblAppHistSub, $ListAppHistory,
    $BtnBlockHistApp, $BtnClearAppHist, $LblAppHistActionStatus
))
$Tab3.Controls.Add($PanelAppHistory)


# ==============================================================================
# TAB 4: Global Analytics & Billing Cycle
# ==============================================================================
$CardToday = New-Object System.Windows.Forms.Panel
$CardToday.Location = New-Object System.Drawing.Point(14, 14)
$CardToday.Size = New-Object System.Drawing.Size(236, 92)
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
$Tab4.Controls.Add($CardToday)

$CardMonth = New-Object System.Windows.Forms.Panel
$CardMonth.Location = New-Object System.Drawing.Point(264, 14)
$CardMonth.Size = New-Object System.Drawing.Size(236, 92)
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
$Tab4.Controls.Add($CardMonth)

$CardYear = New-Object System.Windows.Forms.Panel
$CardYear.Location = New-Object System.Drawing.Point(514, 14)
$CardYear.Size = New-Object System.Drawing.Size(236, 92)
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
$Tab4.Controls.Add($CardYear)

# History Data List
$PanelHistoryTable = New-Object System.Windows.Forms.Panel
$PanelHistoryTable.Location = New-Object System.Drawing.Point(14, 120)
$PanelHistoryTable.Size = New-Object System.Drawing.Size(738, 350)
$PanelHistoryTable.BackColor = $ColorPanelBg
$PanelHistoryTable.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblHistoryTableTitle = New-Object System.Windows.Forms.Label
$LblHistoryTableTitle.Text = "Daily Usage Log (Historical Dates)"
$LblHistoryTableTitle.Font = $FontSub
$LblHistoryTableTitle.ForeColor = $ColorTextLight
$LblHistoryTableTitle.Location = New-Object System.Drawing.Point(12, 10)
$LblHistoryTableTitle.AutoSize = $true

$ListHistory = New-Object System.Windows.Forms.ListView
$ListHistory.Location = New-Object System.Drawing.Point(12, 36)
$ListHistory.Size = New-Object System.Drawing.Size(712, 300)
$ListHistory.View = [System.Windows.Forms.View]::Details
$ListHistory.FullRowSelect = $true
$ListHistory.GridLines = $true
$ListHistory.BackColor = $ColorInputBg
$ListHistory.ForeColor = $ColorTextLight
$ListHistory.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

[void]$ListHistory.Columns.Add("Date", 160)
[void]$ListHistory.Columns.Add("Data Consumed", 200)
[void]$ListHistory.Columns.Add("Raw Bytes", 240)

$PanelHistoryTable.Controls.AddRange(@($LblHistoryTableTitle, $ListHistory))
$Tab4.Controls.Add($PanelHistoryTable)

# Billing Cycle Reset Card
$CardReset = New-Object System.Windows.Forms.Panel
$CardReset.Location = New-Object System.Drawing.Point(14, 484)
$CardReset.Size = New-Object System.Drawing.Size(738, 94)
$CardReset.BackColor = $ColorPanelBg
$CardReset.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblResetTitle = New-Object System.Windows.Forms.Label
$LblResetTitle.Text = "Billing Cycle Synchronization"
$LblResetTitle.Font = $FontSub
$LblResetTitle.ForeColor = $ColorTextLight
$LblResetTitle.Location = New-Object System.Drawing.Point(12, 10)
$LblResetTitle.AutoSize = $true

$LblResetDesc = New-Object System.Windows.Forms.Label
$LblResetDesc.Text = "Reset monthly consumption to 0 GB when your ISP / Cellular billing cycle renews."
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
$Tab4.Controls.Add($CardReset)


# ==============================================================================
# TAB 5: Application Firewall Blocker
# ==============================================================================
$CardFirewallPicker = New-Object System.Windows.Forms.Panel
$CardFirewallPicker.Location = New-Object System.Drawing.Point(14, 12)
$CardFirewallPicker.Size = New-Object System.Drawing.Size(738, 126)
$CardFirewallPicker.BackColor = $ColorPanelBg
$CardFirewallPicker.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblFwTitle = New-Object System.Windows.Forms.Label
$LblFwTitle.Text = "Windows Defender Firewall Outbound Blocker"
$LblFwTitle.Font = $FontSub
$LblFwTitle.ForeColor = $ColorTextLight
$LblFwTitle.Location = New-Object System.Drawing.Point(14, 10)
$LblFwTitle.AutoSize = $true

$LblFwDesc = New-Object System.Windows.Forms.Label
$LblFwDesc.Text = "Select any .exe file to create an immediate outbound block rule in Windows Defender Firewall."
$LblFwDesc.Font = $FontSmall
$LblFwDesc.ForeColor = $ColorTextMuted
$LblFwDesc.Location = New-Object System.Drawing.Point(14, 34)
$LblFwDesc.AutoSize = $true

$TxtExePath = New-Object System.Windows.Forms.TextBox
$TxtExePath.Location = New-Object System.Drawing.Point(16, 58)
$TxtExePath.Size = New-Object System.Drawing.Size(580, 24)
$TxtExePath.BackColor = $ColorInputBg
$TxtExePath.ForeColor = $ColorTextLight
$TxtExePath.ReadOnly = $true

$BtnBrowseExe = New-Object System.Windows.Forms.Button
$BtnBrowseExe.Text = "Browse..."
$BtnBrowseExe.Location = New-Object System.Drawing.Point(606, 56)
$BtnBrowseExe.Size = New-Object System.Drawing.Size(116, 28)
$BtnBrowseExe.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnBrowseExe.FlatAppearance.BorderSize = 0
$BtnBrowseExe.BackColor = $ColorPanelBg
$BtnBrowseExe.ForeColor = $ColorAccent
$BtnBrowseExe.Cursor = [System.Windows.Forms.Cursors]::Hand

$BtnBlockApp = New-Object System.Windows.Forms.Button
$BtnBlockApp.Text = "Block Outbound Access"
$BtnBlockApp.Location = New-Object System.Drawing.Point(16, 90)
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
$LblFwActionStatus.Location = New-Object System.Drawing.Point(210, 96)
$LblFwActionStatus.AutoSize = $true

$CardFirewallPicker.Controls.AddRange(@(
    $LblFwTitle, $LblFwDesc, $TxtExePath, $BtnBrowseExe, $BtnBlockApp, $LblFwActionStatus
))
$Tab5.Controls.Add($CardFirewallPicker)

# Firewall Rules List Card
$CardFirewallList = New-Object System.Windows.Forms.Panel
$CardFirewallList.Location = New-Object System.Drawing.Point(14, 150)
$CardFirewallList.Size = New-Object System.Drawing.Size(738, 436)
$CardFirewallList.BackColor = $ColorPanelBg
$CardFirewallList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$LblRulesListTitle = New-Object System.Windows.Forms.Label
$LblRulesListTitle.Text = "Active DataControl Outbound Block Rules"
$LblRulesListTitle.Font = $FontSub
$LblRulesListTitle.ForeColor = $ColorTextLight
$LblRulesListTitle.Location = New-Object System.Drawing.Point(14, 10)
$LblRulesListTitle.AutoSize = $true

$ListFirewallRules = New-Object System.Windows.Forms.ListView
$ListFirewallRules.Location = New-Object System.Drawing.Point(14, 36)
$ListFirewallRules.Size = New-Object System.Drawing.Size(708, 340)
$ListFirewallRules.View = [System.Windows.Forms.View]::Details
$ListFirewallRules.FullRowSelect = $true
$ListFirewallRules.GridLines = $true
$ListFirewallRules.MultiSelect = $false
$ListFirewallRules.BackColor = $ColorInputBg
$ListFirewallRules.ForeColor = $ColorTextLight
$ListFirewallRules.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

[void]$ListFirewallRules.Columns.Add("Rule Display Name", 240)
[void]$ListFirewallRules.Columns.Add("Program Path", 360)
[void]$ListFirewallRules.Columns.Add("Action", 80)

$BtnUnblockApp = New-Object System.Windows.Forms.Button
$BtnUnblockApp.Text = "Unblock Application"
$BtnUnblockApp.Location = New-Object System.Drawing.Point(14, 388)
$BtnUnblockApp.Size = New-Object System.Drawing.Size(160, 32)
$BtnUnblockApp.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnUnblockApp.FlatAppearance.BorderSize = 0
$BtnUnblockApp.BackColor = $ColorSuccess
$BtnUnblockApp.ForeColor = $ColorTextLight
$BtnUnblockApp.Font = $FontSub
$BtnUnblockApp.Cursor = [System.Windows.Forms.Cursors]::Hand

$BtnRefreshRules = New-Object System.Windows.Forms.Button
$BtnRefreshRules.Text = "Refresh Rules"
$BtnRefreshRules.Location = New-Object System.Drawing.Point(184, 388)
$BtnRefreshRules.Size = New-Object System.Drawing.Size(130, 32)
$BtnRefreshRules.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnRefreshRules.FlatAppearance.BorderSize = 0
$BtnRefreshRules.BackColor = $ColorAccentDark
$BtnRefreshRules.ForeColor = $ColorTextLight
$BtnRefreshRules.Cursor = [System.Windows.Forms.Cursors]::Hand

$LblUnblockStatus = New-Object System.Windows.Forms.Label
$LblUnblockStatus.Text = ""
$LblUnblockStatus.Font = $FontSmall
$LblUnblockStatus.ForeColor = $ColorSuccess
$LblUnblockStatus.Location = New-Object System.Drawing.Point(330, 396)
$LblUnblockStatus.AutoSize = $true

$CardFirewallList.Controls.AddRange(@(
    $LblRulesListTitle, $ListFirewallRules, $BtnUnblockApp, $BtnRefreshRules, $LblUnblockStatus
))
$Tab5.Controls.Add($CardFirewallList)


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

    $dayGB = $dayBytes / 1GB
    $monthGB = $monthBytes / 1GB

    $dailyLimitGB = [double]$script:AppConfig.daily_limit_gb
    $dailyWarnGB  = [double]$script:AppConfig.daily_warning_gb
    $monthlyLimitGB = [double]$script:AppConfig.monthly_limit_gb
    $monthlyWarnGB  = [double]$script:AppConfig.warning_threshold_gb

    # Live Overall Speed Readout
    $rateBps = $script:CurrentThroughputBytesPerSec
    if ($rateBps -ge 1MB) {
        $rateMB = [math]::Round($rateBps / 1MB, 2)
        $LblLiveSpeedValue.Text = "$rateMB MB/s"
    } else {
        $rateKB = [math]::Round($rateBps / 1KB, 1)
        $LblLiveSpeedValue.Text = "$rateKB KB/s"
    }

    # 1. Daily Quota Progress & Percentage
    $dailyPercent = 0.0
    if ($dailyLimitGB -gt 0) {
        $dailyPercent = [math]::Round(($dayGB / $dailyLimitGB) * 100.0, 1)
    }
    $LblDailyPercent.Text = "$dailyPercent%"
    $progValDaily = [int]([math]::Min(100.0, [math]::Max(0.0, $dailyPercent)) * 10)
    $ProgressDaily.Value = $progValDaily

    $dailyRemain = [math]::Max(0.0, [math]::Round($dailyLimitGB - $dayGB, 2))
    $LblDailyDetail.Text = "Used: $(Format-Bytes $dayBytes) / $dailyLimitGB GB (Remaining: $dailyRemain GB)"

    if ($dayGB -ge $dailyLimitGB) {
        $LblDailyPercent.ForeColor = $ColorDanger
    } elseif ($dayGB -ge $dailyWarnGB) {
        $LblDailyPercent.ForeColor = $ColorWarning
    } else {
        $LblDailyPercent.ForeColor = $ColorAccent
    }

    # 2. Monthly Quota Progress & Percentage
    $monthlyPercent = 0.0
    if ($monthlyLimitGB -gt 0) {
        $monthlyPercent = [math]::Round(($monthGB / $monthlyLimitGB) * 100.0, 1)
    }
    $LblMonthlyPercent.Text = "$monthlyPercent%"
    $progValMonthly = [int]([math]::Min(100.0, [math]::Max(0.0, $monthlyPercent)) * 10)
    $ProgressMonthly.Value = $progValMonthly

    $monthlyRemain = [math]::Max(0.0, [math]::Round($monthlyLimitGB - $monthGB, 2))
    $LblMonthlyDetail.Text = "Used: $([math]::Round($monthGB, 2)) GB / $monthlyLimitGB GB (Remaining: $monthlyRemain GB)"

    if ($monthGB -ge $monthlyLimitGB) {
        $LblMonthlyPercent.ForeColor = $ColorDanger
    } elseif ($monthGB -ge $monthlyWarnGB) {
        $LblMonthlyPercent.ForeColor = $ColorWarning
    } else {
        $LblMonthlyPercent.ForeColor = $ColorSuccess
    }

    # Global Analytics Tab Cards
    $LblTodayValue.Text = Format-Bytes $dayBytes
    $LblMonthValue.Text = Format-Bytes $monthBytes
    $LblYearValue.Text = Format-Bytes $yearBytes

    # Tray Tooltip
    $trayStr = "DataControl - Day: $(Format-Bytes $dayBytes) | Month: $([math]::Round($monthGB, 2)) GB"
    if ($trayStr.Length -gt 63) { $trayStr = $trayStr.Substring(0, 63) }
    $NotifyIcon.Text = $trayStr
}

function Refresh-LiveAppsList {
    $filterText = $TxtAppSearch.Text.Trim().ToLower()
    $ListLiveApps.BeginUpdate()
    $ListLiveApps.Items.Clear()

    # Sort active processes by highest speed or session bytes
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

        $sessionStr = Format-Bytes $item.SessionBytes

        $lvItem = New-Object System.Windows.Forms.ListViewItem($item.Name)
        [void]$lvItem.SubItems.Add($item.PID.ToString())
        [void]$lvItem.SubItems.Add($speedStr)
        [void]$lvItem.SubItems.Add($sessionStr)
        [void]$lvItem.SubItems.Add($item.Connections.ToString())
        [void]$lvItem.SubItems.Add($item.Path)
        $lvItem.Tag = $item.Path

        $ListLiveApps.Items.Add($lvItem)
    }

    $ListLiveApps.EndUpdate()
}

function Refresh-AppHistoryList {
    $ListAppHistory.BeginUpdate()
    $ListAppHistory.Items.Clear()

    if ($script:AppHistory) {
        $props = $script:AppHistory.PSObject.Properties | Sort-Object -Property @{
            Expression = { [double]$_.Value.TotalBytes }
        } -Descending

        foreach ($prop in $props) {
            $val = $prop.Value
            $bytes = [double]$val.TotalBytes
            $path = [string]$val.Path
            $seen = [string]$val.LastSeen

            $lvItem = New-Object System.Windows.Forms.ListViewItem($prop.Name)
            [void]$lvItem.SubItems.Add((Format-Bytes $bytes))
            [void]$lvItem.SubItems.Add($seen)
            [void]$lvItem.SubItems.Add($path)
            $lvItem.Tag = $path

            $ListAppHistory.Items.Add($lvItem)
        }
    }
    $ListAppHistory.EndUpdate()
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
# Enforcement Engine (Daily & Monthly Dual Alert / Cutoff)
# ==============================================================================
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
                "Today's data consumption has reached $([math]::Round($dayGB, 2)) GB (Daily Warning: $dailyWarnGB GB / Limit: $dailyLimitGB GB).",
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
                    $LblManualStatus.Text = "Daily cutoff executed! Limit exceeded."
                    $LblManualStatus.ForeColor = $ColorDanger
                    Refresh-AdapterStatusLabel
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
                    $LblManualStatus.Text = "Monthly cutoff executed! Limit exceeded."
                    $LblManualStatus.ForeColor = $ColorDanger
                    Refresh-AdapterStatusLabel
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

    # Live Tab auto-update if active
    if ($TabControl.SelectedTab -eq $Tab2) {
        Refresh-LiveAppsList
    }
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

# Save All Quota Settings
$BtnSaveSettings.Add_Click({
    $script:AppConfig.daily_limit_gb = [double]$NumDailyLimit.Value
    $script:AppConfig.daily_warning_gb = [double]$NumDailyWarn.Value
    $script:AppConfig.monthly_limit_gb = [double]$NumMonthlyLimit.Value
    $script:AppConfig.warning_threshold_gb = [double]$NumMonthlyWarn.Value
    $script:AppConfig.auto_disconnect_daily = [bool]$ChkAutoDisconnectDaily.Checked
    $script:AppConfig.auto_disconnect = [bool]$ChkAutoDisconnectMonthly.Checked

    $selected = [string]$ComboAdapters.SelectedItem
    if ($selected) { $script:AppConfig.target_adapter = $selected }

    $isTaskWanted = [bool]$ChkStartWithWindows.Checked
    Set-StartupTaskEnabled $isTaskWanted | Out-Null
    $TrayMenuItemStartup.Checked = $isTaskWanted

    Save-AppConfig $script:AppConfig
    Refresh-UsageDisplay

    $LblSaveStatus.Text = "All settings saved successfully!"
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

# Live App Search Filter
$TxtAppSearch.Add_TextChanged({
    Refresh-LiveAppsList
})

$BtnRefreshLiveApps.Add_Click({
    Refresh-LiveAppsList
})

# Block Selected Live App
$BtnBlockLiveApp.Add_Click({
    if ($ListLiveApps.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Please select an application from the list to block.",
            "No Application Selected",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return
    }

    $item = $ListLiveApps.SelectedItems[0]
    $appName = $item.Text
    $appPath = [string]$item.Tag

    if (-not $appPath -or -not (Test-Path $appPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not resolve the executable path for $appName. Please locate it manually on the Firewall Blocker tab.",
            "Executable Path Not Found",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($appPath)
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
            -Program $appPath `
            -Action Block `
            -Profile Any `
            -Description "Blocked by DataControl Live Sentry" `
            -ErrorAction Stop

        $LblLiveAppBlockStatus.Text = "Blocked in Firewall: $appName"
        $LblLiveAppBlockStatus.ForeColor = $ColorSuccess
        [System.Windows.Forms.MessageBox]::Show(
            "Application '$appName' has been blocked from outbound network access in Windows Defender Firewall.",
            "Application Blocked",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    } catch {
        $LblLiveAppBlockStatus.Text = "Error: $($_.Exception.Message)"
        $LblLiveAppBlockStatus.ForeColor = $ColorDanger
    }
})

# Block Selected Historical App
$BtnBlockHistApp.Add_Click({
    if ($ListAppHistory.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Please select an application from the history list to block.",
            "No Application Selected",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return
    }

    $item = $ListAppHistory.SelectedItems[0]
    $appName = $item.Text
    $appPath = [string]$item.Tag

    if (-not $appPath -or -not (Test-Path $appPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not resolve the executable path for $appName.",
            "Executable Path Not Found",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($appPath)
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
            -Program $appPath `
            -Action Block `
            -Profile Any `
            -Description "Blocked by DataControl App History" `
            -ErrorAction Stop

        $LblAppHistActionStatus.Text = "Blocked in Firewall: $appName"
        $LblAppHistActionStatus.ForeColor = $ColorSuccess
        [System.Windows.Forms.MessageBox]::Show(
            "Application '$appName' has been blocked from outbound network access in Windows Defender Firewall.",
            "Application Blocked",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    } catch {
        $LblAppHistActionStatus.Text = "Error: $($_.Exception.Message)"
        $LblAppHistActionStatus.ForeColor = $ColorDanger
    }
})

# Clear App History
$BtnClearAppHist.Add_Click({
    $res = [System.Windows.Forms.MessageBox]::Show(
        "Are you sure you want to reset the per-application consumption history?",
        "Confirm App History Reset",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
        $script:AppHistory = New-Object PSCustomObject
        Save-AppHistory $script:AppHistory
        Refresh-AppHistoryList
        $LblAppHistActionStatus.Text = "App history reset to zero."
        $LblAppHistActionStatus.ForeColor = $ColorSuccess
    }
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
        $script:MonthlyWarningNotified = $false
        $script:MonthlyLimitNotified = $false

        Refresh-UsageDisplay
        Refresh-HistoryTable

        $LblResetStatus.Text = "Monthly metrics reset to 0 GB!"
        $LblResetStatus.ForeColor = $ColorSuccess
    }
})

# Tab Switching Event
$TabControl.Add_SelectedIndexChanged({
    if ($TabControl.SelectedTab -eq $Tab2) {
        Refresh-LiveAppsList
    } elseif ($TabControl.SelectedTab -eq $Tab3) {
        Refresh-AppHistoryList
    } elseif ($TabControl.SelectedTab -eq $Tab4) {
        Refresh-HistoryTable
    } elseif ($TabControl.SelectedTab -eq $Tab5) {
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

# Block Application Button Click (Manual)
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
    Save-AppHistory $script:AppHistory
})

# Initial Form Load Preparation
$Form.Add_Load({
    Refresh-AdapterList
    Refresh-AdapterStatusLabel
    Update-NetworkMetrics
    Refresh-UsageDisplay
    Refresh-LiveAppsList
    Refresh-AppHistoryList
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
            "DataControl is actively monitoring dual daily/monthly quotas in the background. Double-click to open dashboard.",
            [System.Windows.Forms.ToolTipIcon]::Info
        )
    })
}

# Launch Application Form
[System.Windows.Forms.Application]::Run($Form)
