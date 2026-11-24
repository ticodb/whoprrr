import Foundation

/// HID++ 2.0 framing (the protocol Logitech receivers and devices speak over vendor HID reports).
public enum HIDPP {
    public static let shortID: UInt8 = 0x10, longID: UInt8 = 0x11, veryLongID: UInt8 = 0x12
    public static let softwareID: UInt8 = 0x7   // 1...F; identifies replies meant for us

    public struct Message: Equatable, Sendable {
        public var deviceIndex: UInt8
        public var featureIndex: UInt8
        public var function: UInt8
        public var softwareID: UInt8
        public var params: [UInt8]
    }

    public enum Parsed: Equatable, Sendable {
        case message(Message)
        /// HID++ 2.0 error: the request for feature/function failed.
        case error(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, code: UInt8)
        /// HID++ 1.0 error (what a HID++ 1.0 receiver or device answers with).
        case error10(deviceIndex: UInt8, subID: UInt8, address: UInt8, code: UInt8)
    }

    /// Builds a request report: short (7 bytes) when the parameters fit in 3, else long (20 bytes).
    public static func request(device: UInt8, feature: UInt8, function: UInt8, params: [UInt8] = []) -> [UInt8] {
        let long = params.count > 3
        var b = [UInt8](repeating: 0, count: long ? 20 : 7)
        b[0] = long ? longID : shortID
        b[1] = device
        b[2] = feature
        b[3] = (function << 4) | (softwareID & 0x0F)
        for (i, p) in params.prefix(long ? 16 : 3).enumerated() { b[4 + i] = p }
        return b
    }

    public static func parse(_ bytes: [UInt8]) -> Parsed? {
        guard bytes.count >= 7, [shortID, longID, veryLongID].contains(bytes[0]) else { return nil }
        let dev = bytes[1], b2 = bytes[2]
        if b2 == 0x8F { return .error10(deviceIndex: dev, subID: bytes[3], address: bytes[4], code: bytes[5]) }
        if b2 == 0xFF { return .error(deviceIndex: dev, featureIndex: bytes[3], function: bytes[4] >> 4, code: bytes[5]) }
        return .message(Message(deviceIndex: dev, featureIndex: b2, function: bytes[3] >> 4, softwareID: bytes[3] & 0x0F, params: Array(bytes[4...])))
    }

    // MARK: Well-known feature IDs

    public enum FeatureID {
        public static let root: UInt16 = 0x0000, featureSet: UInt16 = 0x0001, deviceName: UInt16 = 0x0005
        public static let battery: UInt16 = 0x1004
        public static let reprogControlsV4: UInt16 = 0x1B04
        public static let adjustableDPI: UInt16 = 0x2201, smartShift: UInt16 = 0x2110, hiResWheel: UInt16 = 0x2121
        public static let thumbWheel: UInt16 = 0x2150
    }

    public static func name(of id: UInt16) -> String {
        switch id {
        case 0x0000: "IRoot"; case 0x0001: "IFeatureSet"; case 0x0003: "DeviceFwVersion"; case 0x0005: "DeviceNameType"
        case 0x1000: "BatteryLevel"; case 0x1004: "UnifiedBattery"; case 0x1B00: "ReprogControls"; case 0x1B04: "ReprogControlsV4"
        case 0x1D4B: "WirelessDeviceStatus"; case 0x2100: "VerticalScroll"; case 0x2110: "SmartShift"; case 0x2121: "HiResWheel"
        case 0x2150: "ThumbWheel"; case 0x2200: "MousePointer"; case 0x2201: "AdjustableDPI"; case 0x4521: "DisableKeys"
        case 0x1814: "ChangeHost"; case 0x1982: "BacklightV2"; case 0x4100: "KeyboardLayout"; case 0x4530: "DualPlatform"
        case 0x1E00: "HiddenFeatures"; case 0x1F20: "ADC"; case 0x8100: "OnboardProfiles"; case 0x1B10: "ControlList"
        default: String(format: "0x%04X", id)
        }
    }
}
