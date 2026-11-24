import Foundation
import Carbon.HIToolbox

/// The physical layout class macOS reports for a keyboard. A Spanish or US MacBook and a Logitech keyboard can
/// differ here; two keyboards of the same class can still differ in their raw keyboard type number.
public enum KeyboardLayout: String, Codable, CaseIterable, Sendable {
    case ansi, iso, jis

    public init?(keyboardType: Int) {
        switch UInt32(KBGetLayoutType(Int16(truncatingIfNeeded: keyboardType))) {
        case UInt32(kKeyboardANSI): self = .ansi
        case UInt32(kKeyboardISO): self = .iso
        case UInt32(kKeyboardJIS): self = .jis
        default: return nil
        }
    }

    public var title: String {
        switch self { case .ansi: "ANSI (US)"; case .iso: "ISO (European)"; case .jis: "JIS (Japanese)" }
    }
}
