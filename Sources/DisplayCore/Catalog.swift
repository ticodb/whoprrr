import Foundation

public struct Choice: Hashable, Sendable {
    public var value: Int
    public var label: String
    public init(_ value: Int, _ label: String) { self.value = value; self.label = label }
}

public enum SettingKind: Sendable, Equatable {
    case slider                       // 0...max as reported by the display
    case choice([Choice])             // discrete values; readback decides whether the display accepted it
}

/// What the app knows about a standard VCP feature (VESA MCCS).
public struct SettingSpec: Sendable {
    public var control: Control
    public var key: String
    public var label: String
    public var group: String
    public var kind: SettingKind
    public var note: String?
    /// Included when saving/applying presets.
    public var inPreset: Bool
    /// Needs an explicit confirmation before every write (can blank the screen).
    public var needsConfirm: Bool
    /// Write proven on the Samsung (write, readback, restore). Unproven writes stay off by default.
    public var hardwareVerified: Bool
    /// The display snaps to steps (e.g. sharpness 51 -> 48); an adjusted readback is accepted.
    public var quantized: Bool = false
}

public enum Catalog {
    /// Measured on the S34CG50 (docs/hardware-probe.md): values 1-4 are selectable and each overrides the
    /// RGB gains (labels derived from those gains). 5 = Custom is reported but cannot be selected; it is
    /// entered by writing any RGB gain.
    static let colorPresets: [Choice] = [Choice(1, "Cool"), Choice(2, "Normal"), Choice(3, "Warm 1"), Choice(4, "Warm 2")]
    public static let customTone = 5
    public static let tonePresetRange = 1...4
    static let inputs: [Choice] = [
        Choice(15, "DisplayPort 1"), Choice(16, "DisplayPort 2"), Choice(17, "HDMI 1"), Choice(18, "HDMI 2"),
    ]

    // hardwareVerified is set from docs/hardware-probe.md; keep in sync when a control is proven.
    public static let known: [SettingSpec] = [
        SettingSpec(control: .brightness, key: "brightness", label: "Brightness", group: "Picture", kind: .slider,
                    note: nil, inPreset: true, needsConfirm: false, hardwareVerified: true),
        SettingSpec(control: .contrast, key: "contrast", label: "Contrast", group: "Picture", kind: .slider,
                    note: nil, inPreset: true, needsConfirm: false, hardwareVerified: true),
        SettingSpec(control: .sharpness, key: "sharpness", label: "Sharpness", group: "Picture", kind: .slider,
                    note: "Moves in steps of about 8; the display shows the value it settled on.", inPreset: true,
                    needsConfirm: false, hardwareVerified: true, quantized: true),
        SettingSpec(control: .colorPreset, key: "colorPreset", label: "Color preset", group: "Color", kind: .choice(colorPresets),
                    note: "Each preset overrides the RGB gains. Custom is entered by moving an RGB gain.",
                    inPreset: true, needsConfirm: false, hardwareVerified: true),
        SettingSpec(control: .red, key: "red", label: "Red gain", group: "Color", kind: .slider,
                    note: "Moving any RGB gain switches the tone to Custom.", inPreset: true, needsConfirm: false, hardwareVerified: true),
        SettingSpec(control: .green, key: "green", label: "Green gain", group: "Color", kind: .slider,
                    note: nil, inPreset: true, needsConfirm: false, hardwareVerified: true),
        SettingSpec(control: .blue, key: "blue", label: "Blue gain", group: "Color", kind: .slider,
                    note: nil, inPreset: true, needsConfirm: false, hardwareVerified: true),
        SettingSpec(control: .volume, key: "volume", label: "Volume", group: "Audio", kind: .slider,
                    note: nil, inPreset: false, needsConfirm: false, hardwareVerified: true),
        SettingSpec(control: .input, key: "input", label: "Input source", group: "System", kind: .choice(inputs),
                    note: "Switching to an input with no signal blanks the screen; only the OSD or this app can switch back.",
                    inPreset: false, needsConfirm: true, hardwareVerified: true),
    ]

    public static func spec(for c: Control) -> SettingSpec? { known.first { $0.control == c } }

    /// Codes that must never be written by this app, even if "learned": factory resets, power,
    /// settings save, app-enable key, read-only identity/version codes.
    public static let denied: Set<UInt8> = [0x04, 0x05, 0x06, 0x08, 0x0A, 0xB0, 0xC6, 0xC8, 0xC9, 0xCA, 0xD6, 0xDF, 0x02]
}
