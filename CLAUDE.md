# CLAUDE.md — AI Assistant Guide for BlockADB

## Project Overview

BlockADB is a macOS security utility written in Swift that automatically blocks Android Debug Bridge (ADB) access when Android devices are connected to a Mac. It provides two layers of protection:

1. **USB ADB Blocking** — Detects ADB-capable Android devices via IOKit and kills the `adb` host process (SIGTERM).
2. **Wireless ADB Blocking** — Installs `pfctl` packet filter rules to block TCP ports 5555 and emulator ports 5554–5558.

The tool runs as both a standalone CLI and a persistent macOS `launchd` daemon.

---

## Repository Structure

```
BlockADB/
├── Package.swift                    # Swift Package Manager manifest
├── README.md                        # User-facing documentation
├── CLAUDE.md                        # This file
├── install.sh                       # Build & installation script
├── uninstall.sh                     # Removal script
├── LaunchDaemon/
│   └── com.blockADB.plist           # macOS launchd daemon config
├── Sources/
│   ├── BlockADB/
│   │   └── main.swift               # CLI entry point & argument parsing
│   └── BlockADBCore/                # Core library (importable by tools/tests)
│       ├── Config.swift             # Configuration model & vendor catalog
│       ├── ADBLogger.swift          # Unified logging system
│       ├── USBMonitor.swift         # IOKit USB device monitoring
│       ├── ADBBlocker.swift         # ADB process termination logic
│       ├── NetworkBlocker.swift     # pfctl firewall rule management
│       ├── BlockADBDaemon.swift     # Orchestrator / lifecycle manager
│       ├── ADBProtocol.swift        # ADB wire-protocol message types & parser
│       └── ADBProxyServer.swift     # Selective ADB service filter (proxy mode)
└── Tests/
    └── BlockADBTests/
        └── BlockADBTests.swift      # XCTest unit tests
```

### Key Architectural Split

- **`BlockADBCore`** (library target) — All core logic. Importable by tests and external tools.
- **`BlockADB`** (executable target) — Thin CLI wrapper that parses arguments, loads config, and starts the daemon.

---

## Technology Stack

| Layer | Technology |
|---|---|
| Language | Swift 5.7+ |
| Build | Swift Package Manager (SPM) |
| Platform | macOS 12 (Monterey)+ |
| USB monitoring | IOKit (C framework, bridged to Swift) |
| Firewall | pfctl (BSD packet filter, via `Process`) |
| Proxy networking | Network.framework (`NWListener` / `NWConnection`) |
| Service management | launchd |
| Logging | os.log (macOS Unified Logging) + optional file |
| Testing | XCTest |

---

## Build & Development Commands

```bash
# Debug build
swift build

# Release build
swift build -c release

# Run unit tests
swift test

# Run a specific test class
swift test --filter BlockADBTests.ConfigTests

# Install as daemon (requires root, uses install.sh)
sudo ./install.sh

# Uninstall daemon
sudo ./uninstall.sh

# View live daemon logs
log stream --predicate 'subsystem == "com.blockADB"'

# Check daemon status
sudo launchctl list | grep blockADB
```

The compiled binary is placed at `.build/debug/BlockADB` or `.build/release/BlockADB`.

---

## Component Responsibilities

### `Config.swift`
- Defines the `Config` struct (JSON-serializable via `Codable`)
- Contains the built-in catalog of 20 Android OEM USB vendor IDs
- Searches config paths in priority order: CLI arg → `/etc/BlockADB/config.json` → `~/.config/BlockADB/config.json` → defaults

### `ADBLogger.swift`
- Thread-safe logging via a serial `DispatchQueue`
- Wraps `os_log` (macOS Unified Logging subsystem: `com.blockADB`)
- Optional async file logging; call `ADBLogger.shared` as the singleton

### `USBMonitor.swift`
- Uses `IOKit` matching notifications for USB interface attach/detach events
- Runs on a dedicated `CFRunLoop` thread
- Detects ADB interfaces by USB class/subclass/protocol: `0xFF / 0x42 / 0x01`
- Invokes `onDeviceAttached` / `onDeviceDetached` closures on detection

### `ADBBlocker.swift`
- Finds `adb` processes via `sysctl(KERN_PROC_ALL)`
- Sends `SIGTERM` to matching PIDs
- Returns a `BlockingResult` (killed PIDs, description)

### `NetworkBlocker.swift`
- Installs/removes `pfctl` anchor rules using `/sbin/pfctl` (absolute path — no shell injection)
- Blocks TCP ports 5555 and 5554–5558 by default
- All `Process` invocations use absolute executable paths

### `BlockADBDaemon.swift`
- Wires USBMonitor → ADBBlocker + NetworkBlocker + ADBProxyServer
- Registers `SIGTERM`/`SIGINT` signal handlers for clean shutdown
- Maintains a history of blocking events
- In proxy mode: skips killing adb and starts `ADBProxyServer` instead

### `ADBProtocol.swift`
- Defines `ADBCommand` enum with all six wire-protocol command codes
- `ADBMessage` struct: serialisation, magic-field generation, service-string accessor, CLSE factory
- `ADBMessageParser`: incremental byte-buffer parser; handles TCP fragmentation and framing errors

### `ADBProxyServer.swift`
- `ADBProxyServer`: `NWListener`-based TCP proxy on `127.0.0.1:<proxyPort>`
- Locates the `adb` binary and starts the real server on the upstream port before listening
- `ADBProxyConnection`: per-connection relay; filters client→server OPEN messages by service prefix; drops follow-up WRTE/OKAY/CLSE on blocked streams; passes server→client bytes through unmodified

### `main.swift`
- Parses CLI arguments (`--config`, `--dump-config`, `--verbose`, `--no-network`, `--proxy-mode`, `--proxy-port`, `--upstream-port`, etc.)
- Loads configuration and starts `BlockADBDaemon`

---

## Configuration

Default config schema (JSON):

```json
{
  "blockedVendorIDs": [1282, 2996, ...],
  "allowedVendorIDs": [],
  "adbInterfaceClass": 255,
  "adbInterfaceSubClass": 66,
  "adbInterfaceProtocol": 1,
  "blockNetworkADB": true,
  "additionalBlockedPorts": [5554, 5556, 5557, 5558],
  "killADBServer": true,
  "verboseUSBLogging": false,
  "logFilePath": null
}
```

Config is loaded at startup; no runtime reloading. `blockedVendorIDs` defaults to all 20 known Android OEM vendor IDs defined in `Config.swift`.

### Proxy-mode additions

```json
{
  "proxyMode": false,
  "adbProxyPort": 5037,
  "adbUpstreamPort": 5038,
  "blockedADBServices": ["sync:"]
}
```

`blockedADBServices` lists ADB service string prefixes to reject. The default `["sync:"]` blocks `adb push` and `adb pull` while allowing `install:`, `shell:`, `jdwp:`, and all other services.

---

## Testing

Tests live in `Tests/BlockADBTests/BlockADBTests.swift` and use XCTest.

**Test suites:**

| Suite | What it covers |
|---|---|
| `ConfigTests` | JSON round-trip, vendor ID validation, persistence |
| `KnownAndroidVendorIDTests` | Vendor ID catalog completeness |
| `ADBDeviceInfoTests` | Device descriptor model and equality |
| `BlockingResultTests` | Result logic and string descriptions |
| `ADBBlockerTests` | Process discovery (no hardware required) |
| `NetworkBlockerTests` | pfctl paths, no-op when disabled |
| `LogLevelTests` | Log level ordering |
| `ADBProtocolTests` | Message serialisation, magic field, CLSE factory, service string |
| `ADBMessageParserTests` | Incremental parsing, fragmentation, byte-by-byte, bad magic recovery |
| `ADBProxyFilterTests` | Service prefix filtering logic (no network required) |
| `ProxyConfigTests` | Proxy config defaults and JSON round-trip |

**Testing principles:**
- All tests run without root, attached hardware, or IOKit access
- Focus on pure logic and serialization paths
- Temporary files used for config persistence tests
- No mocking framework — use real types with test-safe inputs

---

## Code Conventions

### Swift Style
- Use `// MARK: -` sections to organize code within files
- Document public APIs with `///` doc comments
- Prefer `struct` over `class` for value types (Config, BlockingResult, ADBDeviceInfo)
- Use `enum` for finite sets (log levels, CLI modes)

### Security Patterns
- Always use absolute paths for external executables (e.g., `/sbin/pfctl`)
- Never invoke external commands via shell string interpolation — use `Process` with explicit argument arrays
- Validate all config inputs; fall back to safe defaults on errors

### Threading
- `USBMonitor` runs on a dedicated `CFRunLoop` thread — do not call IOKit from the main thread
- `ADBLogger` uses a serial `DispatchQueue` for thread-safe log writes
- Use `[weak self]` captures in closures that reference long-lived objects

### Error Handling
- Use `try/catch` for all file I/O and JSON operations
- Log errors and fall back gracefully — do not crash the daemon on recoverable errors
- Avoid `!` force-unwrapping in production code

### Memory Management
- Release all IOKit objects with `IOObjectRelease` when done
- Stop `CFRunLoop` explicitly on daemon shutdown
- Use `Unmanaged` carefully when bridging C callbacks to Swift

---

## LaunchDaemon

The plist at `LaunchDaemon/com.blockADB.plist` configures the daemon:

- **Label:** `com.blockADB`
- **RunAtLoad:** `true` (starts at boot)
- **KeepAlive:** `true` (auto-restarts on crash)
- **ThrottleInterval:** `10` (prevents crash loops)
- **ProcessType:** `Interactive` (prevents suspension)
- **Stdout/Stderr:** `/var/log/BlockADB.log` / `/var/log/BlockADB.error.log`
- Requires root privileges (pfctl, IOKit)

Install path: `/Library/LaunchDaemons/com.blockADB.plist`
Binary path: `/usr/local/bin/BlockADB`

---

## Development Branch

The designated development branch for AI-assisted changes is:

```
claude/add-claude-documentation-399sM
```

Push all changes to this branch. Never push directly to `main` without explicit user approval.

---

## Proxy Mode Architecture

```
Android Studio / adb CLI
         │
         │ TCP :5037
         ▼
  ┌─────────────────┐
  │  ADBProxyServer │  (BlockADB — no entitlements needed)
  │  127.0.0.1:5037 │
  └────────┬────────┘
           │ parse OPEN messages
           │ block "sync:" → send CLSE back to client
           │ allow everything else
           │ TCP :5038
           ▼
  ┌─────────────────┐
  │  adb server     │  (real adb, relocated from :5037)
  │  127.0.0.1:5038 │
  └────────┬────────┘
           │ USB / TCP
           ▼
     Android device
```

**What is blocked:** `sync:` service — covers `adb push` and `adb pull`

**What is allowed:** `install:`, `install-create:`, `install-write:`, `install-commit:` (modern APK install), `shell:`, `exec:`, `jdwp:`, `track-jdwp:`, `forward:`, `reverse:`, and all other services

**Note on `adb install` compatibility:** Modern adb (≥ 1.0.32) and Android 7+ use dedicated `install:` services, not `sync:`. Older devices that use `sync:` + `shell:pm install` will have their install step blocked too.

---

## Common Tasks for AI Assistants

### Adding a new Android vendor ID
Edit `Config.swift` — find the `knownAndroidVendorIDs` array and add the USB vendor ID (decimal integer). Add a corresponding comment with the manufacturer name. Then add a test in `KnownAndroidVendorIDTests`.

### Adding a new CLI flag
Edit `main.swift` — parse the flag in the argument loop, update `Config` or pass directly to `BlockADBDaemon`. Follow the existing pattern of `--flag-name` parsing.

### Adding a blocked port
Update `Config.swift` default for `additionalBlockedPorts`. The `NetworkBlocker` reads this array at startup.

### Modifying firewall rules
Work in `NetworkBlocker.swift`. All pfctl invocations use `/sbin/pfctl` via `Process` — keep it that way. Never use `shell: true` or string interpolation for commands.

### Running the daemon manually (for debugging)
```bash
sudo .build/debug/BlockADB --verbose
```

### Checking IOKit USB events
```bash
log stream --predicate 'subsystem == "com.blockADB"' --level debug
```

### Adding a new blocked ADB service
Edit `Config.swift` — add the service prefix string to the `blockedADBServices` default array. Update `ADBProxyFilterTests` with a matching test case.

### Modifying proxy filtering logic
Work in `ADBProxyServer.swift` — the `processClientMessage(_:)` method on `ADBProxyConnection` is where all filtering decisions are made. `ADBProtocol.swift` contains the message types and parser; changes to either should be accompanied by tests in `ADBMessageParserTests` or `ADBProxyFilterTests`.

### Enabling proxy mode via config file
```json
{
  "proxyMode": true,
  "adbProxyPort": 5037,
  "adbUpstreamPort": 5038,
  "blockedADBServices": ["sync:"],
  "killADBServer": false
}
```
