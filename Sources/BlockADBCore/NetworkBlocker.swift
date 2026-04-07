// NetworkBlocker.swift
// Manages pfctl rules that block wireless ADB (TCP port 5555) on macOS.
//
// Wireless ADB overview
// ----------------------
// Since Android 11, Android devices support ADB over Wi-Fi (also called
// "wireless debugging").  The device listens on a random high port chosen
// at pairing time, but the *initial* TCP handshake always goes to port 5555
// when the user runs `adb connect <device-ip>`.  Android emulators use
// ports 5554–5558.
//
// Blocking strategy
// ------------------
// macOS ships with the PF (packet filter) firewall inherited from BSD.  We
// add a PF anchor — "com.blockADB" — to block outbound and inbound TCP
// connections on the configured ports.  Using an anchor keeps our rules
// isolated and makes them trivially removable without touching the system
// pf.conf.
//
// The approach requires root privileges (or the com.apple.security.network
// entitlement is not sufficient — pfctl itself needs root).  When BlockADB
// runs as a LaunchDaemon it already runs as root.
//
// Security note on pfctl
// -----------------------
// We invoke pfctl via a Process (posix_spawn under the hood).  We use an
// absolute path (/sbin/pfctl) and pass only controlled arguments to avoid
// shell-injection or PATH hijacking.

import Foundation

/// Manages a PF anchor that blocks TCP ports used by wireless ADB.
public final class NetworkBlocker {

    private let config: BlockADBConfig
    private let logger: ADBLogger

    /// Path to the pfctl binary — fixed to the absolute system path.
    private static let pfctlPath = "/sbin/pfctl"

    /// Name of the PF anchor managed by BlockADB.
    private static let anchorName = "com.blockADB"

    public init(config: BlockADBConfig = .default, logger: ADBLogger = .shared) {
        self.config = config
        self.logger = logger
    }

    // -----------------------------------------------------------------------
    // MARK: Public API
    // -----------------------------------------------------------------------

    /// Installs PF rules that block the configured ADB TCP ports.
    /// No-op if ``BlockADBConfig/blockNetworkADB`` is false.
    /// No-op on non-macOS platforms.
    public func installRules() {
#if os(macOS)
        guard config.blockNetworkADB else { return }
        let ports = ([5555] + config.additionalBlockedPorts.map { Int($0) }).uniqued()
        let rules = buildRules(ports: ports)
        logger.log("Installing network ADB blocking rules for ports: \(ports)", level: .info)
        applyRules(rules)
#endif
    }

    /// Removes the BlockADB PF anchor, restoring normal traffic.
    /// No-op on non-macOS platforms.
    public func removeRules() {
#if os(macOS)
        logger.log("Removing network ADB blocking rules", level: .info)
        flushAnchor()
#endif
    }

    // -----------------------------------------------------------------------
    // MARK: Private — rule generation and pfctl helpers (macOS only)
    // -----------------------------------------------------------------------

#if os(macOS)
    private func buildRules(ports: [Int]) -> String {
        var lines: [String] = [
            "# BlockADB — wireless ADB port blocking rules",
            "# Generated: \(ISO8601DateFormatter().string(from: Date()))"
        ]
        for port in ports {
            // Block both directions to prevent the ADB server from listening
            // and from connecting to a remote device.
            lines.append("block in  quick proto tcp from any to any port \(port)")
            lines.append("block out quick proto tcp from any to any port \(port)")
        }
        return lines.joined(separator: "\n")
    }

    /// Pipes *rules* into `pfctl -a <anchor> -f -` and enables PF.
    private func applyRules(_ rules: String) {
        guard let data = rules.data(using: .utf8) else { return }

        // Write rules to a temp file rather than piping to stdin to keep the
        // Process setup simple and auditable.
        let tmpPath = "/tmp/com.blockADB.pf.rules"
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
        } catch {
            logger.log("Failed to write PF rules to \(tmpPath): \(error)", level: .error)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // Load anchor rules.
        run(Self.pfctlPath, args: ["-a", Self.anchorName, "-f", tmpPath])
        // Enable PF if not already active.
        run(Self.pfctlPath, args: ["-e"])
    }

    /// Flushes all rules from the BlockADB anchor.
    private func flushAnchor() {
        run(Self.pfctlPath, args: ["-a", Self.anchorName, "-F", "rules"])
    }
#endif

    /// Runs *executable* with *args*, waits for completion, and logs the exit
    /// status.  Uses an absolute path to avoid PATH hijacking.
    @discardableResult
    func run(_ executable: String, args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        // Suppress pfctl's own stderr output so it does not clutter the
        // caller's console; our own logger is the single source of truth.
        let devNull = FileHandle.nullDevice
        process.standardOutput = devNull
        process.standardError  = devNull

        do {
            try process.run()
            process.waitUntilExit()
            let status = process.terminationStatus
            if status != 0 {
                logger.log("\(executable) \(args.joined(separator: " ")) exited \(status)",
                           level: .warning)
            }
            return status
        } catch {
            logger.log("Failed to launch \(executable): \(error)", level: .error)
            return -1
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Array uniqued helper (no import of Algorithms needed)
// ---------------------------------------------------------------------------

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
