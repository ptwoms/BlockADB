// main.swift
// BlockADB — command-line entry point.
//
// Usage:
//   BlockADB [--config <path>] [--log <path>] [--no-network] [--verbose]
//   BlockADB --proxy-mode [--proxy-port <n>] [--upstream-port <n>]
//   BlockADB --dump-config [--config <path>]
//   BlockADB --help
//   BlockADB --version

import Foundation
import BlockADBCore

let version = "1.0.0"

// ---------------------------------------------------------------------------
// MARK: - Argument parsing
// ---------------------------------------------------------------------------

var args = CommandLine.arguments.dropFirst()

func printHelp() {
    print("""
    BlockADB \(version) — Blocks Android Debug Bridge (ADB) access on macOS.

    USAGE:
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
      --proxy-mode          Run as a selective ADB protocol filter instead of
                            killing the adb server.  Blocks file transfer
                            (adb push/pull) while allowing app debugging and
                            APK installation.  Requires adb in PATH or
                            ANDROID_HOME set.
      --proxy-port <n>      Port the proxy listens on (default 5037).
      --upstream-port <n>   Port the real adb server is relocated to
                            (default 5038).
      --dump-config         Print the effective configuration as JSON and exit.
      --version             Print version and exit.
      --help                Print this help and exit.

    EXAMPLES:
      # Run with defaults — kills adb on device connect (requires root for pfctl)
      sudo BlockADB

      # Proxy mode — allow debugging and installs, block file transfer
      BlockADB --proxy-mode

      # Proxy mode with custom ports
      BlockADB --proxy-mode --proxy-port 5037 --upstream-port 5038

      # Run without network rules (no root required)
      BlockADB --no-network

      # Use a custom config file
      sudo BlockADB --config /etc/myorg/blockadb.json

    PROXY MODE SETUP:
      In proxy mode BlockADB takes over port 5037 and moves the real adb
      server to an alternate port.  Android Studio and adb commands work
      normally — only 'adb push' and 'adb pull' are blocked.

      Ensure ANDROID_HOME is set or adb is in your PATH before starting.

    DAEMON USAGE:
      Install the provided LaunchDaemon plist to run automatically at boot:
        sudo cp LaunchDaemon/com.blockADB.plist /Library/LaunchDaemons/
        sudo launchctl load -w /Library/LaunchDaemons/com.blockADB.plist

    See README.md for full documentation.
    """)
}

// Parse flags
var configPath:    String? = nil
var logPath:       String? = nil
var noNetwork      = false
var noKill         = false
var verbose        = false
var dumpConfig     = false
var proxyMode      = false
var proxyPort:     UInt16? = nil
var upstreamPort:  UInt16? = nil

var i = args.startIndex
while i < args.endIndex {
    let arg = args[i]
    switch arg {
    case "--help", "-h":
        printHelp()
        exit(0)
    case "--version":
        print("BlockADB \(version)")
        exit(0)
    case "--config":
        args.formIndex(after: &i)
        guard i < args.endIndex else {
            fputs("Error: --config requires a path argument\n", stderr)
            exit(1)
        }
        configPath = String(args[i])
    case "--log":
        args.formIndex(after: &i)
        guard i < args.endIndex else {
            fputs("Error: --log requires a path argument\n", stderr)
            exit(1)
        }
        logPath = String(args[i])
    case "--no-network":
        noNetwork = true
    case "--no-kill":
        noKill = true
    case "--verbose":
        verbose = true
    case "--dump-config":
        dumpConfig = true
    case "--proxy-mode":
        proxyMode = true
    case "--proxy-port":
        args.formIndex(after: &i)
        guard i < args.endIndex, let p = UInt16(args[i]) else {
            fputs("Error: --proxy-port requires a numeric port argument\n", stderr)
            exit(1)
        }
        proxyPort = p
    case "--upstream-port":
        args.formIndex(after: &i)
        guard i < args.endIndex, let p = UInt16(args[i]) else {
            fputs("Error: --upstream-port requires a numeric port argument\n", stderr)
            exit(1)
        }
        upstreamPort = p
    default:
        fputs("Unknown option: \(arg)\n", stderr)
        exit(1)
    }
    args.formIndex(after: &i)
}

// ---------------------------------------------------------------------------
// MARK: - Load and apply configuration
// ---------------------------------------------------------------------------

var config: BlockADBConfig

if let path = configPath {
    let url  = URL(fileURLWithPath: path)
    let data = (try? Data(contentsOf: url)) ?? Data()
    config   = (try? JSONDecoder().decode(BlockADBConfig.self, from: data)) ?? .default
} else {
    config = BlockADBConfig.load()
}

// Apply CLI overrides
if noNetwork { config.blockNetworkADB = false }
if noKill    { config.killADBServer   = false }
if verbose   { config.verboseUSBLogging = true }
if let lp = logPath { config.logFilePath = lp }

if proxyMode {
    config.proxyMode    = true
    config.killADBServer = false  // proxy mode must not kill the adb server
}
if let p = proxyPort    { config.adbProxyPort    = p }
if let p = upstreamPort { config.adbUpstreamPort = p }

// ---------------------------------------------------------------------------
// MARK: - Dump config mode
// ---------------------------------------------------------------------------

if dumpConfig {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(config),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    }
    exit(0)
}

// ---------------------------------------------------------------------------
// MARK: - Run daemon
// ---------------------------------------------------------------------------

let daemon = BlockADBDaemon(config: config)
daemon.start()

// Keep the main thread alive — the USB monitor run loop runs on its own thread
// but RunLoop.main is needed for DispatchSource signal handlers.
RunLoop.main.run()
