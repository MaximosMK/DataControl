# DataControl: Windows 11 Data Control System

An autonomous, lightweight network metering, persistent usage tracking, and automated shutoff enforcement system tailored for Windows 10 and Windows 11.

---

## 🎯 Target Audience & Purpose

DataControl is engineered specifically for users who operate on **cellular hotspots, mobile tethering, satellite internet, or metered Wi-Fi connections**. On modern operating systems, background cloud sync services, OS telemetry, browser pre-fetching, and background application updates can rapidly deplete limited data quotas without warning.

DataControl provides **real-time hardware-level network metering**, **persistent historical accounting**, **automated shutoff enforcement** upon reaching data quotas, and a **one-click outbound firewall application blocker** to halt data leaks at the source.

---

## ✨ Key Features

- **Reboot- & Disconnect-Resilient Delta Engine**: Tracks interface byte statistics directly via `Get-NetAdapterStatistics`. Detects counter rollovers, interface disconnects, and system reboots, preventing false spikes or data drops.
- **Persistent Quota Tracking**: Continuously aggregates data consumption into daily (`YYYY-MM-DD`), monthly (`YYYY-MM`), and yearly (`YYYY`) records stored in `data_history.json`.
- **Real-Time Bandwidth Monitor**: Live transfer speed calculation (KB/s and MB/s) updated at configurable intervals.
- **Automated Cut-Off Enforcement**: Configurable monthly limit (GB) and warning threshold (GB). When the hard quota is met, DataControl can automatically disconnect the network adapter to prevent overage charges.
- **Windows System Tray & Balloon Notifications**: Provides warning notifications when approaching limits and critical alerts when automated shutoff engages.
- **Application Firewall Blocker**: Browse and select any `.exe` application to immediately create dedicated Windows Defender Outbound Firewall rules (`DataControl-Block-*`), cutting off bandwidth-heavy applications with a single click.
- **Billing Cycle Reset**: Reset the monthly quota counter with a single click and confirmation modal when your mobile carrier or ISP billing cycle renews.
- **Self-Elevating Architecture**: Automatically detects UAC administrator privileges and prompts for elevation if started from a standard user shell.

---

## 📋 System Requirements

| Component | Minimum Requirement | Recommended |
|---|---|---|
| **Operating System** | Windows 10 (Build 19041+) | Windows 11 (22H2 or higher) |
| **PowerShell** | Windows PowerShell 5.1 | PowerShell 7+ or 5.1 |
| **Privileges** | Administrator (Required for NetAdapter & Firewall cmdlets) | UAC Auto-Elevation Supported |
| **Dependencies** | .NET Framework 4.7.2+ (`System.Windows.Forms`, `System.Drawing`) | Pre-installed on Windows 10/11 |

---

## 🚀 Quick Start & Launch Instructions

### Option 1: Standard PowerShell Launch
Open PowerShell as Administrator (or let the script self-elevate) and run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\DataControl.ps1
```

### Option 2: Run via Command Prompt / Shortcut Target
You can create a desktop shortcut or run directly from `cmd.exe`:

```cmd
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "D:\web\dataControle\DataControl.ps1"
```

---

## 🖥️ User Interface Overview

The application features a modern 650x640 Windows 11 Slate Dark interface organized into three primary workspaces:

### 1. Dashboard & Live Controls
- **Target Network Adapter**: Select active wireless or wired adapters (`Wi-Fi`, `Ethernet`, etc.).
- **Link State & Real-Time Speed**: Displays link status (`Connected`, `Disabled`, etc.) and live transfer speeds (`KB/s` / `MB/s`).
- **Quota Progress Gauge**: Visual progress bar tracking consumption against your monthly data allowance.
- **Threshold Controls**: Adjust Monthly Quota (GB) and Warning Threshold (GB) with instant persistence.
- **Automated Shutoff Toggle**: Enable/disable automated adapter shutoff.
- **Manual Interface Override**: Immediate "Disable Wi-Fi" and "Enable Wi-Fi" buttons.

### 2. Usage History & Analytics
- **Summary Cards**: Quick-glance totals for **Today**, **This Month**, and **This Year**.
- **Daily Usage Log**: Detailed list of data consumed for each recorded calendar date.
- **Billing Cycle Synchronization**: "Reset Current Month" action button with confirmation dialog for carrier renewal dates.

### 3. Application Firewall Blocker
- **Executable Picker**: Select any `.exe` using Windows file dialog.
- **Block Outbound Access**: Automatically applies an outbound block rule in Windows Defender Firewall (`DataControl-Block-[AppName]`).
- **Active Rules Management**: Displays all active DataControl rules with an "Unblock Application" button to cleanly remove them.

---

## ⚙️ Configuration Files

### `config.json`
Stores user settings and enforcement thresholds:

```json
{
  "target_adapter": "Wi-Fi",
  "monthly_limit_gb": 16.0,
  "warning_threshold_gb": 14.0,
  "auto_disconnect": true,
  "poll_frequency_seconds": 3
}
```

- `target_adapter`: Name of the network interface to monitor (e.g., `"Wi-Fi"`).
- `monthly_limit_gb`: Hard data ceiling in gigabytes before automated enforcement triggers.
- `warning_threshold_gb`: Soft alert threshold in gigabytes.
- `auto_disconnect`: When `true`, disables the network adapter upon reaching `monthly_limit_gb`.
- `poll_frequency_seconds`: Sampling interval in seconds for throughput calculation and quota evaluation.

### `data_history.json`
Maintains persistent usage accounting across system reboots:

```json
{
  "last_raw_total_bytes": 0,
  "daily": {
    "2026-09-29": 104857600
  },
  "monthly": {
    "2026-09": 104857600
  },
  "yearly": {
    "2026": 104857600
  }
}
```

---

## 🛡️ Windows Defender Firewall Management

DataControl isolates application outbound network traffic using Windows Defender Firewall with Advanced Security cmdlets:

- **Create Rule**: `New-NetFirewallRule -DisplayName "DataControl-Block-[App]" -Direction Outbound -Program "[Path]" -Action Block -Profile Any`
- **Audit Rules**: `Get-NetFirewallRule -DisplayName "DataControl-Block-*"`
- **Remove Rule**: `Remove-NetFirewallRule -DisplayName "[RuleName]"`

All rules generated by the tool are safely prefixed with `DataControl-Block-` so they can be inspected, refreshed, or removed without impacting standard Windows firewall policies.

---

## 🔍 Troubleshooting

| Issue | Cause | Solution |
|---|---|---|
| **Prompted for Administrator permission** | Network adapter state control and firewall modification require elevated tokens. | Accept the UAC elevation prompt when starting the script. |
| **No adapter statistics shown** | Selected adapter is disconnected or misnamed in `config.json`. | Select your active adapter from the dropdown on the Dashboard tab. |
| **Adapter disabled unexpectedly** | Monthly quota reached and `auto_disconnect` was set to `true`. | Click "Enable Wi-Fi" on the Dashboard or increase your Monthly Quota in settings. |
| **Firewall rule creation fails** | Executable path contains invalid characters or does not exist. | Ensure the target application path is a valid `.exe` on a local drive. |

---

## 📄 License
This project is open-source and intended for personal and commercial data governance on Windows systems.
