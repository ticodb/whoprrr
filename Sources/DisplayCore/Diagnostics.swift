import Foundation
import CryptoKit

public struct DiagnosticEvent: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case topology, sleepWake, ddc, userMark, info }
    public var id = UUID()
    public var timestamp: Date
    public var kind: Kind
    /// Set for `.ddc` events so hardware results are never confused with fake-transport results.
    public var transport: TransportKind?
    public var message: String
    public var ok: Bool?

    public init(timestamp: Date = Date(), kind: Kind, transport: TransportKind? = nil, message: String, ok: Bool? = nil) {
        self.timestamp = timestamp
        self.kind = kind
        self.transport = transport
        self.message = message
        self.ok = ok
    }
}

/// Bounded in-memory timeline. Thread-safe; `onChange` fires after each append (UI hops to main itself).
public final class DiagnosticsLog: @unchecked Sendable {
    public static let capacity = 500
    private let lock = NSLock()
    private var _events: [DiagnosticEvent] = []
    public var onChange: (@Sendable () -> Void)?

    public init() {}

    public var events: [DiagnosticEvent] { lock.withLock { _events } }

    public func record(_ event: DiagnosticEvent) {
        lock.withLock {
            _events.append(event)
            if _events.count > Self.capacity { _events.removeFirst(_events.count - Self.capacity) }
        }
        onChange?()
    }

    public func record(_ kind: DiagnosticEvent.Kind, _ message: String, transport: TransportKind? = nil, ok: Bool? = nil) {
        record(DiagnosticEvent(kind: kind, transport: transport, message: message, ok: ok))
    }

    public var lastDDCEvent: DiagnosticEvent? { events.last { $0.kind == .ddc } }

    public func clear() { lock.withLock { _events.removeAll() }; onChange?() }
}

// MARK: - Redacted export

public enum Redaction {
    /// Stable short token for a hardware identifier: same input, same token within and across exports,
    /// but the identifier itself is not recoverable from the export.
    public static func token(_ value: String, label: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(label)#\(hex)"
    }

    /// Replaces every known identifier occurring inside free text.
    public static func scrub(_ text: String, displays: [DisplayDescriptor]) -> String {
        var out = text
        for d in displays {
            out = out.replacingOccurrences(of: d.uuid, with: token(d.uuid, label: "uuid"))
            if let e = d.edidUUID { out = out.replacingOccurrences(of: e, with: token(e, label: "edid")) }
            if let s = d.identity.alphaSerial { out = out.replacingOccurrences(of: s, with: token(s, label: "serial")) }
            // Short numeric serials would corrupt unrelated numbers in free text; real EDID serials are long.
            if String(d.identity.serial).count >= 6 {
                out = out.replacingOccurrences(of: String(d.identity.serial), with: token(String(d.identity.serial), label: "sn"))
            }
        }
        return out
    }
}

public struct DiagnosticsExport: Codable {
    public struct Display: Codable {
        public var product: String
        public var vendor: UInt32
        public var model: UInt32
        public var builtIn: Bool
        public var hasDDCEndpoint: Bool
        public var uuid: String
        public var serial: String
        public var alphaSerial: String?
    }
    public struct Event: Codable {
        public var time: String
        public var kind: String
        public var transport: String?
        public var ok: Bool?
        public var message: String
    }
    public var generatedAt: String
    public var macOS: String
    public var redacted: Bool
    public var displays: [Display]
    public var events: [Event]
}

public enum DiagnosticsExporter {
    public static func export(displays: [DisplayDescriptor], events: [DiagnosticEvent],
                              redact: Bool = true, now: Date = Date()) throws -> Data {
        let iso = ISO8601DateFormatter()
        let ds = displays.map { d -> DiagnosticsExport.Display in
            DiagnosticsExport.Display(
                product: d.identity.productName, vendor: d.identity.vendor, model: d.identity.model,
                builtIn: d.isBuiltIn, hasDDCEndpoint: d.hasEndpoint,
                uuid: redact ? Redaction.token(d.uuid, label: "uuid") : d.uuid,
                serial: redact ? Redaction.token(String(d.identity.serial), label: "sn") : String(d.identity.serial),
                alphaSerial: d.identity.alphaSerial.map { redact ? Redaction.token($0, label: "serial") : $0 })
        }
        let es = events.map { e in
            DiagnosticsExport.Event(
                time: iso.string(from: e.timestamp), kind: e.kind.rawValue, transport: e.transport?.rawValue, ok: e.ok,
                message: redact ? Redaction.scrub(e.message, displays: displays) : e.message)
        }
        let payload = DiagnosticsExport(
            generatedAt: iso.string(from: now), macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            redacted: redact, displays: ds, events: es)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(payload)
    }
}
