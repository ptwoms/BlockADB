# BlockADB

A macOS security utility that **blocks ADB file-transfer commands** (`adb push`, `adb pull`, `adb sync`) to prevent data exfiltration from company machines, while **preserving developer workflows** — Android Studio debugging, `adb install`, `adb logcat`, and JDWP continue to work normally.

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

BlockADB uses two complementary mechanisms to block **only** ADB file-transfer while leaving the rest of the developer toolchain intact.

### 1. ADB Protocol Proxy (default — selective file-transfer blocking)

`ADBProxyServer` intercepts ADB client connections and inspects each `OPEN` message:

- **Allowed** — `shell:`, `install:`, `install-create:`, `install-write:`, `install-commit:`, `jdwp:`, `track-jdwp:`, `forward:`, `reverse:`, and all other services.
- **Blocked** — `sync:` (the service that backs both `adb push` and `adb pull`, and `adb sync`).  Blocked streams receive an immediate `CLSE` response; Android Studio and the `adb` CLI see a clean rejection for the file-transfer command only.

How it works:

1. BlockADB starts the real `adb` server on an alternate port (default 5038) via `adb -P 5038 start-server`.
2. BlockADB listens on `127.0.0.1:5037` (the port clients expect).
3. Every connection is relayed bidirectionally — except `OPEN sync:` messages, which are rejected with a `CLSE`.

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
  --config <path>       Path to a JSON configuration file.
                        Defaults: /etc/BlockADB/config.json,
                                  ~/.config/BlockADB/config.json
  --log <path>          Write log output to this file in addition to the
                        macOS Unified Logging system.
  --no-network          Skip installing pfctl rules for wireless ADB.
  --no-kill             Do not kill the adb server process.
  --verbose             Log every USB device event, not just ADB ones.
  --proxy-mode          Run as a selective ADB protocol filter (default).
                        Blocks file transfer (adb push/pull/sync) while
                        allowing app debugging and APK installation.
  --proxy-port <n>      Port the proxy listens on (default 5037).
  --upstream-port <n>   Port the real adb server is relocated to (default 5038).
  --dump-config         Print the effective configuration as JSON and exit.
  --version             Print version and exit.
  --help                Print this help and exit.
```

### Examples

```bash
# Run with defaults — blocks file transfer, keeps debugging alive
# (requires root for pfctl network rules)
sudo BlockADB

# Run without network rules (no root required)
BlockADB --no-network

# Dump effective config (useful for debugging)
BlockADB --dump-config

# Run with verbose USB logging and a custom config
sudo BlockADB --verbose --config /etc/myorg/blockadb.json
```

### What is blocked / allowed

| ADB command | Status |
|---|---|
| `adb push` | ❌ Blocked |
| `adb pull` | ❌ Blocked |
| `adb sync` | ❌ Blocked |
| `adb shell` | ✅ Allowed |
| `adb logcat` | ✅ Allowed |
| `adb install` | ✅ Allowed |
| Android Studio debugging | ✅ Allowed |
| JDWP / port forwarding | ✅ Allowed |

### Proxy Mode Setup

BlockADB runs in proxy mode by default — it takes over port 5037 and moves the
real `adb` server to port 5038.  Android Studio and `adb` commands continue to
work normally; only `adb push`, `adb pull`, and `adb sync` are blocked.

Ensure `ANDROID_HOME` is set or `adb` is in your `PATH` before starting.

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
  "blockedADBServices": ["sync:"],
  "blockedVendorIDs": [
    1282, 2996, 4100, 16596, 4820, 6353, 4316, ...
  ],
  "killADBServer": false,
  "logFilePath": "/var/log/BlockADB.log",
  "proxyMode": true,
  "adbProxyPort": 5037,
  "adbUpstreamPort": 5038,
  "verboseUSBLogging": false
}
```

### Key Options

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `proxyMode` | `Bool` | `true` | Run as a selective ADB proxy instead of killing the adb server.  Blocks only `blockedADBServices` while allowing all other ADB traffic. |
| `blockedADBServices` | `[String]` | `["sync:"]` | ADB service prefixes to reject.  `sync:` backs `adb push`, `adb pull`, and `adb sync`. |
| `adbProxyPort` | `UInt16` | `5037` | Port the proxy listens on (clients connect here). |
| `adbUpstreamPort` | `UInt16` | `5038` | Port the real adb server is relocated to. |
| `blockedVendorIDs` | `[UInt16]` | All known Android OEM IDs | Vendor IDs to watch for ADB interface detection. |
| `allowedVendorIDs` | `[UInt16]` | `[]` | Vendor IDs to explicitly allow (overrides block list). |
| `adbInterfaceClass` | `UInt8` | `255` (0xFF) | USB interface class for ADB detection. |
| `adbInterfaceSubClass` | `UInt8` | `66` (0x42) | USB interface sub-class for ADB detection. |
| `adbInterfaceProtocol` | `UInt8` | `1` (0x01) | USB interface protocol for ADB detection. |
| `blockNetworkADB` | `Bool` | `true` | Install pfctl rules for TCP 5555 (wireless ADB). |
| `additionalBlockedPorts` | `[UInt16]` | `[5554,5556,5557,5558]` | Extra TCP ports to block (emulator ports). |
| `killADBServer` | `Bool` | `false` | Send SIGTERM to all `adb` processes on device attach (broad block — overrides proxy mode). |
| `verboseUSBLogging` | `Bool` | `false` | Log all USB events, not just ADB. |
| `logFilePath` | `String?` | `nil` | Optional plain-text log file path. |

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
             │ onDeviceAttached (proxy mode: log only)
    ┌────────▼────────────┐
    │   ADBProxyServer    │  (default mode)
    │   127.0.0.1:5037    │
    │   blocks "sync:"    │
    │   allows all else   │
    └────────┬────────────┘
             │ relay (filtered)
    ┌────────▼────────────┐
    │   real adb server   │
    │   127.0.0.1:5038    │
    └─────────────────────┘
```

---

## Security Considerations

### Why the proxy approach is the right default

BlockADB intercepts ADB messages at the protocol level rather than killing the adb server.  This gives fine-grained control:

- `sync:` OPEN requests are rejected with an immediate `CLSE` — blocking `adb push`, `adb pull`, and `adb sync` without disrupting other services.
- All other services (`shell:`, `install:`, JDWP, etc.) are forwarded to the real adb server transparently.
- The `killADBServer` (full-block) option remains available for environments that need to cut off all ADB access.

### Privilege requirements

| Feature | Privilege needed |
|---------|-----------------|
| USB monitoring (IOKit notifications) | None (user-space) |
| ADB proxy (port binding 5037/5038) | None (user-space, loopback only) |
| Killing `adb` processes | Must own the process *or* be root |
| PF firewall rules (`pfctl`) | Root |
| LaunchDaemon loading | Root |

### What BlockADB does NOT do

- It does **not** modify System Integrity Protection settings.
- It does **not** install any kernel extensions (kexts / dexts).
- It does **not** capture or persist the content of ADB traffic.
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
