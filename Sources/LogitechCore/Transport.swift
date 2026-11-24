import Foundation
import IOKit
import IOKit.hid

public struct LogiInterface: Sendable {
    public var productID: Int
    public var product: String
    public var transport: String
    public var usagePage: Int
    public var usage: Int
}

/// One HID++ vendor interface (a Logitech receiver, or a Bluetooth device exposing HID++).
public final class HIDPPChannel {
    public let device: IOHIDDevice
    public let info: LogiInterface
    private var buffer = [UInt8](repeating: 0, count: 64)
    private var inbox: [[UInt8]] = []
    public var onReport: (([UInt8]) -> Void)?
    private var open = false

    init(device: IOHIDDevice, info: LogiInterface) { self.device = device; self.info = info }

    public func openChannel() -> Bool {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
        open = true
        let me = Unmanaged.passUnretained(self).toOpaque()
        buffer.withUnsafeMutableBufferPointer { p in
            IOHIDDeviceRegisterInputReportCallback(device, p.baseAddress!, 64, { ctx, _, _, _, reportID, report, length in
                let ch = Unmanaged<HIDPPChannel>.fromOpaque(ctx!).takeUnretainedValue()
                var bytes = Array(UnsafeBufferPointer(start: report, count: length))
                // The callback may or may not include the report ID as byte 0; HID++ always wants it there.
                if bytes.first != UInt8(truncatingIfNeeded: reportID) || reportID == 0 { if ![0x10, 0x11, 0x12].contains(bytes.first ?? 0) { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) } }
                ch.inbox.append(bytes)
                ch.onReport?(bytes)
            }, me)
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        return true
    }

    public func close() {
        guard open else { return }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)); open = false
    }

    @discardableResult
    public func send(_ bytes: [UInt8]) -> Bool {
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(bytes[0]), bytes, bytes.count) == kIOReturnSuccess
    }

    /// Sends a request and waits (spinning the run loop) for the matching answer or error.
    public func transact(device idx: UInt8, feature: UInt8, function: UInt8, params: [UInt8] = [], timeout: TimeInterval = 0.8) -> HIDPP.Parsed? {
        inbox.removeAll()
        guard send(HIDPP.request(device: idx, feature: feature, function: function, params: params)) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
            while !inbox.isEmpty {
                guard let p = HIDPP.parse(inbox.removeFirst()) else { continue }
                switch p {
                case .message(let m) where m.deviceIndex == idx && m.featureIndex == feature && m.softwareID == HIDPP.softwareID: return p
                case .error(let d, let f, _, _) where d == idx && f == feature: return p
                case .error10(let d, _, _, _) where d == idx: return p
                default: continue
                }
            }
        }
        return nil
    }
}

public enum LogitechDiscovery {
    public static let vendorID = 0x046D

    /// Every Logitech vendor-defined HID interface (receivers, and Bluetooth devices exposing HID++).
    public static func channels() -> [HIDPPChannel] {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: vendorID] as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return [] }
        func int(_ d: IOHIDDevice, _ k: String) -> Int { (IOHIDDeviceGetProperty(d, k as CFString) as? Int) ?? 0 }
        func str(_ d: IOHIDDevice, _ k: String) -> String { (IOHIDDeviceGetProperty(d, k as CFString) as? String) ?? "" }
        return set.compactMap { d in
            let page = int(d, kIOHIDPrimaryUsagePageKey)
            guard page == 0xFF00 || page == 0xFF43 else { return nil }
            return HIDPPChannel(device: d, info: LogiInterface(productID: int(d, kIOHIDProductIDKey), product: str(d, kIOHIDProductKey),
                                                               transport: str(d, kIOHIDTransportKey), usagePage: page, usage: int(d, kIOHIDPrimaryUsageKey)))
        }
    }
}
