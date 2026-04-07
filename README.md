# BlockADB

A macOS security utility that **automatically blocks Android Debug Bridge (ADB) access** when an Android device is connected to a Mac via USB or over the network (wireless ADB).

---

## Table of Contents

- [Background — How ADB Works on macOS](#background--how-adb-works-on-macos)
- [How BlockADB Works](#how-blockadb-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration](#configuration)
- [LaunchDaemon (Persistent Daemon)](#launchdaemon-persistent-daemon)
- [Uninstallation](#uninstallation)
- [Architecture](#architecture)
- [Security Considerations](#security-considerations)
- [Building from Source](#building-from-source)
- [Running Tests](#running-tests)

---

## Background — How ADB Works on macOS

### USB Communication Stack

When an Android device is connected to a Mac via USB with **USB Debugging** enabled, the following happens:

1. **USB enumeration** — macOS's IOKit framework enumerates the device through the `IOUSBHostDevice` driver stack.  Each device exposes a USB descriptor containing:
   - **Vendor ID** (`idVendor`) — identifies the OEM (e.g. `0x18D1` = Google, `0x04E8` = Samsung).
   - **Product ID** (`idProduct`) — identifies the specific model.
   - One or more **USB interfaces**, each with a class/sub-class/protocol triplet.

2. **ADB interface fingerprint** — The Android firmware exposes a vendor-specific USB interface:
   | Field              | Value  | Meaning                        |
   |--------------------|--------|--------------------------------|
   | Interface Class    | `0xFF` | Vendor-specific                |
   | Interface SubClass | `0x42` | ADB sub-class                  |
   | Interface Protocol | `0x01` | ADB protocol                   |

3. **Host-side ADB server** — The `adb` command-line tool ships with Android SDK Platform-Tools.  On first invocation it forks a background server process (`adb fork-server server`) that:
   - Listens on TCP `127.0.0.1:5037` for local client connections.
   - Opens a **bulk USB transfer** endpoint on the ADB interface for device communication.
   - Multiplexes multiple logical ADB streams (shell, file transfer, port forwarding) over this single USB channel.

### Wireless ADB

Android 11+ supports **ADB over Wi-Fi** (wireless debugging):
- The device listens on **TCP port 5555** by default for `adb connect` handshakes.
- Android emulators use ports **5554–5558**.
- Once connected, ADB traffic flows over TCP rather than USB.

### macOS Security Context

- **System Integrity Protection (SIP)** prevents modification of kernel extensions and protected system paths.
- **Transparency, Consent, and Control (TCC)** governs access to sensitive user data — separate from ADB blocking.
- **IOKit user-space API** (`IOUSBLib`) allows user-space tools to enumerate and interact with USB devices without a kernel extension, provided they run with sufficient privileges.
- **PF (Packet Filter)** is the macOS/BSD firewall.  It supports *anchors* — named, isolated rule sets — allowing third-party tools to add rules without touching the system `pf.conf`.

---

## How BlockADB Works

BlockADB uses two complementary mechanisms:

### 1. USB ADB Blocking

`USBMonitor` registers IOKit matching notifications for `IOUSBInterface` objects.  When a new interface appears, it checks:
- Does the interface expose class `0xFF` / sub-class `0x42` / protocol `0x01`?
- Does the parent device's vendor ID appear in the configured block list?
- Is the vendor ID *not* in the explicit allow list?

If all checks pass, `ADBBlocker` sends **SIGTERM** to every running `adb` process found via `sysctl(KERN_PROC_ALL)`.  This terminates the host-side ADB server, severing the USB communication channel without requiring hardware-level USB disconnection.

### 2. Network (Wireless) ADB Blocking

`NetworkBlocker` installs a **PF anchor** (`com.blockADB`) that drops TCP traffic on port 5555 and the configured emulator port range.  Rules are installed at startup and removed cleanly on shutdown.

---

## Requirements

- macOS 12 Monterey or later
- Swift 5.7+ (Xcode 14+ or `swift` command-line tools)
- **Root privileges** are required for:
  - Installing PF firewall rules (`pfctl`)
  - Loading the LaunchDaemon
- Running without root is supported if `--no-network` is passed (no PF rules)

---

## Installation

```bash
# Clone the repository
git clone https://github.com/ptwoms/BlockADB.git
cd BlockADB

# Build and install (installs binary + LaunchDaemon)
sudo ./install.sh

# Install binary only, without the daemon
./install.sh --no-daemon
```

---

## Usage

```
BlockADB [OPTIONS]

OPTIONS:
  --config <path>     Path to a JSON configuration file.
                      Defaults: /etc/BlockADB/config.json
                                ~/.config/BlockADB/config.json
  --log <path>        Write log output to this file in addition to
                      the macOS Unified Logging system.
  --no-network        Skip installing pfctl rules for wireless ADB.
  --no-kill           Do not kill the adb server process.
  --verbose           Log every USB device event, not just ADB ones.
  --dump-config       Print the effective configuration as JSON and exit.
  --version           Print version and exit.
  --help              Print this help and exit.
```

### Examples

```bash
# Run with all defaults (requires root for pfctl)
sudo BlockADB

# Run without network rules (no root required)
BlockADB --no-network

# Dump effective config (useful for debugging)
BlockADB --dump-config

# Run with verbose USB logging and a custom config
sudo BlockADB --verbose --config /etc/myorg/blockadb.json
```

### Monitoring Logs

BlockADB writes to the macOS Unified Logging system:

```bash
# Stream live log output
log stream --predicate 'subsystem == "com.blockADB"'

# Query historical entries
log show --predicate 'subsystem == "com.blockADB"' --last 1h
```

---

## Configuration

BlockADB reads JSON configuration from (in priority order):

1. Path passed via `--config`
2. `/etc/BlockADB/config.json`
3. `~/.config/BlockADB/config.json`
4. Built-in defaults

### Config File Format

```json
{
  "adbInterfaceClass": 255,
  "adbInterfaceProtocol": 1,
  "adbInterfaceSubClass": 66,
  "additionalBlockedPorts": [5554, 5556, 5557, 5558],
  "allowedVendorIDs": [],
  "blockNetworkADB": true,
  "blockedVendorIDs": [
    1282, 2996, 4100, 16596, 4820, 6353, 4316, ...
  ],
  "killADBServer": true,
  "logFilePath": "/var/log/BlockADB.log",
  "verboseUSBLogging": false
}
```

### Key Options

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `blockedVendorIDs` | `[UInt16]` | All known Android OEM IDs | Vendor IDs to block |
| `allowedVendorIDs` | `[UInt16]` | `[]` | Vendor IDs to explicitly allow (overrides block list) |
| `adbInterfaceClass` | `UInt8` | `255` (0xFF) | USB interface class for ADB detection |
| `adbInterfaceSubClass` | `UInt8` | `66` (0x42) | USB interface sub-class for ADB detection |
| `adbInterfaceProtocol` | `UInt8` | `1` (0x01) | USB interface protocol for ADB detection |
| `blockNetworkADB` | `Bool` | `true` | Install pfctl rules for TCP 5555 |
| `additionalBlockedPorts` | `[UInt16]` | `[5554,5556,5557,5558]` | Extra TCP ports to block |
| `killADBServer` | `Bool` | `true` | Send SIGTERM to `adb` processes on device attach |
| `verboseUSBLogging` | `Bool` | `false` | Log all USB events, not just ADB |
| `logFilePath` | `String?` | `nil` | Optional plain-text log file path |

### Allowing a Specific Developer Device

To allow a specific device (e.g. your own Pixel for development) while blocking all others:

```json
{
  "allowedVendorIDs": [6353]
}
```

`6353` = `0x18D1` (Google). Add other vendor IDs as needed.

---

## LaunchDaemon (Persistent Daemon)

To run BlockADB automatically at boot, install the provided LaunchDaemon:

```bash
sudo cp LaunchDaemon/com.blockADB.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.blockADB.plist
sudo chmod 644 /Library/LaunchDaemons/com.blockADB.plist
sudo launchctl load -w /Library/LaunchDaemons/com.blockADB.plist
```

Check status:
```bash
sudo launchctl list com.blockADB
```

---

## Uninstallation

```bash
sudo ./uninstall.sh
```

This unloads the LaunchDaemon, removes the binary, and flushes the PF anchor rules.

---

## Architecture

```
BlockADB/
├── Package.swift                   # Swift Package Manager manifest
├── Sources/
│   ├── BlockADB/
│   │   └── main.swift              # CLI entry point & argument parsing
│   └── BlockADBCore/
│       ├── Config.swift            # Configuration model & vendor ID catalogue
│       ├── ADBLogger.swift         # Unified logging (os_log) + optional file log
│       ├── USBMonitor.swift        # IOKit USB device monitoring
│       ├── ADBBlocker.swift        # ADB process termination logic
│       ├── NetworkBlocker.swift    # pfctl rule management
│       └── BlockADBDaemon.swift    # Orchestrator / lifecycle manager
├── Tests/
│   └── BlockADBTests/
│       └── BlockADBTests.swift     # Unit tests
├── LaunchDaemon/
│   └── com.blockADB.plist          # launchd daemon configuration
├── install.sh                      # Build & install script
├── uninstall.sh                    # Removal script
└── README.md                       # This file
```

### Component Interaction

```
         ┌──────────────────────────────────┐
         │         BlockADBDaemon           │
         │  (orchestrates all components)   │
         └────┬──────────────┬─────────────┘
              │              │
    ┌─────────▼──────┐  ┌────▼──────────────┐
    │  USBMonitor    │  │  NetworkBlocker   │
    │  (IOKit run    │  │  (pfctl anchor    │
    │   loop thread) │  │   com.blockADB)   │
    └────────┬───────┘  └───────────────────┘
             │ onDeviceAttached
    ┌────────▼───────┐
    │  ADBBlocker    │
    │  (sysctl +     │
    │   SIGTERM adb) │
    └────────────────┘
             │
    ┌────────▼───────┐
    │   ADBLogger    │
    │ (os_log +      │
    │  optional file)│
    └────────────────┘
```

---

## Security Considerations

### Why killing `adb` is sufficient

Forcibly removing a USB interface via IOKit requires the
`com.apple.security.iokit-user-client-class` entitlement, partial SIP
disablement, or a kernel extension — all of which have significant security
implications.  Killing the `adb` host server is equally effective: the Android
device's `adbd` daemon remains running, but without the host-side counterpart,
no ADB communication can occur.

### Privilege requirements

| Feature | Privilege needed |
|---------|-----------------|
| USB monitoring (IOKit notifications) | None (user-space) |
| Killing `adb` processes | Must own the process *or* be root |
| PF firewall rules (`pfctl`) | Root |
| LaunchDaemon loading | Root |

### What BlockADB does NOT do

- It does **not** modify System Integrity Protection settings.
- It does **not** install any kernel extensions (kexts / dexts).
- It does **not** capture or inspect the content of ADB traffic.
- It does **not** prevent users with root from re-enabling ADB manually.

For a locked-down managed environment, combine BlockADB with an MDM profile
that restricts USB device classes at the hardware level.

---

## Building from Source

```bash
# Debug build
swift build

# Release build
swift build -c release

# Run tests
swift test
```

---

## Running Tests

```bash
swift test
```

Tests cover configuration serialisation, vendor ID catalogues, device-info
modelling, blocking result logic, process-discovery, and safe networking paths
— all without requiring attached hardware or root privileges.

---

## Supported Android Vendor IDs

BlockADB includes built-in support for the following manufacturers (configurable):

| Manufacturer | Vendor ID |
|---|---|
| Acer | 0x0502 |
| Dell | 0x413C |
| Foxconn | 0x0489 |
| Fujitsu | 0x04C5 |
| Google / AOSP | 0x18D1 |
| Hisense | 0x109B |
| HTC | 0x0BB4 |
| Huawei | 0x12D1 |
| Kyocera | 0x0482 |
| Lenovo | 0x17EF |
| LG | 0x1004 |
| Motorola | 0x22B8 |
| Nokia | 0x0421 |
| OnePlus | 0x2A96 |
| OPPO | 0x22D9 |
| Realme | 0x3067 |
| Samsung | 0x04E8 |
| Sharp | 0x04DD |
| Sony | 0x0FCE |
| Xiaomi | 0x2717 |
| ZTE | 0x19D2 |
