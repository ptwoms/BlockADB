// Config.swift
// Configuration model for BlockADB
//
// Stores all tunable parameters: vendor ID allow/block lists, TCP port blocking,
// logging verbosity, and run-mode settings.  Values can be overridden via a JSON
// file at /etc/BlockADB/config.json or ~/.config/BlockADB/config.json.

import Foundation

/// Top-level configuration for the BlockADB daemon/tool.
public struct BlockADBConfig: Codable {

    // -------------------------------------------------------------------------
    // MARK: - USB vendor-ID lists
    // -------------------------------------------------------------------------

    /// USB vendor IDs (16-bit) that are *always* blocked regardless of any other
    /// setting.  Populated with well-known Android OEM IDs by default.
    public var blockedVendorIDs: [UInt16]

    /// USB vendor IDs that are *explicitly allowed* through, even when they
    /// appear in ``blockedVendorIDs``.  Useful for allowing specific developer
    /// devices on a workstation while blocking everything else.
    public var allowedVendorIDs: [UInt16]

    // -------------------------------------------------------------------------
    // MARK: - ADB interface fingerprint
    // -------------------------------------------------------------------------

    /// USB interface class used by the Android ADB function (vendor-specific).
    public var adbInterfaceClass: UInt8

    /// USB interface sub-class used by the ADB function.
    public var adbInterfaceSubClass: UInt8

    /// USB interface protocol used by the ADB function.
    public var adbInterfaceProtocol: UInt8

    // -------------------------------------------------------------------------
    // MARK: - Network / wireless ADB
    // -------------------------------------------------------------------------

    /// Block TCP port 5555 (default wireless-ADB port) via pfctl.
    public var blockNetworkADB: Bool

    /// Additional TCP ports to block (e.g. emulator ports 5554-5558).
    public var additionalBlockedPorts: [UInt16]

    // -------------------------------------------------------------------------
    // MARK: - Behavioural options
    // -------------------------------------------------------------------------

    /// Kill the `adb` host-side server process whenever an ADB device is detected.
    /// Automatically set to false in proxy mode (the server must stay alive).
    public var killADBServer: Bool

    /// If true, log every detected USB device even when it is *not* ADB.
    public var verboseUSBLogging: Bool

    /// Path where BlockADB writes its human-readable log.  nil = log only to
    /// the macOS unified logging system (recommended for daemon use).
    public var logFilePath: String?

    // -------------------------------------------------------------------------
    // MARK: - Proxy mode
    // -------------------------------------------------------------------------

    /// When true, BlockADB operates as a selective ADB service filter instead
    /// of killing the adb server entirely.  It relocates the real adb server to
    /// ``adbUpstreamPort`` and intercepts all client connections on
    /// ``adbProxyPort``, blocking only the services listed in
    /// ``blockedADBServices``.
    ///
    /// Proxy mode allows Android app debugging and APK installation while
    /// preventing raw file transfer (`adb push` / `adb pull`).
    public var proxyMode: Bool

    /// Port the transparent proxy listens on (what clients connect to).
    /// Must match the port adb clients expect — default 5037.
    public var adbProxyPort: UInt16

    /// Port the real adb server is relocated to when proxy mode is active.
    /// Default 5038.
    public var adbUpstreamPort: UInt16

    /// ADB service string prefixes that the proxy refuses to open.
    /// Any OPEN message whose service starts with one of these strings is
    /// rejected with a CLSE reply and never forwarded to the real server.
    ///
    /// Default ["sync:"] blocks `adb push` and `adb pull` while leaving
    /// install, shell, and JDWP services untouched.
    public var blockedADBServices: [String]

    // -------------------------------------------------------------------------
    // MARK: - Defaults
    // -------------------------------------------------------------------------

    public static let `default` = BlockADBConfig(
        blockedVendorIDs: KnownAndroidVendorID.all,
        allowedVendorIDs: [],
        adbInterfaceClass: 0xFF,
        adbInterfaceSubClass: 0x42,
        adbInterfaceProtocol: 0x01,
        blockNetworkADB: true,
        additionalBlockedPorts: [5554, 5556, 5557, 5558],
        killADBServer: false,
        verboseUSBLogging: false,
        logFilePath: nil,
        proxyMode: true,
        adbProxyPort: 5037,
        adbUpstreamPort: 5038,
        blockedADBServices: ["sync:"]
    )

    // -------------------------------------------------------------------------
    // MARK: - Persistence helpers
    // -------------------------------------------------------------------------

    /// Returns the first existing config-file URL searched in priority order.
    public static func resolveConfigFileURL() -> URL? {
        let candidates: [URL] = [
            URL(fileURLWithPath: "/etc/BlockADB/config.json"),
            URL(fileURLWithPath: (ProcessInfo.processInfo.environment["HOME"] ?? "/tmp")
                + "/.config/BlockADB/config.json")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Loads configuration from the first available config file, falling back
    /// to ``default`` when none is found or parsing fails.
    public static func load() -> BlockADBConfig {
        guard let url = resolveConfigFileURL(),
              let data = try? Data(contentsOf: url) else {
            return .default
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(BlockADBConfig.self, from: data)) ?? .default
    }

    /// Persists the current configuration to *path*.
    public func save(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

// -------------------------------------------------------------------------
// MARK: - Known Android Vendor IDs
// -------------------------------------------------------------------------

/// A catalogue of USB vendor IDs associated with Android OEMs.
/// Reference: https://developer.android.com/studio/run/device#VendorIds
public enum KnownAndroidVendorID {

    /// Acer
    public static let acer:         UInt16 = 0x0502
    /// HTC
    public static let htc:          UInt16 = 0x0BB4
    /// Dell
    public static let dell:         UInt16 = 0x413C
    /// Foxconn
    public static let foxconn:      UInt16 = 0x0489
    /// Fujitsu
    public static let fujitsu:      UInt16 = 0x04C5
    /// Google / AOSP
    public static let google:       UInt16 = 0x18D1
    /// Hisense
    public static let hisense:      UInt16 = 0x109B
    /// Huawei
    public static let huawei:       UInt16 = 0x12D1
    /// Kyocera
    public static let kyocera:      UInt16 = 0x0482
    /// Lenovo
    public static let lenovo:       UInt16 = 0x17EF
    /// LG Electronics
    public static let lg:           UInt16 = 0x1004
    /// Motorola
    public static let motorola:     UInt16 = 0x22B8
    /// Nokia
    public static let nokia:        UInt16 = 0x0421
    /// OnePlus
    public static let onePlus:      UInt16 = 0x2A96
    /// OPPO
    public static let oppo:         UInt16 = 0x22D9
    /// Realme
    public static let realme:       UInt16 = 0x3067
    /// Samsung
    public static let samsung:      UInt16 = 0x04E8
    /// Sharp
    public static let sharp:        UInt16 = 0x04DD
    /// Sony Mobile (formerly Sony Ericsson)
    public static let sony:         UInt16 = 0x0FCE
    /// Xiaomi / Mi
    public static let xiaomi:       UInt16 = 0x2717
    /// ZTE
    public static let zte:          UInt16 = 0x19D2

    /// The complete set of vendor IDs listed above.
    public static let all: [UInt16] = [
        acer, htc, dell, foxconn, fujitsu, google, hisense, huawei, kyocera,
        lenovo, lg, motorola, nokia, onePlus, oppo, realme, samsung, sharp,
        sony, xiaomi, zte
    ]
}
