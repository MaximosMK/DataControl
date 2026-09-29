# 🛡️ DataControl: Windows 11 Outbound Traffic Sentry & Privacy Shield

[![Platform](https://img.shields.io/badge/Platform-Windows%2011%20%7C%20Windows%2010-0078D4?logo=windows&logoColor=white)](https://microsoft.com/windows)
[![Architecture](https://img.shields.io/badge/Architecture-WPF%20%7C%20Win32%20NDIS%20%7C%20PowerShell-38BDF8)](https://github.com/MaximosMK/DataControl)
[![Security](https://img.shields.io/badge/Security-Zero--Trust%20Egress%20%7C%20Fail--Secure-10B981)](#-core-capabilities)
[![Privacy](https://img.shields.io/badge/Privacy-100%25%20Offline%20%7C%20Zero%20Telemetry-A855F7)](#-privacy-first--zero-telemetry-guarantee)
[![License](https://img.shields.io/badge/License-MIT-F59E0B)](#-license)

**DataControl** is an open-source, hardware-integrated endpoint network governance and outbound data sentry system for Windows 11 and Windows 10. It replaces the default operating system model of silent, unconstrained outbound internet access with an active **Zero-Trust Privacy & Data Governance Framework**.

With DataControl, you gain complete visibility over every byte leaving your computer. Instantly discover which background applications are using your bandwidth, surgically isolate rogue software in Windows Defender Firewall, set enforceable daily and monthly limits, and protect your digital privacy without needing complex networking knowledge.

---

## ❓ The Problem: Why Windows Users Need DataControl

Modern desktop operating systems and third-party software operate on an **implicit-trust model**: once an application runs on your PC, Windows grants it unrestricted permission to connect to the internet, open background sockets, and send or receive data without your knowledge or consent.

For everyday users, privacy-conscious individuals, remote professionals, and anyone on a limited internet plan, this creates major problems:

1. **Silent Background Telemetry & Data Leaks**: 
   Applications continuously transmit diagnostic pings, analytics beacons, behavioral profiles, and unannounced telemetry to remote cloud servers in the background while you work.
2. **Hidden Bandwidth Depletion**: 
   Cloud synchronizers, background updaters, and game launchers can quietly download or upload gigabytes of data in minutes, saturating your connection and causing severe lag.
3. **Expensive Data Overages on Metered Connections**: 
   When connected to mobile hotspots, travel SIMs, satellite links, or capped home internet plans, unconstrained background processes can exhaust your monthly data quota in a single afternoon.
4. **All-or-Nothing Network Controls**: 
   Windows lacks granular per-app controls. Standard tools either leave your connection completely wide open or force you to disconnect your Wi-Fi entirely, interrupting all your work.

**DataControl solves this completely.** It gives you a real-time, interactive dashboard that puts you in command: monitor bandwidth per process, receive interactive alerts when new apps try to connect, set custom data quotas, and block unwanted internet access with a single click.

---

## ⚡ Core Capabilities

```
+-----------------------------------------------------------------------------------+
|                           DATACONTROL WORKSTATION SENTRY                          |
+-----------------------------------------------------------------------------------+
       |                                       |                               |
       v                                       v                               v
[ NETWORK PROFILES ]                 [ PROCESS TRACKER ]              [ NDIS TELEMETRY ]
- Auto-detects connected network     - Win32 Extended Socket Table    - Kernel-Grade Interface Registers
- Metered vs Unlimited mode          - Full Binary Path Resolution    - Sleep/Wake Resilient
- Auto-suspends rules on trusted LAN - Real-time MB/s & Total Bytes   - Rollover-Safe Math
       |                                       |                               |
       +-------------------+-------------------+-------------------------------+
                           |
                           v
          [ ZERO-TRUST EGRESS GATEKEEPER ]
          - Unknown outbound connection detected
          - Interactive 30-Second Fluent Notification Card
          - Quick Options: [Allow Free] | [Set Quota] | [Block Outbound]
          - Fail-Secure: Auto-quarantines outbound traffic if unattended
                           |
          +----------------+----------------+
          |                                 |
          v                                 v
[ SURGICAL PER-APP FIREWALL ]       [ HARDWARE EMERGENCY DISCONNECT ]
- Block specific executable only    - Disable Wi-Fi/Ethernet adapter
- Windows Defender Firewall API     - Triggered only on hard aggregate limit
- Keeps Browser, IDE & Work alive   - Prevents unexpected carrier bill shock
```

### 1. 🛡️ Zero-Trust Egress Gatekeeper (Interactive Prompts)
When enabled, DataControl acts as an intelligent gatekeeper. Whenever a newly detected application attempts to connect to the internet, DataControl displays a non-intrusive, floating Windows 11 Fluent card above your taskbar:
- **Visual Application Header**: Extracts the real executable icon and displays the program name and path.
- **30-Second Countdown**: Shows an animated countdown timer.
- **Three Clear Choices**:
  - **Allow Free**: Grants the application full, unmetered internet access.
  - **Set Quota**: Limits the application to a micro-quota (e.g., 500 MB), preventing runaway background usage.
  - **Block Outbound**: Instantly cuts off internet access for this executable via Windows Defender Firewall.
- **Fail-Secure Architecture**: If you step away from your computer, DataControl automatically quarantines the application when the timer expires to keep your network secure.

### 2. 🚫 One-Click Application Firewall Isolation
Block any program instantly without opening complex firewall management consoles:
- Select any active program from the **Live Apps** or **App History** lists and click **Block Selected App in Firewall**.
- DataControl creates a dedicated outbound block rule in Windows Defender Firewall (`DataControl-Block-[AppName]`).
- Only the target application is blocked—your browser, messaging apps, and critical work tools remain completely unaffected.
- Unblock or change permissions at any time from the **App Rules** workspace.

### 3. ⏱️ Dual Quotas & Automatic Cutoff (Daily & Monthly)
Set clear, enforceable boundaries to protect your data plan:
- **Daily Quota**: Configure your daily data limit and warning threshold (e.g., 2 GB daily limit, warning at 1.7 GB).
- **Monthly Quota**: Set your monthly billing cycle ceiling (e.g., 16 GB monthly limit, warning at 14 GB).
- **Automated Cutoff**: Optionally enable automatic adapter disconnection when limits are reached to eliminate accidental bill shock.

### 4. 🌐 Context-Aware Network Profiles
DataControl automatically detects your active network profile:
- **Metered Mode (Hotspot / Limited Plan)**: Strict quotas, active firewall rules, and zero-trust prompts are engaged.
- **Unlimited Mode (Home Fiber / Office LAN)**: Quotas and prompts can be paused so you can download large updates freely.
- **One-Click Switch**: Toggle modes anytime directly from the top header badge.

### 5. 📈 Persistent Historical Usage Ledger
Standard Windows Task Manager resets network stats every time you restart your PC. DataControl maintains a persistent, local JSON ledger:
- Tracks total data consumed per application across all reboots and sessions.
- Helps you identify quiet, long-term bandwidth drains and software that connects when you are not actively using it.

---

## 🎨 Clean Windows 11 Fluent 2 Interface

DataControl is built with a native Windows 11 Fluent 2 design:
- **Deep Dark Theme**: Styled with modern obsidian tones (`#0A0E17`, `#111827`, `#1E293B`) and vibrant, high-contrast status colors.
- **Native Vector Indicators**: Anti-aliased vector dots for link status, profile mode, and sentry status that render cleanly on any resolution.
- **High-DPI Scaling**: Vector XAML layout scales crisply from 1080p laptop screens to 4K desktop monitors.
- **Zero-Console-Flash Launcher**: Built with a dedicated C# native launcher binary ([`DataControl.exe`](file:///d:/web/dataControle/DataControl.exe)) that runs silently without black PowerShell terminal windows popping up.
- **System Tray Resident**: Closing the window hides the application into the Windows system tray. Double-click the shield icon anytime to restore the dashboard.

---

## 🖥️ Workspaces Overview

| Workspace | Purpose & Capabilities |
|---|---|
| **📊 Dashboard** | Real-time mission control. Displays target adapter link status, live transfer speed, daily and monthly progress bars, quick adapter enable/disable controls, and a top bandwidth consumers leaderboard. |
| **🛡️ App Rules & Quotas** | Centralized application permission manager. View and change permissions for all known apps (`Allowed`, `Quota`, `Blocked`, `AutoBlocked`), browse and add custom executables manually, and configure micro-quotas. |
| **⚡ Live Apps** | Real-time process monitor. Shows active applications, process IDs (PID), live transfer rate, session bytes transferred, open socket counts, and instant firewall block buttons. |
| **📈 App History** | Cumulative consumption leaderboard. Tracks historical data usage per executable across all reboots to audit long-term background consumers. |
| **📅 Analytics** | Historical usage trends. Displays usage for **Today**, **This Month**, and **This Year**, daily logs, and a one-click billing-cycle reset button. |
| **🔒 Firewall Rules** | Dedicated Windows Defender Firewall manager. Inspect and audit all active DataControl outbound rules, block any `.exe` by file path, or remove block rules instantly. |
| **⚙️ Settings** | Central settings. Configure daily/monthly limits, warning thresholds, auto-disconnect policies, prompt timeouts, poll frequency, and automatic Windows logon startup. |

---

## 📁 Project Architecture & Code Organization

The DataControl codebase is structured into clean, modular components:

```
DataControl/
├── assets/
│   └── DataControl.ico             # Native Windows high-resolution application icon
│
├── scripts/
│   ├── Install-Shortcuts.ps1        # Creates Desktop & Start Menu shortcuts
│   ├── Uninstall-Shortcuts.ps1      # Removes Desktop & Start Menu shortcuts
│   ├── Register-StartupTask.ps1     # Registers elevated Task Scheduler auto-start on logon
│   └── Unregister-StartupTask.ps1   # Removes the automated startup task
│
├── src/
│   ├── core/
│   │   ├── NativeMethods.ps1        # Win32 DWM dark theme interop & process I/O counters
│   │   ├── NetworkProfiles.ps1      # Network profile & SSID intelligence (Metered vs Unlimited)
│   │   ├── PromptManager.ps1        # 30-second interactive Zero-Trust connection prompt engine
│   │   ├── NetworkEngine.ps1        # NDIS hardware adapter throughput & delta tracking
│   │   ├── ProcessTracker.ps1       # Win32 extended TCP/UDP socket tracking & app quota monitor
│   │   └── Enforcement.ps1          # Daily/Monthly aggregate quota thresholds & cutoff logic
│   │
│   ├── firewall/
│   │   └── FirewallManager.ps1      # Windows Defender Firewall with Advanced Security manager
│   │
│   ├── storage/
│   │   └── ConfigManager.ps1        # Local configuration & isolated JSON data ledger manager
│   │
│   └── ui/
│       ├── MainWindow.xaml          # Pure Windows 11 Fluent 2 WPF XAML interface
│       └── UIController.ps1         # View router, responsive list binders, and toast alerts
│
├── .gitignore                       # Ensures user data and history remain strictly local
├── config.example.json              # Public configuration template
├── DataControl.exe                  # Compiled native C# launcher (silent, zero console flash)
├── DataControl.ps1                  # Main application orchestrator and bootstrapper
├── Launcher.cs                      # C# source code for the silent launcher executable
├── PSScriptAnalyzerSettings.psd1   # Code quality and PowerShell analysis rules
└── README.md                        # Documentation & operator manual
```

---

## 📋 System Requirements

| Component | Minimum | Recommended |
|---|---|---|
| **Operating System** | Windows 10 (64-bit, Version 1903+) | Windows 11 (22H2 or higher) |
| **PowerShell** | Windows PowerShell 5.1 (Built-in) | Windows PowerShell 5.1 |
| **UI Framework** | .NET Framework 4.7.2+ (WPF) | .NET Framework 4.8+ (Built into Windows) |
| **Dependencies** | **Zero external dependencies** | No third-party drivers or runtimes required |
| **Privileges** | Administrator | Required for Windows Defender Firewall & Adapter controls |

---

## 🚀 Getting Started & How to Run

### Step 1: Download or Clone DataControl
Download the project as a ZIP and extract it to a folder on your computer (e.g., `C:\Tools\DataControl` or `D:\Tools\DataControl`), or clone it with Git:
```bash
git clone https://github.com/MaximosMK/DataControl.git
```

### Step 2: Create Desktop & Start Menu Shortcuts (Optional)
To easily access DataControl from your Start menu and Desktop, open an elevated PowerShell terminal and run:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Install-Shortcuts.ps1
```

### Step 3: Run DataControl
You can start DataControl in any of the following ways:
- **Double-click [`DataControl.exe`](file:///d:/web/dataControle/DataControl.exe)** in the project folder or from your Desktop shortcut.
- Windows will ask for Administrator permission (UAC prompt) to allow firewall and network adapter monitoring. Click **Yes**.
- The dark Fluent dashboard will open immediately.

To run directly from PowerShell:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DataControl.ps1
```

---

## ⚡ Running Automatically on Windows Startup

Because managing firewall rules and network hardware requires Administrator privileges, placing standard shortcuts in the Windows `Startup` folder would annoy you with a UAC prompt every time you turn on your PC.

DataControl provides **seamless, zero-UAC startup automation** using the Windows Task Scheduler engine:

### Method A: One-Click Inside the App (Recommended)
1. Open DataControl and navigate to **⚙️ Settings** in the left sidebar.
2. In the **System Startup & Sentry Daemon** card, toggle on:
   > **Start with Windows Logon (Runs silently in background with highest Administrator privileges)**
3. Click **💾 Save All Quota & Policy Settings**.

### Method B: Via PowerShell Script
From an elevated PowerShell terminal:
```powershell
# Enable silent startup on Windows logon
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Register-StartupTask.ps1

# Disable automated startup
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Unregister-StartupTask.ps1
```

Once enabled, DataControl launches silently at logon, sits in your system tray, and protects your bandwidth in the background.

---

## ⚙️ Configuration Reference (`config.json`)

When DataControl starts for the first time, it automatically creates `config.json` locally from [`config.example.json`](file:///d:/web/dataControle/config.example.json):

```json
{
  "target_adapter": "Wi-Fi",
  "daily_limit_gb": 2.0,
  "daily_warning_gb": 1.7,
  "monthly_limit_gb": 16.0,
  "warning_threshold_gb": 14.0,
  "auto_disconnect": true,
  "auto_disconnect_daily": true,
  "poll_frequency_seconds": 3,
  "prompt_on_new_apps": true,
  "prompt_timeout_seconds": 30,
  "network_profiles": {
    "Mobile_Hotspot": {
      "is_unlimited": false,
      "mode": "Metered"
    }
  }
}
```

All settings can be adjusted directly inside the **⚙️ Settings** workspace without manually editing JSON files.

---

## 🔒 Privacy-First & Zero-Telemetry Guarantee

- **100% Offline & Local**: DataControl makes **zero external network requests**, connects to no telemetry servers, and requires no account or cloud registration.
- **Your Data Remains Yours**: All metrics, application lists, and historical logs are stored exclusively in your local folder:
  - `data_history.json`: Daily, monthly, and yearly consumption numbers.
  - `app_history.json`: Per-application historical bandwidth records.
  - `app_rules.json`: Custom permission rules and quota settings.
- **Excluded from Version Control**: All user data files are included in [`.gitignore`](file:///d:/web/dataControle/.gitignore) so personal network usage is never committed to Git repositories.

---

## 📄 License

This project is licensed under the **MIT License**. You are free to use, modify, and distribute it.
