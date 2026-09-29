<#
.SYNOPSIS
    DataControl - Windows 11 Data Control System (v3.5 Ultra-Modern WPF)
.DESCRIPTION
    Autonomous network metering, dual daily/monthly quota enforcement, live per-application
    bandwidth tracking, application consumption history, and Windows Defender Firewall blocker.
    Features: Windows 11 Fluent 2 Dark Mode, WPF hardware-accelerated vector UI, fully responsive
    resizable/maximizable layout, smooth mouse-wheel scrolling, modern pill toggle switches,
    custom gradient progress bars, minimize-to-tray on close, and elevated background execution.
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

# Load Required .NET Assemblies (WPF + WinForms Tray)
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Paths Configuration
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $AppDir) { $AppDir = (Get-Location).Path }
$ConfigFile = Join-Path $AppDir "config.json"
$HistoryFile = Join-Path $AppDir "data_history.json"
$AppHistoryFile = Join-Path $AppDir "app_history.json"
$IconPath = Join-Path $AppDir "DataControl.ico"
$TaskName = "DataControl_Monitor"

# Load Native Win32 API Helpers (Process IO Tracking & Windows 11 DWM Aesthetics)
$csharpNative = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class Win11Native {
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

    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWCP_ROUND = 2;

    public static void ApplyWin11Aesthetics(IntPtr hwnd) {
        try {
            int dark = 1;
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
            int round = DWMWCP_ROUND;
            DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
        } catch {}
    }
}
'@
Add-Type -TypeDefinition $csharpNative -ErrorAction SilentlyContinue

# ==============================================================================
# Helper Functions: Config & History Management
# ==============================================================================
function Load-AppConfig {
    if (Test-Path $ConfigFile) {
        try {
            $raw = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
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
$script:AllowRealExit = $false
$script:ProcStateCache = @{}

# ==============================================================================
# Network Metering Engine
# ==============================================================================
function Update-NetworkMetrics {
    param ([string]$AdapterName)

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
            $rawBytes = [Win11Native]::GetProcessBytes($pidNum)
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

# ==============================================================================
# Ultra-Modern WPF XAML Specification (Windows 11 Fluent 2 Dark Mode)
# ==============================================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DataControl - Windows 11 Data Control System"
        Width="1080" Height="760" MinWidth="880" MinHeight="620"
        WindowStartupLocation="CenterScreen"
        Background="#0A0E17" Foreground="#F8FAFC"
        FontFamily="Segoe UI, Segoe UI Variable Display, Arial">

    <Window.Resources>
        <!-- Modern Obsidian/Slate Color Palette Brushes -->
        <SolidColorBrush x:Key="BgRoot" Color="#0A0E17"/>
        <SolidColorBrush x:Key="BgSidebar" Color="#0E1422"/>
        <SolidColorBrush x:Key="BgCard" Color="#131B2E"/>
        <SolidColorBrush x:Key="BgCardElevated" Color="#182238"/>
        <SolidColorBrush x:Key="BgInput" Color="#0A0E18"/>
        <SolidColorBrush x:Key="BorderSubtle" Color="#1E2D4A"/>
        <SolidColorBrush x:Key="BorderLight" Color="#2A3D63"/>
        <SolidColorBrush x:Key="AccentSky" Color="#38BDF8"/>
        <SolidColorBrush x:Key="AccentBlue" Color="#0284C7"/>
        <SolidColorBrush x:Key="AccentSuccess" Color="#10B981"/>
        <SolidColorBrush x:Key="AccentWarning" Color="#F59E0B"/>
        <SolidColorBrush x:Key="AccentDanger" Color="#F43F5E"/>
        <SolidColorBrush x:Key="TextPrimary" Color="#F8FAFC"/>
        <SolidColorBrush x:Key="TextSecondary" Color="#94A3B8"/>
        <SolidColorBrush x:Key="TextMuted" Color="#64748B"/>

        <!-- Custom Slim Dark ScrollBar Style -->
        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="8"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="Transparent">
                            <Track x:Name="PART_Track" IsDirectionReversed="true">
                                <Track.Thumb>
                                    <Thumb>
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="Thumb">
                                                <Border Background="#253552" CornerRadius="4" Margin="1,0"/>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Modern Elevated Card Style -->
        <Style x:Key="ModernCard" TargetType="Border">
            <Setter Property="Background" Value="#131B2E"/>
            <Setter Property="BorderBrush" Value="#1E2D4A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="12"/>
            <Setter Property="Padding" Value="18"/>
        </Style>

        <!-- Modern Pill Toggle Switch -->
        <Style x:Key="ModernToggle" TargetType="CheckBox">
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal" Cursor="Hand">
                            <Grid Width="44" Height="22" Margin="0,0,12,0" VerticalAlignment="Center">
                                <Border x:Name="Track" Background="#1E293B" CornerRadius="11" BorderThickness="1" BorderBrush="#334155"/>
                                <Ellipse x:Name="Thumb" Width="14" Height="14" Fill="#F8FAFC" HorizontalAlignment="Left" Margin="4,0,0,0"/>
                            </Grid>
                            <ContentPresenter VerticalAlignment="Center"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Track" Property="Background" Value="#0284C7"/>
                                <Setter TargetName="Track" Property="BorderBrush" Value="#38BDF8"/>
                                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                                <Setter TargetName="Thumb" Property="Margin" Value="0,0,4,0"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Modern Action Button -->
        <Style x:Key="PrimaryBtn" TargetType="Button">
            <Setter Property="Background" Value="#0284C7"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#0369A1"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#075985"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DangerBtn" TargetType="Button">
            <Setter Property="Background" Value="#E11D48"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#BE123C"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SuccessBtn" TargetType="Button">
            <Setter Property="Background" Value="#059669"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#047857"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SecondaryBtn" TargetType="Button">
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="#334155" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#334155"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Sidebar Navigation Button Style -->
        <Style x:Key="NavBtn" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#94A3B8"/>
            <Setter Property="FontSize" Value="13.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="16,10"/>
            <Setter Property="Margin" Value="8,3"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#162035"/>
                                <Setter Property="Foreground" Value="#F8FAFC"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Dark Styled Modern ListView & Headers -->
        <Style TargetType="ListView">
            <Setter Property="Background" Value="#0A0E18"/>
            <Setter Property="BorderBrush" Value="#1E2D4A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Auto"/>
            <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>
            <Setter Property="ScrollViewer.CanContentScroll" Value="False"/>
        </Style>
        <Style TargetType="GridViewColumnHeader">
            <Setter Property="Background" Value="#131B2E"/>
            <Setter Property="Foreground" Value="#94A3B8"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="BorderBrush" Value="#1E2D4A"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
        </Style>
        <Style TargetType="ListViewItem">
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListViewItem">
                        <Border x:Name="Bd" Background="Transparent" CornerRadius="6" Margin="2,1" Padding="4,5">
                            <GridViewRowPresenter VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#162238"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#1E3A8A"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Modern Dark Inputs -->
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#0A0E18"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="BorderBrush" Value="#1E2D4A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="CaretBrush" Value="#38BDF8"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#0A0E18"/>
            <Setter Property="Foreground" Value="#0A0E18"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
    </Window.Resources>

    <!-- Main Grid Layout (Left Sidebar + Right Responsive Workspace) -->
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="220"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- ================================================================== -->
        <!-- LEFT SIDEBAR NAVIGATION RAIL                                       -->
        <!-- ================================================================== -->
        <Border Grid.Column="0" Background="#0C101A" BorderBrush="#1A2438" BorderThickness="0,0,1,0">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="80"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- App Brand / Header -->
                <StackPanel Grid.Row="0" Margin="18,18,18,0">
                    <StackPanel Orientation="Horizontal">
                        <Border Width="26" Height="26" CornerRadius="6" Background="#0284C7" Margin="0,0,10,0">
                            <TextBlock Text="🛡" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Text="DATACONTROL" Foreground="#38BDF8" FontWeight="Bold" FontSize="16" VerticalAlignment="Center"/>
                    </StackPanel>
                    <TextBlock Text="Windows 11 Pro Sentry" Foreground="#64748B" FontSize="10.5" Margin="36,2,0,0"/>
                </StackPanel>

                <!-- Navigation Menu Buttons -->
                <StackPanel Grid.Row="1" Margin="4,10,4,0">
                    <Button x:Name="BtnNavDashboard" Content="📊  Dashboard" Style="{StaticResource NavBtn}"/>
                    <Button x:Name="BtnNavLiveApps" Content="⚡  Live Apps" Style="{StaticResource NavBtn}"/>
                    <Button x:Name="BtnNavAppHistory" Content="📈  App History" Style="{StaticResource NavBtn}"/>
                    <Button x:Name="BtnNavAnalytics" Content="📅  Analytics" Style="{StaticResource NavBtn}"/>
                    <Button x:Name="BtnNavFirewall" Content="🛡️  Firewall Rules" Style="{StaticResource NavBtn}"/>
                    <Button x:Name="BtnNavSettings" Content="⚙️  Settings" Style="{StaticResource NavBtn}"/>
                </StackPanel>

                <!-- Sidebar Footer Status & Quick Actions -->
                <StackPanel Grid.Row="2" Margin="14,0,14,16">
                    <Border CornerRadius="8" Background="#131B2E" BorderBrush="#1E2D4A" BorderThickness="1" Padding="12,10" Margin="0,0,0,10">
                        <StackPanel>
                            <TextBlock x:Name="SidebarSentryStatus" Text="● SENTRY ACTIVE" Foreground="#10B981" FontWeight="Bold" FontSize="11"/>
                            <TextBlock x:Name="SidebarAdapterLabel" Text="Target: Wi-Fi" Foreground="#94A3B8" FontSize="11" Margin="0,2,0,0"/>
                        </StackPanel>
                    </Border>
                    <Button x:Name="BtnSidebarToggleWifi" Content="⚡ Toggle Adapter" Style="{StaticResource SecondaryBtn}" Margin="0,0,0,6"/>
                    <Button x:Name="BtnSidebarExit" Content="Exit DataControl" Style="{StaticResource SecondaryBtn}" Foreground="#F43F5E"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- ================================================================== -->
        <!-- RIGHT WORKSPACE: DYNAMIC RESPONSIVE CONTENT AREA                   -->
        <!-- ================================================================== -->
        <Grid Grid.Column="1" Background="#0A0E17">
            <Grid.RowDefinitions>
                <RowDefinition Height="64"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- Top Header Bar -->
            <Border Grid.Row="0" Background="#0C101A" BorderBrush="#1A2438" BorderThickness="0,0,0,1" Padding="24,0">
                <Grid VerticalAlignment="Center">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Grid.Column="0">
                        <TextBlock x:Name="WorkspaceTitle" Text="System Dashboard &amp; Dual Quotas" Foreground="#F8FAFC" FontWeight="Bold" FontSize="17"/>
                        <TextBlock x:Name="WorkspaceSubtitle" Text="Real-time telemetry, auto-cutoff, and metered connection protection" Foreground="#64748B" FontSize="11.5"/>
                    </StackPanel>

                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <Border x:Name="BadgeLinkStatus" CornerRadius="6" Background="#064E3B" Padding="10,4" Margin="0,0,12,0">
                            <TextBlock x:Name="TxtLinkStatus" Text="● CONNECTED" Foreground="#10B981" FontWeight="Bold" FontSize="11"/>
                        </Border>
                        <Border CornerRadius="6" Background="#131B2E" BorderBrush="#1E2D4A" BorderThickness="1" Padding="12,4">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="Speed: " Foreground="#94A3B8" FontSize="11" VerticalAlignment="Center"/>
                                <TextBlock x:Name="TxtLiveSpeedTop" Text="0.00 KB/s" Foreground="#38BDF8" FontWeight="Bold" FontSize="12.5" VerticalAlignment="Center"/>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- Dynamic In-App Toast Notification Banner -->
            <Border x:Name="ToastBanner" Grid.Row="1" Background="#064E3B" BorderBrush="#10B981" BorderThickness="1" CornerRadius="8" Margin="24,12,24,0" Padding="14,10" Visibility="Collapsed">
                <TextBlock x:Name="ToastText" Text="Settings saved successfully!" Foreground="#F8FAFC" FontSize="12.5" FontWeight="SemiBold"/>
            </Border>

            <!-- Active View Containers (Workspace Panels) -->
            <Grid Grid.Row="2" Margin="24,16,24,20">

                <!-- 1. DASHBOARD VIEW (Smooth ScrollViewer) -->
                <ScrollViewer x:Name="ViewDashboard" VerticalScrollBarVisibility="Auto" CanContentScroll="False" Visibility="Visible">
                    <StackPanel>
                        <!-- Hero Interface & Throughput Card -->
                        <Border Style="{StaticResource ModernCard}" Margin="0,0,0,16">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0">
                                    <TextBlock Text="NETWORK INTERFACE &amp; THROUGHPUT SENTRY" Foreground="#94A3B8" FontWeight="SemiBold" FontSize="11"/>
                                    <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                                        <TextBlock Text="Target Adapter:" Foreground="#F8FAFC" FontWeight="SemiBold" FontSize="13.5" VerticalAlignment="Center" Margin="0,0,12,0"/>
                                        <ComboBox x:Name="ComboAdapters" Width="200" Height="28"/>
                                    </StackPanel>
                                    <TextBlock x:Name="TxtAdapterDetails" Text="Status: Connected (Up) | Sentry active on Wi-Fi" Foreground="#64748B" FontSize="11.5" Margin="0,6,0,0"/>
                                </StackPanel>
                                <StackPanel Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center">
                                    <TextBlock Text="Live Speed" Foreground="#94A3B8" FontSize="11" HorizontalAlignment="Right"/>
                                    <TextBlock x:Name="TxtHeroSpeed" Text="0.00 KB/s" Foreground="#38BDF8" FontWeight="Bold" FontSize="26" HorizontalAlignment="Right"/>
                                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,6,0,0">
                                        <Button x:Name="BtnDisableWifiHero" Content="Disable Adapter" Style="{StaticResource DangerBtn}" Padding="10,5" FontSize="11.5" Margin="0,0,8,0"/>
                                        <Button x:Name="BtnEnableWifiHero" Content="Enable Adapter" Style="{StaticResource SuccessBtn}" Padding="10,5" FontSize="11.5"/>
                                    </StackPanel>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <!-- Responsive Dual Quota Cards (2-Column Proportional Grid) -->
                        <Grid Margin="0,0,0,16">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="1*"/>
                                <ColumnDefinition Width="16"/>
                                <ColumnDefinition Width="1*"/>
                            </Grid.ColumnDefinitions>

                            <!-- Daily Quota Card -->
                            <Border Grid.Column="0" Style="{StaticResource ModernCard}">
                                <StackPanel>
                                    <Grid>
                                        <TextBlock Text="📅 DAILY QUOTA" Foreground="#94A3B8" FontWeight="SemiBold" FontSize="11"/>
                                        <TextBlock x:Name="TxtDailyPercent" Text="0.0%" Foreground="#38BDF8" FontWeight="Bold" FontSize="15" HorizontalAlignment="Right"/>
                                    </Grid>
                                    <TextBlock x:Name="TxtDailyHero" Text="0.00 MB / 2.00 GB" Foreground="#F8FAFC" FontWeight="Bold" FontSize="22" Margin="0,6,0,0"/>
                                    
                                    <!-- Linear Gradient Progress Bar -->
                                    <Border Background="#0E1422" CornerRadius="7" BorderBrush="#1E2D4A" BorderThickness="1" Height="14" Margin="0,10,0,0">
                                        <Grid>
                                            <Border x:Name="BarDailyFill" HorizontalAlignment="Left" Width="10" CornerRadius="6">
                                                <Border.Background>
                                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                                        <GradientStop Color="#0284C7" Offset="0.0"/>
                                                        <GradientStop Color="#38BDF8" Offset="1.0"/>
                                                    </LinearGradientBrush>
                                                </Border.Background>
                                            </Border>
                                        </Grid>
                                    </Border>

                                    <TextBlock x:Name="TxtDailyRemaining" Text="Remaining Today: 2.00 GB" Foreground="#64748B" FontSize="11.5" Margin="0,8,0,0"/>
                                    <CheckBox x:Name="ToggleDailyCutoff" Content="Auto-disconnect Wi-Fi when daily quota reached" Style="{StaticResource ModernToggle}" Margin="0,12,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- Monthly Quota Card -->
                            <Border Grid.Column="2" Style="{StaticResource ModernCard}">
                                <StackPanel>
                                    <Grid>
                                        <TextBlock Text="🌐 MONTHLY QUOTA" Foreground="#94A3B8" FontWeight="SemiBold" FontSize="11"/>
                                        <TextBlock x:Name="TxtMonthlyPercent" Text="0.0%" Foreground="#10B981" FontWeight="Bold" FontSize="15" HorizontalAlignment="Right"/>
                                    </Grid>
                                    <TextBlock x:Name="TxtMonthlyHero" Text="0.00 GB / 16.00 GB" Foreground="#F8FAFC" FontWeight="Bold" FontSize="22" Margin="0,6,0,0"/>

                                    <!-- Linear Gradient Progress Bar -->
                                    <Border Background="#0E1422" CornerRadius="7" BorderBrush="#1E2D4A" BorderThickness="1" Height="14" Margin="0,10,0,0">
                                        <Grid>
                                            <Border x:Name="BarMonthlyFill" HorizontalAlignment="Left" Width="10" CornerRadius="6">
                                                <Border.Background>
                                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                                        <GradientStop Color="#059669" Offset="0.0"/>
                                                        <GradientStop Color="#10B981" Offset="1.0"/>
                                                    </LinearGradientBrush>
                                                </Border.Background>
                                            </Border>
                                        </Grid>
                                    </Border>

                                    <TextBlock x:Name="TxtMonthlyRemaining" Text="Remaining This Month: 16.00 GB" Foreground="#64748B" FontSize="11.5" Margin="0,8,0,0"/>
                                    <CheckBox x:Name="ToggleMonthlyCutoff" Content="Auto-disconnect Wi-Fi when monthly quota reached" Style="{StaticResource ModernToggle}" Margin="0,12,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Top Consuming Active Processes Quick Preview -->
                        <Border Style="{StaticResource ModernCard}">
                            <StackPanel>
                                <Grid Margin="0,0,0,10">
                                    <TextBlock Text="⚡ TOP LIVE BANDWIDTH CONSUMERS" Foreground="#94A3B8" FontWeight="SemiBold" FontSize="11"/>
                                    <TextBlock Text="Live Sentry Sample" Foreground="#64748B" FontSize="11" HorizontalAlignment="Right"/>
                                </Grid>
                                <ListView x:Name="ListDashboardTopApps" Height="150">
                                    <ListView.View>
                                        <GridView>
                                            <GridViewColumn Header="Application" Width="220" DisplayMemberBinding="{Binding Path=Name}"/>
                                            <GridViewColumn Header="PID" Width="70" DisplayMemberBinding="{Binding Path=PID}"/>
                                            <GridViewColumn Header="Transfer Speed" Width="120" DisplayMemberBinding="{Binding Path=Speed}"/>
                                            <GridViewColumn Header="Session Total" Width="120" DisplayMemberBinding="{Binding Path=SessionBytes}"/>
                                            <GridViewColumn Header="Sockets" Width="70" DisplayMemberBinding="{Binding Path=Sockets}"/>
                                        </GridView>
                                    </ListView.View>
                                </ListView>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>

                <!-- 2. LIVE APPS VIEW -->
                <Grid x:Name="ViewLiveApps" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Filter / Search Header -->
                    <Border Grid.Row="0" Style="{StaticResource ModernCard}" Padding="14,10" Margin="0,0,0,12">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="280"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" Text="🔍 Filter Processes: " Foreground="#94A3B8" VerticalAlignment="Center" Margin="0,0,10,0"/>
                            <TextBox x:Name="TxtLiveSearch" Grid.Column="1" Height="28"/>
                            <TextBlock Grid.Column="2" Text="Type application name or executable path to filter in real-time" Foreground="#64748B" FontSize="11" VerticalAlignment="Center" Margin="14,0,0,0"/>
                            <Button x:Name="BtnRefreshLive" Grid.Column="3" Content="🔄 Refresh Now" Style="{StaticResource SecondaryBtn}" Padding="12,5"/>
                        </Grid>
                    </Border>

                    <!-- Live App ListView -->
                    <ListView x:Name="ListLiveApps" Grid.Row="1">
                        <ListView.View>
                            <GridView>
                                <GridViewColumn Header="Application Name" Width="190" DisplayMemberBinding="{Binding Path=Name}"/>
                                <GridViewColumn Header="PID" Width="70" DisplayMemberBinding="{Binding Path=PID}"/>
                                <GridViewColumn Header="Live Speed" Width="120" DisplayMemberBinding="{Binding Path=Speed}"/>
                                <GridViewColumn Header="Session Total" Width="120" DisplayMemberBinding="{Binding Path=SessionBytes}"/>
                                <GridViewColumn Header="Sockets" Width="75" DisplayMemberBinding="{Binding Path=Sockets}"/>
                                <GridViewColumn Header="Executable Path" Width="360" DisplayMemberBinding="{Binding Path=Path}"/>
                            </GridView>
                        </ListView.View>
                    </ListView>

                    <!-- Bottom Action Controls -->
                    <Border Grid.Row="2" Style="{StaticResource ModernCard}" Padding="14,10" Margin="0,12,0,0">
                        <Grid>
                            <StackPanel Orientation="Horizontal">
                                <Button x:Name="BtnBlockLiveApp" Content="🚫 Block Selected App in Firewall" Style="{StaticResource DangerBtn}" Margin="0,0,12,0"/>
                                <TextBlock x:Name="TxtLiveBlockStatus" Text="" Foreground="#10B981" FontWeight="SemiBold" VerticalAlignment="Center"/>
                            </StackPanel>
                            <TextBlock Text="Blocks outbound network access for selected executable in Windows Defender Firewall" Foreground="#64748B" FontSize="11" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                        </Grid>
                    </Border>
                </Grid>

                <!-- 3. APP HISTORY VIEW -->
                <Grid x:Name="ViewAppHistory" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <Border Grid.Row="0" Style="{StaticResource ModernCard}" Padding="14,10" Margin="0,0,0,12">
                        <Grid>
                            <StackPanel>
                                <TextBlock Text="APPLICATION DATA CONSUMPTION LEADERBOARD" Foreground="#94A3B8" FontWeight="SemiBold" FontSize="11"/>
                                <TextBlock Text="Cumulative data ledger across reboots. Select any application to block it." Foreground="#64748B" FontSize="11.5" Margin="0,2,0,0"/>
                            </StackPanel>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                <Button x:Name="BtnResetAppHistory" Content="🗑️ Reset App History" Style="{StaticResource SecondaryBtn}" Padding="12,6"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <ListView x:Name="ListAppHistory" Grid.Row="1">
                        <ListView.View>
                            <GridView>
                                <GridViewColumn Header="Application Name" Width="200" DisplayMemberBinding="{Binding Path=Name}"/>
                                <GridViewColumn Header="Total Consumed" Width="140" DisplayMemberBinding="{Binding Path=TotalBytes}"/>
                                <GridViewColumn Header="Last Seen Timestamp" Width="160" DisplayMemberBinding="{Binding Path=LastSeen}"/>
                                <GridViewColumn Header="Executable Path" Width="380" DisplayMemberBinding="{Binding Path=Path}"/>
                            </GridView>
                        </ListView.View>
                    </ListView>

                    <Border Grid.Row="2" Style="{StaticResource ModernCard}" Padding="14,10" Margin="0,12,0,0">
                        <StackPanel Orientation="Horizontal">
                            <Button x:Name="BtnBlockHistoryApp" Content="🚫 Block Selected App in Firewall" Style="{StaticResource DangerBtn}" Margin="0,0,12,0"/>
                            <TextBlock x:Name="TxtHistoryBlockStatus" Text="" Foreground="#10B981" FontWeight="SemiBold" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Border>
                </Grid>

                <!-- 4. ANALYTICS & BILLING CYCLE VIEW -->
                <ScrollViewer x:Name="ViewAnalytics" VerticalScrollBarVisibility="Auto" CanContentScroll="False" Visibility="Collapsed">
                    <StackPanel>
                        <!-- 3 Hero Metric Cards -->
                        <Grid Margin="0,0,0,16">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="1*"/>
                                <ColumnDefinition Width="16"/>
                                <ColumnDefinition Width="1*"/>
                                <ColumnDefinition Width="16"/>
                                <ColumnDefinition Width="1*"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Style="{StaticResource ModernCard}">
                                <StackPanel>
                                    <TextBlock Text="TODAY" Foreground="#94A3B8" FontWeight="SemiBold" FontSize="11"/>
                                    <TextBlock x:Name="TxtAnalyticsToday" Text="0.00 MB" Foreground="#38BDF8" FontWeight="Bold" FontSize="24" Margin="0,6,0,0"/>
                                    <TextBlock x:Name="TxtAnalyticsTodaySub" Text="2026-09-29" Foreground="#64748B" FontSize="11" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>

                            <Border Grid.Column="2" Style="{StaticResource ModernCard}">
                                <StackPanel>
                                    <TextBlock Text="THIS MONTH" Foreground="#94A3B8" FontWeight="SemiBold" FontSize="11"/>
                                    <TextBlock x:Name="TxtAnalyticsMonth" Text="0.00 GB" Foreground="#10B981" FontWeight="Bold" FontSize="24" Margin="0,6,0,0"/>
                                    <TextBlock x:Name="TxtAnalyticsMonthSub" Text="September 2026" Foreground="#64748B" FontSize="11" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>

                            <Border Grid.Column="4" Style="{StaticResource ModernCard}">
                                <StackPanel>
                                    <TextBlock Text="THIS YEAR" Foreground="#94A3B8" FontWeight="SemiBold" FontSize="11"/>
                                    <TextBlock x:Name="TxtAnalyticsYear" Text="0.00 GB" Foreground="#F59E0B" FontWeight="Bold" FontSize="24" Margin="0,6,0,0"/>
                                    <TextBlock x:Name="TxtAnalyticsYearSub" Text="2026" Foreground="#64748B" FontSize="11" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Billing Cycle Synchronization Card -->
                        <Border Style="{StaticResource ModernCard}" Margin="0,0,0,16">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0">
                                    <TextBlock Text="BILLING CYCLE SYNCHRONIZATION" Foreground="#94A3B8" FontWeight="SemiBold" FontSize="11"/>
                                    <TextBlock Text="Reset monthly consumption metrics to 0 GB when your ISP or Cellular hotspot data cycle renews." Foreground="#64748B" FontSize="12" Margin="0,4,0,0"/>
                                </StackPanel>
                                <Button x:Name="BtnResetCurrentMonth" Grid.Column="1" Content="🔄 Reset Current Month to 0 GB" Style="{StaticResource SecondaryBtn}" VerticalAlignment="Center"/>
                            </Grid>
                        </Border>

                        <!-- Daily Consumption History Table -->
                        <Border Style="{StaticResource ModernCard}">
                            <StackPanel>
                                <TextBlock Text="HISTORICAL DAILY DATA CONSUMPTION" Foreground="#94A3B8" FontWeight="SemiBold" FontSize="11" Margin="0,0,0,10"/>
                                <ListView x:Name="ListDailyHistory" Height="260">
                                    <ListView.View>
                                        <GridView>
                                            <GridViewColumn Header="Date" Width="180" DisplayMemberBinding="{Binding Path=Date}"/>
                                            <GridViewColumn Header="Data Consumed" Width="200" DisplayMemberBinding="{Binding Path=Formatted}"/>
                                            <GridViewColumn Header="Raw Transfer Bytes" Width="240" DisplayMemberBinding="{Binding Path=Raw}"/>
                                        </GridView>
                                    </ListView.View>
                                </ListView>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>

                <!-- 5. FIREWALL RULES VIEW -->
                <ScrollViewer x:Name="ViewFirewall" VerticalScrollBarVisibility="Auto" CanContentScroll="False" Visibility="Collapsed">
                    <StackPanel>
                        <!-- Manual Executable Blocker Card -->
                        <Border Style="{StaticResource ModernCard}" Margin="0,0,0,16">
                            <StackPanel>
                                <TextBlock Text="MANUAL FIREWALL OUTBOUND BLOCKER" Foreground="#94A3B8" FontWeight="SemiBold" FontSize="11"/>
                                <TextBlock Text="Select any executable (.exe) on your computer to create an outbound block rule in Windows Defender Firewall." Foreground="#64748B" FontSize="11.5" Margin="0,3,0,10"/>
                                
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBox x:Name="TxtFirewallExePath" Grid.Column="0" IsReadOnly="True" Height="30" Margin="0,0,8,0"/>
                                    <Button x:Name="BtnBrowseExe" Grid.Column="1" Content="Browse..." Style="{StaticResource SecondaryBtn}" Height="30" Margin="0,0,8,0"/>
                                    <Button x:Name="BtnBlockExeManual" Grid.Column="2" Content="🚫 Block Outbound Access" Style="{StaticResource DangerBtn}" Height="30"/>
                                </Grid>
                                <TextBlock x:Name="TxtFirewallManualStatus" Text="" Foreground="#10B981" FontWeight="SemiBold" FontSize="12" Margin="0,6,0,0"/>
                            </StackPanel>
                        </Border>

                        <!-- Managed Rules Table -->
                        <Border Style="{StaticResource ModernCard}">
                            <StackPanel>
                                <Grid Margin="0,0,0,10">
                                    <TextBlock Text="ACTIVE DATACONTROL OUTBOUND BLOCK RULES" Foreground="#94A3B8" FontWeight="SemiBold" FontSize="11"/>
                                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                        <Button x:Name="BtnUnblockRule" Content="✓ Unblock Selected" Style="{StaticResource SuccessBtn}" Padding="10,4" Margin="0,0,8,0"/>
                                        <Button x:Name="BtnRefreshRules" Content="🔄 Refresh Rules" Style="{StaticResource SecondaryBtn}" Padding="10,4"/>
                                    </StackPanel>
                                </Grid>
                                <ListView x:Name="ListFirewallRules" Height="320">
                                    <ListView.View>
                                        <GridView>
                                            <GridViewColumn Header="Rule Display Name" Width="240" DisplayMemberBinding="{Binding Path=RuleName}"/>
                                            <GridViewColumn Header="Program Executable Path" Width="400" DisplayMemberBinding="{Binding Path=ProgramPath}"/>
                                            <GridViewColumn Header="Firewall Action" Width="100" DisplayMemberBinding="{Binding Path=Action}"/>
                                        </GridView>
                                    </ListView.View>
                                </ListView>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>

                <!-- 6. SETTINGS VIEW -->
                <ScrollViewer x:Name="ViewSettings" VerticalScrollBarVisibility="Auto" CanContentScroll="False" Visibility="Collapsed">
                    <StackPanel>
                        <Border Style="{StaticResource ModernCard}" Margin="0,0,0,16">
                            <StackPanel>
                                <TextBlock Text="DUAL QUOTA CONFIGURATION &amp; THRESHOLDS" Foreground="#94A3B8" FontWeight="SemiBold" FontSize="11" Margin="0,0,0,12"/>
                                
                                <Grid Margin="0,0,0,14">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="1*"/>
                                        <ColumnDefinition Width="16"/>
                                        <ColumnDefinition Width="1*"/>
                                    </Grid.ColumnDefinitions>

                                    <!-- Daily Settings -->
                                    <Border Grid.Column="0" Background="#0E1422" CornerRadius="8" BorderBrush="#1E2D4A" BorderThickness="1" Padding="14">
                                        <StackPanel>
                                            <TextBlock Text="Daily Quota Settings" Foreground="#38BDF8" FontWeight="Bold" FontSize="13" Margin="0,0,0,10"/>
                                            <TextBlock Text="Daily Limit (GB):" Foreground="#94A3B8" FontSize="12"/>
                                            <TextBox x:Name="InputDailyLimit" Height="28" Margin="0,4,0,10"/>

                                            <TextBlock Text="Daily Warning Threshold (GB):" Foreground="#94A3B8" FontSize="12"/>
                                            <TextBox x:Name="InputDailyWarn" Height="28" Margin="0,4,0,10"/>

                                            <CheckBox x:Name="ChkSettingAutoDaily" Content="Cutoff: Disable Wi-Fi at Daily Limit" Style="{StaticResource ModernToggle}"/>
                                        </StackPanel>
                                    </Border>

                                    <!-- Monthly Settings -->
                                    <Border Grid.Column="2" Background="#0E1422" CornerRadius="8" BorderBrush="#1E2D4A" BorderThickness="1" Padding="14">
                                        <StackPanel>
                                            <TextBlock Text="Monthly Quota Settings" Foreground="#10B981" FontWeight="Bold" FontSize="13" Margin="0,0,0,10"/>
                                            <TextBlock Text="Monthly Limit (GB):" Foreground="#94A3B8" FontSize="12"/>
                                            <TextBox x:Name="InputMonthlyLimit" Height="28" Margin="0,4,0,10"/>

                                            <TextBlock Text="Monthly Warning Threshold (GB):" Foreground="#94A3B8" FontSize="12"/>
                                            <TextBox x:Name="InputMonthlyWarn" Height="28" Margin="0,4,0,10"/>

                                            <CheckBox x:Name="ChkSettingAutoMonthly" Content="Cutoff: Disable Wi-Fi at Monthly Limit" Style="{StaticResource ModernToggle}"/>
                                        </StackPanel>
                                    </Border>
                                </Grid>

                                <!-- Hardware & Startup Policies -->
                                <Border Background="#0E1422" CornerRadius="8" BorderBrush="#1E2D4A" BorderThickness="1" Padding="14" Margin="0,0,0,16">
                                    <StackPanel>
                                        <TextBlock Text="System Startup &amp; Sentry Daemon" Foreground="#F8FAFC" FontWeight="Bold" FontSize="13" Margin="0,0,0,10"/>
                                        <CheckBox x:Name="ChkSettingStartWithWindows" Content="Start with Windows Logon (Runs silently in background with highest Administrator privileges)" Style="{StaticResource ModernToggle}" Margin="0,0,0,10"/>
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock Text="Poll Frequency (seconds): " Foreground="#94A3B8" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                            <TextBox x:Name="InputPollSeconds" Width="80" Height="26"/>
                                        </StackPanel>
                                    </StackPanel>
                                </Border>

                                <StackPanel Orientation="Horizontal">
                                    <Button x:Name="BtnSaveAllSettings" Content="💾 Save All Quota &amp; System Settings" Style="{StaticResource PrimaryBtn}" Padding="20,10"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>
            </Grid>
        </Grid>
    </Grid>
</Window>
'@

# Parse XAML
$sr = New-Object System.IO.StringReader($xaml)
$xr = [System.Xml.XmlReader]::Create($sr)
$Window = [System.Windows.Markup.XamlReader]::Load($xr)

# Wire Controls by Name
$BtnNavDashboard          = $Window.FindName("BtnNavDashboard")
$BtnNavLiveApps           = $Window.FindName("BtnNavLiveApps")
$BtnNavAppHistory         = $Window.FindName("BtnNavAppHistory")
$BtnNavAnalytics          = $Window.FindName("BtnNavAnalytics")
$BtnNavFirewall           = $Window.FindName("BtnNavFirewall")
$BtnNavSettings           = $Window.FindName("BtnNavSettings")
$BtnSidebarToggleWifi     = $Window.FindName("BtnSidebarToggleWifi")
$BtnSidebarExit           = $Window.FindName("BtnSidebarExit")

$WorkspaceTitle           = $Window.FindName("WorkspaceTitle")
$WorkspaceSubtitle        = $Window.FindName("WorkspaceSubtitle")
$TxtLinkStatus            = $Window.FindName("TxtLinkStatus")
$BadgeLinkStatus          = $Window.FindName("BadgeLinkStatus")
$TxtLiveSpeedTop          = $Window.FindName("TxtLiveSpeedTop")
$ToastBanner              = $Window.FindName("ToastBanner")
$ToastText                = $Window.FindName("ToastText")

$ViewDashboard            = $Window.FindName("ViewDashboard")
$ViewLiveApps             = $Window.FindName("ViewLiveApps")
$ViewAppHistory           = $Window.FindName("ViewAppHistory")
$ViewAnalytics            = $Window.FindName("ViewAnalytics")
$ViewFirewall             = $Window.FindName("ViewFirewall")
$ViewSettings             = $Window.FindName("ViewSettings")

# Dashboard Controls
$ComboAdapters            = $Window.FindName("ComboAdapters")
$TxtAdapterDetails        = $Window.FindName("TxtAdapterDetails")
$TxtHeroSpeed             = $Window.FindName("TxtHeroSpeed")
$BtnDisableWifiHero       = $Window.FindName("BtnDisableWifiHero")
$BtnEnableWifiHero        = $Window.FindName("BtnEnableWifiHero")
$TxtDailyPercent          = $Window.FindName("TxtDailyPercent")
$TxtDailyHero             = $Window.FindName("TxtDailyHero")
$BarDailyFill             = $Window.FindName("BarDailyFill")
$TxtDailyRemaining        = $Window.FindName("TxtDailyRemaining")
$ToggleDailyCutoff        = $Window.FindName("ToggleDailyCutoff")
$TxtMonthlyPercent        = $Window.FindName("TxtMonthlyPercent")
$TxtMonthlyHero           = $Window.FindName("TxtMonthlyHero")
$BarMonthlyFill           = $Window.FindName("BarMonthlyFill")
$TxtMonthlyRemaining      = $Window.FindName("TxtMonthlyRemaining")
$ToggleMonthlyCutoff      = $Window.FindName("ToggleMonthlyCutoff")
$ListDashboardTopApps     = $Window.FindName("ListDashboardTopApps")

# Live Apps Controls
$TxtLiveSearch            = $Window.FindName("TxtLiveSearch")
$BtnRefreshLive           = $Window.FindName("BtnRefreshLive")
$ListLiveApps             = $Window.FindName("ListLiveApps")
$BtnBlockLiveApp          = $Window.FindName("BtnBlockLiveApp")
$TxtLiveBlockStatus       = $Window.FindName("TxtLiveBlockStatus")

# History Controls
$BtnResetAppHistory       = $Window.FindName("BtnResetAppHistory")
$ListAppHistory           = $Window.FindName("ListAppHistory")
$BtnBlockHistoryApp       = $Window.FindName("BtnBlockHistoryApp")
$TxtHistoryBlockStatus    = $Window.FindName("TxtHistoryBlockStatus")

# Analytics Controls
$TxtAnalyticsToday        = $Window.FindName("TxtAnalyticsToday")
$TxtAnalyticsTodaySub     = $Window.FindName("TxtAnalyticsTodaySub")
$TxtAnalyticsMonth        = $Window.FindName("TxtAnalyticsMonth")
$TxtAnalyticsMonthSub     = $Window.FindName("TxtAnalyticsMonthSub")
$TxtAnalyticsYear         = $Window.FindName("TxtAnalyticsYear")
$TxtAnalyticsYearSub      = $Window.FindName("TxtAnalyticsYearSub")
$BtnResetCurrentMonth     = $Window.FindName("BtnResetCurrentMonth")
$ListDailyHistory         = $Window.FindName("ListDailyHistory")

# Firewall Controls
$TxtFirewallExePath       = $Window.FindName("TxtFirewallExePath")
$BtnBrowseExe             = $Window.FindName("BtnBrowseExe")
$BtnBlockExeManual        = $Window.FindName("BtnBlockExeManual")
$TxtFirewallManualStatus  = $Window.FindName("TxtFirewallManualStatus")
$ListFirewallRules        = $Window.FindName("ListFirewallRules")
$BtnUnblockRule           = $Window.FindName("BtnUnblockRule")
$BtnRefreshRules          = $Window.FindName("BtnRefreshRules")

# Settings Controls
$InputDailyLimit          = $Window.FindName("InputDailyLimit")
$InputDailyWarn           = $Window.FindName("InputDailyWarn")
$ChkSettingAutoDaily      = $Window.FindName("ChkSettingAutoDaily")
$InputMonthlyLimit        = $Window.FindName("InputMonthlyLimit")
$InputMonthlyWarn         = $Window.FindName("InputMonthlyWarn")
$ChkSettingAutoMonthly    = $Window.FindName("ChkSettingAutoMonthly")
$ChkSettingStartWithWindows = $Window.FindName("ChkSettingStartWithWindows")
$InputPollSeconds         = $Window.FindName("InputPollSeconds")
$BtnSaveAllSettings       = $Window.FindName("BtnSaveAllSettings")

# Sidebar Elements
$SidebarSentryStatus      = $Window.FindName("SidebarSentryStatus")
$SidebarAdapterLabel      = $Window.FindName("SidebarAdapterLabel")

# ==============================================================================
# System Tray Integration (Desktop Background Resident)
# ==============================================================================
$AppCustomIcon = $null
if (Test-Path $IconPath) {
    try { $AppCustomIcon = New-Object System.Drawing.Icon($IconPath) } catch {}
}

$NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
if ($AppCustomIcon) {
    $NotifyIcon.Icon = $AppCustomIcon
} else {
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
$TrayItemStatusToday = $TrayMenu.Items.Add("Today: Calculating...")
$TrayItemStatusMonth = $TrayMenu.Items.Add("Month: Calculating...")
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
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        & $RestoreAction
    }
})

# ==============================================================================
# Dynamic UI & State Binding Functions
# ==============================================================================
function Show-Toast ([string]$message, [string]$colorHex = "#10B981") {
    $ToastText.Text = $message
    $ToastBanner.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#064E3B"))
    $ToastBanner.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($colorHex))
    $ToastBanner.Visibility = [System.Windows.Visibility]::Visible

    $toastTimer = New-Object System.Windows.Threading.DispatcherTimer
    $toastTimer.Interval = [TimeSpan]::FromSeconds(3)
    $toastTimer.Add_Tick({
        $ToastBanner.Visibility = [System.Windows.Visibility]::Collapsed
        $toastTimer.Stop()
    })
    $toastTimer.Start()
}

function Set-ActiveView ([string]$viewName) {
    $views = @($ViewDashboard, $ViewLiveApps, $ViewAppHistory, $ViewAnalytics, $ViewFirewall, $ViewSettings)
    foreach ($v in $views) { $v.Visibility = [System.Windows.Visibility]::Collapsed }

    $navButtons = @($BtnNavDashboard, $BtnNavLiveApps, $BtnNavAppHistory, $BtnNavAnalytics, $BtnNavFirewall, $BtnNavSettings)
    foreach ($b in $navButtons) {
        $b.Background = [System.Windows.Media.Brushes]::Transparent
        $b.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#94A3B8"))
    }

    $activeBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#162035"))
    $activeFg = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F8FAFC"))

    switch ($viewName) {
        "Dashboard" {
            $ViewDashboard.Visibility = [System.Windows.Visibility]::Visible
            $BtnNavDashboard.Background = $activeBrush
            $BtnNavDashboard.Foreground = $activeFg
            $WorkspaceTitle.Text = "System Dashboard & Dual Quotas"
            $WorkspaceSubtitle.Text = "Real-time telemetry, auto-cutoff, and metered connection protection"
        }
        "LiveApps" {
            $ViewLiveApps.Visibility = [System.Windows.Visibility]::Visible
            $BtnNavLiveApps.Background = $activeBrush
            $BtnNavLiveApps.Foreground = $activeFg
            $WorkspaceTitle.Text = "Live Application Bandwidth Sentry"
            $WorkspaceSubtitle.Text = "Real-time per-process socket tracking and instantaneous firewall blocking"
            Refresh-LiveAppsList
        }
        "AppHistory" {
            $ViewAppHistory.Visibility = [System.Windows.Visibility]::Visible
            $BtnNavAppHistory.Background = $activeBrush
            $BtnNavAppHistory.Foreground = $activeFg
            $WorkspaceTitle.Text = "Application Consumption Leaderboard"
            $WorkspaceSubtitle.Text = "Cumulative historical network usage ledger across all reboots and sessions"
            Refresh-AppHistoryList
        }
        "Analytics" {
            $ViewAnalytics.Visibility = [System.Windows.Visibility]::Visible
            $BtnNavAnalytics.Background = $activeBrush
            $BtnNavAnalytics.Foreground = $activeFg
            $WorkspaceTitle.Text = "Usage Analytics & Billing Cycle"
            $WorkspaceSubtitle.Text = "Daily, monthly, and yearly historical consumption breakdown and billing renewal reset"
            Refresh-AnalyticsDisplay
        }
        "Firewall" {
            $ViewFirewall.Visibility = [System.Windows.Visibility]::Visible
            $BtnNavFirewall.Background = $activeBrush
            $BtnNavFirewall.Foreground = $activeFg
            $WorkspaceTitle.Text = "Windows Defender Firewall Blocker"
            $WorkspaceSubtitle.Text = "Manage active outbound block rules and target custom executable binaries"
            Refresh-FirewallRulesList
        }
        "Settings" {
            $ViewSettings.Visibility = [System.Windows.Visibility]::Visible
            $BtnNavSettings.Background = $activeBrush
            $BtnNavSettings.Foreground = $activeFg
            $WorkspaceTitle.Text = "Quota Policies & System Daemon"
            $WorkspaceSubtitle.Text = "Configure daily/monthly cutoff thresholds, background polling, and Windows startup"
            Refresh-SettingsInputs
        }
    }
}

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

function Refresh-AdapterStatus {
    $sel = [string]$ComboAdapters.SelectedItem
    if (-not $sel) { $sel = $script:AppConfig.target_adapter }
    $SidebarAdapterLabel.Text = "Target: $sel"

    try {
        $adapter = Get-NetAdapter -Name $sel -ErrorAction SilentlyContinue
        if ($adapter) {
            if ($adapter.Status -eq "Up") {
                $TxtLinkStatus.Text = "● CONNECTED (UP)"
                $TxtLinkStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
                $BadgeLinkStatus.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#064E3B"))
                $TxtAdapterDetails.Text = "Status: Connected (Up) | Sentry active on $sel"
            } elseif ($adapter.Status -eq "Disabled") {
                $TxtLinkStatus.Text = "● DISABLED"
                $TxtLinkStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
                $BadgeLinkStatus.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#4C0519"))
                $TxtAdapterDetails.Text = "Status: Disabled | Network hardware is disabled"
            } else {
                $TxtLinkStatus.Text = "● $($adapter.Status.ToUpper())"
                $TxtLinkStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
                $BadgeLinkStatus.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#451A03"))
                $TxtAdapterDetails.Text = "Status: $($adapter.Status) on $sel"
            }
        } else {
            $TxtLinkStatus.Text = "● NOT FOUND"
            $TxtLinkStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
            $BadgeLinkStatus.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#4C0519"))
            $TxtAdapterDetails.Text = "Adapter '$sel' was not found on this system."
        }
    } catch {
        $TxtLinkStatus.Text = "● ERROR"
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

    # Live Throughput
    $rateBps = $script:CurrentThroughputBytesPerSec
    $speedStr = if ($rateBps -ge 1MB) {
        "$([math]::Round($rateBps / 1MB, 2)) MB/s"
    } else {
        "$([math]::Round($rateBps / 1KB, 1)) KB/s"
    }
    $TxtLiveSpeedTop.Text = $speedStr
    $TxtHeroSpeed.Text = $speedStr

    # 1. Daily Progress & Bar
    $dailyPercent = 0.0
    if ($dailyLimitGB -gt 0) {
        $dailyPercent = [math]::Round(($dayGB / $dailyLimitGB) * 100.0, 1)
    }
    $TxtDailyPercent.Text = "$dailyPercent%"
    $TxtDailyHero.Text = "$(Format-Bytes $dayBytes) / $dailyLimitGB GB"
    $dailyRemain = [math]::Max(0.0, [math]::Round($dailyLimitGB - $dayGB, 2))
    $TxtDailyRemaining.Text = "Remaining Today: $dailyRemain GB (Warning at $dailyWarnGB GB)"

    # Compute progress bar fill width (relative to container ~350px)
    $dailyClamp = [math]::Min(100.0, [math]::Max(0.0, $dailyPercent))
    $barDailyWidth = [math]::Max(6.0, (380.0 * ($dailyClamp / 100.0)))
    $BarDailyFill.Width = $barDailyWidth

    if ($dayGB -ge $dailyLimitGB) {
        $TxtDailyPercent.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
        $BarDailyFill.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
    } elseif ($dayGB -ge $dailyWarnGB) {
        $TxtDailyPercent.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
        $BarDailyFill.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
    } else {
        $TxtDailyPercent.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#38BDF8"))
        $grad = New-Object System.Windows.Media.LinearGradientBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString("#0284C7"),
            [System.Windows.Media.ColorConverter]::ConvertFromString("#38BDF8"),
            (New-Object System.Windows.Point(0,0)),
            (New-Object System.Windows.Point(1,0))
        )
        $BarDailyFill.Background = $grad
    }

    # 2. Monthly Progress & Bar
    $monthlyPercent = 0.0
    if ($monthlyLimitGB -gt 0) {
        $monthlyPercent = [math]::Round(($monthGB / $monthlyLimitGB) * 100.0, 1)
    }
    $TxtMonthlyPercent.Text = "$monthlyPercent%"
    $TxtMonthlyHero.Text = "$([math]::Round($monthGB, 2)) GB / $monthlyLimitGB GB"
    $monthlyRemain = [math]::Max(0.0, [math]::Round($monthlyLimitGB - $monthGB, 2))
    $TxtMonthlyRemaining.Text = "Remaining This Month: $monthlyRemain GB (Warning at $monthlyWarnGB GB)"

    $monthlyClamp = [math]::Min(100.0, [math]::Max(0.0, $monthlyPercent))
    $barMonthlyWidth = [math]::Max(6.0, (380.0 * ($monthlyClamp / 100.0)))
    $BarMonthlyFill.Width = $barMonthlyWidth

    if ($monthGB -ge $monthlyLimitGB) {
        $TxtMonthlyPercent.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
        $BarMonthlyFill.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F43F5E"))
    } elseif ($monthGB -ge $monthlyWarnGB) {
        $TxtMonthlyPercent.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
        $BarMonthlyFill.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
    } else {
        $TxtMonthlyPercent.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
        $gradM = New-Object System.Windows.Media.LinearGradientBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString("#059669"),
            [System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"),
            (New-Object System.Windows.Point(0,0)),
            (New-Object System.Windows.Point(1,0))
        )
        $BarMonthlyFill.Background = $gradM
    }

    # Tray Tooltip and Menu Labels
    $trayStr = "DataControl: $(Format-Bytes $dayBytes) / $dailyLimitGB GB ($dailyPercent%) - Sentry Active"
    if ($trayStr.Length -gt 63) { $trayStr = $trayStr.Substring(0, 63) }
    $NotifyIcon.Text = $trayStr

    $TrayItemStatusToday.Text = "Today: $(Format-Bytes $dayBytes) / $dailyLimitGB GB ($dailyPercent%)"
    $TrayItemStatusMonth.Text = "Month: $([math]::Round($monthGB, 2)) GB / $monthlyLimitGB GB ($monthlyPercent%)"

    # Refresh Top Apps preview on dashboard
    $topApps = $script:ProcStateCache.Values | Sort-Object -Property SpeedBps, SessionBytes -Descending | Select-Object -First 4
    $ListDashboardTopApps.Items.Clear()
    foreach ($item in $topApps) {
        $spStr = if ($item.SpeedBps -ge 1MB) { "$([math]::Round($item.SpeedBps / 1MB, 2)) MB/s" } elseif ($item.SpeedBps -ge 1KB) { "$([math]::Round($item.SpeedBps / 1KB, 1)) KB/s" } else { "0.0 KB/s" }
        $ListDashboardTopApps.Items.Add([PSCustomObject]@{
            Name         = $item.Name
            PID          = $item.PID
            Speed        = $spStr
            SessionBytes = Format-Bytes $item.SessionBytes
            Sockets      = $item.Connections
            Path         = $item.Path
        }) | Out-Null
    }
}

function Refresh-LiveAppsList {
    $filterText = $TxtLiveSearch.Text.Trim().ToLower()
    $ListLiveApps.Items.Clear()

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

        $ListLiveApps.Items.Add([PSCustomObject]@{
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

            $ListAppHistory.Items.Add([PSCustomObject]@{
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

    $TxtAnalyticsToday.Text = Format-Bytes $dayBytes
    $TxtAnalyticsTodaySub.Text = $dayKey
    $TxtAnalyticsMonth.Text = Format-Bytes $monthBytes
    $TxtAnalyticsMonthSub.Text = $dateNow.ToString("MMMM yyyy")
    $TxtAnalyticsYear.Text = Format-Bytes $yearBytes
    $TxtAnalyticsYearSub.Text = $yearKey

    $ListDailyHistory.Items.Clear()
    if ($script:DataHistory.daily) {
        $props = $script:DataHistory.daily.PSObject.Properties | Sort-Object -Property Name -Descending
        foreach ($prop in $props) {
            $bytes = [double]$prop.Value
            $ListDailyHistory.Items.Add([PSCustomObject]@{
                Date       = $prop.Name
                Formatted  = Format-Bytes $bytes
                Raw        = ($bytes.ToString("N0") + " bytes")
            }) | Out-Null
        }
    }
}

function Refresh-FirewallRulesList {
    $ListFirewallRules.Items.Clear()
    try {
        $rules = Get-NetFirewallRule -DisplayName "DataControl-Block-*" -ErrorAction SilentlyContinue
        foreach ($r in $rules) {
            $progPath = ""
            try {
                $filter = $r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
                if ($filter -and $filter.Program) { $progPath = $filter.Program }
            } catch {}

            $ListFirewallRules.Items.Add([PSCustomObject]@{
                RuleName    = $r.DisplayName
                ProgramPath = $progPath
                Action      = $r.Action.ToString()
            }) | Out-Null
        }
    } catch {}
}

function Refresh-SettingsInputs {
    $InputDailyLimit.Text = [string]$script:AppConfig.daily_limit_gb
    $InputDailyWarn.Text = [string]$script:AppConfig.daily_warning_gb
    $ChkSettingAutoDaily.IsChecked = [bool]$script:AppConfig.auto_disconnect_daily

    $InputMonthlyLimit.Text = [string]$script:AppConfig.monthly_limit_gb
    $InputMonthlyWarn.Text = [string]$script:AppConfig.warning_threshold_gb
    $ChkSettingAutoMonthly.IsChecked = [bool]$script:AppConfig.auto_disconnect

    $ChkSettingStartWithWindows.IsChecked = Test-StartupTaskEnabled
    $InputPollSeconds.Text = [string]$script:AppConfig.poll_frequency_seconds
}

function Toggle-TargetAdapterHardware {
    $target = [string]$ComboAdapters.SelectedItem
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

# ==============================================================================
# Event Handlers Setup
# ==============================================================================

# Navigation Handlers
$BtnNavDashboard.Add_Click({ Set-ActiveView "Dashboard" })
$BtnNavLiveApps.Add_Click({ Set-ActiveView "LiveApps" })
$BtnNavAppHistory.Add_Click({ Set-ActiveView "AppHistory" })
$BtnNavAnalytics.Add_Click({ Set-ActiveView "Analytics" })
$BtnNavFirewall.Add_Click({ Set-ActiveView "Firewall" })
$BtnNavSettings.Add_Click({ Set-ActiveView "Settings" })

# Adapter ComboBox Selection Changed
$ComboAdapters.Add_SelectionChanged({
    $selected = [string]$ComboAdapters.SelectedItem
    if ($selected -and $selected -ne $script:AppConfig.target_adapter) {
        $script:AppConfig.target_adapter = $selected
        Save-AppConfig $script:AppConfig
        Refresh-AdapterStatus
        Show-Toast "Target adapter set to: $selected"
    }
})

# Hardware Controls
$BtnSidebarToggleWifi.Add_Click({ Toggle-TargetAdapterHardware })
$BtnDisableWifiHero.Add_Click({
    $target = [string]$ComboAdapters.SelectedItem
    if (-not $target) { $target = $script:AppConfig.target_adapter }
    try {
        Disable-NetAdapter -Name $target -Confirm:$false -ErrorAction Stop
        Refresh-AdapterStatus
        Show-Toast "Adapter '$target' disabled." "#F43F5E"
    } catch { Show-Toast "Error: $($_.Exception.Message)" "#F43F5E" }
})
$BtnEnableWifiHero.Add_Click({
    $target = [string]$ComboAdapters.SelectedItem
    if (-not $target) { $target = $script:AppConfig.target_adapter }
    try {
        Enable-NetAdapter -Name $target -Confirm:$false -ErrorAction Stop
        Refresh-AdapterStatus
        Show-Toast "Adapter '$target' enabled." "#10B981"
    } catch { Show-Toast "Error: $($_.Exception.Message)" "#F43F5E" }
})

# Dashboard Cutoff Toggles
$ToggleDailyCutoff.Add_Click({
    $script:AppConfig.auto_disconnect_daily = [bool]$ToggleDailyCutoff.IsChecked
    Save-AppConfig $script:AppConfig
})
$ToggleMonthlyCutoff.Add_Click({
    $script:AppConfig.auto_disconnect = [bool]$ToggleMonthlyCutoff.IsChecked
    Save-AppConfig $script:AppConfig
})

# Live Apps Search & Refresh
$TxtLiveSearch.Add_TextChanged({ Refresh-LiveAppsList })
$BtnRefreshLive.Add_Click({ Refresh-LiveAppsList })

# Block Selected Live App
$BtnBlockLiveApp.Add_Click({
    $item = $ListLiveApps.SelectedItem
    if (-not $item) {
        [System.Windows.MessageBox]::Show("Please select an application from the list to block.", "No Selection", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    $appName = $item.Name
    $appPath = [string]$item.Path
    if (-not $appPath -or -not (Test-Path $appPath)) {
        [System.Windows.MessageBox]::Show("Could not resolve the executable path for $appName.", "Path Not Found", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($appPath)
    $ruleName = "DataControl-Block-$cleanName"

    try {
        Remove-NetFirewallRule -DisplayName $ruleName -Confirm:$false -ErrorAction SilentlyContinue
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Name $ruleName `
            -Direction Outbound `
            -Program $appPath `
            -Action Block `
            -Profile Any `
            -Description "Blocked by DataControl Live Sentry" `
            -ErrorAction Stop | Out-Null

        $TxtLiveBlockStatus.Text = "Blocked in Firewall: $appName"
        Show-Toast "Application '$appName' blocked in Windows Defender Firewall!" "#10B981"
    } catch {
        Show-Toast "Firewall Error: $($_.Exception.Message)" "#F43F5E"
    }
})

# Block Selected History App
$BtnBlockHistoryApp.Add_Click({
    $item = $ListAppHistory.SelectedItem
    if (-not $item) {
        [System.Windows.MessageBox]::Show("Please select an application from history to block.", "No Selection", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    $appName = $item.Name
    $appPath = [string]$item.Path
    if (-not $appPath -or -not (Test-Path $appPath)) {
        [System.Windows.MessageBox]::Show("Could not resolve path for $appName.", "Path Not Found", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($appPath)
    $ruleName = "DataControl-Block-$cleanName"

    try {
        Remove-NetFirewallRule -DisplayName $ruleName -Confirm:$false -ErrorAction SilentlyContinue
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Name $ruleName `
            -Direction Outbound `
            -Program $appPath `
            -Action Block `
            -Profile Any `
            -Description "Blocked by DataControl App History" `
            -ErrorAction Stop | Out-Null

        $TxtHistoryBlockStatus.Text = "Blocked: $appName"
        Show-Toast "Application '$appName' blocked in Firewall!" "#10B981"
    } catch {
        Show-Toast "Firewall Error: $($_.Exception.Message)" "#F43F5E"
    }
})

# Reset App History
$BtnResetAppHistory.Add_Click({
    $res = [System.Windows.MessageBox]::Show("Are you sure you want to reset the per-application consumption history?", "Confirm Reset", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($res -eq [System.Windows.MessageBoxResult]::Yes) {
        $script:AppHistory = New-Object PSCustomObject
        Save-AppHistory $script:AppHistory
        Refresh-AppHistoryList
        Show-Toast "App history ledger reset to zero."
    }
})

# Reset Current Month
$BtnResetCurrentMonth.Add_Click({
    $curMonthName = (Get-Date).ToString("MMMM yyyy")
    $res = [System.Windows.MessageBox]::Show("Reset monthly consumption metrics to 0 GB for $curMonthName?`n`nRecommended when your billing cycle renews.", "Confirm Billing Reset", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
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

# Firewall Rule Management
$BtnBrowseExe.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Executable files (*.exe)|*.exe|All files (*.*)|*.*"
    $ofd.Title = "Select Application to Block"
    $ofd.InitialDirectory = [Environment]::GetFolderPath("ProgramFiles")
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $TxtFirewallExePath.Text = $ofd.FileName
    }
    $ofd.Dispose()
})

$BtnBlockExeManual.Add_Click({
    $exePath = $TxtFirewallExePath.Text.Trim()
    if (-not $exePath -or -not (Test-Path $exePath)) {
        [System.Windows.MessageBox]::Show("Please select a valid executable (.exe) first.", "Invalid File", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $fileName = [System.IO.Path]::GetFileName($exePath)
    $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($exePath)
    $ruleName = "DataControl-Block-$cleanName"

    try {
        Remove-NetFirewallRule -DisplayName $ruleName -Confirm:$false -ErrorAction SilentlyContinue
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Name $ruleName `
            -Direction Outbound `
            -Program $exePath `
            -Action Block `
            -Profile Any `
            -Description "Blocked by DataControl Outbound Traffic Blocker" `
            -ErrorAction Stop | Out-Null

        $TxtFirewallExePath.Text = ""
        Refresh-FirewallRulesList
        Show-Toast "Successfully blocked: $fileName" "#10B981"
    } catch {
        Show-Toast "Firewall Error: $($_.Exception.Message)" "#F43F5E"
    }
})

$BtnUnblockRule.Add_Click({
    $item = $ListFirewallRules.SelectedItem
    if (-not $item) {
        [System.Windows.MessageBox]::Show("Please select a firewall rule from the list to unblock.", "No Selection", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    $ruleName = [string]$item.RuleName
    try {
        Remove-NetFirewallRule -DisplayName $ruleName -Confirm:$false -ErrorAction Stop
        Refresh-FirewallRulesList
        Show-Toast "Rule removed: $ruleName" "#10B981"
    } catch {
        Show-Toast "Error removing rule: $($_.Exception.Message)" "#F43F5E"
    }
})

$BtnRefreshRules.Add_Click({
    Refresh-FirewallRulesList
    Show-Toast "Firewall rules refreshed."
})

# Save All Settings
$BtnSaveAllSettings.Add_Click({
    try {
        $dailyLimit = [double]$InputDailyLimit.Text
        $dailyWarn  = [double]$InputDailyWarn.Text
        $monthlyLimit = [double]$InputMonthlyLimit.Text
        $monthlyWarn  = [double]$InputMonthlyWarn.Text
        $pollSec = [int]$InputPollSeconds.Text

        if ($dailyLimit -gt 0) { $script:AppConfig.daily_limit_gb = $dailyLimit }
        if ($dailyWarn -gt 0) { $script:AppConfig.daily_warning_gb = $dailyWarn }
        if ($monthlyLimit -gt 0) { $script:AppConfig.monthly_limit_gb = $monthlyLimit }
        if ($monthlyWarn -gt 0) { $script:AppConfig.warning_threshold_gb = $monthlyWarn }
        if ($pollSec -gt 0) { $script:AppConfig.poll_frequency_seconds = $pollSec }

        $script:AppConfig.auto_disconnect_daily = [bool]$ChkSettingAutoDaily.IsChecked
        $script:AppConfig.auto_disconnect = [bool]$ChkSettingAutoMonthly.IsChecked

        $isTaskWanted = [bool]$ChkSettingStartWithWindows.IsChecked
        Set-StartupTaskEnabled $isTaskWanted | Out-Null

        Save-AppConfig $script:AppConfig
        Refresh-UsageDisplay
        Show-Toast "All settings saved and applied successfully!" "#10B981"
    } catch {
        Show-Toast "Invalid numeric input: $($_.Exception.Message)" "#F43F5E"
    }
})

# Sidebar Exit Button
$BtnSidebarExit.Add_Click({
    $res = [System.Windows.MessageBox]::Show("Do you want to completely exit DataControl?`n`nTo keep monitoring data in the background, click No and simply close the window [X].", "Exit DataControl", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($res -eq [System.Windows.MessageBoxResult]::Yes) {
        $script:AllowRealExit = $true
        $Window.Close()
    }
})

# Intercept Window Close [X] -> Hide to Tray Sentry
$Window.Add_Closing({
    param($s, $e)

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

    # Real Exit Cleanup
    $script:PollTimer.Stop()
    $NotifyIcon.Visible = $false
    $NotifyIcon.Dispose()
    Save-DataHistory $script:DataHistory
    Save-AppHistory $script:AppHistory
    [System.Windows.Application]::Current.Shutdown()
})

# ==============================================================================
# Dispatcher Timer & Application Boot
# ==============================================================================
$script:PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollSeconds = [int]$script:AppConfig.poll_frequency_seconds
if ($pollSeconds -lt 1) { $pollSeconds = 3 }
$script:PollTimer.Interval = [TimeSpan]::FromSeconds($pollSeconds)

$script:PollTimer.Add_Tick({
    $target = [string]$ComboAdapters.SelectedItem
    if (-not $target) { $target = $script:AppConfig.target_adapter }

    Update-NetworkMetrics -AdapterName $target
    Refresh-AdapterStatus
    Refresh-UsageDisplay
    Check-EnforcementRules

    if ($ViewLiveApps.Visibility -eq [System.Windows.Visibility]::Visible) {
        Refresh-LiveAppsList
    }
})

# Initial Form Preparation
$Window.Add_SourceInitialized({
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($Window)
    [Win11Native]::ApplyWin11Aesthetics($helper.Handle)
})

$Window.Add_Loaded({
    Refresh-AdapterList
    Refresh-AdapterStatus
    Update-NetworkMetrics
    Refresh-UsageDisplay
    Refresh-LiveAppsList
    Refresh-AppHistoryList
    Refresh-FirewallRulesList
    Refresh-SettingsInputs

    $ToggleDailyCutoff.IsChecked = [bool]$script:AppConfig.auto_disconnect_daily
    $ToggleMonthlyCutoff.IsChecked = [bool]$script:AppConfig.auto_disconnect

    Set-ActiveView "Dashboard"
    $script:PollTimer.Start()
})

# Create WPF Application instance
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
