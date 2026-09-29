# DataControl: Windows 11 Data Control System (v2.0)

An autonomous, lightweight network metering, persistent usage tracking, and automated shutoff enforcement system tailored for Windows 10 and Windows 11.

---

## 🎯 Target Audience & Purpose

DataControl is engineered specifically for users operating on **cellular hotspots (MiFi), mobile tethering, satellite internet, or metered Wi-Fi connections**. On modern operating systems, background cloud sync services, OS telemetry, browser pre-fetching, and background application updates (such as Windows Update) can rapidly deplete limited data quotas without warning.

DataControl provides **dual daily and monthly quota enforcement**, **live per-application bandwidth metering**, **per-application historical accounting**, **automated shutoff enforcement**, and **one-click outbound firewall isolation** to halt data leaks at the source.

---

## ✨ Key Features

- **Dual Daily & Monthly Quotas**: Independent controls for daily allowances (e.g. 2.0 GB) and monthly limits (e.g. 16.0 GB) with individual progress gauges, soft warning alerts, and automated cutoffs.
- **Live Application Sentry**: Real-time monitoring of all active network processes (e.g. Chrome, Windows Update / `svchost.exe`, Steam, Discord). Displays live transfer speeds (`KB/s` / `MB/s`), session totals, active socket counts, and executable paths.
- **Direct One-Click App Firewall Blocking**: Spot an unexpected application consuming your bandwidth? Click **"🚫 Block Selected App in Firewall"** directly from the live list to instantly isolate it with a Windows Defender Outbound Firewall rule.
- **Application Consumption Leaderboard**: Persistent historical tracking (`app_history.json`) of data consumed by each application over time, making it easy to identify background bandwidth hogs.
- **Reboot- & Disconnect-Resilient Delta Engine**: Tracks interface byte statistics directly via `Get-NetAdapterStatistics`. Detects counter rollovers, interface disconnects, and system reboots, preventing false spikes or data drops.
- **Data Privacy by Design**: All personal usage metrics, daily logs, and configuration remain exclusively on your local machine (`.gitignore` protected) and are never shared to public GitHub repositories.
- **Windows System Tray & Background Sentry**: Runs silently in the Windows Notification Area. Double-clicking the tray icon restores the dashboard, while clicking the minimize button sends it back to the tray.
- **Windows Startup Integration**: Seamlessly configure DataControl to run automatically at user logon with highest Administrator privileges via Windows Task Scheduler (no repeated UAC prompts).
- **Billing Cycle Reset**: Reset monthly quota counters with a single click and confirmation modal when your mobile carrier or ISP billing cycle renews.
- **Native GUI Launcher**: Includes compiled native executable [`DataControl.exe`](file:///d:/web/dataControle/DataControl.exe) with embedded custom sentry shield icon and zero console flash.

---

## 📋 System Requirements

| Component | Minimum Requirement | Recommended |
|---|---|---|
| **Operating System** | Windows 10 (Build 19041+) | Windows 11 (22H2 or higher) |
| **PowerShell** | Windows PowerShell 5.1 | PowerShell 7+ or 5.1 |
| **Privileges** | Administrator (Required for NetAdapter & Firewall cmdlets) | UAC Auto-Elevation Supported |
| **Dependencies** | .NET Framework 4.7.2+ (`System.Windows.Forms`, `System.Drawing`) | Pre-installed on Windows 10/11 |

---

## 🚀 Running the Program & Background Execution

### 1. Run via Desktop or Start Menu (Recommended)
Double-click the **DataControl** shortcut on your Desktop or open the Windows Start Menu and type **DataControl**.
- Launches instantly via native [`DataControl.exe`](file:///d:/web/dataControle/DataControl.exe) with **zero console window flash**.
- Sits in the **Windows System Tray** with the custom shield icon.

### 2. Run from PowerShell / Terminal
Open PowerShell as Administrator (or let the script self-elevate) and run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\DataControl.ps1
```

### 3. Minimize to Background
Whenever DataControl is open, clicking the **Minimize (`_`)** button automatically hides the window and sends it directly to the system tray so your taskbar stays clutter-free. Double-click the shield tray icon or right-click ➔ **Open DataControl** anytime to bring it back.

---

## ⚡ Enabling Automatic Startup (Run on Windows Boot)

Because DataControl requires Administrator privileges to control network adapters and firewall rules, standard startup shortcuts trigger a UAC confirmation prompt on every login. 

DataControl uses **Windows Task Scheduler with Highest Privileges** to run automatically at logon completely silently without any UAC prompts.

### Method A: Through the Application GUI (Easiest)
1. Open DataControl.
2. In **Tab 1 (Dashboard & Quotas)**, check the box:
   ☑ **Run at Windows Startup (Runs silently in background with highest Administrator privileges)**
3. Click **Save All Quota Settings**.
*(Alternatively, right-click the tray icon and toggle **Start with Windows**).*

### Method B: Via PowerShell Helper Script
To register the startup task via command line:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Register-StartupTask.ps1
```

To remove the startup task at any time:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Unregister-StartupTask.ps1
```

---

## 🖥️ User Interface Overview (5 Dedicated Workspaces)

The application features a modern 780x720 Windows 11 Slate Dark interface organized into five workspaces:

### 1. Dashboard & Quotas
- **Target Network Adapter**: Select active wireless or wired adapters (`Wi-Fi`, `Ethernet`, etc.).
- **Link State & Real-Time Speed**: Displays link status (`Connected`, `Disabled`, etc.) and live transfer speeds (`KB/s` / `MB/s`).
- **Daily Quota Card**: Visual progress gauge and human-readable counter for today's data allowance.
- **Monthly Quota Card**: Visual progress gauge and counter for monthly allowance.
- **Dual Quota Controls**: Set Daily Limit (GB), Daily Warning (GB), Monthly Limit (GB), and Monthly Warning (GB).
- **Automated Cutoff Toggles**: Separate switches for daily shutoff and monthly shutoff.
- **Manual Hardware Overrides**: Immediate "Disable Wi-Fi" and "Enable Wi-Fi" buttons.

### 2. Live App Sentry
- **Active Process Table**: Lists all running applications with open TCP/UDP sockets.
- **Real-Time Throughput**: Shows live speed (`KB/s` / `MB/s`) and session data consumed.
- **Live Search Filter**: Quickly find specific apps (e.g., `update`, `chrome`, `steam`).
- **One-Click Firewall Block**: Select any app and click **"🚫 Block Selected App in Firewall"** to isolate it immediately.

### 3. App Usage History
- **Consumption Leaderboard**: Displays top bandwidth-consuming applications over time.
- **Historical Records**: Total data consumed and last active timestamps per application.
- **Direct Block Action**: Block high-bandwidth background apps directly from the historical list.
- **Reset App History**: Clear application tracking stats with a single click.

### 4. Global Analytics
- **Summary Cards**: Quick-glance totals for **Today**, **This Month**, and **This Year**.
- **Daily Usage Log**: Detailed list of data consumed for each recorded calendar date.
- **Billing Cycle Synchronization**: "Reset Current Month" action button with confirmation dialog for carrier renewal dates.

### 5. Firewall Blocker
- **Executable Picker**: Select any `.exe` using the Windows file dialog.
- **Block Outbound Access**: Automatically applies an outbound block rule in Windows Defender Firewall (`DataControl-Block-[AppName]`).
- **Active Rules Management**: Displays all active DataControl rules with an "Unblock Application" button to cleanly remove them.

---

## 🔒 Personal Data Privacy & Security

To ensure complete privacy:
- Your personal network statistics (`data_history.json`), per-process usage logs (`app_history.json`), and custom configurations (`config.json`) are automatically ignored by Git and **never uploaded to GitHub**.
- The repository only tracks source code, scripts, documentation, and the default template [`config.example.json`](file:///d:/web/dataControle/config.example.json).

---

## 🛡️ Windows Defender Firewall Management

DataControl isolates application outbound network traffic using Windows Defender Firewall with Advanced Security cmdlets:

- **Create Rule**: `New-NetFirewallRule -DisplayName "DataControl-Block-[App]" -Direction Outbound -Program "[Path]" -Action Block -Profile Any`
- **Audit Rules**: `Get-NetFirewallRule -DisplayName "DataControl-Block-*"`
- **Remove Rule**: `Remove-NetFirewallRule -DisplayName "[RuleName]"`

All rules generated by the tool are safely prefixed with `DataControl-Block-` so they can be inspected, refreshed, or removed without impacting standard Windows firewall policies.

---

## 📄 License
This project is open-source and intended for personal and commercial data governance on Windows systems.
