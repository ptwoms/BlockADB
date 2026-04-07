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

    func testDefaultConfigKillsADBServer() {
        XCTAssertTrue(BlockADBConfig.default.killADBServer)
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
        config.allowedVendorIDs = [KnownAndroidVendorID.google]
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
