// ADBProtocol.swift
// ADB wire-protocol message types and incremental byte parser.
//
// ADB message framing
// --------------------
// Every ADB message consists of a fixed 24-byte header followed by an
// optional variable-length payload.  All header fields are 32-bit integers
// stored in little-endian byte order:
//
//   Offset  Size  Field        Description
//   0       4     command      Command identifier (see ADBCommand enum)
//   4       4     arg0         First argument (meaning is command-specific)
//   8       4     arg1         Second argument (meaning is command-specific)
//   12      4     data_length  Byte length of the payload that follows
//   16      4     data_crc32   CRC-32 of payload (ignored by modern adb)
//   20      4     magic        command XOR 0xFFFF_FFFF — framing sentinel
//
// OPEN semantics (used for service filtering)
// --------------------------------------------
//   arg0 = local_id   — non-zero stream ID chosen by the sender
//   arg1 = 0
//   data = service string, NUL-terminated UTF-8
//          e.g. "sync:\0", "shell:logcat\0", "jdwp:1234\0"
//
// Rejection of an OPEN (sent by proxy back to client)
// -----------------------------------------------------
//   CLSE(arg0=0, arg1=client_local_id)
//   arg0 is 0 because the proxy never assigned a local_id for this stream.

import Foundation

// ---------------------------------------------------------------------------
// MARK: - Command enum
// ---------------------------------------------------------------------------

/// All command identifiers defined by the ADB wire protocol.
public enum ADBCommand: UInt32, CustomStringConvertible {
    /// Version/feature negotiation — first message exchanged on connect.
    case cnxn = 0x4E584E43   // "CNXN"
    /// Public-key authentication handshake.
    case auth = 0x48545541   // "AUTH"
    /// Open a new logical stream to the named service.
    case open = 0x4E45504F   // "OPEN"
    /// Close a logical stream.
    case clse = 0x45534C43   // "CLSE"
    /// Write payload bytes to an open stream.
    case wrte = 0x45545257   // "WRTE"
    /// Acknowledge receipt of a WRTE or confirm an OPEN.
    case okay = 0x59414B4F   // "OKAY"

    public var description: String {
        switch self {
        case .cnxn: return "CNXN"
        case .auth: return "AUTH"
        case .open: return "OPEN"
        case .clse: return "CLSE"
        case .wrte: return "WRTE"
        case .okay: return "OKAY"
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Message
// ---------------------------------------------------------------------------

/// One complete ADB protocol message.
public struct ADBMessage {

    /// Byte size of the fixed header.
    public static let headerSize = 24

    public let command: ADBCommand
    /// First argument — meaning is command-specific (see file header).
    public let arg0: UInt32
    /// Second argument — meaning is command-specific.
    public let arg1: UInt32
    /// Variable-length payload (may be empty).
    public let data: Data

    // -----------------------------------------------------------------------
    // MARK: Convenience accessors
    // -----------------------------------------------------------------------

    /// The NUL-terminated service string from an OPEN message.
    /// Returns nil for all other command types or on decoding failure.
    public var serviceString: String? {
        guard command == .open, !data.isEmpty else { return nil }
        let payload = data.last == 0 ? data.dropLast() : data   // strip NUL
        return String(bytes: payload, encoding: .utf8)
    }

    // -----------------------------------------------------------------------
    // MARK: Serialisation
    // -----------------------------------------------------------------------

    /// Returns the on-wire byte representation of this message.
    public func serialized() -> Data {
        var out = Data(capacity: ADBMessage.headerSize + data.count)
        let dataLen = UInt32(data.count)
        let magic   = command.rawValue ^ 0xFFFF_FFFF

        func appendLE(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }

        appendLE(command.rawValue)
        appendLE(arg0)
        appendLE(arg1)
        appendLE(dataLen)
        appendLE(0)      // CRC — set to 0; modern adb ignores it
        appendLE(magic)
        out.append(data)
        return out
    }

    // -----------------------------------------------------------------------
    // MARK: Factory helpers
    // -----------------------------------------------------------------------

    /// Builds the CLSE message the proxy sends to reject a client OPEN.
    /// Per protocol: arg0=0 (proxy has no local_id), arg1=client's local_id.
    public static func clse(remoteID: UInt32) -> ADBMessage {
        ADBMessage(command: .clse, arg0: 0, arg1: remoteID, data: Data())
    }
}

// ---------------------------------------------------------------------------
// MARK: - Incremental parser
// ---------------------------------------------------------------------------

/// Accumulates raw bytes from a TCP stream and emits complete ``ADBMessage``
/// values as they arrive.
///
/// ADB is a binary framing protocol: a 24-byte header declares the payload
/// length, so the parser must buffer bytes across multiple read callbacks
/// until a complete message is available.
///
/// - Note: Not thread-safe — call from a single dispatch queue.
public final class ADBMessageParser {

    private var buffer = Data()

    // -----------------------------------------------------------------------
    // MARK: Public API
    // -----------------------------------------------------------------------

    /// Feed newly received bytes into the parser.
    /// Returns every complete message that can be extracted from the
    /// accumulated buffer (zero or more per call).
    public func feed(_ bytes: Data) -> [ADBMessage] {
        buffer.append(bytes)
        var messages: [ADBMessage] = []

        while buffer.count >= ADBMessage.headerSize {
            let cmdRaw  = le32(at: 0)
            let arg0    = le32(at: 4)
            let arg1    = le32(at: 8)
            let dataLen = le32(at: 12)
            // offset 16 = crc32 (skipped)
            let magic   = le32(at: 20)

            // Magic validation catches framing errors.
            guard magic == (cmdRaw ^ 0xFFFF_FFFF) else {
                buffer.removeFirst()   // discard one byte and try to re-sync
                continue
            }

            let totalLen = ADBMessage.headerSize + Int(dataLen)
            guard buffer.count >= totalLen else { break }   // wait for payload

            // Skip unknown commands rather than treating them as errors.
            guard let command = ADBCommand(rawValue: cmdRaw) else {
                buffer.removeFirst(totalLen)
                continue
            }

            let payloadStart = buffer.startIndex + ADBMessage.headerSize
            let payloadEnd   = buffer.startIndex + totalLen
            let payload      = dataLen > 0 ? Data(buffer[payloadStart ..< payloadEnd]) : Data()

            messages.append(
                ADBMessage(command: command, arg0: arg0, arg1: arg1, data: payload)
            )
            buffer.removeFirst(totalLen)
        }

        return messages
    }

    /// Resets the parser's internal buffer (e.g. on connection close).
    public func reset() { buffer.removeAll() }

    // -----------------------------------------------------------------------
    // MARK: Private
    // -----------------------------------------------------------------------

    private func le32(at offset: Int) -> UInt32 {
        let s = buffer.startIndex + offset
        return buffer[s ..< s + 4].withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }
    }
}
