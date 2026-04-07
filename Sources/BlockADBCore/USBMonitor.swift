// USBMonitor.swift
// IOKit-based USB device monitor for BlockADB.
//
// Registers IOKit matching notifications for USB device attach/detach events.
// When a device matching a known Android vendor ID *and* exposing the ADB
// interface fingerprint is detected, the provided callback is invoked so that
// ADBBlocker can act on it.
//
// macOS USB communication overview
// ---------------------------------
// USB devices enumerate through the IOUSBHostDevice/IOUSBDevice driver stack.
// Each device is described by a set of IOKit properties including:
//   kUSBVendorID   (idVendor  in the USB descriptor)   — identifies the OEM
//   kUSBProductID  (idProduct in the USB descriptor)   — identifies the model
// Each USB *interface* on the device exposes:
//   kUSBInterfaceClass      — 0xFF = vendor-specific (used by ADB)
//   kUSBInterfaceSubClass   — 0x42 (ADB sub-class)
//   kUSBInterfaceProtocol   — 0x01 (ADB protocol)
//
// ADB transport details
// ----------------------
// When USB Debugging is enabled on an Android device the firmware exposes a
// vendor-specific USB interface (class 0xFF / sub-class 0x42 / protocol 0x01).
// The host-side ADB server opens a bulk-transfer endpoint on that interface to
// send/receive ADB messages.  Killing the host-side `adb` process or removing
// the IOUSBInterface service severs this communication channel.

import Foundation
#if os(macOS)
import IOKit
import IOKit.usb
#endif

// ---------------------------------------------------------------------------
// MARK: - ADB device descriptor
// ---------------------------------------------------------------------------

/// Describes a USB device that has been identified as running ADB.
public struct ADBDeviceInfo: Equatable, CustomStringConvertible {
    public let vendorID:  UInt16
    public let productID: UInt16
    /// Human-readable product name reported by the device (may be empty).
    public let productName: String
    /// Serial number reported by the device (may be empty).
    public let serialNumber: String
    /// IOKit registry entry ID — unique per session.
    public let registryEntryID: UInt64

    public var description: String {
        "ADBDevice(vendor=0x\(String(vendorID, radix: 16, uppercase: true)), "
        + "product=0x\(String(productID, radix: 16, uppercase: true)), "
        + "name=\(productName.isEmpty ? "<unknown>" : productName), "
        + "serial=\(serialNumber.isEmpty ? "<none>" : serialNumber))"
    }
}

// ---------------------------------------------------------------------------
// MARK: - USB monitor
// ---------------------------------------------------------------------------

/// Monitors USB bus events via IOKit and calls back when ADB-capable Android
/// devices connect or disconnect.
///
/// - Note: USB monitoring is only operational on macOS.  On other platforms
///   ``start()`` is a no-op and a warning is logged.
public final class USBMonitor {

    // -----------------------------------------------------------------------
    // MARK: Public API
    // -----------------------------------------------------------------------

    public typealias DeviceCallback = (ADBDeviceInfo) -> Void

    /// Called when an ADB device is attached.
    public var onDeviceAttached: DeviceCallback?
    /// Called when an ADB device is detached.
    public var onDeviceDetached: DeviceCallback?

    private let config: BlockADBConfig
    private let logger: ADBLogger

    public init(config: BlockADBConfig = .default, logger: ADBLogger = .shared) {
        self.config = config
        self.logger = logger
    }

    // -----------------------------------------------------------------------
    // MARK: Start / stop
    // -----------------------------------------------------------------------

    private var runLoopThread: Thread?

    /// Starts USB monitoring on a dedicated background run-loop thread.
    public func start() {
#if os(macOS)
        let thread = Thread { [weak self] in self?.runMonitorLoop() }
        thread.name = "com.blockADB.usbMonitor"
        thread.qualityOfService = .userInitiated
        runLoopThread = thread
        thread.start()
#else
        logger.log("USB monitoring is not supported on this platform", level: .warning)
#endif
    }

    /// Stops USB monitoring and cleans up IOKit resources.
    public func stop() {
#if os(macOS)
        _stop()
#endif
    }

// -----------------------------------------------------------------------
// MARK: macOS-only implementation
// -----------------------------------------------------------------------

#if os(macOS)
    private var notificationPort: IONotificationPortRef?
    private var addedIterator:    io_iterator_t = 0
    private var removedIterator:  io_iterator_t = 0
    private var runLoop: CFRunLoop?

    private func _stop() {
        if let rl = runLoop { CFRunLoopStop(rl) }
        if addedIterator   != 0 { IOObjectRelease(addedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
        if let port = notificationPort { IONotificationPortDestroy(port) }
        notificationPort = nil
    }

    private func runMonitorLoop() {
        runLoop = CFRunLoopGetCurrent()

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logger.log("Failed to create IONotificationPort", level: .fault)
            return
        }
        notificationPort = port

        let runLoopSource = IONotificationPortGetRunLoopSource(port)!.takeUnretainedValue()
        CFRunLoopAddSource(runLoop, runLoopSource, .defaultMode)

        // Match on IOUSBInterface to inspect individual interface descriptors.
        let matchingDict = IOServiceMatching(kIOUSBInterfaceClassName) as NSMutableDictionary

        // Context pointer carries `self` across the C callback boundary.
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        // ---- Attach notification ----
        let addResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matchingDict,
            { context, iterator in
                guard let ctx = context else { return }
                let monitor = Unmanaged<USBMonitor>.fromOpaque(ctx).takeUnretainedValue()
                monitor.handleIterator(iterator!, attached: true)
            },
            selfPtr,
            &addedIterator
        )
        guard addResult == KERN_SUCCESS else {
            logger.log("Failed to add attach notification: \(addResult)", level: .fault)
            return
        }

        // ---- Detach notification ----
        let detachMatchingDict = IOServiceMatching(kIOUSBInterfaceClassName) as NSMutableDictionary
        let removeResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            detachMatchingDict,
            { context, iterator in
                guard let ctx = context else { return }
                let monitor = Unmanaged<USBMonitor>.fromOpaque(ctx).takeUnretainedValue()
                monitor.handleIterator(iterator!, attached: false)
            },
            selfPtr,
            &removedIterator
        )
        guard removeResult == KERN_SUCCESS else {
            logger.log("Failed to add detach notification: \(removeResult)", level: .fault)
            return
        }

        // Drain initial iterators so existing devices are processed and IOKit
        // starts delivering future notifications.
        handleIterator(addedIterator, attached: true)
        handleIterator(removedIterator, attached: false)

        logger.log("USB monitor started — watching for ADB interfaces", level: .info)
        CFRunLoopRun()
        logger.log("USB monitor stopped", level: .info)

        // Balance the passRetained above once the run loop exits.
        Unmanaged<USBMonitor>.fromOpaque(selfPtr).release()
    }

    // -----------------------------------------------------------------------
    // MARK: Private — iterator processing
    // -----------------------------------------------------------------------

    private func handleIterator(_ iterator: io_iterator_t, attached: Bool) {
        var service: io_service_t = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let info = adbDeviceInfo(from: service) else {
                if config.verboseUSBLogging {
                    logger.log("Non-ADB USB interface \(attached ? "attached" : "detached")",
                               level: .debug)
                }
                continue
            }

            logger.log("ADB interface \(attached ? "attached" : "detached"): \(info)",
                       level: .info)
            if attached {
                onDeviceAttached?(info)
            } else {
                onDeviceDetached?(info)
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Private — ADB interface detection
    // -----------------------------------------------------------------------

    /// Returns an ``ADBDeviceInfo`` if *service* (an IOUSBInterface) exposes
    /// the ADB interface fingerprint and belongs to a blocked vendor ID.
    /// Returns nil for non-ADB or explicitly-allowed devices.
    private func adbDeviceInfo(from service: io_service_t) -> ADBDeviceInfo? {
        guard
            let ifClass    = ioProperty(service, key: kUSBInterfaceClass)    as? UInt8,
            let ifSubClass = ioProperty(service, key: kUSBInterfaceSubClass) as? UInt8,
            let ifProtocol = ioProperty(service, key: kUSBInterfaceProtocol) as? UInt8,
            ifClass    == config.adbInterfaceClass,
            ifSubClass == config.adbInterfaceSubClass,
            ifProtocol == config.adbInterfaceProtocol
        else {
            return nil
        }

        var parent: io_service_t = IO_OBJECT_NULL
        var kr = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
        guard kr == KERN_SUCCESS, parent != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(parent) }

        guard
            let vendorIDRaw  = ioProperty(parent, key: kUSBVendorID)  as? Int,
            let productIDRaw = ioProperty(parent, key: kUSBProductID) as? Int
        else {
            return nil
        }
        let vendorID  = UInt16(bitPattern: Int16(vendorIDRaw))
        let productID = UInt16(bitPattern: Int16(productIDRaw))

        if config.allowedVendorIDs.contains(vendorID) { return nil }
        guard config.blockedVendorIDs.contains(vendorID) else { return nil }

        let productName  = ioProperty(parent, key: kUSBProductString)       as? String ?? ""
        let serialNumber = ioProperty(parent, key: kUSBSerialNumberString)  as? String ?? ""

        var entryID: UInt64 = 0
        kr = IORegistryEntryGetRegistryEntryID(service, &entryID)
        if kr != KERN_SUCCESS { entryID = 0 }

        return ADBDeviceInfo(
            vendorID:        vendorID,
            productID:       productID,
            productName:     productName,
            serialNumber:    serialNumber,
            registryEntryID: entryID
        )
    }

    // -----------------------------------------------------------------------
    // MARK: Private — IOKit helpers
    // -----------------------------------------------------------------------

    private func ioProperty(_ service: io_service_t, key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
#endif
}
