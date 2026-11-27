import Foundation

/// One kind of thing that was left out of a shared setup, for a screen to show.
public struct SharedSetupRemoval: Equatable, Sendable {
    /// The part it came from ("keys"), or nil when it belongs to the setup as a whole.
    public var part: String?
    /// In plain words: "Key rules that type text".
    public var what: String
    public var count: Int
    public var summary: String { count > 1 ? "\(what) (\(count))" : what }
}

/// What the display part is made from. A recipe only remembers the name of a display preset, so the caller supplies the preset's values.
public struct SharedDisplaySource: Sendable {
    /// The monitor's model name ("S34CG50"). Never a serial number.
    public var model: String
    /// Control name to value, as the display module stores a preset ("brightness", "colorPreset", "red", "vcpe0"…).
    public var values: [String: Int]
    public init(model: String, values: [String: Int]) { self.model = model; self.values = values }
}

public struct SharedSetupExportResult: Sendable {
    /// The document, or nil when it was refused (see `violations`).
    public var setup: SharedSetup?
    /// Why it was refused. Empty when `setup` exists.
    public var violations: [SharedSetupViolation]
    /// What was taken out of this recipe on the way, so a screen can show it before anything is sent.
    public var removed: [SharedSetupRemoval]
    /// Things the shared copy changed rather than took out (the limiter is switched on, its ceiling brought down).
    public var adjusted: [String]
    /// The checker's view of the document: whether it is ordinary, and why not.
    public var report: SharedSetupReport?
}

/// Turns a recipe into a shared setup: only Whoprrr's own settings, in the stable JSON shape, nothing personal. The recipe is
/// never changed; only the shared copy is limited. The result is run through the same checker the server and every opening use,
/// and nothing is produced when it finds a violation.
public enum SharedSetupExport {
    /// What is never in a shared setup, whatever the recipe holds. For a screen that explains what sharing sends.
    public static let alwaysLeftOut = [
        "Clipboard history and snippets",
        "Any text a key rule would type",
        "The list of apps the clipboard ignores",
        "Serial numbers",
        "Display IDs, audio device IDs and any other identifier of your devices",
        "The names you gave your devices (only the model name is kept)",
        "File paths and anything in your home folder",
        "Plugin files and plugin settings (plugins are named, never included)",
        "Web addresses",
        "Shell commands",
        "Rules that open apps",
        "Rule names",
        "The names of your display presets and their notes",
    ]

    public static func export(title: String, line: String, recipe: Recipe, parts requested: Set<String>? = nil,
                              display: [String: SharedDisplaySource] = [:]) -> SharedSetupExportResult {
        var b = Builder(recipe: recipe, display: display)
        let want = requested ?? Set(SharedSetupTable.parts)
        b.build(want)
        let gear = b.gear
        let setup = SharedSetup(title: title, line: line, parts: SharedSetupTable.parts.filter { b.settings[$0] != nil }, gear: gear,
                                requirements: b.requirements(), settings: b.settings)
        let report = SharedSetupLimits.check(setup)
        guard report.ok else {
            return SharedSetupExportResult(setup: nil, violations: report.violations, removed: b.removed, adjusted: b.adjusted, report: report)
        }
        return SharedSetupExportResult(setup: setup, violations: [], removed: b.removed, adjusted: b.adjusted, report: report)
    }
}

// MARK: - Reading the app's own settings JSON

private typealias J = JSONValue
private typealias T = SharedSetupTable

extension JSONValue {
    fileprivate func num(_ k: String, _ d: Double) -> Double { self[k]?.number ?? d }
    fileprivate func flag(_ k: String, _ d: Bool) -> Bool { self[k]?.bool ?? d }
    fileprivate func text(_ k: String) -> String? { self[k]?.string }
    fileprivate func items(_ k: String) -> [JSONValue] { self[k]?.array ?? [] }
}

/// The modifier bits the app stores for global shortcuts (Carbon): ⌘ 256, ⇧ 512, ⌥ 2048, ⌃ 4096.
enum CarbonMods {
    static let table: [(String, Int)] = [("command", 256), ("shift", 512), ("option", 2048), ("control", 4096)]
    static func names(_ bits: Int) -> [String]? {
        var rest = bits, out: [String] = []
        for (n, b) in table where bits & b != 0 { out.append(n); rest &= ~b }
        return rest == 0 ? out : nil        // any other bit is not something the app writes
    }
    static func bits(_ names: [String]) -> Int { table.filter { names.contains($0.0) }.reduce(0) { $0 | $1.1 } }
}

/// The modifier bits of `InputCore.Mods`: shift 1, control 2, option 4, command 8, fn 16.
enum InputMods {
    static let table: [(String, Int)] = [("shift", 1), ("control", 2), ("option", 4), ("command", 8), ("fn", 16)]
    static func names(_ bits: Int) -> [String] { table.filter { bits & $0.1 != 0 }.map(\.0) }
    static func bits(_ names: [String]) -> Int { table.filter { names.contains($0.0) }.reduce(0) { $0 | $1.1 } }
}

enum MediaKeys {
    static let table: [(String, Int)] = [("volumeUp", 0), ("volumeDown", 1), ("brightnessUp", 2), ("brightnessDown", 3), ("mute", 7), ("playPause", 16), ("next", 17), ("previous", 18)]
}

/// The audio-curve `kind` raw values are shared as they are; these are the app's own defaults, used when an old recipe lacks a field.
private enum Defaults {
    static let compressor: [String: J] = ["enabled": .bool(false), "thresholdDB": .number(-20), "ratio": .number(3), "attackMs": .number(8), "releaseMs": .number(150), "makeupDB": .number(3)]
    static let gate: [String: J] = ["enabled": .bool(false), "thresholdDB": .number(-55), "attackMs": .number(3), "releaseMs": .number(120)]
}

private struct Builder {
    let recipe: Recipe
    let display: [String: SharedDisplaySource]
    var gear: [SharedGear] = []
    /// Index into `gear` for each of the recipe's devices.
    var deviceIndex: [String: Int] = [:]
    var settings: [String: J] = [:]
    var removed: [SharedSetupRemoval] = []
    var adjusted: [String] = []
    var plugins: [String] = []
    var needs = Set<String>()
    var minMacOS: String?

    init(recipe: Recipe, display: [String: SharedDisplaySource]) {
        self.recipe = recipe; self.display = display
        for d in recipe.devices {
            let g = SharedGear(d)
            if let i = gear.firstIndex(of: g) { deviceIndex[d.id] = i } else { deviceIndex[d.id] = gear.count; gear.append(g) }
        }
    }

    mutating func drop(_ part: String?, _ what: String, _ count: Int = 1) {
        guard count > 0 else { return }
        if let i = removed.firstIndex(where: { $0.part == part && $0.what == what }) { removed[i].count += count }
        else { removed.append(SharedSetupRemoval(part: part, what: what, count: count)) }
    }

    func section(_ key: String) -> J? { recipe.sections[key].flatMap(J.parse) }

    /// The index in `gear` of the recipe's device of this kind with this machine key.
    func device(_ kind: DeviceSignature.Kind, _ key: String) -> Int? {
        recipe.devices.first { $0.kind == kind && $0.key == key }.flatMap { deviceIndex[$0.id] }
    }

    mutating func build(_ want: Set<String>) {
        if let a = section("audio") {
            if want.contains("audio") { settings["audio"] = audio(a) }
            if want.contains("microphone") { settings["microphone"] = microphone(a["mic"] ?? .object([:])) }
        }
        if want.contains("windows"), let w = section("windows") { settings["windows"] = windows(w) }
        if want.contains("keys"), let k = section("input") { settings["keys"] = keys(k) }
        if want.contains("clipboard"), let c = section("clipboard") { settings["clipboard"] = clipboard(c) }
        if want.contains("display"), let d = section("display"), let p = displayPart(d) { settings["display"] = p }
    }

    func requirements() -> SharedRequirements {
        let order = T.permissions
        return SharedRequirements(plugins: Array(Set(plugins)).sorted(), minMacOS: minMacOS,
                                  permissions: order.filter(needs.contains))
    }

    // MARK: Audio

    func curve(_ p: J?) -> J {
        let p = p ?? .object([:])
        let bands: [J] = p.items("bands").map { b in
            .object(["hz": .number(b.num("freq", 1000)), "gainDb": .number(b.num("gainDB", 0)), "q": .number(b.num("q", 1.41)), "kind": .string(b.text("kind") ?? "peak")])
        }
        return .object(["enabled": .bool(p.flag("enabled", true)), "preampDb": .number(p.num("preampDB", 0)), "bands": .array(bands)])
    }

    func compressor(_ c: J?) -> J {
        let c = c ?? .object(Defaults.compressor)
        let d = Defaults.compressor
        return .object(["enabled": .bool(c.flag("enabled", false)), "thresholdDb": .number(c.num("thresholdDB", d["thresholdDB"]!.number!)),
                        "ratio": .number(c.num("ratio", 3)), "attackMs": .number(c.num("attackMs", 8)), "releaseMs": .number(c.num("releaseMs", 150)),
                        "makeupDb": .number(c.num("makeupDB", 3))])
    }

    mutating func pluginList(_ part: String, _ slots: [J]) -> J {
        var out: [J] = []
        for s in slots {
            guard let name = s.text("name") else { continue }
            out.append(.object(["name": .string(name), "maker": .string(s.text("manufacturer") ?? ""), "enabled": .bool(s.flag("enabled", true))]))
            plugins.append(name)
            if let st = s["state"], !st.isNull { drop(part, "Plugin settings (plugins load with their own defaults)") }
        }
        return .array(out)
    }

    mutating func audio(_ a: J) -> J {
        let eq = a["eq"] ?? .object([:])
        if eq.flag("enabled", false) { needs.insert("systemAudio"); minMacOS = T.minMacOSForEqualizer }
        if let t = eq.text("targetUID"), !t.isEmpty { drop("audio", "The device the equalizer follows (a device identifier)") }

        var speakerCurves: [(Int, J)] = []
        for (uid, p) in (eq["profiles"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let g = device(.audioOutput, uid) { speakerCurves.append((g, curve(p))) }
            else { drop("audio", "Equalizer curves for speakers that are not in this recipe’s gear") }
        }
        speakerCurves.sort { $0.0 < $1.0 }

        // The limiter always stays on in a shared copy, with a ceiling no higher than -1 dB.
        let dyn = eq["dynamics"] ?? .object([:])
        let ceiling = dyn.num("ceilingDB", -1)
        let safe = min(ceiling, T.limiterCeilingMaxDB)
        if !dyn.flag("limiterEnabled", false) { adjusted.append("The output limiter is switched on in the shared copy (it always is).") }
        if ceiling > T.limiterCeilingMaxDB { adjusted.append("The limiter ceiling is brought down from \(ceiling) dB to \(T.limiterCeilingMaxDB) dB in the shared copy.") }

        var keep: [(Int, J)] = []
        for (uid, k) in (a["keepAlive"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let g = device(.audioOutput, uid) else { drop("audio", "Keep-awake settings for speakers that are not in this recipe’s gear"); continue }
            keep.append((g, .object(["gear": .int(g), "enabled": .bool(k.flag("enabled", false)), "levelDb": .number(k.num("levelDB", -60)),
                                     "frequencyHz": .number(k.num("frequencyHz", 40)), "pulseEverySeconds": .number(k.num("pulseEverySeconds", 0)),
                                     "burstSeconds": .number(k.num("burstSeconds", 0.5))])))
        }
        keep.sort { $0.0 < $1.0 }

        let pin = a["inputPin"] ?? .object([:])
        var pinned: [J] = []
        for uid in pin.items("preferredUIDs").compactMap(\.string) {
            if let g = device(.audioInput, uid) { if !pinned.contains(.int(g)) { pinned.append(.int(g)) } }
            else { drop("audio", "Preferred microphones that are not in this recipe’s gear") }
        }
        if a["knownNames"]?.object?.isEmpty == false { drop("audio", "Remembered names of audio devices") }

        return .object([
            "equalizer": .object(["enabled": .bool(eq.flag("enabled", false)), "curve": curve(eq["defaultProfile"]),
                                  "speakerCurves": .array(speakerCurves.map { .object(["gear": .int($0.0), "curve": $0.1]) })]),
            "effects": .object(["compressor": compressor(dyn["compressor"]),
                                "limiter": .object(["enabled": .bool(true), "ceilingDb": .number(safe), "releaseMs": .number(dyn.num("limiterReleaseMs", 80))]),
                                "plugins": pluginList("audio", eq.items("plugins"))]),
            "keepAwake": .array(keep.map(\.1)),
            "keepInput": .object(["enabled": .bool(pin.flag("enabled", false)), "gear": .array(pinned)]),
        ])
    }

    mutating func microphone(_ m: J) -> J {
        if m.flag("enabled", false) { needs.insert("microphone") }
        var source: J = .null
        if let uid = m.text("sourceUID") {
            if let g = device(.audioInput, uid) { source = .int(g) } else { drop("microphone", "The microphone the chain listens to (not in this recipe’s gear)") }
        }
        let gate = m["gate"] ?? .object(Defaults.gate)
        return .object([
            "enabled": .bool(m.flag("enabled", false)), "source": source, "gainDb": .number(m.num("gainDB", 0)),
            "highPass": .object(["enabled": .bool(m.flag("highPassEnabled", true)), "hz": .number(m.num("highPassHz", 80))]),
            "equalizer": curve(m["eq"]),
            "gate": .object(["enabled": .bool(gate.flag("enabled", false)), "thresholdDb": .number(gate.num("thresholdDB", -55)),
                             "attackMs": .number(gate.num("attackMs", 3)), "releaseMs": .number(gate.num("releaseMs", 120))]),
            "compressor": compressor(m["compressor"]),
            "plugins": pluginList("microphone", m.items("plugins")),
        ])
    }

    // MARK: Windows

    mutating func windows(_ w: J) -> J {
        needs.insert("accessibility")
        let known = Set(T.windowActions)
        func order(_ names: [String]) -> [String] { T.windowActions.filter(Set(names).contains) }
        let drawer: J = {
            guard let a = w["drawerActions"]?.array else { return .null }
            return .strings(order(a.compactMap(\.string).filter(known.contains)))
        }()
        let disabled = (w["disabled"]?.array ?? []).compactMap(\.string)
        var shortcuts: [J] = []
        for (action, s) in (w["custom"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard known.contains(action), let key = s["keyCode"]?.integer, let mods = CarbonMods.names(s["modifiers"]?.integer ?? 0) else {
                drop("windows", "Window shortcuts Whoprrr could not read"); continue
            }
            shortcuts.append(.object(["action": .string(action), "key": .int(key), "modifiers": .strings(mods)]))
        }
        shortcuts.sort { T.windowActions.firstIndex(of: $0["action"]?.string ?? "")! < T.windowActions.firstIndex(of: $1["action"]?.string ?? "")! }
        return .object([
            "shortcutsEnabled": .bool(w.flag("shortcutsEnabled", true)), "gapPoints": .number(w.num("gap", 0)),
            "cycleHalves": .bool(w.flag("cycleHalves", true)), "snapByDrag": .bool(w.flag("snapByDrag", true)),
            "drawer": drawer, "disabled": .strings(order(disabled.filter(known.contains))), "shortcuts": .array(shortcuts),
        ])
    }

    // MARK: Clipboard

    mutating func clipboard(_ c: J) -> J {
        if c.flag("autoPaste", true) { needs.insert("accessibility") }
        if let ignored = c["ignoredBundles"]?.array, !ignored.isEmpty { drop("clipboard", "The list of apps the clipboard ignores") }
        let hk = c["hotkey"] ?? .object([:])
        let mods = CarbonMods.names(hk["modifiers"]?.integer ?? 0) ?? []
        return .object([
            "enabled": .bool(c.flag("enabled", true)),
            "hotkey": .object(["key": .int(hk["keyCode"]?.integer ?? 9), "modifiers": .strings(mods)]),
            "maxItems": .number(c.num("maxItems", 1000)), "maxAgeDays": .number(c.num("maxAgeDays", 30)),
            "captureImages": .bool(c.flag("captureImages", true)), "captureFiles": .bool(c.flag("captureFiles", true)),
            "maxImageMb": .number(c.num("maxImageMB", 20)), "maxTextKb": .number(c.num("maxTextKB", 1024)),
            "autoPaste": .bool(c.flag("autoPaste", true)), "plainTextByDefault": .bool(c.flag("plainTextByDefault", false)),
        ])
    }

    // MARK: Keys and mouse

    /// The app's own encoding of an enum case with one value is `{"case": {"_0": value}}`; one without is `{"case": {}}`.
    func enumCase(_ v: J?) -> (name: String, payload: J?)? {
        guard let o = v?.object, o.count == 1, let (k, inner) = o.first else { return nil }
        return (k, inner["_0"])
    }

    func chord(_ v: J?) -> J? {
        guard let k = v?["key"]?.integer else { return nil }
        return .object(["key": .int(k), "mods": .strings(InputMods.names(v?["mods"]?.integer ?? 0))])
    }

    /// Converts one action. `.left(json)` is kept, `.right(why)` is dropped with that reason.
    enum Converted { case keep(J), drop(String) }

    func output(_ v: J?) -> Converted {
        guard let (name, payload) = enumCase(v) else { return .drop("Key rules Whoprrr could not read") }
        switch name {
        case "chord": return chord(payload).map { c in var o = c.object!; o["type"] = .string("chord"); return .keep(.object(o)) } ?? .drop("Key rules Whoprrr could not read")
        case "modifiers": return .keep(.object(["type": .string("modifiers"), "mods": .strings(InputMods.names(payload?.integer ?? 0))]))
        case "layer": return payload?.string.map { .keep(.object(["type": .string("layer"), "name": .string($0)])) } ?? .drop("Key rules Whoprrr could not read")
        case "media":
            guard let n = payload?.integer, let key = MediaKeys.table.first(where: { $0.1 == n }) else { return .drop("Key rules Whoprrr could not read") }
            return .keep(.object(["type": .string("media"), "key": .string(key.0)]))
        case "mouseButton": return payload?.integer.map { .keep(.object(["type": .string("mouseButton"), "button": .int($0)])) } ?? .drop("Key rules Whoprrr could not read")
        case "command":
            guard let id = payload?.string else { return .drop("Key rules Whoprrr could not read") }
            return T.commands.contains(id) ? .keep(.object(["type": .string("command"), "id": .string(id)])) : .drop("Key rules that run a command a shared setup may not run")
        case "sequence":
            let chords = (payload?.array ?? []).compactMap { chord($0) }
            return .keep(.object(["type": .string("sequence"), "chords": .array(chords)]))
        case "nothing": return .keep(.object(["type": .string("nothing")]))
        case "text": return .drop("Key rules that type text")
        case "openURL": return .drop("Key rules that open a web address")
        case "openApp": return .drop("Key rules that open an app")
        case "shell": return .drop("Key rules that run a shell command")
        default: return .drop("Key rules Whoprrr could not read")
        }
    }

    mutating func keys(_ k: J) -> J {
        needs.insert("accessibility"); needs.insert("inputMonitoring")
        var rules: [J] = []
        var named = 0
        for r in k.items("rules") {
            guard let (tn, tp) = enumCase(r["trigger"]), let tcode = tp?.integer else { drop("keys", "Key rules Whoprrr could not read"); continue }
            let trigger: J
            switch tn {
            case "key": trigger = .object(["type": .string("key"), "code": .int(tcode)])
            case "mouse": trigger = .object(["type": .string("mouse"), "button": .int(tcode)])
            case "logi": trigger = .object(["type": .string("logi"), "control": .int(tcode)])
            default: drop("keys", "Key rules Whoprrr could not read"); continue
            }
            let tap = output(r["tap"])
            var hold: Converted?
            if let h = r["hold"], !h.isNull { hold = output(h) }
            guard case .keep(let tapJ) = tap else { if case .drop(let why) = tap { drop("keys", why) }; continue }
            var holdJ: J?
            if let hold { guard case .keep(let hj) = hold else { if case .drop(let why) = hold { drop("keys", why) }; continue }; holdJ = hj }
            if (r.text("name") ?? "").isEmpty == false { named += 1 }

            var o: [String: J] = [
                "enabled": .bool(r.flag("enabled", true)), "trigger": trigger, "mods": .strings(InputMods.names(r["requiredMods"]?.integer ?? 0)),
                "anyExtraMods": .bool(r.flag("allowExtraModifiers", false)), "tap": tapJ, "holdMs": .number(r.num("holdMs", 200)),
                "scope": .object(["mode": .string(r["scope"]?.text("mode") ?? "everywhere"),
                                  "apps": .strings((r["scope"]?.items("bundleIDs") ?? []).compactMap(\.string).sorted())]),
            ]
            if let holdJ { o["hold"] = holdJ }
            if let l = r.text("layer"), !l.isEmpty { o["layer"] = .string(l) }
            let layouts = r.items("layouts").compactMap(\.string)
            if !layouts.isEmpty { o["layouts"] = .strings(layouts) }
            let types = r.items("keyboardTypes").compactMap(\.integer)
            if !types.isEmpty { o["keyboardTypes"] = .array(types.map { .int($0) }) }
            rules.append(.object(o))
        }
        drop("keys", "Rule names", named)

        var hid: [J] = []
        for m in k.items("hidMappings") {
            guard let s = m["src"]?.number, let d = m["dst"]?.number,
                  let from = T.hidFrom.first(where: { Double(T.hidCodes[$0]!) == s }), let to = T.hidTo.first(where: { Double(T.hidCodes[$0]!) == d }) else {
                drop("keys", "Key mappings other than Caps Lock or a right-hand ⌘ or ⌥ becoming F18 or F19"); continue
            }
            hid.append(.object(["from": .string(from), "to": .string(to)]))
        }
        return .object(["enabled": .bool(k.flag("enabled", true)), "invertMouseWheel": .bool(k.flag("invertMouseWheel", false)),
                        "rules": .array(rules), "hid": .array(hid)])
    }

    // MARK: Display

    mutating func displayPart(_ d: J) -> J? {
        guard let name = d.text("preset"), let src = display[name] else { drop("display", "A display preset whose values were not available"); return nil }
        var values: [String: J] = [:]
        var dropped = 0
        for (k, v) in src.values.sorted(by: { $0.key < $1.key }) {
            switch k {
            case "brightness", "contrast", "sharpness": values[k] = .int(v)
            case "colorPreset":
                if T.displayColor.contains(Double(v)) { values["color"] = .int(v) } else { dropped += 1 }   // "Custom" is never shared
            default: dropped += 1
            }
        }
        drop("display", "Display values other than brightness, contrast, color and sharpness (input, volume, RGB gains, manufacturer and learned codes)", dropped)
        guard !values.isEmpty else { return nil }
        let g = SharedGear(role: DeviceRole.display.rawValue, model: KnownGear.publicName(src.model))
        let index: Int
        if let i = gear.firstIndex(of: g) { index = i } else { index = gear.count; gear.append(g) }
        return .object(["monitor": .int(index), "values": .object(values)])
    }
}
