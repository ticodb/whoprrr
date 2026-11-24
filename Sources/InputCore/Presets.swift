import Foundation

public struct InputPreset: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var rules: [Rule]
    public var hid: [HIDMapping]
}

public enum InputPresets {
    private static let esc = 53, f18 = 79, f19 = 80

    /// ⌃ + vowel → accented vowel, ⌃⇧ + vowel → capital, ⌃N → ñ, ⌃1 → ¡, ⌃/ → ¿, typed as real characters so they work in any app
    /// on any layout. Limited to ANSI keyboards, which are the ones that lack these keys.
    static let spanishAccents: [Rule] = {
        let vowels: [(Int, String, String)] = [(0, "á", "Á"), (14, "é", "É"), (34, "í", "Í"), (31, "ó", "Ó"), (32, "ú", "Ú"), (45, "ñ", "Ñ")]
        var out: [Rule] = []
        for (code, lower, upper) in vowels {
            out.append(Rule(name: "⌃\(KeyLabel.name(code)) → \(lower)", trigger: .key(code), requiredMods: .control, tap: .text(lower), layouts: [.ansi]))
            out.append(Rule(name: "⌃⇧\(KeyLabel.name(code)) → \(upper)", trigger: .key(code), requiredMods: [.control, .shift], tap: .text(upper), layouts: [.ansi]))
        }
        out.append(Rule(name: "⌃1 → ¡", trigger: .key(18), requiredMods: .control, tap: .text("¡"), layouts: [.ansi]))
        out.append(Rule(name: "⌃/ → ¿", trigger: .key(44), requiredMods: .control, tap: .text("¿"), layouts: [.ansi]))
        return out
    }()

    public static let all: [InputPreset] = [
        InputPreset(id: "numpad-period", title: "Numpad decimal key always types “.”",
                    detail: "Whatever your region or layout says, the keypad’s decimal key (. or ,) types a period.",
                    rules: [Rule(name: "Keypad decimal → .", trigger: .key(65), tap: .text(".")),
                            Rule(name: "Keypad comma → .", trigger: .key(95), tap: .text("."))],
                    hid: []),
        InputPreset(id: "spanish-accents", title: "Spanish accents on US keyboards (⌃ + letter)",
                    detail: "⌃A ⌃E ⌃I ⌃O ⌃U → á é í ó ú, add ⇧ for capitals, ⌃N → ñ, ⌃1 → ¡, ⌃/ → ¿. Only on ANSI keyboards. Overrides ⌃A and ⌃E in terminals.",
                    rules: spanishAccents, hid: []),
        InputPreset(id: "comma-space", title: "Comma adds a space after it",
                    detail: "Typing “,” types “, ”. Handy for prose; not for code or numbers.",
                    rules: [Rule(name: "Comma + space", trigger: .key(43), tap: .text(", "))], hid: []),
        InputPreset(id: "caps-esc-ctrl", title: "Caps Lock: Esc on tap, Control on hold",
                    detail: "The classic. Tap for Escape, hold and press another key for Control.",
                    rules: [Rule(name: "Caps Lock", trigger: .key(f18), tap: .chord(Chord(esc)), hold: .modifiers(.control))],
                    hid: [HIDMapping(src: HIDMapping.capsLock, dst: HIDMapping.f18)]),
        InputPreset(id: "caps-hyper", title: "Caps Lock: Esc on tap, Hyper on hold",
                    detail: "Hold for ⌃⌥⇧⌘ at once: free shortcuts for everything.",
                    rules: [Rule(name: "Caps Lock", trigger: .key(f18), tap: .chord(Chord(esc)), hold: .modifiers(.hyper))],
                    hid: [HIDMapping(src: HIDMapping.capsLock, dst: HIDMapping.f18)]),
        InputPreset(id: "caps-nav", title: "Caps Lock: Esc on tap, arrow layer on hold",
                    detail: "Hold Caps Lock and use H J K L as ← ↓ ↑ → anywhere.",
                    rules: [Rule(name: "Caps Lock", trigger: .key(f18), tap: .chord(Chord(esc)), hold: .layer("nav")),
                            Rule(name: "←", trigger: .key(4), tap: .chord(Chord(123)), layer: "nav"),
                            Rule(name: "↓", trigger: .key(38), tap: .chord(Chord(125)), layer: "nav"),
                            Rule(name: "↑", trigger: .key(40), tap: .chord(Chord(126)), layer: "nav"),
                            Rule(name: "→", trigger: .key(37), tap: .chord(Chord(124)), layer: "nav")],
                    hid: [HIDMapping(src: HIDMapping.capsLock, dst: HIDMapping.f18)]),
        InputPreset(id: "right-cmd-hyper", title: "Right ⌘: Hyper on hold",
                    detail: "Keeps Caps Lock alone; the right Command key becomes Hyper while held.",
                    rules: [Rule(name: "Right ⌘", trigger: .key(f19), tap: .chord(Chord(54)), hold: .modifiers(.hyper))],
                    hid: [HIDMapping(src: HIDMapping.rightCommand, dst: HIDMapping.f19)]),
        InputPreset(id: "mouse-back-forward", title: "Mouse back / forward buttons → ⌘[ and ⌘]",
                    detail: "Back and forward in browsers, Finder and most apps.",
                    rules: [Rule(name: "Back", trigger: .mouse(3), tap: .chord(Chord(33, .command))),
                            Rule(name: "Forward", trigger: .mouse(4), tap: .chord(Chord(30, .command)))],
                    hid: []),
        InputPreset(id: "mouse-middle-mission", title: "Middle click → Mission Control",
                    detail: "Replaces the middle click. Goes straight to the Dock, so it works even if the Mission Control shortcut is off.",
                    rules: [Rule(name: "Middle click → Mission Control", trigger: .mouse(2), tap: .command("system.missionControl"))],
                    hid: []),
    ]

    /// Adds a preset's rules and key mappings, skipping what is already there.
    public static func apply(_ p: InputPreset, to s: InputSettings) -> InputSettings {
        var out = s
        for r in p.rules where !out.rules.contains(where: { $0.trigger == r.trigger && $0.layer == r.layer && $0.requiredMods == r.requiredMods }) {
            out.rules.append(r)
        }
        for m in p.hid where !out.hidMappings.contains(where: { $0.src == m.src }) { out.hidMappings.append(m) }
        return out
    }
}
