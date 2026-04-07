// BlockADBDaemon.swift
// Orchestrator that wires together USBMonitor, ADBBlocker, and NetworkBlocker.
//
// Intended to be instantiated once and kept alive (e.g. from a LaunchDaemon).
// Handles graceful shutdown on SIGTERM/SIGINT via DispatchSource signal handlers.

import Foundation

/// Main orchestrator for the BlockADB daemon.
public final class BlockADBDaemon {

    // -----------------------------------------------------------------------
    // MARK: Properties
    // -----------------------------------------------------------------------

    private let config:         BlockADBConfig
    private let logger:         ADBLogger
    private let usbMonitor:     USBMonitor
    private let adbBlocker:     ADBBlocker
    private let networkBlocker: NetworkBlocker

    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource:  DispatchSourceSignal?

    /// Human-readable summary of every blocking action taken since start.
    private(set) public var blockingHistory: [BlockingResult] = []
    private let historyQueue = DispatchQueue(label: "com.blockADB.history")

    // -----------------------------------------------------------------------
    // MARK: Init
    // -----------------------------------------------------------------------

    public init(config: BlockADBConfig = .load()) {
        self.config = config

        logger = ADBLogger.shared
        logger.configure(logFilePath: config.logFilePath)

        usbMonitor     = USBMonitor(config: config, logger: logger)
        adbBlocker     = ADBBlocker(config: config, logger: logger)
        networkBlocker = NetworkBlocker(config: config, logger: logger)
    }

    // -----------------------------------------------------------------------
    // MARK: Lifecycle
    // -----------------------------------------------------------------------

    /// Starts the daemon: installs network rules, begins USB monitoring, and
    /// registers signal handlers for clean shutdown.
    public func start() {
        logger.log("BlockADB daemon starting (PID \(ProcessInfo.processInfo.processIdentifier))",
                   level: .info)

        networkBlocker.installRules()

        usbMonitor.onDeviceAttached = { [weak self] device in
            guard let self else { return }
            let result = self.adbBlocker.blockDevice(device)
            self.historyQueue.async {
                self.blockingHistory.append(result)
            }
            self.logger.log(result.description, level: .info)
        }

        usbMonitor.onDeviceDetached = { [weak self] device in
            self?.logger.log("ADB device disconnected: \(device)", level: .info)
        }

        usbMonitor.start()
        registerSignalHandlers()

        logger.log("BlockADB daemon running — monitoring USB and network ADB", level: .info)
    }

    /// Stops the daemon cleanly: removes network rules and stops USB monitoring.
    public func stop() {
        logger.log("BlockADB daemon stopping", level: .info)
        usbMonitor.stop()
        networkBlocker.removeRules()
    }

    // -----------------------------------------------------------------------
    // MARK: Private — signal handling
    // -----------------------------------------------------------------------

    private func registerSignalHandlers() {
        // Ignore the default signal dispositions so our DispatchSource handlers
        // are the sole responders.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT,  SIG_IGN)

        sigtermSource = makeSignalSource(signal: SIGTERM)
        sigintSource  = makeSignalSource(signal: SIGINT)
    }

    private func makeSignalSource(signal sig: Int32) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: sig,
                                                     queue: .main)
        source.setEventHandler { [weak self] in
            self?.logger.log("Received signal \(sig) — shutting down", level: .info)
            self?.stop()
            exit(0)
        }
        source.resume()
        return source
    }
}
