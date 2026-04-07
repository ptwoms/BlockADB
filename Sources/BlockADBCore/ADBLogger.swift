// ADBLogger.swift
// Centralised logging for BlockADB using the macOS Unified Logging system.
//
// All messages are written to the subsystem "com.blockADB" so that they can
// be queried with:
//   log stream --predicate 'subsystem == "com.blockADB"'
// Optional file-based logging is also supported when a path is configured.

import Foundation
#if canImport(os)
import os.log
#endif

/// Severity levels mirroring OSLogType.
public enum LogLevel: String, CaseIterable, Comparable {
    case debug   = "DEBUG"
    case info    = "INFO"
    case warning = "WARNING"
    case error   = "ERROR"
    case fault   = "FAULT"

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel] = [.debug, .info, .warning, .error, .fault]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }

#if canImport(os)
    var osLogType: OSLogType {
        switch self {
        case .debug:   return .debug
        case .info:    return .info
        case .warning: return .default
        case .error:   return .error
        case .fault:   return .fault
        }
    }
#endif
}

/// Thread-safe logger that writes to the macOS Unified Logging system and,
/// optionally, to a plain-text log file.
public final class ADBLogger {

    public static let shared = ADBLogger()

#if canImport(os)
    private let osLog = OSLog(subsystem: "com.blockADB", category: "main")
#endif
    private let queue = DispatchQueue(label: "com.blockADB.logger", qos: .utility)
    private var fileHandle: FileHandle?
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {}

    /// Configures optional file-based logging.  Must be called once before
    /// the first ``log(_:level:)`` call if file output is desired.
    public func configure(logFilePath: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.fileHandle?.closeFile()
            self.fileHandle = nil
            guard let path = logFilePath else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: path) {
                fm.createFile(atPath: path, contents: nil)
            }
            self.fileHandle = FileHandle(forWritingAtPath: path)
            self.fileHandle?.seekToEndOfFile()
        }
    }

    /// Writes *message* at *level* to the unified log and, if configured,
    /// to the log file.
    public func log(_ message: String, level: LogLevel = .info) {
#if canImport(os)
        os_log("%{public}s", log: osLog, type: level.osLogType, message)
#endif
        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = self.dateFormatter.string(from: Date())
            let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
            if let data = line.data(using: .utf8) {
                self.fileHandle?.write(data)
            }
        }
    }

    deinit {
        fileHandle?.closeFile()
    }
}

