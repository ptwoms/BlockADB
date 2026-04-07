// BlockADBTests.swift
// Unit tests for BlockADB core components.
//
// These tests exercise the pure-logic parts of BlockADBCore that do not
// require attached hardware, root privileges, or a live IOKit run loop.

import XCTest
@testable import BlockADBCore

final class ConfigTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: Default config
    // -----------------------------------------------------------------------

    func testDefaultConfigHasExpectedVendorIDs() {
        let config = BlockADBConfig.default
        XCTAssertTrue(config.blockedVendorIDs.contains(KnownAndroidVendorID.google),
                      "Default config should block Google/AOSP devices")
        XCTAssertTrue(config.blockedVendorIDs.contains(KnownAndroidVendorID.samsung),
                      "Default config should block Samsung devices")
        XCTAssertFalse(config.blockedVendorIDs.isEmpty,
                       "Default blockedVendorIDs must not be empty")
    }

    func testDefaultConfigADBInterfaceFingerprint() {
        let config = BlockADBConfig.default
        XCTAssertEqual(config.adbInterfaceClass,    0xFF, "ADB interface class must be 0xFF")
        XCTAssertEqual(config.adbInterfaceSubClass, 0x42, "ADB sub-class must be 0x42")
        XCTAssertEqual(config.adbInterfaceProtocol, 0x01, "ADB protocol must be 0x01")
    }

    func testDefaultConfigBlocksNetworkADB() {
        XCTAssertTrue(BlockADBConfig.default.blockNetworkADB)
    }

    func testDefaultConfigDoesNotKillADBServer() {
        XCTAssertFalse(BlockADBConfig.default.killADBServer,
                       "Default config must not kill the ADB server — proxy mode handles filtering")
    }

    func testDefaultConfigAllowedVendorIDsIsEmpty() {
        XCTAssertTrue(BlockADBConfig.default.allowedVendorIDs.isEmpty)
    }

    // -----------------------------------------------------------------------
    // MARK: JSON round-trip
    // -----------------------------------------------------------------------

    func testConfigJSONRoundTrip() throws {
        let original = BlockADBConfig.default
        let encoder  = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data     = try encoder.encode(original)
        let decoded  = try JSONDecoder().decode(BlockADBConfig.self, from: data)

        XCTAssertEqual(decoded.blockedVendorIDs,      original.blockedVendorIDs)
        XCTAssertEqual(decoded.allowedVendorIDs,      original.allowedVendorIDs)
        XCTAssertEqual(decoded.adbInterfaceClass,     original.adbInterfaceClass)
        XCTAssertEqual(decoded.adbInterfaceSubClass,  original.adbInterfaceSubClass)
        XCTAssertEqual(decoded.adbInterfaceProtocol,  original.adbInterfaceProtocol)
        XCTAssertEqual(decoded.blockNetworkADB,       original.blockNetworkADB)
        XCTAssertEqual(decoded.additionalBlockedPorts, original.additionalBlockedPorts)
        XCTAssertEqual(decoded.killADBServer,         original.killADBServer)
        XCTAssertEqual(decoded.verboseUSBLogging,     original.verboseUSBLogging)
        XCTAssertNil(decoded.logFilePath)
    }

    func testConfigJSONRoundTripWithLogFilePath() throws {
        var config = BlockADBConfig.default
        config.logFilePath = "/var/log/BlockADB.log"
        let data   = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(BlockADBConfig.self, from: data)
        XCTAssertEqual(decoded.logFilePath, "/var/log/BlockADB.log")
    }

    // -----------------------------------------------------------------------
    // MARK: Allowlist overrides blocklist
    // -----------------------------------------------------------------------

    func testAllowlistPreventBlocking() {
        var config = BlockADBConfig.default
        config.allowedVendorIDs = KnownAndroidVendorID.all
        XCTAssertTrue(config.allowedVendorIDs.contains(KnownAndroidVendorID.google))
    }

    // -----------------------------------------------------------------------
    // MARK: Persistence (temp file)
    // -----------------------------------------------------------------------

    func testConfigSaveAndLoad() throws {
        let path = "/tmp/BlockADBTestConfig-\(Int.random(in: 1000...9999)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }

        var config = BlockADBConfig.default
        config.verboseUSBLogging = true
        config.logFilePath = "/tmp/BlockADB.log"

        try config.save(to: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let loaded = (try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONDecoder().decode(BlockADBConfig.self, from: $0) }
        XCTAssertNotNil(loaded)
        XCTAssertTrue(loaded!.verboseUSBLogging)
        XCTAssertEqual(loaded!.logFilePath, "/tmp/BlockADB.log")
    }

    func testRuntimeSummaryDescribesDefaultDebugFriendlyMode() {
        let summary = BlockADBConfig.default.runtimeSummary
        XCTAssertTrue(summary.contains("mode=proxy"))
        XCTAssertTrue(summary.contains("proxyPort=5037"))
        XCTAssertTrue(summary.contains("blockedServices=[\"sync:\"]"))
    }
}

// ---------------------------------------------------------------------------
// MARK: - KnownAndroidVendorID tests
// ---------------------------------------------------------------------------

final class KnownAndroidVendorIDTests: XCTestCase {

    func testAllContainsGoogleVendorID() {
        XCTAssertTrue(KnownAndroidVendorID.all.contains(0x18D1))
    }

    func testAllContainsSamsungVendorID() {
        XCTAssertTrue(KnownAndroidVendorID.all.contains(0x04E8))
    }

    func testNoDuplicateVendorIDs() {
        let ids = KnownAndroidVendorID.all
        XCTAssertEqual(ids.count, Set(ids).count, "KnownAndroidVendorID.all must not contain duplicates")
    }

    func testAllIsNonEmpty() {
        XCTAssertFalse(KnownAndroidVendorID.all.isEmpty)
    }
}

// ---------------------------------------------------------------------------
// MARK: - ADBDeviceInfo tests
// ---------------------------------------------------------------------------

final class ADBDeviceInfoTests: XCTestCase {

    func testDescriptionContainsVendorAndProduct() {
        let info = ADBDeviceInfo(vendorID: 0x18D1, productID: 0x4EE7,
                                 productName: "Pixel 8",
                                 serialNumber: "ABC123",
                                 registryEntryID: 99)
        let desc = info.description
        XCTAssertTrue(desc.contains("18D1"), "Description should contain vendor ID")
        XCTAssertTrue(desc.contains("4EE7"), "Description should contain product ID")
        XCTAssertTrue(desc.contains("Pixel 8"))
    }

    func testDescriptionUnknownNameFallback() {
        let info = ADBDeviceInfo(vendorID: 0x18D1, productID: 0x4EE7,
                                 productName: "",
                                 serialNumber: "",
                                 registryEntryID: 0)
        XCTAssertTrue(info.description.contains("<unknown>"))
    }

    func testEquality() {
        let a = ADBDeviceInfo(vendorID: 0x18D1, productID: 0x4EE7,
                              productName: "Test", serialNumber: "S1",
                              registryEntryID: 1)
        let b = ADBDeviceInfo(vendorID: 0x18D1, productID: 0x4EE7,
                              productName: "Test", serialNumber: "S1",
                              registryEntryID: 1)
        XCTAssertEqual(a, b)
    }

    func testInequalityOnRegistryID() {
        let a = ADBDeviceInfo(vendorID: 0x18D1, productID: 0x4EE7,
                              productName: "Test", serialNumber: "S1",
                              registryEntryID: 1)
        let b = ADBDeviceInfo(vendorID: 0x18D1, productID: 0x4EE7,
                              productName: "Test", serialNumber: "S1",
                              registryEntryID: 2)
        XCTAssertNotEqual(a, b)
    }
}

// ---------------------------------------------------------------------------
// MARK: - BlockingResult tests
// ---------------------------------------------------------------------------

final class BlockingResultTests: XCTestCase {

    private let dummyDevice = ADBDeviceInfo(
        vendorID: 0x18D1, productID: 0x4EE7,
        productName: "Pixel", serialNumber: "SERIAL",
        registryEntryID: 42
    )

    func testWasBlockedTrueWhenPIDsKilled() {
        let result = BlockingResult(device: dummyDevice, killedPIDs: [1234], timestamp: Date())
        XCTAssertTrue(result.wasBlocked)
    }

    func testWasBlockedFalseWhenNoPIDs() {
        let result = BlockingResult(device: dummyDevice, killedPIDs: [], timestamp: Date())
        XCTAssertFalse(result.wasBlocked)
    }

    func testDescriptionMentionsPIDsWhenBlocked() {
        let result = BlockingResult(device: dummyDevice, killedPIDs: [9999], timestamp: Date())
        XCTAssertTrue(result.description.contains("9999"))
    }

    func testDescriptionNoPIDsMessage() {
        let result = BlockingResult(device: dummyDevice, killedPIDs: [], timestamp: Date())
        XCTAssertTrue(result.description.contains("no adb process"))
    }
}

// ---------------------------------------------------------------------------
// MARK: - ADBBlocker tests (no hardware required)
// ---------------------------------------------------------------------------

final class ADBBlockerTests: XCTestCase {

    func testFindADBProcessPIDsReturnsList() {
        // This is a pure sysctl call; we can't control whether "adb" is
        // running, but we can assert the method returns without crashing and
        // returns only non-negative PIDs.
        let config  = BlockADBConfig.default
        let blocker = ADBBlocker(config: config)
        let pids    = blocker.findADBProcessPIDs()
        XCTAssertTrue(pids.allSatisfy { $0 > 0 })
    }

    func testBlockDeviceWithNoKillReturnsFalseWasBlocked() {
        var config = BlockADBConfig.default
        config.killADBServer = false
        let blocker = ADBBlocker(config: config)
        let device  = ADBDeviceInfo(vendorID: 0x18D1, productID: 0x4EE7,
                                    productName: "", serialNumber: "",
                                    registryEntryID: 0)
        let result  = blocker.blockDevice(device)
        XCTAssertFalse(result.wasBlocked,
                       "When killADBServer is false, no PIDs should be killed")
        XCTAssertEqual(result.killedPIDs, [])
    }
}

// ---------------------------------------------------------------------------
// MARK: - NetworkBlocker tests (no root required — only tests safe paths)
// ---------------------------------------------------------------------------

final class NetworkBlockerTests: XCTestCase {

    func testInstallRulesIsNoOpWhenBlockNetworkADBIsFalse() {
        var config = BlockADBConfig.default
        config.blockNetworkADB = false
        // Should not throw, crash, or call pfctl.
        let blocker = NetworkBlocker(config: config)
        blocker.installRules()   // No-op path exercised.
    }

    func testRunWithNonExistentExecutableReturnsMinusOne() {
        let config  = BlockADBConfig.default
        let blocker = NetworkBlocker(config: config)
        let result  = blocker.run("/nonexistent/binary", args: [])
        XCTAssertEqual(result, -1,
                       "Running a non-existent binary should return -1")
    }
}

// ---------------------------------------------------------------------------
// MARK: - LogLevel ordering tests
// ---------------------------------------------------------------------------

final class LogLevelTests: XCTestCase {

    func testLogLevelOrdering() {
        XCTAssertLessThan(LogLevel.debug,   LogLevel.info)
        XCTAssertLessThan(LogLevel.info,    LogLevel.warning)
        XCTAssertLessThan(LogLevel.warning, LogLevel.error)
        XCTAssertLessThan(LogLevel.error,   LogLevel.fault)
    }

    func testAllCasesCount() {
        XCTAssertEqual(LogLevel.allCases.count, 5)
    }
}

// ---------------------------------------------------------------------------
// MARK: - ADBMessage serialisation tests
// ---------------------------------------------------------------------------

final class ADBProtocolTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: Serialisation round-trip helpers
    // -----------------------------------------------------------------------

    /// Builds a minimal valid ADB message and serialises it.
    private func makeMessage(command: ADBCommand,
                             arg0: UInt32 = 0,
                             arg1: UInt32 = 0,
                             data: Data = Data()) -> Data {
        ADBMessage(command: command, arg0: arg0, arg1: arg1, data: data).serialized()
    }

    // -----------------------------------------------------------------------
    // MARK: Header structure
    // -----------------------------------------------------------------------

    func testSerializedLengthWithoutPayload() {
        let bytes = makeMessage(command: .okay)
        XCTAssertEqual(bytes.count, ADBMessage.headerSize,
                       "A message with no payload must be exactly \(ADBMessage.headerSize) bytes")
    }

    func testSerializedLengthWithPayload() {
        let payload = Data("sync:\0".utf8)
        let bytes   = makeMessage(command: .open, data: payload)
        XCTAssertEqual(bytes.count, ADBMessage.headerSize + payload.count)
    }

    func testMagicFieldIsCommandXorMask() {
        let bytes = makeMessage(command: .open)
        // command is at offset 0, magic at offset 20 — both little-endian UInt32
        let cmd   = bytes[0..<4].withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        let magic = bytes[20..<24].withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        XCTAssertEqual(magic, cmd ^ 0xFFFF_FFFF)
    }

    func testDataLengthFieldMatchesPayload() {
        let payload = Data(repeating: 0xAB, count: 42)
        let bytes   = makeMessage(command: .wrte, data: payload)
        let dataLen = bytes[12..<16].withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        XCTAssertEqual(dataLen, 42)
    }

    // -----------------------------------------------------------------------
    // MARK: CLSE factory
    // -----------------------------------------------------------------------

    func testClseFactoryCommand() {
        let msg = ADBMessage.clse(remoteID: 7)
        XCTAssertEqual(msg.command, .clse)
        XCTAssertEqual(msg.arg0, 0,  "CLSE arg0 must be 0 (proxy has no local_id)")
        XCTAssertEqual(msg.arg1, 7,  "CLSE arg1 must equal the client local_id")
        XCTAssertTrue(msg.data.isEmpty)
    }

    // -----------------------------------------------------------------------
    // MARK: Service string accessor
    // -----------------------------------------------------------------------

    func testServiceStringParsedFromOpenPayload() {
        let svc  = "sync:"
        let data = Data((svc + "\0").utf8)
        let msg  = ADBMessage(command: .open, arg0: 1, arg1: 0, data: data)
        XCTAssertEqual(msg.serviceString, svc)
    }

    func testServiceStringWithoutNulTerminator() {
        let svc  = "shell:logcat"
        let data = Data(svc.utf8)           // no NUL — parser should still work
        let msg  = ADBMessage(command: .open, arg0: 1, arg1: 0, data: data)
        XCTAssertEqual(msg.serviceString, svc)
    }

    func testServiceStringNilForNonOpenCommand() {
        let msg = ADBMessage(command: .wrte, arg0: 1, arg1: 2, data: Data("hello".utf8))
        XCTAssertNil(msg.serviceString)
    }
}

// ---------------------------------------------------------------------------
// MARK: - ADBMessageParser tests
// ---------------------------------------------------------------------------

final class ADBMessageParserTests: XCTestCase {

    private func serialized(_ command: ADBCommand,
                            arg0: UInt32 = 0,
                            arg1: UInt32 = 0,
                            data: Data = Data()) -> Data {
        ADBMessage(command: command, arg0: arg0, arg1: arg1, data: data).serialized()
    }

    func testParseSingleCompleteMessage() {
        let parser = ADBMessageParser()
        let bytes  = serialized(.okay, arg0: 1, arg1: 2)
        let msgs   = parser.feed(bytes)

        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].command, .okay)
        XCTAssertEqual(msgs[0].arg0, 1)
        XCTAssertEqual(msgs[0].arg1, 2)
    }

    func testParseTwoConsecutiveMessages() {
        let parser = ADBMessageParser()
        var bytes  = serialized(.okay)
        bytes     += serialized(.clse, arg0: 3, arg1: 4)
        let msgs   = parser.feed(bytes)

        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].command, .okay)
        XCTAssertEqual(msgs[1].command, .clse)
        XCTAssertEqual(msgs[1].arg0, 3)
    }

    func testParseMessageWithPayload() {
        let parser  = ADBMessageParser()
        let payload = Data("sync:\0".utf8)
        let bytes   = serialized(.open, arg0: 5, data: payload)
        let msgs    = parser.feed(bytes)

        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].command, .open)
        XCTAssertEqual(msgs[0].serviceString, "sync:")
        XCTAssertEqual(msgs[0].data, payload)
    }

    func testParserBuffersIncompleteMessage() {
        let parser = ADBMessageParser()
        let full   = serialized(.okay)

        // Feed only the first half — should produce no complete message.
        let half   = full.prefix(full.count / 2)
        let first  = parser.feed(Data(half))
        XCTAssertEqual(first.count, 0, "Partial message must not be emitted")

        // Feed the second half — should now complete.
        let second = parser.feed(Data(full.dropFirst(half.count)))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].command, .okay)
    }

    func testParserByteByByte() {
        let parser  = ADBMessageParser()
        let bytes   = serialized(.wrte, arg0: 9, arg1: 10)
        var results = [ADBMessage]()

        for byte in bytes {
            results += parser.feed(Data([byte]))
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].command, .wrte)
        XCTAssertEqual(results[0].arg0, 9)
    }

    func testParserRejectsInvalidMagic() {
        // Craft a header with a wrong magic field — the parser should skip it.
        let parser = ADBMessageParser()
        var bad    = serialized(.okay)
        // Corrupt the magic bytes at offset 20
        bad[20] = 0xFF
        bad[21] = 0xFF
        bad[22] = 0xFF
        bad[23] = 0xFF

        // Feed corrupt header followed by a valid message.
        var stream = bad
        stream    += serialized(.clse, arg0: 1)
        let msgs   = parser.feed(stream)

        // The valid CLSE should eventually be found after re-sync.
        XCTAssertTrue(msgs.contains { $0.command == .clse },
                      "Parser should recover and emit the valid message after a bad magic")
    }

    func testParserReset() {
        let parser = ADBMessageParser()
        let half   = Data(serialized(.okay).prefix(10))
        _ = parser.feed(half)   // partial data buffered

        parser.reset()

        // After reset, feeding a new complete message should work cleanly.
        let msgs = parser.feed(serialized(.cnxn))
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].command, .cnxn)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Proxy service filter logic tests (no network required)
// ---------------------------------------------------------------------------

final class ADBProxyFilterTests: XCTestCase {

    /// Extracts service strings from OPEN messages and checks them against
    /// the blocked prefix list — mirrors the filter logic in ADBProxyConnection.
    private func isBlocked(_ service: String,
                           prefixes: [String] = ["sync:"]) -> Bool {
        prefixes.contains { service.hasPrefix($0) }
    }

    func testSyncServiceIsBlocked() {
        XCTAssertTrue(isBlocked("sync:"))
    }

    func testShellServiceIsAllowed() {
        XCTAssertFalse(isBlocked("shell:"))
    }

    func testShellWithCommandIsAllowed() {
        XCTAssertFalse(isBlocked("shell:logcat -v time"))
    }

    func testJDWPServiceIsAllowed() {
        XCTAssertFalse(isBlocked("jdwp:1234"))
    }

    func testTrackJDWPIsAllowed() {
        XCTAssertFalse(isBlocked("track-jdwp:"))
    }

    func testModernInstallServicesAreAllowed() {
        for svc in ["install:", "install-create:", "install-write:",
                    "install-commit:", "install-session:"] {
            XCTAssertFalse(isBlocked(svc), "\(svc) must not be blocked")
        }
    }

    func testForwardAndReverseAreAllowed() {
        XCTAssertFalse(isBlocked("forward:"))
        XCTAssertFalse(isBlocked("reverse:"))
    }

    func testCustomBlockedPrefixIsRespected() {
        XCTAssertTrue(isBlocked("shell:", prefixes: ["shell:", "sync:"]))
        XCTAssertFalse(isBlocked("jdwp:",  prefixes: ["shell:", "sync:"]))
    }

    func testClseMessageForBlockedStream() {
        // Verify that the CLSE rejection message carries the right IDs.
        let clientLocalID: UInt32 = 42
        let clse = ADBMessage.clse(remoteID: clientLocalID)
        XCTAssertEqual(clse.command, .clse)
        XCTAssertEqual(clse.arg0, 0,            "Proxy has no local_id for a rejected stream")
        XCTAssertEqual(clse.arg1, clientLocalID, "arg1 must echo the client's local_id")
    }
}

// ---------------------------------------------------------------------------
// MARK: - Proxy config tests
// ---------------------------------------------------------------------------

final class ProxyConfigTests: XCTestCase {

    func testDefaultProxyModeIsEnabled() {
        XCTAssertTrue(BlockADBConfig.default.proxyMode,
                      "Default config must enable proxy mode to block only file transfer")
    }

    func testDefaultProxyPorts() {
        let cfg = BlockADBConfig.default
        XCTAssertEqual(cfg.adbProxyPort,    5037)
        XCTAssertEqual(cfg.adbUpstreamPort, 5038)
    }

    func testDefaultBlockedServicesContainsSync() {
        XCTAssertTrue(BlockADBConfig.default.blockedADBServices.contains("sync:"))
    }

    func testProxyConfigRoundTrip() throws {
        var cfg = BlockADBConfig.default
        cfg.proxyMode           = true
        cfg.adbProxyPort        = 5037
        cfg.adbUpstreamPort     = 5039
        cfg.blockedADBServices  = ["sync:", "exec:"]

        let data    = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(BlockADBConfig.self, from: data)

        XCTAssertTrue(decoded.proxyMode)
        XCTAssertEqual(decoded.adbProxyPort,       5037)
        XCTAssertEqual(decoded.adbUpstreamPort,    5039)
        XCTAssertEqual(decoded.blockedADBServices, ["sync:", "exec:"])
    }
}

final class ADBProxyStartupDiagnosticsTests: XCTestCase {

    func testParseListeningProcessSummaryFromLsofFieldOutput() {
        let output = """
        p4242
        cadb
        n127.0.0.1:5037
        """

        XCTAssertEqual(
            ADBProxyServer.parseListeningProcessSummary(from: output),
            "adb (PID 4242) on 127.0.0.1:5037"
        )
    }

    func testPortInUseErrorIncludesHelpfulOwner() {
        let error = ADBProxyError.portInUse(5037, owner: "BlockADB (PID 9001) on 127.0.0.1:5037")
        XCTAssertTrue(error.description.contains("BlockADB"))
        XCTAssertTrue(error.description.contains("--proxy-port"))
    }
}
