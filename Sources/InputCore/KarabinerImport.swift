import Foundation

/// Converts Karabiner-Elements configuration into Whoprrr rules. Handles the common 90%: basic manipulators
/// (key or mouse button to keys, key sequences, media keys, shell commands), tap-vs-hold (`to_if_alone`,
/// `to_if_held_down`), `simple_modifications` (global and per device) and app / keyboard-type conditions.
/// Anything else is skipped and reported in `warnings`, never silently dropped.
public struct KarabinerImportResult: Equatable, Sendable {
    public var rules: [Rule] = []
    public var hidMappings: [HIDMapping] = []
    public var warnings: [String] = []
    public var skipped = 0
}

public enum KarabinerImport {
    public enum ImportError: Error, Equatable { case notJSON, nothingFound }

    /// - Parameter deviceLayouts: Karabiner scopes rules to a device (vendor/product ID). Whoprrr tells keyboards apart by
    ///   layout instead, so device-scoped rules are limited to keyboards of these layouts.
    public static func parse(_ data: Data, deviceLayouts: [KeyboardLayout] = [.ansi]) throws -> KarabinerImportResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw ImportError.notJSON }
        var out = KarabinerImportResult()
        var found = false

        func addRules(_ rules: [[String: Any]]) {
            found = true
            for r in rules { addRule(r, into: &out, deviceLayouts: deviceLayouts) }
        }

        if let dict = root as? [String: Any] {
            if let profiles = dict["profiles"] as? [[String: Any]] {
                let p = profiles.first { ($0["selected"] as? Bool) == true } ?? profiles.first
                if let p {
                    found = true
                    if let cm = p["complex_modifications"] as? [String: Any], let rules = cm["rules"] as? [[String: Any]] { addRules(rules) }
                    for m in (p["simple_modifications"] as? [[String: Any]]) ?? [] { addSimple(m, layouts: [], device: nil, into: &out) }
                    for dev in (p["devices"] as? [[String: Any]]) ?? [] {
                        let ids = dev["identifiers"] as? [String: Any] ?? [:]
                        guard (ids["is_pointing_device"] as? Bool) != true else { continue }
                        let label = "vendor \(ids["vendor_id"] as? Int ?? 0) product \(ids["product_id"] as? Int ?? 0)"
                        for m in (dev["simple_modifications"] as? [[String: Any]]) ?? [] {
                            addSimple(m, layouts: deviceLayouts, device: label, into: &out)
                        }
                    }
                }
            } else if let rules = dict["rules"] as? [[String: Any]] {
                addRules(rules)
            } else if dict["manipulators"] != nil {
                addRules([dict])
            }
        } else if let arr = root as? [[String: Any]] {
            addRules(arr)
        }
        guard found else { throw ImportError.nothingFound }
        return out
    }

    // MARK: Rules

    private static func addRule(_ rule: [String: Any], into out: inout KarabinerImportResult, deviceLayouts: [KeyboardLayout]) {
        let title = rule["description"] as? String ?? ""
        let manips = rule["manipulators"] as? [[String: Any]] ?? []
        for (i, m) in manips.enumerated() {
            let name = manips.count > 1 ? "\(title) (\(i + 1))" : title
            switch convert(m, name: name, deviceLayouts: deviceLayouts) {
            case .success(let r):
                out.rules.append(r.rule)
                out.hidMappings.append(contentsOf: r.hid.filter { h in !out.hidMappings.contains(h) })
                out.warnings += r.warnings.map { "\(name): \($0)" }
            case .failure(let reason):
                out.skipped += 1
                out.warnings.append("Skipped “\(name)”: \(reason)")
            }
        }
    }

    private struct Converted { var rule: Rule; var hid: [HIDMapping] = []; var warnings: [String] = [] }
    private struct Skip: Error, CustomStringConvertible { var description: String; init(_ d: String) { description = d } }

    private static func convert(_ m: [String: Any], name: String, deviceLayouts: [KeyboardLayout]) -> Result<Converted, Skip> {
        guard (m["type"] as? String ?? "basic") == "basic" else { return .failure(Skip("only basic manipulators are supported")) }
        guard let from = m["from"] as? [String: Any] else { return .failure(Skip("no “from”")) }
        if from["simultaneous"] != nil { return .failure(Skip("simultaneous key presses are not supported")) }
        guard let trigger = trigger(from) else { return .failure(Skip("unsupported trigger key")) }
        var warnings: [String] = []

        // Modifiers on the trigger.
        var required: Mods = []
        var allowExtra = false
        if let mods = from["modifiers"] as? [String: Any] {
            required = parseMods(mods["mandatory"] as? [String] ?? [])
            if (mods["optional"] as? [String] ?? []).contains("any") { allowExtra = true }
        }

        // Conditions.
        var scope = Scope()
        var layouts: [KeyboardLayout] = []
        for c in (m["conditions"] as? [[String: Any]]) ?? [] {
            switch c["type"] as? String ?? "" {
            case "frontmost_application_if", "frontmost_application_unless":
                let ids = (c["bundle_identifiers"] as? [String] ?? []).compactMap(literalBundleID)
                if ids.isEmpty { warnings.append("app condition uses a pattern Whoprrr cannot read; the rule applies everywhere"); continue }
                scope = Scope(mode: (c["type"] as? String) == "frontmost_application_if" ? .only : .except, bundleIDs: ids)
            case "keyboard_type_if":
                layouts = (c["keyboard_types"] as? [String] ?? []).compactMap { KeyboardLayout(rawValue: $0.lowercased()) }
            case "device_if":
                layouts = deviceLayouts
                warnings.append("limited to \(deviceLayouts.map { $0.rawValue.uppercased() }.joined(separator: "/")) keyboards instead of a specific device")
            default:
                return .failure(Skip("condition “\(c["type"] as? String ?? "?")” is not supported"))
            }
        }

        let to = (m["to"] as? [[String: Any]]) ?? []
        let alone = (m["to_if_alone"] as? [[String: Any]]) ?? []
        let held = (m["to_if_held_down"] as? [[String: Any]]) ?? []
        for key in ["to_after_key_up", "to_delayed_action"] where m[key] != nil { warnings.append("“\(key)” ignored") }

        var tapOut: Output?, holdOut: Output?
        if !alone.isEmpty || !held.isEmpty {
            // Dual role: Karabiner's `to` is what happens while held (usually a modifier), `to_if_alone` the tap.
            tapOut = alone.isEmpty ? nil : output(alone, &warnings)
            holdOut = held.isEmpty ? (to.isEmpty ? nil : output(to, &warnings)) : output(held, &warnings)
            if tapOut == nil { tapOut = .nothing }
        } else if !to.isEmpty {
            tapOut = output(to, &warnings)
        }
        guard let tapOut else { return .failure(Skip("nothing to do (no “to”)")) }

        var hid: [HIDMapping] = []
        var finalTrigger = trigger
        // Caps Lock cannot be seen by an event tap: map it to F18 with hidutil first, like the built-in presets.
        if trigger == .key(ModifierKey.capsLock) {
            hid.append(HIDMapping(src: HIDMapping.capsLock, dst: HIDMapping.f18)); finalTrigger = .key(79)
        }
        var rule = Rule(name: name, trigger: finalTrigger, requiredMods: required, tap: tapOut, hold: holdOut, scope: scope, layouts: layouts)
        rule.allowExtraModifiers = allowExtra
        return .success(Converted(rule: rule, hid: hid, warnings: warnings))
    }

    // MARK: Simple modifications

    private static func addSimple(_ m: [String: Any], layouts: [KeyboardLayout], device: String?, into out: inout KarabinerImportResult) {
        guard let from = m["from"] as? [String: Any], let trig = trigger(from) else { out.skipped += 1; return }
        var warnings: [String] = []
        guard let to = m["to"] as? [[String: Any]], !to.isEmpty else { out.skipped += 1; return }
        let o = output(to, &warnings)
        if let hid = hidPair(from: from, to: to), device == nil {
            out.hidMappings.append(hid); return
        }
        var name = "Simple: \(trig.label) → \(o.summary)"
        if let d = device { name += " (\(d))" }
        var rule = Rule(name: name, trigger: trig, tap: o, layouts: layouts)
        rule.allowExtraModifiers = true
        out.rules.append(rule)
        if device != nil && !layouts.isEmpty {
            out.warnings.append("\(name): limited to \(layouts.map { $0.rawValue.uppercased() }.joined(separator: "/")) keyboards instead of that specific device")
        }
        out.warnings += warnings.map { "\(name): \($0)" }
    }

    /// Caps Lock and modifier keys become `hidutil` replacements (an event tap cannot remap them cleanly).
    private static func hidPair(from: [String: Any], to: [[String: Any]]) -> HIDMapping? {
        guard let f = from["key_code"] as? String, let t = to.first?["key_code"] as? String, to.count == 1,
              let s = hidUsage[f], let d = hidUsage[t] else { return nil }
        return HIDMapping(src: s, dst: d)
    }

    private static let hidUsage: [String: UInt64] = [
        "caps_lock": 0x700000039, "escape": 0x700000029,
        "left_control": 0x7000000E0, "left_shift": 0x7000000E1, "left_option": 0x7000000E2, "left_command": 0x7000000E3,
        "right_control": 0x7000000E4, "right_shift": 0x7000000E5, "right_option": 0x7000000E6, "right_command": 0x7000000E7,
    ]

    // MARK: Pieces

    private static func trigger(_ from: [String: Any]) -> Trigger? {
        if let k = from["key_code"] as? String, let code = keyCodes[k] { return .key(code) }
        if let b = from["pointing_button"] as? String, b.hasPrefix("button"), let n = Int(b.dropFirst(6)), n >= 3 { return .mouse(n - 1) }
        return nil
    }

    private static func output(_ items: [[String: Any]], _ warnings: inout [String]) -> Output {
        var parts: [Output] = []
        var chords: [Chord] = []
        for it in items {
            if let k = it["key_code"] as? String, let code = keyCodes[k] {
                let mods = parseMods(it["modifiers"] as? [String] ?? [])
                if let m = ModifierKey.mods(for: code), mods.isEmpty { parts.append(.modifiers(m)); continue }
                chords.append(Chord(code, mods)); continue
            }
            if let c = it["consumer_key_code"] as? String, let mk = mediaKeys[c] { parts.append(.media(mk)); continue }
            if let b = it["pointing_button"] as? String, b.hasPrefix("button"), let n = Int(b.dropFirst(6)) { parts.append(.mouseButton(n - 1)); continue }
            if let s = it["shell_command"] as? String { parts.append(.shell(s)); continue }
            if let sw = it["software_function"] as? [String: Any], sw["open_application"] != nil { warnings.append("open_application is not converted"); continue }
            warnings.append("an action Whoprrr cannot do was left out")
        }
        if !chords.isEmpty {
            parts.insert(chords.count == 1 ? .chord(chords[0]) : .sequence(chords), at: 0)
        }
        if parts.count > 1 { warnings.append("mixed actions: only the first is kept") }
        return parts.first ?? .nothing
    }

    private static func parseMods(_ names: [String]) -> Mods {
        var m: Mods = []
        for n in names {
            switch n {
            case "control", "left_control", "right_control": m.insert(.control)
            case "shift", "left_shift", "right_shift": m.insert(.shift)
            case "option", "left_option", "right_option", "alt", "left_alt", "right_alt": m.insert(.option)
            case "command", "left_command", "right_command", "gui", "left_gui", "right_gui": m.insert(.command)
            case "fn": m.insert(.fn)
            default: break
            }
        }
        return m
    }

    /// Karabiner matches app bundle IDs with regular expressions. Only plain ones (`^com\.apple\.Terminal$`) convert.
    private static func literalBundleID(_ pattern: String) -> String? {
        var s = pattern
        if s.hasPrefix("^") { s.removeFirst() }
        if s.hasSuffix("$") { s.removeLast() }
        s = s.replacingOccurrences(of: "\\.", with: ".")
        let meta = CharacterSet(charactersIn: "\\[](){}*+?|^$")
        return s.rangeOfCharacter(from: meta) == nil && !s.isEmpty ? s : nil
    }

    private static let mediaKeys: [String: MediaKey] = [
        "volume_increment": .volumeUp, "volume_decrement": .volumeDown, "mute": .mute, "play_or_pause": .playPause,
        "scan_next_track": .next, "scan_previous_track": .previous,
        "display_brightness_increment": .brightnessUp, "display_brightness_decrement": .brightnessDown,
    ]

    /// Karabiner key names → macOS virtual key codes.
    static let keyCodes: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "non_us_backslash": 10, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal_sign": 24, "9": 25, "7": 26,
        "hyphen": 27, "8": 28, "0": 29, "close_bracket": 30, "o": 31, "u": 32, "open_bracket": 33, "i": 34, "p": 35, "return_or_enter": 36,
        "l": 37, "j": 38, "quote": 39, "k": 40, "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47,
        "tab": 48, "spacebar": 49, "grave_accent_and_tilde": 50, "delete_or_backspace": 51, "escape": 53,
        "right_command": 54, "left_command": 55, "left_shift": 56, "caps_lock": 57, "left_option": 58, "left_control": 59,
        "right_shift": 60, "right_option": 61, "right_control": 62, "fn": 63,
        "f17": 64, "keypad_period": 65, "keypad_asterisk": 67, "keypad_plus": 69, "keypad_num_lock": 71, "keypad_slash": 75,
        "keypad_enter": 76, "keypad_hyphen": 78, "keypad_equal_sign": 81,
        "keypad_0": 82, "keypad_1": 83, "keypad_2": 84, "keypad_3": 85, "keypad_4": 86, "keypad_5": 87, "keypad_6": 88, "keypad_7": 89,
        "keypad_8": 91, "keypad_9": 92, "keypad_comma": 95,
        "f18": 79, "f19": 80, "f20": 90, "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f13": 105, "f16": 106,
        "f14": 107, "f10": 109, "f12": 111, "f15": 113, "help": 114, "insert": 114, "home": 115, "page_up": 116, "delete_forward": 117,
        "f4": 118, "end": 119, "f2": 120, "page_down": 121, "f1": 122,
        "left_arrow": 123, "right_arrow": 124, "down_arrow": 125, "up_arrow": 126,
    ]
}
