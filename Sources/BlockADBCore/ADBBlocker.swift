// ADBBlocker.swift
// Core blocking logic for BlockADB.
//
// Responds to ADB device attach events by:
//   1. Killing the host-side `adb` server process (if configured).
//   2. Logging the event to the macOS Unified Logging system.
//
// Host-side ADB architecture on macOS
// -------------------------------------
// The ADB toolchain ships with Android SDK Platform-Tools.  On macOS the
// relevant processes are:
//
//   adb          — CLI front-end; forks a background server on first invocation.
//   adb fork-server server — long-running server at ~$HOME/.android/adb.log
//
// The server listens on TCP 127.0.0.1:5037 (by default) for local client
// connections and communicates with attached Android devices over:
//   • USB  — via the IOUSBInterface identified by class 0xFF / sub-class 0x42
//   • TCP  — over port 5555 when "adb connect <host>" is used (wireless ADB)
//
// Killing approach
// -----------------
// The simplest reliable approach on macOS is to send SIGTERM to every process
// whose executable name is "adb".  We locate these using sysctl(KERN_PROC_ALL)
// rather than shelling out to `ps`, which avoids spawning a child process and
// the associated TOCTOU race.
//
// Why not IOKit eject?
// ---------------------
// Forcibly removing an IOUSBInterface via IOCFPlugIn requires the
// com.apple.security.iokit-user-client-class entitlement and SIP to be
// partially disabled.  Killing the `adb` server is both simpler and
// sufficient: without the host server the device cannot be accessed even
// though the USB hardware remains enumerated.

import Foundation
#if os(macOS)
import Darwin
#endif

/// Encapsulates the action taken when an ADB device is detected.
public final class ADBBlocker {

    private let config: BlockADBConfig
    private let logger: ADBLogger

    public init(config: BlockADBConfig = .default, logger: ADBLogger = .shared) {
        self.config = config
        self.logger = logger
    }

    // -----------------------------------------------------------------------
    // MARK: Public API
    // -----------------------------------------------------------------------

    /// Called by ``USBMonitor`` when an ADB device attaches.
    /// Executes all configured blocking actions and returns a summary of what
    /// was done.
    @discardableResult
    public func blockDevice(_ device: ADBDeviceInfo) -> BlockingResult {
        logger.log("Blocking ADB device: \(device)", level: .info)

        var killedPIDs: [Int32] = []
        if config.killADBServer {
            killedPIDs = killADBProcesses()
        }

        return BlockingResult(
            device:     device,
            killedPIDs: killedPIDs,
            timestamp:  Date()
        )
    }

    // -----------------------------------------------------------------------
    // MARK: Private — process termination
    // -----------------------------------------------------------------------

    /// Finds and SIGTERMs every process named "adb".
    /// Returns the list of PIDs that were signalled.
    func killADBProcesses() -> [Int32] {
        let pids = findADBProcessPIDs()
        if pids.isEmpty {
            logger.log("No running adb process found", level: .info)
        }
        for pid in pids {
            let result = kill(pid, SIGTERM)
            if result == 0 {
                logger.log("Sent SIGTERM to adb process (PID \(pid))", level: .info)
            } else {
                logger.log("Failed to signal PID \(pid): errno \(errno)",
                           level: .error)
            }
        }
        return pids
    }

    /// Returns PIDs of all processes whose executable name is "adb" using the
    /// BSD sysctl KERN_PROC_ALL interface — no child process spawning required.
    func findADBProcessPIDs() -> [Int32] {
#if os(macOS)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0

        // First call: determine buffer size.
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        var pids: [Int32] = []
        for proc in procs {
            // kp_proc.p_comm holds the first MAXCOMLEN (16) bytes of the
            // executable name as a C string tuple.
            var comm = proc.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { bytes -> String in
                let ptr = bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: ptr)
            }
            if name == "adb" {
                pids.append(proc.kp_proc.p_pid)
            }
        }
        return pids
#else
        // Fallback for non-macOS platforms: not applicable for this tool.
        return []
#endif
    }
}

// ---------------------------------------------------------------------------
// MARK: - Result type
// ---------------------------------------------------------------------------

/// Summary of the blocking actions taken for one ADB device attach event.
public struct BlockingResult {
    public let device:     ADBDeviceInfo
    public let killedPIDs: [Int32]
    public let timestamp:  Date

    public var wasBlocked: Bool { !killedPIDs.isEmpty }

    public var description: String {
        if killedPIDs.isEmpty {
            return "Device detected but no adb process was running: \(device)"
        }
        return "Blocked \(device) — terminated PIDs: \(killedPIDs)"
    }
}
