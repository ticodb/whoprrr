import Foundation
import CDDC

/// Synchronous DDC access. Implementations are not thread-safe; `DisplayController` is the only
/// caller and serializes every call on a single worker queue.
public protocol DDCTransport: AnyObject, Sendable {
    var kind: TransportKind { get }
    func scan() -> [DisplayDescriptor]
    func read(_ control: Control, uuid: String) throws -> ControlValue
    func write(_ control: Control, value: Int, uuid: String) throws
}

// MARK: - Hardware (vendored m1ddc transport behind CDDC)

public final class HardwareTransport: DDCTransport, @unchecked Sendable {
    public let kind: TransportKind = .hardware
    public var readWaitMicros: UInt32
    public var readAttempts: Int

    public init(readWaitMicros: UInt32 = 50_000, readAttempts: Int = 4) {
        self.readWaitMicros = readWaitMicros
        self.readAttempts = readAttempts
    }

    public func scan() -> [DisplayDescriptor] {
        var buffer = [CDDCDisplay](repeating: CDDCDisplay(), count: Int(CDDC_MAX_DISPLAYS))
        let count = Int(cddc_list_displays(&buffer, Int32(buffer.count)))
        return buffer.prefix(count).map { d in
            var d = d
            func str<T>(_ t: inout T) -> String {
                withUnsafePointer(to: &t) {
                    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
                }
            }
            let name = str(&d.productName)
            let identity = DisplayIdentity(
                vendor: d.vendor, model: d.model, serial: d.serial,
                alphaSerial: str(&d.alphaSerial), productName: name.isEmpty ? "Unknown Display" : name,
                manufacturer: str(&d.manufacturer))
            let edid = str(&d.edidUUID)
            return DisplayDescriptor(
                uuid: str(&d.uuid), edidUUID: edid.isEmpty ? nil : edid, displayID: d.displayID,
                identity: identity, isBuiltIn: d.isBuiltIn, hasEndpoint: d.hasDDCEndpoint)
        }
    }

    public func read(_ control: Control, uuid: String) throws -> ControlValue {
        var cur: UInt16 = 0
        var max: UInt16 = 0
        var io: Int32 = 0
        let status = cddc_read(uuid, control.rawValue, readWaitMicros, Int32(readAttempts), &cur, &max, &io)
        try Self.check(status, io)
        return ControlValue(current: Int(cur), maximum: Int(max))
    }

    public func write(_ control: Control, value: Int, uuid: String) throws {
        guard value >= 0, value <= Int(UInt16.max) else { throw DDCFailure.outOfRange(requested: value, maximum: Int(UInt16.max)) }
        var io: Int32 = 0
        let status = cddc_write(uuid, control.rawValue, UInt16(value), &io)
        try Self.check(status, io)
    }

    /// Raw VCP read by code, for discovery scans only. Never used for writes.
    public func readRaw(vcp: UInt8, uuid: String, attempts: Int = 2) throws -> ControlValue {
        var cur: UInt16 = 0, max: UInt16 = 0
        var io: Int32 = 0
        let status = cddc_read(uuid, vcp, readWaitMicros, Int32(attempts), &cur, &max, &io)
        try Self.check(status, io)
        return ControlValue(current: Int(cur), maximum: Int(max))
    }

    static func check(_ status: CDDCStatus, _ io: Int32) throws {
        switch status {
        case CDDC_OK: return
        case CDDC_NO_DISPLAY, CDDC_NO_TRANSPORT: throw DDCFailure.disconnected
        case CDDC_UNSUPPORTED: throw DDCFailure.unsupported
        case CDDC_NO_VALID_REPLY: throw DDCFailure.timeout
        case CDDC_REFUSED: throw DDCFailure.refused
        default: throw DDCFailure.io(io)
        }
    }
}

// MARK: - Fake (tests and hardware-less development)

public final class FakeTransport: DDCTransport, @unchecked Sendable {
    public let kind: TransportKind = .fake

    public struct WriteRecord: Equatable, Sendable {
        public var uuid: String
        public var control: Control
        public var value: Int
    }

    private let lock = NSLock()
    private var _displays: [DisplayDescriptor]
    private var values: [String: [Control: ControlValue]] = [:]
    private var readFailures: [Control: DDCFailure] = [:]
    private var writeFailures: [Control: DDCFailure] = [:]
    private var _writes: [WriteRecord] = []
    private var _reads: Int = 0
    /// Called before each read/write; tests use it to simulate unplug mid-operation.
    public var beforeOperation: (@Sendable () -> Void)?
    /// When true, writes succeed but are silently ignored (readback shows the old value).
    public var ignoreWrites = false
    /// Per-control quantization: a written value settles on the nearest lower multiple (like sharpness).
    public var step: [Control: Int] = [:]

    public init(displays: [DisplayDescriptor] = []) {
        _displays = displays
    }

    public var writes: [WriteRecord] { lock.withLock { _writes } }
    public var readCount: Int { lock.withLock { _reads } }

    public func currentValue(_ c: Control, uuid: String) -> Int? { lock.withLock { values[uuid]?[c]?.current } }
    public func setDisplays(_ d: [DisplayDescriptor]) { lock.withLock { _displays = d } }
    public func setValue(_ v: ControlValue, _ c: Control, uuid: String) {
        lock.withLock { values[uuid, default: [:]][c] = v }
    }
    public func failReads(_ c: Control, with f: DDCFailure?) { lock.withLock { readFailures[c] = f } }
    public func failWrites(_ c: Control, with f: DDCFailure?) { lock.withLock { writeFailures[c] = f } }

    public func scan() -> [DisplayDescriptor] { lock.withLock { _displays } }

    public func read(_ control: Control, uuid: String) throws -> ControlValue {
        beforeOperation?()
        return try lock.withLock {
            _reads += 1
            guard let d = _displays.first(where: { $0.uuid == uuid }), d.hasEndpoint else { throw DDCFailure.disconnected }
            if let f = readFailures[control] { throw f }
            guard let v = values[uuid]?[control] else { throw DDCFailure.unsupported }
            return v
        }
    }

    public func write(_ control: Control, value: Int, uuid: String) throws {
        beforeOperation?()
        try lock.withLock {
            guard let d = _displays.first(where: { $0.uuid == uuid }), d.hasEndpoint else { throw DDCFailure.disconnected }
            if let f = writeFailures[control] { throw f }
            _writes.append(WriteRecord(uuid: uuid, control: control, value: value))
            if !ignoreWrites {
                let q = step[control].map { value / $0 * $0 } ?? value
                values[uuid]?[control]?.current = q
            }
        }
    }
}
