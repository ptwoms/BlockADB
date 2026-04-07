// ADBProxyServer.swift
// Selective ADB service filter implemented as a transparent TCP proxy.
//
// Architecture
// ------------
// The standard adb server listens on 127.0.0.1:5037.  Android Studio and
// the adb CLI connect to this port and speak the ADB wire protocol.
//
// In proxy mode BlockADB:
//   1. Starts the real adb server on an alternate port (default 5038) by
//      running:  adb -P 5038 start-server
//   2. Listens on 127.0.0.1:5037 (the port clients expect).
//   3. For every incoming connection, opens a matching connection to :5038.
//   4. Relays all traffic bidirectionally, except:
//      • OPEN messages whose service string starts with a blocked prefix
//        (default: "sync:") are *not* forwarded.  Instead, a CLSE is sent
//        back to the client so it receives a clean rejection.
//      • Subsequent WRTE/OKAY/CLSE messages for a blocked stream are
//        silently dropped, because the real server never saw the OPEN.
//
// Service filtering rationale
// ---------------------------
// "sync:" is the ADB service that backs both `adb push` and `adb pull`.
// Android 7+ (API 24+) adb uses the dedicated "install:" / "install-create:"
// / "install-write:" / "install-commit:" services and does NOT go through
// "sync:", so blocking "sync:" prevents file transfer while leaving APK
// installation fully intact on target devices.
//
// Devices below Android 7.0 use sync: internally for adb install and will
// have APK installation blocked as well.  This is an accepted trade-off for
// environments targeting Android 11+ (API 30+).
//
// Security note
// -------------
// The proxy and the real adb server both bind to 127.0.0.1 (loopback only).
// No external connections are accepted.

import Foundation
#if canImport(Network)
import Network
#endif

// ---------------------------------------------------------------------------
// MARK: - Proxy server
// ---------------------------------------------------------------------------

#if canImport(Network)
/// Listens on the ADB client port and relays connections to the real adb
/// server, filtering out blocked service streams along the way.
public final class ADBProxyServer {

    // -----------------------------------------------------------------------
    // MARK: Public configuration
    // -----------------------------------------------------------------------

    /// Port that ADB clients (Android Studio, adb CLI) connect to.
    /// Default: 5037 (the well-known adb server port).
    public let proxyPort: UInt16

    /// Port the real adb server is relocated to.
    /// Default: 5038.
    public let upstreamPort: UInt16

    /// Service string prefixes that the proxy will reject.
    /// Any OPEN whose service starts with one of these strings is denied.
    public let blockedServicePrefixes: [String]

    // -----------------------------------------------------------------------
    // MARK: Private state
    // -----------------------------------------------------------------------

    private let logger: ADBLogger
    private var listener: NWListener?
    private var activeConnections: [UUID: ADBProxyConnection] = [:]
    private let queue = DispatchQueue(label: "com.blockADB.proxy",
                                      qos: .userInitiated)
    private static let lsofPath = "/usr/sbin/lsof"

    // -----------------------------------------------------------------------
    // MARK: Init
    // -----------------------------------------------------------------------

    public init(
        proxyPort: UInt16 = 5037,
        upstreamPort: UInt16 = 5038,
        blockedServicePrefixes: [String] = ["sync:"],
        logger: ADBLogger = .shared
    ) {
        self.proxyPort              = proxyPort
        self.upstreamPort           = upstreamPort
        self.blockedServicePrefixes = blockedServicePrefixes
        self.logger                 = logger
    }

    // -----------------------------------------------------------------------
    // MARK: Lifecycle
    // -----------------------------------------------------------------------

    /// Starts the real adb server on ``upstreamPort``, then begins listening
    /// on ``proxyPort``.  Throws if the listener cannot be created.
    public func start() throws {
        let adbPath = ADBProxyServer.resolveADBExecutable()
        releaseProxyPort(adbPath: adbPath)
        startUpstreamADBServer(adbPath: adbPath)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Keep the listener local-only without also pre-binding a specific
        // endpoint. Using requiredLocalEndpoint here and then passing `on:`
        // to NWListener caused EINVAL on startup because the local bind
        // details were effectively specified twice.
        params.acceptLocalOnly = true

        guard let nwPort = NWEndpoint.Port(rawValue: proxyPort) else {
            throw ADBProxyError.invalidPort(proxyPort)
        }
        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        let startupSemaphore = DispatchSemaphore(value: 0)
        var startupError: Error?
        var startupResolved = false

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.log(
                    "ADB proxy listening on 127.0.0.1:\(self.proxyPort) "
                    + "→ upstream :(\(self.upstreamPort))",
                    level: .info
                )
                if !startupResolved {
                    startupResolved = true
                    startupSemaphore.signal()
                }
            case .failed(let err):
                let resolvedError = self.listenerStartupError(from: err)
                self.logger.log("ADB proxy listener failed: \(resolvedError)", level: .fault)
                if !startupResolved {
                    startupResolved = true
                    startupError = resolvedError
                    startupSemaphore.signal()
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNewClient(conn)
        }

        listener.start(queue: queue)

        if startupSemaphore.wait(timeout: .now() + .seconds(2)) == .success,
           let startupError {
            listener.cancel()
            self.listener = nil
            throw startupError
        }
    }

    /// Stops listening and cancels all in-flight connections.
    public func stop() {
        listener?.cancel()
        listener = nil
        activeConnections.values.forEach { $0.stop() }
        activeConnections.removeAll()
        logger.log("ADB proxy stopped", level: .info)
    }

    // -----------------------------------------------------------------------
    // MARK: Private — upstream adb server management
    // -----------------------------------------------------------------------

    /// Launches `adb -P <upstreamPort> start-server` so the real server
    /// relocates to the upstream port before the proxy takes :5037.
    private func startUpstreamADBServer(adbPath: String?) {
        guard let adbPath else {
            logger.log(
                "adb executable not found — skipping upstream server start. "
                + "Set ANDROID_HOME or add adb to PATH.",
                level: .warning
            )
            return
        }

        let result = runProcess(adbPath, args: ["-P", "\(upstreamPort)", "start-server"])
        if result.status == 0 {
            logger.log(
                "Started upstream adb server on port \(upstreamPort)",
                level: .info
            )
        } else {
            logger.log(
                "Failed to start upstream adb server on port \(upstreamPort) "
                + "(exit: \(result.status))",
                level: .error
            )
        }
    }

    /// Best-effort cleanup of any existing adb server already listening on the
    /// client-facing proxy port before we try to bind it ourselves.
    private func releaseProxyPort(adbPath: String?) {
        guard let adbPath else { return }

        let result = runProcess(adbPath, args: ["-P", "\(proxyPort)", "kill-server"])
        if result.status == 0 {
            logger.log(
                "Requested adb server shutdown on proxy port \(proxyPort) before starting proxy",
                level: .info
            )
        }
    }

    /// Searches well-known locations for the `adb` binary.
    /// Returns the first executable found, or nil.
    public static func resolveADBExecutable() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? ""
        let androidHome = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"] ?? ""

        let candidates: [String] = [
            androidHome.isEmpty ? "" : "\(androidHome)/platform-tools/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
            "/usr/bin/adb",
        ].filter { !$0.isEmpty }

        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static func parseListeningProcessSummary(from output: String) -> String? {
        var pid: String?
        var command: String?
        var endpoint: String?

        for line in output.split(whereSeparator: \.isNewline) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p":
                pid = value
            case "c":
                command = value
            case "n":
                endpoint = value
            default:
                continue
            }
        }

        guard pid != nil || command != nil || endpoint != nil else { return nil }

        var summary = command ?? "unknown process"
        if let pid {
            summary += " (PID \(pid))"
        }
        if let endpoint {
            summary += " on \(endpoint)"
        }
        return summary
    }

    private func listenerStartupError(from error: NWError) -> Error {
        if case .posix(let code) = error, code == .EADDRINUSE {
            let owner = currentProxyPortOwner()
            return ADBProxyError.portInUse(proxyPort, owner: owner)
        }
        return ADBProxyError.listenerStartupFailed(String(describing: error))
    }

    private func currentProxyPortOwner() -> String? {
        let result = runProcess(
            Self.lsofPath,
            args: ["-nP", "-iTCP:\(proxyPort)", "-sTCP:LISTEN", "-Fpcn"],
            captureOutput: true
        )
        guard result.status == 0 else { return nil }
        return Self.parseListeningProcessSummary(from: result.output)
    }

    @discardableResult
    private func runProcess(
        _ executable: String,
        args: [String],
        captureOutput: Bool = false
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let outputPipe = Pipe()
        if captureOutput {
            process.standardOutput = outputPipe
            process.standardError = outputPipe
        } else {
            let devNull = FileHandle.nullDevice
            process.standardOutput = devNull
            process.standardError = devNull
        }

        do {
            try process.run()
            process.waitUntilExit()
            let output: String
            if captureOutput {
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                output = String(data: data, encoding: .utf8) ?? ""
            } else {
                output = ""
            }
            return (process.terminationStatus, output)
        } catch {
            logger.log("Failed to launch \(executable): \(error)", level: .error)
            return (-1, "")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Private — connection handling
    // -----------------------------------------------------------------------

    private func handleNewClient(_ clientConn: NWConnection) {
        guard let nwPort = NWEndpoint.Port(rawValue: upstreamPort) else { return }

        let serverConn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let connectionID = UUID()

        let proxyConn = ADBProxyConnection(
            id:                     connectionID,
            client:                 clientConn,
            server:                 serverConn,
            blockedServicePrefixes: blockedServicePrefixes,
            logger:                 logger,
            queue:                  queue,
            onClose:                { [weak self] id in
                self?.activeConnections.removeValue(forKey: id)
            }
        )
        activeConnections[connectionID] = proxyConn
        logger.log(
            "ADB proxy accepted client connection \(connectionID.uuidString)",
            level: .debug
        )
        proxyConn.start()
    }
}

// ---------------------------------------------------------------------------
// MARK: - Per-connection relay
// ---------------------------------------------------------------------------

/// Manages one (client ↔ proxy ↔ server) connection triple.
///
/// Traffic from the client is parsed into ``ADBMessage`` values; OPEN
/// messages are inspected and either forwarded or rejected based on their
/// service string.  Traffic from the server is relayed to the client as
/// raw bytes without modification.
final class ADBProxyConnection {

    // -----------------------------------------------------------------------
    // MARK: Properties
    // -----------------------------------------------------------------------

    private let id: UUID
    private let clientConn: NWConnection
    private let serverConn: NWConnection
    private let blockedServicePrefixes: [String]
    private let logger: ADBLogger
    private let queue: DispatchQueue
    private let onClose: (UUID) -> Void

    /// Parser for the client→server direction.
    private let clientParser = ADBMessageParser()

    /// Local stream IDs (from OPEN arg0) whose OPEN was blocked.
    /// WRTE / OKAY / CLSE messages carrying these IDs are dropped silently.
    private var blockedLocalIDs = Set<UInt32>()
    private var isClosed = false

    // -----------------------------------------------------------------------
    // MARK: Init & start
    // -----------------------------------------------------------------------

    init(
        id: UUID,
        client: NWConnection,
        server: NWConnection,
        blockedServicePrefixes: [String],
        logger: ADBLogger,
        queue: DispatchQueue,
        onClose: @escaping (UUID) -> Void
    ) {
        self.id                     = id
        self.clientConn             = client
        self.serverConn             = server
        self.blockedServicePrefixes = blockedServicePrefixes
        self.logger                 = logger
        self.queue                  = queue
        self.onClose                = onClose
    }

    func start() {
        // Connect upstream first; start the relay once it is ready.
        serverConn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.startRelay()
            case .failed(let err):
                self?.logger.log("Proxy upstream connect failed: \(err)", level: .warning)
                self?.stop()
            case .cancelled:
                self?.closeIfNeeded()
            default:
                break
            }
        }
        serverConn.start(queue: queue)
        clientConn.start(queue: queue)
    }

    func stop() {
        clientConn.cancel()
        serverConn.cancel()
        closeIfNeeded()
    }

    // -----------------------------------------------------------------------
    // MARK: Relay
    // -----------------------------------------------------------------------

    private func startRelay() {
        readFromClient()
        readFromServer()
    }

    // MARK: Client → Server (filtered)

    private func readFromClient() {
        clientConn.receive(minimumIncompleteLength: 1,
                           maximumLength: 65_536)
        { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                let messages = self.clientParser.feed(data)
                for msg in messages {
                    self.processClientMessage(msg)
                }
            }

            if isComplete || error != nil {
                self.stop()
                return
            }
            self.readFromClient()
        }
    }

    private func processClientMessage(_ msg: ADBMessage) {
        switch msg.command {

        case .open:
            let service = msg.serviceString ?? "<unknown>"
            let isBlocked = blockedServicePrefixes.contains { service.hasPrefix($0) }

            if isBlocked {
                // Track this stream so we can drop follow-up messages.
                blockedLocalIDs.insert(msg.arg0)
                logger.log(
                    "ADB proxy: blocked OPEN \"\(service)\" (local_id=\(msg.arg0))",
                    level: .info
                )
                // Send CLSE so the client gets a clean, immediate rejection.
                send(ADBMessage.clse(remoteID: msg.arg0).serialized(), on: clientConn)
                return   // do NOT forward to the real server
            }

            logger.log(
                "ADB proxy: allowed OPEN \"\(service)\" (local_id=\(msg.arg0))",
                level: .debug
            )
            forward(msg)

        case .wrte, .okay, .clse:
            // arg0 is the sender's local_id; for client→server messages this
            // is the id the client chose in its OPEN.
            if blockedLocalIDs.contains(msg.arg0) {
                // Clean up tracking state when the client closes a blocked stream.
                if msg.command == .clse { blockedLocalIDs.remove(msg.arg0) }
                return   // silently drop
            }
            forward(msg)

        default:
            // CNXN, AUTH and anything unknown passes through unmodified.
            forward(msg)
        }
    }

    // MARK: Server → Client (passthrough)

    private func readFromServer() {
        serverConn.receive(minimumIncompleteLength: 1,
                           maximumLength: 65_536)
        { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                // Server responses need no filtering — relay raw bytes.
                self.send(data, on: self.clientConn)
            }

            if isComplete || error != nil {
                self.stop()
                return
            }
            self.readFromServer()
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Helpers
    // -----------------------------------------------------------------------

    private func forward(_ msg: ADBMessage) {
        send(msg.serialized(), on: serverConn)
    }

    private func send(_ data: Data, on conn: NWConnection) {
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.log("ADB proxy send error: \(error)", level: .warning)
            }
        })
    }

    private func closeIfNeeded() {
        guard !isClosed else { return }
        isClosed = true
        logger.log(
            "ADB proxy closed client connection \(id.uuidString)",
            level: .debug
        )
        onClose(id)
    }
}

#else // !canImport(Network)

// ---------------------------------------------------------------------------
// MARK: - Platform stub (non-macOS)
// ---------------------------------------------------------------------------
// Network.framework is not available on Linux or other non-Apple platforms.
// These stubs satisfy the type system so BlockADBDaemon compiles everywhere;
// start() always throws, so proxy mode is effectively disabled on unsupported
// platforms.

/// Stub: ADB proxy is not supported on platforms without Network.framework.
public final class ADBProxyServer {
    public let proxyPort: UInt16
    public let upstreamPort: UInt16
    public let blockedServicePrefixes: [String]

    public init(
        proxyPort: UInt16 = 5037,
        upstreamPort: UInt16 = 5038,
        blockedServicePrefixes: [String] = ["sync:"],
        logger: ADBLogger = .shared
    ) {
        self.proxyPort = proxyPort
        self.upstreamPort = upstreamPort
        self.blockedServicePrefixes = blockedServicePrefixes
    }

    public func start() throws {
        throw ADBProxyError.unsupportedPlatform
    }

    public func stop() {}

    public static func resolveADBExecutable() -> String? { nil }
}

#endif // canImport(Network)

// ---------------------------------------------------------------------------
// MARK: - Error
// ---------------------------------------------------------------------------

public enum ADBProxyError: Error, CustomStringConvertible {
    case invalidPort(UInt16)
    case portInUse(UInt16, owner: String?)
    case listenerStartupFailed(String)
    case unsupportedPlatform

    public var description: String {
        switch self {
        case .invalidPort(let p): return "Invalid proxy port: \(p)"
        case .portInUse(let p, let owner):
            if let owner {
                return "Proxy port \(p) is already in use by \(owner). Stop the existing adb server or BlockADB instance, or choose a different --proxy-port."
            }
            return "Proxy port \(p) is already in use. Stop the existing adb server or BlockADB instance, or choose a different --proxy-port."
        case .listenerStartupFailed(let message):
            return "ADB proxy listener startup failed: \(message)"
        case .unsupportedPlatform: return "ADB proxy requires Network.framework (macOS/iOS only)"
        }
    }
}
