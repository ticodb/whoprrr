import Foundation

/// A DDC/CI feature, identified by its VCP code. Known features have static names; any other code
/// (including Samsung manufacturer-specific ones the user has "learned") is still a valid `Control`.
public struct Control: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(_ code: UInt8) { rawValue = code }
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let brightness = Control(0x10)
    public static let contrast = Control(0x12)
    public static let colorPreset = Control(0x14)
    public static let red = Control(0x16)
    public static let green = Control(0x18)
    public static let blue = Control(0x1A)
    public static let input = Control(0x60)
    public static let volume = Control(0x62)
    public static let sharpness = Control(0x87)

    /// Known controls in the order presets apply them (color preset before RGB gain).
    public static let allCases: [Control] = [.brightness, .contrast, .colorPreset, .red, .green, .blue, .sharpness, .volume, .input]

    public var label: String { Catalog.spec(for: self)?.label ?? String(format: "VCP 0x%02X", rawValue) }
    public var key: String { Catalog.spec(for: self)?.key ?? String(format: "vcp%02x", rawValue) }
    public var description: String { label }

    public static func from(key: String) -> Control? {
        if let c = allCases.first(where: { $0.key == key }) { return c }
        if key.hasPrefix("vcp"), let v = UInt8(key.dropFirst(3), radix: 16) { return Control(v) }
        return nil
    }

    /// Writes allowed without an explicit opt-in: brightness (hardware-verified) plus whatever
    /// `Catalog` marks verified. Everything else is read-only until proven on the hardware.
    public static var defaultWritable: Set<Control> { Set(Catalog.known.filter(\.hardwareVerified).map(\.control)) }
}

public struct ControlValue: Equatable, Codable, Sendable {
    public var current: Int
    public var maximum: Int
    public init(current: Int, maximum: Int) {
        self.current = current
        self.maximum = maximum
    }
}

public enum TransportKind: String, Codable, Sendable {
    case hardware
    case fake
}

/// Failure categories the UI and logs must tell apart.
public enum DDCFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupported                 // display said it does not implement this control
    case timeout                     // no valid reply after all attempts
    case disconnected                // no DDC endpoint for this display (unplugged or not resolvable)
    case stale                       // the connection generation changed since the target was chosen
    case outOfRange(requested: Int, maximum: Int)
    case notWritable(Control)        // control not enabled for writes
    case builtInRefused              // the MacBook panel is a comparison reference, never a write target
    case ambiguousTarget             // identity matches more than one live display
    case identityMismatch            // preset belongs to a different display
    case refused                     // transport allowlist rejected the control
    case io(Int32)

    public var description: String {
        switch self {
        case .unsupported: return "unsupported"
        case .timeout: return "timeout (no valid reply)"
        case .disconnected: return "disconnected"
        case .stale: return "stale target (connection changed)"
        case .outOfRange(let r, let m): return "out of range (\(r) > max \(m))"
        case .notWritable(let c): return "\(c.label) writes are not enabled"
        case .builtInRefused: return "built-in display is read-only reference"
        case .ambiguousTarget: return "ambiguous display identity, reselect"
        case .identityMismatch: return "preset belongs to a different display"
        case .refused: return "refused by transport"
        case .io(let code): return "IOKit error 0x\(String(UInt32(bitPattern: code), radix: 16))"
        }
    }
}

/// Hardware-derived identity used to recognise a display across sessions.
/// `CGDirectDisplayID` is deliberately absent: it is a session handle.
public struct DisplayIdentity: Codable, Hashable, Sendable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var alphaSerial: String?
    public var productName: String
    public var manufacturer: String?

    public init(vendor: UInt32, model: UInt32, serial: UInt32, alphaSerial: String?,
                productName: String, manufacturer: String?) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.alphaSerial = (alphaSerial?.isEmpty ?? true) ? nil : alphaSerial
        self.productName = productName
        self.manufacturer = (manufacturer?.isEmpty ?? true) ? nil : manufacturer
    }

    /// Identity is only trusted when something unique (a serial) is present.
    public var isStrong: Bool { serial != 0 || alphaSerial != nil }

    /// Same physical monitor model and serial.
    public func matches(_ other: DisplayIdentity) -> Bool {
        vendor == other.vendor && model == other.model && serial == other.serial
            && alphaSerial == other.alphaSerial
    }
}

/// One live display as seen during the most recent scan.
public struct DisplayDescriptor: Identifiable, Hashable, Sendable {
    public var id: String { uuid }
    public var uuid: String                // macOS system UUID: session-scoped, used to reach the endpoint
    public var edidUUID: String?
    public var displayID: UInt32           // CGDirectDisplayID: session handle
    public var identity: DisplayIdentity
    public var isBuiltIn: Bool
    public var hasEndpoint: Bool           // a DDC endpoint was resolved

    public init(uuid: String, edidUUID: String?, displayID: UInt32, identity: DisplayIdentity,
                isBuiltIn: Bool, hasEndpoint: Bool) {
        self.uuid = uuid
        self.edidUUID = edidUUID
        self.displayID = displayID
        self.identity = identity
        self.isBuiltIn = isBuiltIn
        self.hasEndpoint = hasEndpoint
    }

    public var shortName: String {
        isBuiltIn && identity.productName == "Unknown Display" ? "MacBook display" : identity.productName
    }

    public var displayName: String {
        isBuiltIn ? "\(shortName) (built-in, reference)" : identity.productName
    }
}

/// An explicitly chosen write target, bound to the connection generation in which it was resolved.
public struct DisplayTarget: Hashable, Sendable {
    public var uuid: String
    public var identity: DisplayIdentity
    public var generation: UInt64
    public init(uuid: String, identity: DisplayIdentity, generation: UInt64) {
        self.uuid = uuid
        self.identity = identity
        self.generation = generation
    }
}

public struct WriteOutcome: Equatable, Sendable {
    public var control: Control
    public var requested: Int
    public var applied: Int          // after clamping to the verified range
    public var before: Int?          // value read just before the write, when available
    public var readback: Int?        // value read after the write; nil = readback failed
    public var verified: Bool { readback == applied }
    /// The display accepted the write but settled on a different step (quantized control).
    public var adjusted: Bool { if let r = readback, r != applied, r != before { return true }; return false }
    public var accepted: Bool { verified || adjusted }
    public var maximum: Int
}
