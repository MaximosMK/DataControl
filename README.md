# 🛡️ DataControl: Autonomous Zero-Trust Network Governance & Egress Sentry for Windows 11

[![Platform](https://img.shields.io/badge/Platform-Windows%2011%20%7C%20Windows%2010-0078D4?logo=windows&logoColor=white)](https://microsoft.com/windows)
[![Architecture](https://img.shields.io/badge/Architecture-WPF%20%7C%20Win32%20NDIS%20%7C%20PowerShell-38BDF8)](https://github.com/MaximosMK/DataControl)
[![Security](https://img.shields.io/badge/Security-Zero--Trust%20Egress%20%7C%20Fail--Secure-10B981)](#-core-architectural-pillars)
[![Privacy](https://img.shields.io/badge/Privacy-100%25%20Local%20%7C%20Zero--Cloud%20Telemetry-A855F7)](#-sovereignty--air-gapped-data-privacy)
[![License](https://img.shields.io/badge/License-MIT%20%2F%20Open-F59E0B)](#-license)

**DataControl** is an autonomous, hardware-integrated endpoint network governance and outbound application sentry system engineered for Windows 11 and Windows 10. By replacing the default operating system paradigm of unconstrained outbound trust with an active **Zero-Trust Egress Framework**, DataControl guarantees definitive operator sovereignty over every single byte entering and exiting the local workstation perimeter.

---

## 🏛️ Executive Abstract: Why DataControl Was Engineered

Contemporary operating systems and modern software ecosystems operate on an implicit-trust network model: applications executing on an endpoint assume unchecked authority to initiate outbound TCP/UDP sockets, transmit unmetered telemetry payloads, invoke background analytical beacons, and stream automated updates without deterministic operator knowledge or explicit per-session consent.

In managed environments, sovereign workstations, mobile command nodes, or bandwidth-governed deployments (e.g., satellite links, mobile cellular MiFi hotspots, metered enterprise uplinks), unmanaged outbound traffic constitutes a critical operational, financial, and security risk:

1. **Unchecked Diagnostic & Telemetry Exfiltration**: Commercial applications and modern OS components continuously leak behavioral metadata, telemetry beacons, and telemetry pings to external cloud infrastructure.
2. **Silent Background Depletion**: Background cloud synchronizers (OneDrive, Google Drive, Creative Cloud) and automated patch engines can rapidly congest the network interface and consume gigabytes of bandwidth within minutes.
3. **Lack of Granular Outbound Containment**: Standard perimeter firewalls either permit all outbound traffic or break user workflows with monolithic, complex policies. Workstations have lacked an adaptive, application-level micro-gatekeeper capable of surgically bounding individual software egress.

**DataControl** inverts this posture from *Implicit Outbound Trust* to **Explicit, Zero-Trust Endpoint Network Governance**. Integrating directly with native Windows Network Driver Interface Specification (NDIS) counters, Win32 Extended Socket APIs, and Windows Defender Firewall with Advanced Security, DataControl provides real-time telemetry isolation, contextual network profile intelligence, 30-second interactive zero-trust micro-prompts, and surgical per-application quota enforcement.

---

## ⚡ Core Architectural Pillars

```
+-----------------------------------------------------------------------------------+
|                           DATACONTROL WORKSTATION SENTRY                          |
+-----------------------------------------------------------------------------------+
       |                                       |                               |
       v                                       v                               v
[ NETWORK PROFILES ]                 [ PROCESS TRACKER ]              [ NDIS TELEMETRY ]
- Auto-detect SSID (MiFi vs Fiber)   - Extended TCP/UDP Table         - High-Precision Deltas
- Adaptive Sentry Activation         - Binary Path Identification     - Sleep/Wake Resilient
- Unlimited Bypass Mode              - Memory & Socket Auditing       - Rollover Handling
       |                                       |                               |
       +-------------------+-------------------+-------------------------------+
                           |
                           v
          [ ZERO-TRUST EGRESS GATEKEEPER ]
          - Unregistered Outbound Process Detected
          - 30-Second Non-Blocking Fluent Dark Card Prompt
          - Decision Matrix: [Allow Free] | [Set Quota] | [Block]
          - FAIL-SECURE DEFAULT: Auto-Blocks Outbound Egress on Timeout
                           |
          +----------------+----------------+
          |                                 |
          v                                 v
[ SURGICAL APP QUOTA CUTOFF ]      [ HARDWARE EMERGENCY DISCONNECT ]
- Isolate offending binary only     - Disable physical Wi-Fi/NIC
- Windows Defender Firewall Rule    - Preserves uncommitted data
- Keeps IDE, Browser & Slack alive  - Full network blackout protection
```

### 1. 🛡️ Zero-Trust Egress Gatekeeper (Interactive 30-Second Micro-Prompts)
Whenever an unregistered application attempts outbound network communication on a metered or monitored connection, DataControl instantly intercepts the event and presents a hardware-accelerated, floating Windows 11 Fluent dark card above the taskbar clock:
- **Visual Binary Identification**: Dynamically extracts high-DPI 32x32 native application icons directly from the executable binary header on disk.
- **30-Second Animated Depletion Bar**: A continuous linear visual countdown timer clearly indicates remaining decision time.
- **Operator Decision Matrix**:
  - **Allow Free**: Grants unlimited, unrestricted outbound egress for trusted executables.
  - **Set Quota**: Bounds the application to a surgical micro-quota (e.g., 500 MB), preventing runaway cloud downloads.
  - **Block Now**: Instantly generates an outbound isolation rule in Windows Defender Firewall.
- **Fail-Secure Architecture**: If the operator is away from the workstation or neglects the prompt for 30 seconds, DataControl defaults to **Fail-Secure Quarantine**—automatically generating an outbound firewall rule to prevent unauthorized data exfiltration until explicitly unlocked.

### 2. 🌐 Context-Aware Network Profile Intelligence
DataControl continuously tracks the connected Network Profile (e.g., `Home_Fiber_5G`, `MiFi_Mobile_Hotspot`, `Office_LAN`):
- **Metered Sentry Mode**: On mobile hotspots, satellite uplinks, or cellular tethering, DataControl automatically activates strict quotas, live process socket inspection, warning notifications, and interactive zero-trust prompts.
- **Unlimited Pass-Through Mode**: When connecting to trusted, high-capacity unmetered networks, the sentry automatically suspends quota cutoffs, prevents false disconnects, and disables blocking prompts.
- **One-Click Override**: Operators can manually toggle profile states with a single click in the header badge.

### 3. 🎯 Surgical Micro-Quotas vs. Hardware-Level Kill Switches
Traditional tools force an all-or-nothing trade-off: either sever the entire physical network adapter or let rogue applications consume bandwidth unchecked. DataControl implements **Dual-Tiered Enforcement**:
- **Surgical Per-Application Quotas**: Assign specific megabyte allowances (e.g., 250 MB for Spotify, 500 MB for a build tool). When that threshold is reached, DataControl locks *only that specific process* with an outbound Windows Defender Firewall rule. Your IDE, terminal sessions, browser, and enterprise messaging remain completely uninterrupted.
- **Workstation Emergency Kill-Switch**: If total daily or monthly aggregate volume breaches hard limits, the physical network adapter can be automatically un-bound and placed into a disabled state via native NDIS management, preventing carrier overage penalties.

### 4. 🔬 Kernel-Grade Delta Metering Engine
DataControl avoids error-prone high-level HTTP proxies or packet-sniffing packet capture libraries:
- Directly interrogates native NDIS interface byte registers (`Get-NetAdapterStatistics`).
- Resilient to network disconnects, interface re-negotiations, sleep/hibernation cycles, and counter rollovers.
- Simultaneously maps open local/remote network sockets via Win32 `iphlpapi.dll` extended TCP/UDP table APIs (`GetExtendedTcpTable`, `GetExtendedUdpTable`), calculating per-process throughput without injecting third-party kernel drivers.

### 5. 🔒 Sovereignty & Air-Gapped Data Privacy
- **Zero Third-Party Cloud Dependencies**: DataControl operates entirely air-gapped on the local machine. It contains zero external telemetry beacons, analytics engines, or external licensing checks.
- **Private Data Isolation**: All historical usage logs (`data_history.json`), per-app ledgers (`app_history.json`), and custom application policies (`app_rules.json`) are stored strictly within the local application folder and are hardcoded into `.gitignore` to prevent inadvertent public exposure.

---

## 🎨 User Experience & Design Philosophy

DataControl is built to conform to the **Windows 11 Fluent Design System 2.0**:
- **Deep Obsidian Palette**: Modern dark theme with subtle contrasting surfaces (`#0F172A`, `#1E293B`, `#334155`), slate typography, and high-contrast accent highlights (Sky Blue `#38BDF8`, Emerald `#10B981`, Amber `#F59E0B`, Rose `#F43F5E`).
- **Dynamic DWM Integration**: Direct Win32 interop via `DwmSetWindowAttribute` to engage native Windows 11 dark window chrome, rounded corner clipping, and Mica backdrop attributes.
- **Responsive Proportional Layouts**: Vector-rendered XAML grids scale cleanly across 1080p, 1440p, and high-DPI 4K displays with zero blurry assets or broken bounding boxes.
- **Fluid Micro-Animations**: Smooth visual progress bars, sliding Fluent pill toggle switches, and non-intrusive floating toast notifications.
- **Silent Background Resident**: Closing the primary window hides the interface directly into the Windows System Tray (Notification Area). The resident sentry monitors throughput in the background, updating dynamic tray tooltips and context menus.

---

## 🖥️ Workspaces Overview

| Workspace | Purpose & Capabilities |
|---|---|
| **📊 Dashboard** | Real-time mission control. Displays adapter link status, live throughput rate (`KB/s` / `MB/s`), daily and monthly progress bars with dynamic color shifts, hardware enable/disable buttons, and a live top-consumer leaderboard. |
| **⚡ Live Apps** | High-frequency active process monitor. Displays all active executables with live throughput, session data consumed, active socket counts, and a direct one-click **"Block Selected App in Firewall"** button. |
| **🛡️ App Rules** | Centralized Zero-Trust Permission Matrix. Lists every discovered application, its security permission (`[Allowed]`, `[Quota]`, `[Blocked]`, `[Auto-Blocked]`), assigned micro-quota limit, and bytes consumed. Includes instant rule switching (`Allow Free`, `Set 500MB`, `Block App`). |
| **📈 App History** | Cumulative, persistent bandwidth ledger. Tracks historical data consumption per binary across system reboots, enabling long-term egress auditing and discovery of silent background consumers. |
| **📅 Analytics** | Historical temporal view. Features summary metrics for **Today**, **This Month**, and **This Year**, daily data breakdown, and a carrier billing-cycle reset utility. |
| **🔒 Firewall Rules** | Dedicated Windows Defender Firewall policy inspector. Audit active `DataControl-Block-*` rules, pick any `.exe` to block manually, or remove rules to restore connectivity. |
| **⚙️ Settings** | System-wide configuration. Set daily/monthly limits and warning thresholds, auto-cutoff toggles, polling frequency, and Windows Startup logon automation. |

---

## 📁 System Architecture & Codebase Map

```
DataControl/
├── assets/
│   └── DataControl.ico             # High-resolution sentry shield icon
├── scripts/
│   ├── Install-Shortcuts.ps1        # Desktop & Start Menu shortcut provisioner
│   ├── Uninstall-Shortcuts.ps1      # Clean shortcut removal script
│   ├── Register-StartupTask.ps1     # Elevated silent startup task registrar
│   └── Unregister-StartupTask.ps1   # Startup task removal utility
├── src/
│   ├── core/
│   │   ├── NativeMethods.ps1        # Win32 DWM dark title bar & Process IO API
│   │   ├── NetworkProfiles.ps1      # Context-aware SSID & profile classification engine
│   │   ├── PromptManager.ps1        # 30-second Zero-Trust interactive prompt window & timer
│   │   ├── NetworkEngine.ps1        # NDIS hardware interface delta & throughput engine
│   │   ├── ProcessTracker.ps1       # Win32 TCP/UDP socket tracking & micro-quota enforcer
│   │   └── Enforcement.ps1          # Daily/Monthly aggregate quota rules & alerts
│   ├── firewall/
│   │   └── FirewallManager.ps1      # Windows Defender Firewall with Advanced Security API
│   ├── storage/
│   │   └── ConfigManager.ps1        # Local configuration & isolated JSON ledgers
│   └── ui/
│       ├── MainWindow.xaml          # Pure Windows 11 Fluent 2 XAML interface
│       └── UIController.ps1         # View router, toast notifications, and list binders
├── .gitignore                       # Privacy protection rules (excludes personal data)
├── config.example.json              # Public template configuration file
├── DataControl.exe                  # Compiled native launcher binary (zero console flash)
├── DataControl.ps1                  # Primary bootstrapper and application orchestrator
├── Launcher.cs                      # C# silent launcher source code
└── README.md                        # Project documentation & architecture manual
```

---

## 📋 System Requirements

| Component | Minimum Specification | Recommended |
|---|---|---|
| **Operating System** | Windows 10 (Build 19041+) | Windows 11 (22H2 or higher) |
| **Architecture** | x64 / AMD64 | x64 / ARM64 (via emulation) |
| **PowerShell** | Windows PowerShell 5.1 | Windows PowerShell 5.1 (Built-in) |
| **UI Framework** | .NET Framework 4.7.2+ (WPF, XAML) | .NET Framework 4.8+ |
| **Privileges** | Administrator (Required for NetAdapter & Firewall) | UAC Auto-Elevation Supported |

---

## 🚀 Deployment & Operational Guide

### 1. Launch via Desktop or Start Menu (Recommended)
Double-click the **DataControl** shortcut on your Desktop or search for **DataControl** in the Windows Start Menu:
- Spawns instantly through the native binary [`DataControl.exe`](file:///d:/web/dataControle/DataControl.exe) with **zero console window flash**.
- Requests Administrator rights via standard Windows UAC auto-elevation.
- Sits unobtrusively in the Windows System Tray with the custom shield icon.

### 2. Manual Terminal Launch
You can launch the bootstrapper directly from an administrative PowerShell terminal:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DataControl.ps1
```

To launch directly into the background system tray without displaying the dashboard:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DataControl.ps1 -StartMinimized
```

### 3. Background Resident & Tray Interaction
- **Close Window (`[X]`)**: Automatically hides to the Notification Area; monitoring and firewall sentries remain 100% active.
- **Restore**: Single-click or double-click the shield icon in the taskbar.
- **Hover**: Real-time tooltip reflects current daily consumption, remaining quota, and active network profile.
- **Context Menu**: Right-click the shield icon to open the dashboard, toggle the network adapter, or cleanly exit.

---

## ⚡ Automated Windows Startup (Zero UAC Prompts)

Because managing hardware network adapters and firewall rules requires Administrator elevation, placing standard shortcuts into the Windows `Startup` folder triggers an annoying UAC prompt on every user logon.

DataControl resolves this cleanly using the **Windows Task Scheduler Engine with Highest Privileges**:

### GUI Setup (One-Click)
1. Open DataControl and navigate to **⚙️ Settings**.
2. Toggle the switch:
   > **Start with Windows Logon (Runs silently in background with highest Administrator privileges)**
3. Click **💾 Save All Quota & System Settings**.

### PowerShell Script Setup
```powershell
# Register silent background startup task
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Register-StartupTask.ps1

# Remove startup task
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Unregister-StartupTask.ps1
```

---

## ⚙️ Configuration Schema (`config.json`)

The system configuration is stored locally in `config.json` (auto-generated from [`config.example.json`](file:///d:/web/dataControle/config.example.json)):

```json
{
  "target_adapter": "Wi-Fi",
  "daily_limit_gb": 3.0,
  "daily_warning_gb": 2.5,
  "monthly_limit_gb": 16.0,
  "warning_threshold_gb": 14.0,
  "poll_frequency_seconds": 3,
  "auto_disconnect": false,
  "auto_disconnect_daily": false,
  "prompt_on_new_apps": true,
  "prompt_timeout_seconds": 30,
  "network_profiles": {
    "MiFi": {
      "IsUnlimited": false,
      "Description": "Cellular Hotspot"
    }
  }
}
```

---

## 🛡️ Windows Defender Firewall Integration

All application-level isolation rules generated by DataControl leverage native Windows Defender Firewall with Advanced Security:

- **Rule Creation**:
  ```powershell
  New-NetFirewallRule -DisplayName "DataControl-Block-[AppName]" -Direction Outbound -Program "[Path]" -Action Block -Profile Any
  ```
- **Rule Auditing**:
  ```powershell
  Get-NetFirewallRule -DisplayName "DataControl-Block-*"
  ```
- **Rule Removal**:
  ```powershell
  Remove-NetFirewallRule -DisplayName "DataControl-Block-[AppName]"
  ```

All rules generated by DataControl carry the distinct prefix `DataControl-Block-`, guaranteeing that user rules can be audited, refreshed, or removed without impacting existing operating system or corporate security policies.

---

## 📄 License & Attribution

This project is open-source software licensed under the **MIT License**. Engineered for personal digital sovereignty, enterprise data containment, and deterministic endpoint network governance.
