import Foundation

/// Reprogrammable-controls feature (HID++ 0x1B00 / 0x1B04): lists a device's buttons and lets software take them over
/// ("divert") so presses arrive as events instead of the device's default action.
public enum Reprog {
    public struct Control: Equatable, Sendable, Identifiable {
        public var id: UInt16 { cid }
        public var index: Int
        public var cid: UInt16
        public var taskID: UInt16
        public var flags: UInt8
        public var isMouse: Bool { flags & 0x01 != 0 }
        public var isReprogrammable: Bool { flags & 0x10 != 0 }
        public var isDivertable: Bool { flags & 0x20 != 0 }
        public var name: String { Reprog.name(of: cid) }
    }

    /// Names for the controls whose IDs are well established; everything else shows its hex ID.
    public static func name(of cid: UInt16) -> String {
        switch cid {
        case 0x0050: "Left button"; case 0x0051: "Right button"; case 0x0052: "Middle button (wheel click)"
        case 0x0053: "Back button"; case 0x0056: "Forward button"
        case 0x005B: "Wheel tilt left (0x005B)"; case 0x005D: "Wheel tilt right (0x005D)"
        case 0x00C3: "Gesture button"; case 0x00C4: "SmartShift button"; case 0x00D7: "DPI switch (0x00D7)"
        case 0x00ED: "Precision button (0x00ED)"
        default: String(format: "Control 0x%04X", cid)
        }
    }

    /// Function 1 reply -> control. Layout: cid(2) tid(2) flags(1) pos(1) group(1) gmask(1) flags2(1).
    public static func parseInfo(index: Int, params p: [UInt8]) -> Control? {
        guard p.count >= 5 else { return nil }
        let cid = UInt16(p[0]) << 8 | UInt16(p[1])
        guard cid != 0 else { return nil }
        return Control(index: index, cid: cid, taskID: UInt16(p[2]) << 8 | UInt16(p[3]), flags: p[4])
    }

    /// setCtrlIdReporting params to divert (or release) a control. Bit 0 = divert, bit 1 = "apply bit 0".
    public static func divertParams(cid: UInt16, divert: Bool) -> [UInt8] {
        [UInt8(cid >> 8), UInt8(cid & 0xFF), divert ? 0x03 : 0x02]
    }

    /// divertedButtonsEvent params: up to four 16-bit control IDs currently held, zero-terminated.
    public static func pressed(from params: [UInt8]) -> Set<UInt16> {
        var out = Set<UInt16>()
        var i = 0
        while i + 1 < params.count, i < 8 {
            let c = UInt16(params[i]) << 8 | UInt16(params[i + 1])
            if c != 0 { out.insert(c) }
            i += 2
        }
        return out
    }
}
