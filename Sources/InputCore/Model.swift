import Foundation
import CoreGraphics

public struct Mods: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = Mods(rawValue: 1), control = Mods(rawValue: 2), option = Mods(rawValue: 4)
    public static let command = Mods(rawValue: 8), fn = Mods(rawValue: 16)
    public static let main: Mods = [.shift, .control, .option, .command]
    public static let hyper: Mods = [.shift, .control, .option, .command]

    public init(cg flags: CGEventFlags) {
        var m: Mods = []
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        if flags.contains(.maskSecondaryFn) { m.insert(.fn) }
        self = m
    }

    /// From Carbon modifier bits (cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096).
    public init(carbon: UInt32) {
        var m: Mods = []
        if carbon & 256 != 0 { m.insert(.command) }
        if carbon & 512 != 0 { m.insert(.shift) }
        if carbon & 2048 != 0 { m.insert(.option) }
        if carbon & 4096 != 0 { m.insert(.control) }
        self = m
    }

    public var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.shift) { f.insert(.maskShift) }
        if contains(.control) { f.insert(.maskControl) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.command) { f.insert(.maskCommand) }
        if contains(.fn) { f.insert(.maskSecondaryFn) }
        return f
    }

    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// Virtual key codes of the modifier keys (they arrive as flagsChanged, not keyDown).
public enum ModifierKey {
    public static let table: [Int: Mods] = [55: .command, 54: .command, 56: .shift, 60: .shift, 58: .option, 61: .option, 59: .control, 62: .control, 63: .fn]
    public static let capsLock = 57
    public static func mods(for code: Int) -> Mods? { table[code] }
    /// A key code to press when we must emit a modifier.
    public static func code(for m: Mods) -> Int {
        if m == .command { return 55 }; if m == .shift { return 56 }; if m == .option { return 58 }; if m == .control { return 59 }
        return 63
    }
}

public enum Trigger: Codable, Hashable, Sendable {
    case key(Int)
    case mouse(Int)       // other-mouse button number: 2 middle, 3 back, 4 forward, ...
    case logi(Int)        // a Logitech control ID diverted over HID++ (buttons macOS never sees)

    public var label: String {
        switch self {
        case .key(let c): return KeyLabel.name(c)
        case .logi(let c): return String(format: "Logitech 0x%04X", c)
        case .mouse(let b): return ["Left click", "Right click", "Middle click", "Back button", "Forward button"][safe: b] ?? "Button \(b + 1)"
        }
    }
}

public struct Chord: Codable, Hashable, Sendable {
    public var key: Int
    public var mods: Mods
    public init(_ key: Int, _ mods: Mods = []) { self.key = key; self.mods = mods }
    public var label: String { mods.symbols + KeyLabel.name(key) }
}

public enum MediaKey: Int, Codable, CaseIterable, Sendable {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7, playPause = 16, next = 17, previous = 18
    public var title: String {
        switch self {
        case .volumeUp: "Volume up"; case .volumeDown: "Volume down"; case .mute: "Mute"
        case .brightnessUp: "Brightness up"; case .brightnessDown: "Brightness down"
        case .playPause: "Play / pause"; case .next: "Next track"; case .previous: "Previous track"
        }
    }
}

public enum Output: Codable, Equatable, Sendable {
    case chord(Chord)
    /// Behave as these modifiers while the trigger is held.
    case modifiers(Mods)
    /// Switch a named layer on while the trigger is held.
    case layer(String)
    case media(MediaKey)
    case mouseButton(Int)
    /// A Whopper command, e.g. "window.leftHalf" or "clipboard.open".
    case command(String)
    case openApp(String)
    case openURL(String)
    case shell(String)
    /// Types this text, whatever the keyboard layout or region settings (a numpad "." that always means ".").
    case text(String)
    /// Presses these combos one after another, e.g. ⌥E then A for "á" on a US layout.
    case sequence([Chord])
    case nothing

    public var summary: String {
        switch self {
        case .chord(let c): return c.label
        case .modifiers(let m): return m == .hyper ? "Hyper ⌃⌥⇧⌘" : m.symbols
        case .layer(let n): return "layer “\(n)”"
        case .media(let k): return k.title
        case .mouseButton(let b): return "mouse button \(b + 1)"
        case .command(let c): return "command \(c)"
        case .openApp(let a): return "open \(a)"
        case .openURL(let u): return "open \(u)"
        case .shell(let s): return "run `\(s.prefix(24))`"
        case .text(let t): return "type “\(t)”"
        case .sequence(let cs): return cs.map(\.label).joined(separator: " then ")
        case .nothing: return "nothing"
        }
    }
}

public struct Scope: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case everywhere, only, except }
    public var mode: Mode = .everywhere
    public var bundleIDs: [String] = []
    public init(mode: Mode = .everywhere, bundleIDs: [String] = []) { self.mode = mode; self.bundleIDs = bundleIDs }

    public func allows(_ bundle: String?) -> Bool {
        switch mode {
        case .everywhere: return true
        case .only: return bundle.map(bundleIDs.contains) ?? false
        case .except: return !(bundle.map(bundleIDs.contains) ?? false)
        }
    }
}

public struct Rule: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name = ""
    public var enabled = true
    public var trigger: Trigger
    /// Modifiers that must be down (exactly, unless `allowExtraModifiers`).
    public var requiredMods: Mods = []
    public var allowExtraModifiers = false
    /// The action, or the tap action when `hold` is set.
    public var tap: Output
    /// When set the key is dual-role: tap does `tap`, holding does `hold`.
    public var hold: Output?
    public var holdMs = 200
    public var scope = Scope()
    /// Only active while this layer is on.
    public var layer: String?
    /// Only for keys typed on a keyboard of this physical layout (empty = any). Needs the event's keyboard type.
    public var layouts: [KeyboardLayout] = []
    /// Only for keyboards that report one of these raw keyboard types (empty = any). Tells two ANSI keyboards apart.
    public var keyboardTypes: [Int] = []

    public init(name: String = "", trigger: Trigger, requiredMods: Mods = [], tap: Output, hold: Output? = nil,
                scope: Scope = Scope(), layer: String? = nil, layouts: [KeyboardLayout] = [], keyboardTypes: [Int] = []) {
        self.name = name; self.trigger = trigger; self.requiredMods = requiredMods; self.tap = tap; self.hold = hold
        self.scope = scope; self.layer = layer; self.layouts = layouts; self.keyboardTypes = keyboardTypes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, trigger, requiredMods, allowExtraModifiers, tap, hold, holdMs, scope, layer, layouts, keyboardTypes
    }

    /// Tolerant decoding: settings saved before a field existed must keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        requiredMods = try c.decodeIfPresent(Mods.self, forKey: .requiredMods) ?? []
        allowExtraModifiers = try c.decodeIfPresent(Bool.self, forKey: .allowExtraModifiers) ?? false
        tap = try c.decode(Output.self, forKey: .tap)
        hold = try c.decodeIfPresent(Output.self, forKey: .hold)
        holdMs = try c.decodeIfPresent(Int.self, forKey: .holdMs) ?? 200
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? Scope()
        layer = try c.decodeIfPresent(String.self, forKey: .layer)
        layouts = try c.decodeIfPresent([KeyboardLayout].self, forKey: .layouts) ?? []
        keyboardTypes = try c.decodeIfPresent([Int].self, forKey: .keyboardTypes) ?? []
    }

    public var summary: String {
        let t = requiredMods.symbols + trigger.label
        if let h = hold { return "\(t): tap → \(tap.summary), hold → \(h.summary)" }
        return "\(t) → \(tap.summary)"
    }
}

/// A key remap done by macOS itself through `hidutil` (needed for Caps Lock and for modifier keys,
/// which an event tap cannot remap cleanly).
public struct HIDMapping: Codable, Equatable, Sendable, Hashable {
    public var src: UInt64
    public var dst: UInt64
    public init(src: UInt64, dst: UInt64) { self.src = src; self.dst = dst }
    public static let capsLock: UInt64 = 0x700000039
    public static let f18: UInt64 = 0x70000006D
    public static let f19: UInt64 = 0x70000006E
    public static let rightCommand: UInt64 = 0x7000000E7
    public static let rightOption: UInt64 = 0x7000000E6
}

public struct InputSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var rules: [Rule] = []
    public var hidMappings: [HIDMapping] = []
    /// Mouse wheel scrolls the opposite way to the trackpad.
    public var invertMouseWheel = false
    /// Which built-in default rules have been offered already, so one the user deleted does not come back.
    public var defaultsVersion = 0
    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, rules, hidMappings, invertMouseWheel, defaultsVersion }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        hidMappings = try c.decodeIfPresent([HIDMapping].self, forKey: .hidMappings) ?? []
        invertMouseWheel = try c.decodeIfPresent(Bool.self, forKey: .invertMouseWheel) ?? false
        defaultsVersion = try c.decodeIfPresent(Int.self, forKey: .defaultsVersion) ?? 0
    }

    public static let currentDefaultsVersion = 2

    /// Version 1 added Back/Forward rules for the mouse's side buttons. They did more harm than good: apps already handle those
    /// buttons natively, and a keyboard shortcut sent in their place depends on the keyboard layout (on a Spanish layout the
    /// "]" key position types "+", so Forward zoomed in). Remove exactly the rules version 1 added; keep anything the user made.
    public mutating func applyDefaults() {
        guard defaultsVersion < Self.currentDefaultsVersion else { return }
        rules.removeAll { r in
            (r.name == "Back button → Back" && r.trigger == .mouse(3) && r.tap == .command("common.back")) ||
            (r.name == "Forward button → Forward" && r.trigger == .mouse(4) && r.tap == .command("common.forward"))
        }
        defaultsVersion = Self.currentDefaultsVersion
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

enum KeyLabel {
    static let names: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 54: "Right ⌘", 55: "Left ⌘", 56: "Left ⇧",
        57: "Caps Lock", 58: "Left ⌥", 59: "Left ⌃", 60: "Right ⇧", 61: "Right ⌥", 62: "Right ⌃", 63: "fn",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
        111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "⇞", 117: "⌦", 118: "F4", 119: "End", 120: "F2", 121: "⇟", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Keypad Clear", 75: "Keypad /", 76: "Keypad ↩", 78: "Keypad -", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7",
        91: "Keypad 8", 92: "Keypad 9", 95: "Keypad ,", 10: "§ (ISO)",
    ]
    static func name(_ code: Int) -> String { names[code] ?? "Key \(code)" }
}
