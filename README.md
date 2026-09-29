# DataControl: Windows 11 Data Control System (v3.5 Ultra-Modern WPF)

An autonomous, ultra-modern network metering, persistent usage tracking, and automated cutoff enforcement system tailored for Windows 10 and Windows 11.

---

## 🎯 Target Audience & Purpose

DataControl is engineered specifically for users operating on **cellular hotspots (MiFi), mobile tethering, satellite internet, or metered Wi-Fi connections**. On modern operating systems, background cloud sync services, OS telemetry, browser pre-fetching, and background application updates (such as Windows Update) can rapidly deplete limited data quotas without warning.

DataControl provides **dual daily and monthly quota enforcement**, **live per-application bandwidth metering**, **per-application historical accounting**, **automated shutoff enforcement**, and **one-click outbound firewall isolation** to halt data leaks at the source.

---

## ✨ Key Features & UX Innovations

- **Ultra-Modern Windows 11 Fluent 2 UI**: Hardware-accelerated WPF vector graphics with deep obsidian theme, rounded card containers, crisp Segoe UI typography, and native DWM dark title bar.
- **Desktop-Friendly & Fully Responsive**:
  - Resizable and maximizable window with fluid proportional grids (`*`-sizing) that expand beautifully on 1080p, 1440p, and 4K displays.
  - Smooth pixel-based mouse-wheel scrolling on every workspace via custom minimalist dark scrollbars.
- **Minimize-to-Tray Background Resident**:
  - Closing the window (`[X]`) hides the interface and keeps the monitoring sentry running seamlessly in the Windows Notification Area.
  - Left-clicking or double-clicking the tray icon immediately restores the dashboard.
  - Real-time tray tooltip updates dynamically with today's quota usage, remaining data, and active network interface.
  - Rich tray context menu provides one-click access to the dashboard, quick adapter toggle, and full exit.
- **Modern Pill Toggle Switches**: Replaces dated checkbox boxes with sleek, sliding iOS/Fluent-style pill toggle switches.
- **Dual Daily & Monthly Quotas**: Independent controls for daily allowances (e.g. 2.0 GB) and monthly limits (e.g. 16.0 GB) with dynamic linear gradient meters (Sky Blue ➔ Amber ➔ Rose Red), soft warning alerts, and automated cutoffs.
- **Live Application Sentry**: Real-time monitoring of all active network processes (e.g. Chrome, Windows Update, Steam, Discord). Displays live transfer speeds (`KB/s` / `MB/s`), session totals, active socket counts, and executable paths.
- **Direct One-Click App Firewall Blocking**: Spot an unexpected application consuming your bandwidth? Click **"🚫 Block Selected App in Firewall"** directly from the live or historical list to instantly isolate it with a Windows Defender Outbound Firewall rule.
- **Application Consumption Leaderboard**: Persistent historical tracking (`app_history.json`) of data consumed by each application across reboots.
- **Reboot- & Disconnect-Resilient Delta Engine**: Tracks interface byte statistics directly via `Get-NetAdapterStatistics`. Detects counter rollovers, interface disconnects, and system reboots, preventing false spikes or data drops.
- **Data Privacy by Design**: All personal usage metrics, daily logs, and configuration remain exclusively on your local machine (`.gitignore` protected) and are never shared to public GitHub repositories.
- **Windows Startup Integration**: Seamlessly configure DataControl to run automatically at user logon with highest Administrator privileges via Windows Task Scheduler (no repeated UAC prompts).
- **Billing Cycle Reset**: Reset monthly quota counters with a single click and confirmation modal when your mobile carrier or ISP billing cycle renews.
- **Native GUI Launcher**: Includes compiled native executable [`DataControl.exe`](file:///d:/web/dataControle/DataControl.exe) with embedded custom sentry shield icon and zero console flash.

---

## 📋 System Requirements

| Component | Minimum Requirement | Recommended |
|---|---|---|
| **Operating System** | Windows 10 (Build 19041+) | Windows 11 (22H2 or higher) |
| **Framework** | .NET Framework 4.7.2+ (WPF, XAML) | Built-in on Windows 10/11 |
| **PowerShell** | Windows PowerShell 5.1 | Built-in on Windows 10/11 |
| **Privileges** | Administrator (Required for NetAdapter & Firewall cmdlets) | UAC Auto-Elevation Supported |

---

## 🚀 Running the Program & Desktop Workflow

### 1. Launch via Desktop or Start Menu (Recommended)
Double-click the **DataControl** shortcut on your Desktop or open the Windows Start Menu and type **DataControl**.
- Launches instantly via native [`DataControl.exe`](file:///d:/web/dataControle/DataControl.exe) with **zero console window flash**.
- Sits in the **Windows System Tray** with the custom shield icon.

### 2. Launch from PowerShell / Terminal
Open PowerShell as Administrator (or let the script self-elevate) and run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\DataControl.ps1
```

### 3. Background Resident & System Tray
- Whenever you close the window (`[X]`), DataControl automatically hides and stays active in the background as a resident sentry.
- Look for the shield icon in your taskbar notification area.
- Hover over the tray icon to see a real-time tooltip with your current data consumption.
- Left-click or double-click the icon anytime to bring the window back to the front.
- To completely exit the application, right-click the tray icon and select **Exit DataControl** (or click **Exit DataControl** in the sidebar).

---

## ⚡ Enabling Automatic Startup (Run on Windows Boot)

Because DataControl requires Administrator privileges to control network adapters and firewall rules, standard startup shortcuts trigger a UAC confirmation prompt on every login. 

DataControl uses **Windows Task Scheduler with Highest Privileges** to run automatically at logon completely silently without any UAC prompts.

### Method A: Through the Application GUI (Easiest)
1. Open DataControl and navigate to **⚙️ Settings**.
2. Toggle the switch:
   ☑ **Start with Windows Logon (Runs silently in background with highest Administrator privileges)**
3. Click **💾 Save All Quota & System Settings**.

### Method B: Via PowerShell Helper Script
To register the startup task via command line:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Register-StartupTask.ps1
```

To remove the startup task at any time:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Unregister-StartupTask.ps1
```

---

## 📁 Project Architecture & File Organization

The codebase is organized into modular layers to ensure high maintainability, clear separation of concerns, and clean navigation:

```
dataControle/
├── assets/
│   └── DataControl.ico             # High-resolution sentry shield icon
├── scripts/
│   ├── Install-Shortcuts.ps1        # Desktop & Start Menu shortcut installer
│   ├── Uninstall-Shortcuts.ps1      # Shortcut uninstaller
│   ├── Register-StartupTask.ps1     # Elevated silent startup task registrar
│   └── Unregister-StartupTask.ps1   # Startup task remover
├── src/
│   ├── core/
│   │   ├── NativeMethods.ps1        # Win32 DWM dark title bar & Process IO API
│   │   ├── NetworkEngine.ps1        # Interface delta calculation & throughput metering
│   │   ├── ProcessTracker.ps1       # Per-process network I/O & socket tracking
│   │   └── Enforcement.ps1          # Daily/Monthly warning & auto-cutoff rules
│   ├── firewall/
│   │   └── FirewallManager.ps1      # Windows Defender Firewall block/unblock cmdlets
│   ├── storage/
│   │   └── ConfigManager.ps1        # JSON config & data/app history persistence
│   └── ui/
│       ├── MainWindow.xaml          # Fluent 2 Dark Mode UI markup (pure XAML)
│       └── UIController.ps1         # View routing, toast alerts, list binding
├── .gitignore                       # Git exclusions (privacy protection)
├── config.example.json              # Public template configuration
├── DataControl.exe                  # Compiled native launcher binary
├── DataControl.ps1                  # Main application bootstrapper
├── Launcher.cs                      # C# launcher source code
└── README.md                        # Documentation & architecture guide
```

---

## 🖥️ Workspaces Overview

The application features a modern Windows 11 Fluent 2 Obsidian interface organized into 6 dedicated workspaces accessible via the left navigation rail:

### 1. 📊 Dashboard
- **Target Network Adapter**: Select active wireless or wired adapters (`Wi-Fi`, `Ethernet`, etc.).
- **Link State & Real-Time Speed**: Displays link status (`Connected`, `Disabled`, etc.) and live transfer speeds (`KB/s` / `MB/s`).
- **Daily Quota Card**: Visual gradient progress meter, used vs. limit readouts, remaining data counter, and auto-cutoff toggle.
- **Monthly Quota Card**: Visual gradient progress meter, monthly usage, remaining data counter, and auto-cutoff toggle.
- **Top Live Consumers Preview**: Mini-leaderboard showing top active bandwidth-consuming processes right on the dashboard.
- **Hardware Controls**: Instant "Disable Adapter" and "Enable Adapter" buttons.

### 2. ⚡ Live Apps
- **Active Process Table**: Lists all running applications with open TCP/UDP sockets.
- **Real-Time Throughput**: Shows live speed (`KB/s` / `MB/s`) and session data consumed.
- **Live Search Filter**: Quickly find specific apps (e.g., `update`, `chrome`, `steam`).
- **One-Click Firewall Block**: Select any app and click **"🚫 Block Selected App in Firewall"** to isolate it immediately.

### 3. 📈 App History
- **Consumption Leaderboard**: Displays top bandwidth-consuming applications over time.
- **Historical Records**: Total data consumed and last active timestamps per application.
- **Direct Block Action**: Block high-bandwidth background apps directly from the historical list.
- **Reset App History**: Clear application tracking stats with a single click.

### 4. 📅 Analytics
- **Summary Cards**: Quick-glance totals for **Today**, **This Month**, and **This Year**.
- **Daily Usage Log**: Detailed list of data consumed for each recorded calendar date.
- **Billing Cycle Synchronization**: "Reset Current Month" action button with confirmation dialog for carrier renewal dates.

### 5. 🛡️ Firewall Rules
- **Executable Picker**: Select any `.exe` using the Windows file dialog.
- **Block Outbound Access**: Automatically applies an outbound block rule in Windows Defender Firewall (`DataControl-Block-[AppName]`).
- **Active Rules Management**: Displays all active DataControl rules with an "Unblock Application" button to cleanly remove them.

### 6. ⚙️ Settings
- Editable Daily Quota (GB) and Daily Warning Threshold (GB).
- Editable Monthly Quota (GB) and Monthly Warning Threshold (GB).
- Auto-disconnect toggle switches for daily and monthly limits.
- Background polling frequency configuration.
- Start with Windows logon integration toggle.

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
