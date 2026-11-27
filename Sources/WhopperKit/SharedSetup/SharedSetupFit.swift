import Foundation

// MARK: - What the receiving Mac looks like

/// An audio plugin installed on the receiving Mac.
public struct InstalledPlugin: Equatable, Sendable {
    public var name: String
    public var maker: String
    public var type: UInt32, subtype: UInt32, manufacturerCode: UInt32
    public init(name: String, maker: String, type: UInt32, subtype: UInt32, manufacturerCode: UInt32) {
        self.name = name; self.maker = maker; self.type = type; self.subtype = subtype; self.manufacturerCode = manufacturerCode
    }
}

/// Everything the fitting needs to know about the Mac that takes a setup. Plain data, so it can be tested without hardware.
public struct ReceiverEnvironment: Sendable {
    /// The gear connected now, as the gear scan reports it (role, model and the key this Mac uses for it).
    public var gear: [DeviceSignature]
    public var plugins: [InstalledPlugin]
    /// "27.2"
    public var macOS: String
    public var permissions: [Permission: PermissionStatus]
    /// The Mac's own settings per recipe key ("audio", "windows"…), as `RecipeStore.snapshot` returns them.
    public var sections: [String: Data]

    public init(gear: [DeviceSignature] = [], plugins: [InstalledPlugin] = [], macOS: String = "14.0",
                permissions: [Permission: PermissionStatus] = [:], sections: [String: Data] = [:]) {
        self.gear = gear; self.plugins = plugins; self.macOS = macOS; self.permissions = permissions; self.sections = sections
    }
}

// MARK: - The plan

public enum MatchQuality: Equatable, Sendable {
    /// The same model.
    case exactModel
    /// A different model with the same role.
    case sameRole
    case none
}

/// What a person may say about one of the author's devices instead of the proposal.
public enum GearOverride: Equatable, Sendable {
    /// Use this connected device (`DeviceSignature.id`).
    case device(String)
    /// Match nothing.
    case none
}

/// The author's device and the one on this Mac it is proposed to stand for.
public struct GearMatch: Equatable, Sendable {
    public var authorIndex: Int
    public var author: SharedGear
    public var receiver: DeviceSignature?
    public var quality: MatchQuality
}

public enum LineState: Equatable, Sendable {
    case applies
    case appliesWithNote(String)
    /// Switched off, with the reason in plain words.
    case off(String)

    public var isOff: Bool { if case .off = self { return true }; return false }
    public var reason: String? {
        switch self { case .applies: return nil; case .appliesWithNote(let n): return n; case .off(let r): return r }
    }
}

/// What a line of the setup is, so it can be applied.
public enum LineKind: Equatable, Sendable {
    case equalizerCurve
    case speakerCurve(gear: Int)
    case outputEffects
    case outputPlugins
    case keepAwake(gear: Int)
    case keepInput
    case microphoneChain
    case microphonePlugins
    case windows
    case keysSettings
    case keysRules
    case keysLogitech
    case keysMappings
    case clipboard
    case display
}

/// Why a line is off, when the cause is something a screen can name: one of the author's devices is not connected, a plugin is
/// not installed, or the person switched the line off. Nothing else is named here; any other reason is just its sentence.
public enum OffCause: Equatable, Sendable {
    /// No device on this Mac stands for the author's device at this index.
    case gearMissing(Int)
    /// Every plugin the line needs that is not installed (by name).
    case pluginsMissing([String])
    /// The person switched it off on the review.
    case person
}

public struct SetupLine: Equatable, Identifiable, Sendable {
    /// Stable: "audio.equalizer", "keys.rules"…
    public var id: String
    public var part: String
    public var kind: LineKind
    public var title: String
    public var state: LineState
    /// Set for an off line whose cause is one of `OffCause`; nil for every other reason, which is only the sentence in `state`.
    public var cause: OffCause? = nil
}

public struct FitPlan: Equatable, Sendable {
    public var matches: [GearMatch]
    public var lines: [SetupLine]
    public var off: [SetupLine] { lines.filter { $0.state.isOff } }
    public func line(_ id: String) -> SetupLine? { lines.first { $0.id == id } }
}

/// A display preset the app has to create for the monitor before the recipe can use it (the recipe only remembers a preset's name).
public struct DisplayPresetRequest: Equatable, Sendable {
    public var name: String
    public var model: String
    /// "brightness", "contrast", "colorPreset", "sharpness" and their values.
    public var values: [String: Int]
}

public struct SharedSetupFitResult: Sendable {
    /// An ordinary recipe of this Mac's: its own settings in the app's own JSON, plus the author's original and the skipped lines.
    public var recipe: Recipe
    public var plan: FitPlan
    public var displayPreset: DisplayPresetRequest?
}

/// One area of the app taken on its own, in the same form the per-area preset menus store: `key` is the preset surface
/// ("audio.eq", "audio.outputfx", "audio.mic", "audio.routing", "windows", "clipboard", "input").
public struct TakenPreset: Equatable, Sendable {
    public var key: String
    public var title: String
    public var data: Data
}

// MARK: - The fitting

public enum SharedSetupFit {
    /// The reason a line carries when the person switched it off themselves.
    public static let switchedOffReason = "You switched this off."

    /// Proposes a match for each of the author's devices (exact model first, the same role otherwise, none) and a state for each line.
    /// `overrides` replaces the proposal for the author's devices a person chose; `switchedOff` holds line ids the person turned off.
    public static func plan(_ setup: SharedSetup, for env: ReceiverEnvironment, overrides: [Int: GearOverride] = [:], switchedOff: Set<String> = []) -> FitPlan {
        let matches = Planner.matches(setup, env, overrides)
        var p = Planner(setup: setup, env: env, matches: matches)
        let lines = p.lines().map { l -> SetupLine in
            var l = l
            if switchedOff.contains(l.id), !l.state.isOff { l.state = .off(SharedSetupFit.switchedOffReason); l.cause = .person }
            return l
        }
        return FitPlan(matches: matches, lines: lines)
    }

    /// Turns a plan into the receiver's own recipe. Lines that apply are merged into the receiver's current settings; parts that
    /// are switched off keep the receiver's own. The author's original, as first fitted, and the skipped lines are kept with it.
    public static func fit(_ setup: SharedSetup, plan: FitPlan, for env: ReceiverEnvironment, madeBy: String? = nil, now: Date = Date()) -> SharedSetupFitResult {
        var sections = Merger.base(env, parts: setup.parts)
        var display: DisplayPresetRequest?
        for l in plan.lines where !l.state.isOff { Merger.apply(l, setup, plan.matches, env, into: &sections, display: &display) }

        var data: [String: Data] = [:]
        for (k, v) in sections { data[k] = v.encoded() }
        var devices: [DeviceSignature] = []
        for m in plan.matches { if let r = m.receiver, !devices.contains(where: { $0.id == r.id }) { devices.append(r) } }

        var r = Recipe(name: setup.title, devices: devices, sections: data, autoApply: false)
        r.createdAt = now; r.updatedAt = now
        r.skippedLines = plan.off.map { SkippedLine(id: $0.id, part: $0.part, title: $0.title, reason: $0.state.reason ?? "") }
        r.authorsOriginal = AuthorsOriginal(title: setup.title, madeBy: madeBy, setup: setup.encoded(), fittedSections: data, takenAt: now)
        if display != nil { r.sections["display"] = JSONValue.object(["preset": .string(display!.name)]).encoded(); r.authorsOriginal?.fittedSections["display"] = r.sections["display"] }
        return SharedSetupFitResult(recipe: r, plan: plan, displayPreset: display)
    }

    /// Switches on a line that was skipped, merging only that line into the recipe's current settings (the person's own changes
    /// stay). The setup is read from the author's original and checked again. Nil when the line cannot be applied at all (no device
    /// to put it on, the plugin is still missing) or the stored setup no longer passes the checks.
    public static func switchOn(_ lineID: String, in recipe: Recipe, for env: ReceiverEnvironment, overrides: [Int: GearOverride] = [:]) -> SharedSetupFitResult? {
        guard let orig = recipe.authorsOriginal, let json = JSONValue.parse(orig.setup), SharedSetupLimits.check(value: json).ok,
              let setup = SharedSetup(json: json), recipe.skipped.contains(where: { $0.id == lineID }) else { return nil }
        var env = env
        for (k, v) in recipe.sections { env.sections[k] = v }                       // the recipe's own settings are the base
        let plan = SharedSetupFit.plan(setup, for: env, overrides: overrides)
        guard let line = plan.line(lineID), Merger.possible(line, setup, plan.matches, env) else { return nil }

        var sections = Merger.base(env, parts: setup.parts)
        var display: DisplayPresetRequest?
        Merger.apply(line, setup, plan.matches, env, into: &sections, display: &display)
        var out = recipe
        for (k, v) in sections where recipe.sections[k] != nil || k == Merger.sectionKey(line.part) { out.sections[k] = v.encoded() }
        if let display { out.sections["display"] = JSONValue.object(["preset": .string(display.name)]).encoded() }
        out.skippedLines = recipe.skipped.filter { $0.id != lineID }
        return SharedSetupFitResult(recipe: out, plan: plan, displayPreset: display)
    }

    /// Takes one part of a setup on its own, as preset-like results for the areas it covers (the same form the per-area preset
    /// menus store). Lines that are switched off are left out, so the receiver's own settings stay.
    public static func take(part: String, of setup: SharedSetup, plan: FitPlan, for env: ReceiverEnvironment) -> [TakenPreset] {
        guard setup.parts.contains(part) else { return [] }
        var sections = Merger.base(env, parts: [part])
        var display: DisplayPresetRequest?
        let lines = plan.lines.filter { $0.part == part && !$0.state.isOff }
        for l in lines { Merger.apply(l, setup, plan.matches, env, into: &sections, display: &display) }
        return Merger.presets(part: part, lines: lines, sections: sections, display: display)
    }
}

// MARK: - Planning

private typealias J = JSONValue
private typealias T = SharedSetupTable

private struct Planner {
    let setup: SharedSetup, env: ReceiverEnvironment, matches: [GearMatch]

    static func same(_ a: String, _ b: String) -> Bool { a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame }

    static func matches(_ setup: SharedSetup, _ env: ReceiverEnvironment, _ overrides: [Int: GearOverride]) -> [GearMatch] {
        var used = Set<String>()
        var out: [GearMatch?] = Array(repeating: nil, count: setup.gear.count)
        // Choices a person made come first, then exact models, then the same role.
        for (i, g) in setup.gear.enumerated() {
            guard let o = overrides[i] else { continue }
            switch o {
            case .none: out[i] = GearMatch(authorIndex: i, author: g, receiver: nil, quality: .none)
            case .device(let id):
                if let d = env.gear.first(where: { $0.id == id }) {
                    used.insert(d.id)
                    out[i] = GearMatch(authorIndex: i, author: g, receiver: d, quality: same(d.model, g.model) ? .exactModel : .sameRole)
                } else { out[i] = GearMatch(authorIndex: i, author: g, receiver: nil, quality: .none) }
            }
        }
        for (i, g) in setup.gear.enumerated() where out[i] == nil {
            if let d = env.gear.first(where: { $0.role.rawValue == g.role && same($0.model, g.model) && !used.contains($0.id) }) {
                used.insert(d.id); out[i] = GearMatch(authorIndex: i, author: g, receiver: d, quality: .exactModel)
            }
        }
        for (i, g) in setup.gear.enumerated() where out[i] == nil {
            let pool = env.gear.filter { $0.role.rawValue == g.role }
            if let d = pool.first(where: { !used.contains($0.id) }) ?? pool.first {
                used.insert(d.id); out[i] = GearMatch(authorIndex: i, author: g, receiver: d, quality: .sameRole)
            } else { out[i] = GearMatch(authorIndex: i, author: g, receiver: nil, quality: .none) }
        }
        return out.compactMap { $0 }
    }

    // MARK: Words and checks

    func version(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
    func macOSAtLeast(_ need: String) -> Bool {
        let a = version(env.macOS), b = version(need)
        for i in 0..<max(a.count, b.count) { let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0; if x != y { return x > y } }
        return true
    }

    /// Why the line cannot run here for lack of macOS or a permission, or a note when only asking is left.
    func platform(needs: [Permission], macOS: String? = nil) -> (off: String?, note: String?) {
        if let m = macOS, !macOSAtLeast(m) { return ("Needs macOS \(m) or newer; this Mac has \(env.macOS).", nil) }
        for p in needs {
            switch env.permissions[p] {
            case .denied?: return ("\(p.title) is not allowed for Whoprrr on this Mac. Allow it in System Settings, then switch this on.", nil)
            case .notDetermined?: return (nil, "Whoprrr will ask for \(p.title).")
            default: break
            }
        }
        return (nil, nil)
    }

    func state(_ off: String?, note: String?...) -> LineState {
        if let off { return .off(off) }
        let n = note.compactMap { $0 }.joined(separator: " ")
        return n.isEmpty ? .applies : .appliesWithNote(n)
    }

    func gearName(_ i: Int) -> String { setup.gear.indices.contains(i) ? setup.gear[i].model : "the author’s gear" }
    func match(_ i: Int) -> GearMatch? { matches.first { $0.authorIndex == i } }

    /// How a line that needs one of the author's devices stands.
    func deviceState(_ i: Int, what: String, allowDifferentModel: Bool, differentModelNote: String) -> (off: String?, note: String?) {
        guard let m = match(i), let r = m.receiver else { return ("No \(setup.gear[i].role) connected that matches the \(gearName(i)).", nil) }
        switch m.quality {
        case .exactModel: return (nil, nil)
        case .sameRole:
            return allowDifferentModel ? (nil, "Made for the \(gearName(i)); yours is the \(r.model). \(differentModelNote)")
                : ("Your \(setup.gear[i].role) is the \(r.model), not the \(gearName(i)) this was made for, so this is skipped and yours is kept.", nil)
        case .none: return ("No \(setup.gear[i].role) connected that matches the \(gearName(i)).", nil)
        }
    }

    /// True when no device at all stands for the author's device at `i` (so the line waits for gear rather than for a different model).
    func gearGone(_ i: Int) -> Bool { match(i)?.receiver == nil || match(i)?.quality == MatchQuality.none }

    func pluginMissingNames(_ list: [J]) -> [String] {
        list.filter { p in !env.plugins.contains { Planner.same($0.name, p["name"]?.string ?? "") && ($0.maker.isEmpty || (p["maker"]?.string ?? "").isEmpty || Planner.same($0.maker, p["maker"]?.string ?? "")) } }.compactMap { $0["name"]?.string }
    }

    func pluginState(_ list: [J], what: String) -> LineState {
        let names = list.compactMap { $0["name"]?.string }
        let missing = list.filter { p in !env.plugins.contains { Planner.same($0.name, p["name"]?.string ?? "") && ($0.maker.isEmpty || (p["maker"]?.string ?? "").isEmpty || Planner.same($0.maker, p["maker"]?.string ?? "")) } }.compactMap { $0["name"]?.string }
        if missing.isEmpty { return .applies }
        let list = missing.map { "“\($0)”" }.joined(separator: ", ")
        if missing.count == names.count { return .off(missing.count == 1 ? "The plugin \(list) is not installed on this Mac." : "The plugins \(list) are not installed on this Mac.") }
        return .appliesWithNote("Without \(list), which \(missing.count == 1 ? "is" : "are") not installed here.")
    }

    // MARK: Lines

    mutating func lines() -> [SetupLine] {
        var out: [SetupLine] = []
        func add(_ id: String, _ part: String, _ kind: LineKind, _ title: String, _ state: LineState, cause: OffCause? = nil) {
            out.append(SetupLine(id: id, part: part, kind: kind, title: title, state: state, cause: state.isOff ? cause : nil))
        }
        let s = setup.settings

        if let a = s["audio"] {
            let eq = a["equalizer"] ?? .null
            let speakers = setup.gear.indices.filter { setup.gear[$0].role == "speaker" }
            let plat = platform(needs: [.systemAudio], macOS: T.minMacOSForEqualizer)
            var curveState: LineState
            var curveCause: OffCause?
            if let off = plat.off { curveState = .off(off) }
            else if speakers.isEmpty { curveState = state(nil, note: plat.note) }
            else if speakers.contains(where: { match($0)?.quality == .exactModel }) { curveState = state(nil, note: plat.note) }
            else if let i = speakers.first(where: { match($0)?.quality == .sameRole }), let r = match(i)?.receiver {
                curveState = .off("Your speakers are the \(r.model), not the \(gearName(i)) this curve was made for, so the equalizer curve is skipped and yours is kept.")
            } else { curveState = .off("No speakers connected that match the \(gearName(speakers[0])) this curve was made for."); curveCause = .gearMissing(speakers[0]) }
            add("audio.equalizer", "audio", .equalizerCurve, "Equalizer curve", curveState, cause: curveCause)

            for item in (eq["speakerCurves"]?.array ?? []) {
                guard let g = item["gear"]?.integer, setup.gear.indices.contains(g) else { continue }
                let d = deviceState(g, what: "speaker", allowDifferentModel: false, differentModelNote: "")
                add("audio.equalizer.speaker.\(g)", "audio", .speakerCurve(gear: g), "Equalizer curve for the \(gearName(g))", state(plat.off ?? d.off, note: plat.note, d.note),
                    cause: plat.off == nil && gearGone(g) ? .gearMissing(g) : nil)
            }
            add("audio.effects", "audio", .outputEffects, "Output compressor and limiter", .appliesWithNote("The output limiter is switched on and stays on."))
            let plug = a["effects"]?["plugins"]?.array ?? []
            if !plug.isEmpty { add("audio.plugins", "audio", .outputPlugins, "Output plugins", pluginState(plug, what: "output"), cause: .pluginsMissing(pluginMissingNames(plug))) }
            for item in (a["keepAwake"]?.array ?? []) {
                guard let g = item["gear"]?.integer, setup.gear.indices.contains(g) else { continue }
                let d = deviceState(g, what: "speaker", allowDifferentModel: false, differentModelNote: "")
                add("audio.keepAwake.\(g)", "audio", .keepAwake(gear: g), "Keep the \(gearName(g)) awake", state(d.off, note: d.note), cause: gearGone(g) ? .gearMissing(g) : nil)
            }
            let keep = a["keepInput"] ?? .null
            let mics = (keep["gear"]?.array ?? []).compactMap(\.integer).filter { setup.gear.indices.contains($0) }
            if keep["enabled"]?.bool == true || !mics.isEmpty {
                let ok = mics.filter { match($0)?.quality == .exactModel }
                let st: LineState = mics.isEmpty || !ok.isEmpty
                    ? (ok.count < mics.count ? .appliesWithNote("Only for the microphones you have.") : .applies)
                    : .off("None of the microphones this keeps (\(mics.map(gearName).joined(separator: ", "))) are connected.")
                add("audio.keepInput", "audio", .keepInput, "Keep a microphone as the input", st, cause: mics.count == 1 ? .gearMissing(mics[0]) : nil)
            }
        }

        if let m = s["microphone"] {
            let plat = platform(needs: [.microphone])
            var off = plat.off, note = plat.note, extra: String?
            var cause: OffCause?
            if let src = m["source"]?.integer, setup.gear.indices.contains(src) {
                let d = deviceState(src, what: "microphone", allowDifferentModel: true, differentModelNote: "Check the level.")
                if off == nil, d.off != nil, gearGone(src) { cause = .gearMissing(src) }
                off = off ?? d.off; extra = d.note
            }
            add("microphone.chain", "microphone", .microphoneChain, "Microphone chain", state(off, note: note, extra), cause: cause)
            let plug = m["plugins"]?.array ?? []
            if !plug.isEmpty { add("microphone.plugins", "microphone", .microphonePlugins, "Microphone plugins", pluginState(plug, what: "microphone"), cause: .pluginsMissing(pluginMissingNames(plug))) }
        }

        if s["windows"] != nil {
            let plat = platform(needs: [.accessibility])
            add("windows", "windows", .windows, "Window layouts and shortcuts", state(plat.off, note: plat.note))
        }

        if let k = s["keys"] {
            let plat = platform(needs: [.accessibility, .inputMonitoring])
            add("keys.settings", "keys", .keysSettings, "Keys and mouse on or off", state(plat.off, note: plat.note))
            let rules = k["rules"]?.array ?? []
            let logi = rules.filter { $0["trigger"]?["type"]?.string == "logi" }
            if rules.count > logi.count { add("keys.rules", "keys", .keysRules, "Key and mouse rules", state(plat.off, note: plat.note)) }
            if !logi.isEmpty {
                let have = env.gear.contains { $0.kind == .logitech }
                add("keys.logitech", "keys", .keysLogitech, "Logitech button rules", have ? state(plat.off, note: plat.note) : .off("No Logitech device is connected."))
            }
            if !(k["hid"]?.array ?? []).isEmpty {
                add("keys.mappings", "keys", .keysMappings, "Caps Lock and modifier key changes", state(plat.off, note: "Changes how these keys behave on every keyboard until Whoprrr puts them back."))
            }
        }

        if let c = s["clipboard"] {
            let plat: (off: String?, note: String?) = c["autoPaste"]?.bool == true ? platform(needs: [.accessibility]) : (nil, nil)
            add("clipboard", "clipboard", .clipboard, "Clipboard history", state(plat.off, note: plat.note))
        }

        if let d = s["display"] {
            let g = d["monitor"]?.integer ?? -1
            var st: LineState = .off("No monitor is connected.")
            var cause: OffCause?
            if setup.gear.indices.contains(g), let m = match(g) {
                switch m.quality {
                case .exactModel: st = .applies
                case .sameRole: st = .off("Your monitor is the \(m.receiver?.model ?? "another model"), not the \(gearName(g)) these values were made for, so they are skipped.")
                case .none: st = .off("No monitor connected matches the \(gearName(g)) these values were made for."); cause = .gearMissing(g)
                }
            }
            add("display", "display", .display, "Monitor brightness, contrast, color and sharpness", st, cause: cause)
        }
        return out
    }
}

// MARK: - Merging into the app's own settings

/// Builds the app's own settings JSON (the shape `AudioSettings`, `WindowSettings`… encode to) from the shared document.
private enum Merger {
    static func sectionKey(_ part: String) -> String {
        switch part { case "microphone": return "audio"; case "keys": return "input"; default: return part }
    }

    /// The receiver's current settings for the surfaces these parts touch, or complete defaults when there are none.
    static func base(_ env: ReceiverEnvironment, parts: [String]) -> [String: J] {
        var out: [String: J] = [:]
        for part in parts {
            let key = sectionKey(part)
            if out[key] != nil { continue }
            if let d = env.sections[key], let v = J.parse(d), v.object != nil { out[key] = v } else if let v = defaults(key) { out[key] = v }
        }
        return out
    }

    static func defaults(_ key: String) -> J? {
        switch key {
        case "audio": return .object(["inputPin": .object(["enabled": .bool(false), "preferredUIDs": .array([])]), "keepAlive": .object([:]), "eq": .object([:]), "mic": .object([:]), "knownNames": .object([:])])
        case "windows": return .object(["shortcutsEnabled": .bool(true), "custom": .object([:]), "disabled": .array([]), "gap": .number(0), "cycleHalves": .bool(true), "snapByDrag": .bool(true)])
        case "clipboard": return .object(["enabled": .bool(true), "hotkey": .object(["keyCode": .int(9), "modifiers": .int(4352)]), "maxItems": .int(1000), "maxAgeDays": .int(30),
                                          "captureImages": .bool(true), "captureFiles": .bool(true), "maxImageMB": .int(20), "maxTextKB": .int(1024), "autoPaste": .bool(true),
                                          "plainTextByDefault": .bool(false), "ignoredBundles": .strings(T.clipboardDefaultIgnored)])
        case "input": return .object(["enabled": .bool(true), "rules": .array([]), "hidMappings": .array([]), "invertMouseWheel": .bool(false), "defaultsVersion": .int(0)])
        default: return nil
        }
    }

    // MARK: Doc to app shape

    static func curve(_ c: J?) -> J {
        let bands: [J] = (c?["bands"]?.array ?? []).map { b in
            .object(["freq": b["hz"] ?? .number(1000), "gainDB": b["gainDb"] ?? .number(0), "q": b["q"] ?? .number(1.41), "kind": b["kind"] ?? .string("peak")])
        }
        return .object(["enabled": c?["enabled"] ?? .bool(true), "preampDB": c?["preampDb"] ?? .number(0), "bands": .array(bands)])
    }

    static func compressor(_ c: J?) -> J {
        .object(["enabled": c?["enabled"] ?? .bool(false), "thresholdDB": c?["thresholdDb"] ?? .number(-20), "ratio": c?["ratio"] ?? .number(3),
                 "attackMs": c?["attackMs"] ?? .number(8), "releaseMs": c?["releaseMs"] ?? .number(150), "makeupDB": c?["makeupDb"] ?? .number(3)])
    }

    static func chord(_ c: J) -> J { .object(["key": c["key"] ?? .int(0), "mods": .int(InputMods.bits((c["mods"]?.array ?? []).compactMap(\.string)))]) }

    static func output(_ o: J) -> J {
        func one(_ name: String, _ v: J?) -> J { .object([name: v.map { .object(["_0": $0]) } ?? .object([:])]) }
        switch o["type"]?.string {
        case "chord": return one("chord", chord(o))
        case "modifiers": return one("modifiers", .int(InputMods.bits((o["mods"]?.array ?? []).compactMap(\.string))))
        case "layer": return one("layer", o["name"])
        case "media": return one("media", .int(MediaKeys.table.first { $0.0 == o["key"]?.string }?.1 ?? 0))
        case "mouseButton": return one("mouseButton", o["button"])
        case "command": return one("command", o["id"])
        case "sequence": return one("sequence", .array((o["chords"]?.array ?? []).map(chord)))
        default: return one("nothing", nil)
        }
    }

    static func rule(_ r: J) -> J {
        let t = r["trigger"] ?? .null
        let trig: J
        switch t["type"]?.string {
        case "mouse": trig = .object(["mouse": .object(["_0": t["button"] ?? .int(0)])])
        case "logi": trig = .object(["logi": .object(["_0": t["control"] ?? .int(0)])])
        default: trig = .object(["key": .object(["_0": t["code"] ?? .int(0)])])
        }
        var o: [String: J] = [
            "id": .string(UUID().uuidString), "name": .string(""), "enabled": r["enabled"] ?? .bool(true), "trigger": trig,
            "requiredMods": .int(InputMods.bits((r["mods"]?.array ?? []).compactMap(\.string))), "allowExtraModifiers": r["anyExtraMods"] ?? .bool(false),
            "tap": output(r["tap"] ?? .null), "holdMs": r["holdMs"] ?? .int(200),
            "scope": .object(["mode": r["scope"]?["mode"] ?? .string("everywhere"), "bundleIDs": r["scope"]?["apps"] ?? .array([])]),
            "layouts": r["layouts"] ?? .array([]), "keyboardTypes": r["keyboardTypes"] ?? .array([]),
        ]
        if let h = r["hold"] { o["hold"] = output(h) }
        if let l = r["layer"] { o["layer"] = l }
        return .object(o)
    }

    static func slot(_ p: J, _ env: ReceiverEnvironment) -> J? {
        guard let inst = env.plugins.first(where: { Planner.same($0.name, p["name"]?.string ?? "") && ($0.maker.isEmpty || (p["maker"]?.string ?? "").isEmpty || Planner.same($0.maker, p["maker"]?.string ?? "")) }) else { return nil }
        // The plugin is the one installed on this Mac, found by name; nothing of the author's plugin or its state comes along.
        return .object(["id": .string(UUID().uuidString), "name": .string(inst.name), "manufacturer": .string(inst.maker), "type": .number(Double(inst.type)),
                        "subtype": .number(Double(inst.subtype)), "manufacturerCode": .number(Double(inst.manufacturerCode)),
                        "enabled": p["enabled"] ?? .bool(true), "inProcess": .bool(false)])
    }

    // MARK: Applying a line

    static func receiverKey(_ matches: [GearMatch], _ i: Int) -> String? { matches.first { $0.authorIndex == i }?.receiver?.key }

    /// False when there is nothing to put the line on (no device, no installed plugin), even if the person insists.
    static func possible(_ l: SetupLine, _ setup: SharedSetup, _ matches: [GearMatch], _ env: ReceiverEnvironment) -> Bool {
        switch l.kind {
        case .speakerCurve(let g), .keepAwake(let g): return receiverKey(matches, g) != nil
        case .outputPlugins: return (setup.settings["audio"]?["effects"]?["plugins"]?.array ?? []).contains { slot($0, env) != nil }
        case .microphonePlugins: return (setup.settings["microphone"]?["plugins"]?.array ?? []).contains { slot($0, env) != nil }
        case .display: return receiverKey(matches, setup.settings["display"]?["monitor"]?.integer ?? -1) != nil
        case .keysLogitech: return env.gear.contains { $0.kind == .logitech }
        case .equalizerCurve:
            let sp = setup.gear.indices.filter { setup.gear[$0].role == "speaker" }
            return sp.isEmpty || sp.contains { receiverKey(matches, $0) != nil }
        default: return true
        }
    }

    static func apply(_ l: SetupLine, _ setup: SharedSetup, _ matches: [GearMatch], _ env: ReceiverEnvironment, into s: inout [String: J], display: inout DisplayPresetRequest?) {
        let doc = setup.settings
        switch l.kind {
        case .equalizerCurve:
            guard let a = doc["audio"], var au = s["audio"] else { return }
            au = au.setting(["eq", "defaultProfile"], curve(a["equalizer"]?["curve"]))
            au = au.setting(["eq", "enabled"], a["equalizer"]?["enabled"] ?? .bool(false))
            s["audio"] = au
        case .speakerCurve(let g):
            guard let key = receiverKey(matches, g), var au = s["audio"],
                  let item = (doc["audio"]?["equalizer"]?["speakerCurves"]?.array ?? []).first(where: { $0["gear"]?.integer == g }) else { return }
            s["audio"] = au.setting(["eq", "profiles", key], curve(item["curve"]))
        case .outputEffects:
            guard let e = doc["audio"]?["effects"], let au = s["audio"] else { return }
            let lim = e["limiter"] ?? .null
            s["audio"] = au.setting(["eq", "dynamics"], .object(["compressor": compressor(e["compressor"]), "limiterEnabled": .bool(true),
                                                                  "ceilingDB": lim["ceilingDb"] ?? .number(-1), "limiterReleaseMs": lim["releaseMs"] ?? .number(80)]))
        case .outputPlugins:
            guard let au = s["audio"] else { return }
            s["audio"] = au.setting(["eq", "plugins"], .array((doc["audio"]?["effects"]?["plugins"]?.array ?? []).compactMap { slot($0, env) }))
        case .keepAwake(let g):
            guard let key = receiverKey(matches, g), let au = s["audio"],
                  let k = (doc["audio"]?["keepAwake"]?.array ?? []).first(where: { $0["gear"]?.integer == g }) else { return }
            s["audio"] = au.setting(["keepAlive", key], .object(["enabled": k["enabled"] ?? .bool(false), "levelDB": k["levelDb"] ?? .number(-60), "frequencyHz": k["frequencyHz"] ?? .number(40),
                                                                  "pulseEverySeconds": k["pulseEverySeconds"] ?? .number(0), "burstSeconds": k["burstSeconds"] ?? .number(0.5)]))
        case .keepInput:
            guard let k = doc["audio"]?["keepInput"], let au = s["audio"] else { return }
            let keys = (k["gear"]?.array ?? []).compactMap(\.integer).compactMap { g -> String? in matches.first { $0.authorIndex == g && $0.quality == .exactModel }?.receiver?.key }
            s["audio"] = au.setting(["inputPin"], .object(["enabled": k["enabled"] ?? .bool(false), "preferredUIDs": .strings(keys)]))
        case .microphoneChain:
            guard let m = doc["microphone"], var au = s["audio"] else { return }
            au = au.setting(["mic", "enabled"], m["enabled"] ?? .bool(false))
            if let src = m["source"]?.integer, let key = receiverKey(matches, src) { au = au.setting(["mic", "sourceUID"], .string(key)) }
            au = au.setting(["mic", "gainDB"], m["gainDb"] ?? .number(0))
            au = au.setting(["mic", "highPassEnabled"], m["highPass"]?["enabled"] ?? .bool(true))
            au = au.setting(["mic", "highPassHz"], m["highPass"]?["hz"] ?? .number(80))
            au = au.setting(["mic", "eq"], curve(m["equalizer"]))
            let g = m["gate"] ?? .null
            au = au.setting(["mic", "gate"], .object(["enabled": g["enabled"] ?? .bool(false), "thresholdDB": g["thresholdDb"] ?? .number(-55), "attackMs": g["attackMs"] ?? .number(3), "releaseMs": g["releaseMs"] ?? .number(120)]))
            au = au.setting(["mic", "compressor"], compressor(m["compressor"]))
            s["audio"] = au
        case .microphonePlugins:
            guard let au = s["audio"] else { return }
            s["audio"] = au.setting(["mic", "plugins"], .array((doc["microphone"]?["plugins"]?.array ?? []).compactMap { slot($0, env) }))
        case .windows:
            guard let w = doc["windows"], var cur = s["windows"] else { return }
            cur = cur.setting(["shortcutsEnabled"], w["shortcutsEnabled"] ?? .bool(true)).setting(["gap"], w["gapPoints"] ?? .number(0))
            cur = cur.setting(["cycleHalves"], w["cycleHalves"] ?? .bool(true)).setting(["snapByDrag"], w["snapByDrag"] ?? .bool(true))
            cur = cur.setting(["disabled"], w["disabled"] ?? .array([]))
            var custom: [String: J] = [:]
            for sc in w["shortcuts"]?.array ?? [] {
                if let a = sc["action"]?.string { custom[a] = .object(["keyCode": sc["key"] ?? .int(0), "modifiers": .int(CarbonMods.bits((sc["modifiers"]?.array ?? []).compactMap(\.string)))]) }
            }
            cur = cur.setting(["custom"], .object(custom))
            if let d = w["drawer"], !d.isNull { cur = cur.setting(["drawerActions"], d) } else { cur = cur.removing(["drawerActions"]) }
            s["windows"] = cur
        case .keysSettings:
            guard let k = doc["keys"], let cur = s["input"] else { return }
            s["input"] = cur.setting(["enabled"], k["enabled"] ?? .bool(true)).setting(["invertMouseWheel"], k["invertMouseWheel"] ?? .bool(false))
        case .keysRules, .keysLogitech:
            guard let k = doc["keys"], let cur = s["input"] else { return }
            let isLogi = l.kind == .keysLogitech
            func logi(_ r: J) -> Bool { (r["trigger"]?["type"]?.string ?? r["trigger"]?.object?.keys.first) == "logi" }
            let theirs = (k["rules"]?.array ?? []).filter { logi($0) == isLogi }.map(rule)
            let mine = (cur["rules"]?.array ?? []).filter { logi($0) != isLogi }
            s["input"] = cur.setting(["rules"], .array(mine + theirs))
        case .keysMappings:
            guard let k = doc["keys"], let cur = s["input"] else { return }
            let maps: [J] = (k["hid"]?.array ?? []).compactMap { m in
                guard let f = m["from"]?.string, let t = m["to"]?.string, let fc = T.hidCodes[f], let tc = T.hidCodes[t] else { return nil }
                return .object(["src": .number(Double(fc)), "dst": .number(Double(tc))])
            }
            s["input"] = cur.setting(["hidMappings"], .array(maps))
        case .clipboard:
            guard let c = doc["clipboard"], var cur = s["clipboard"] else { return }
            cur = cur.setting(["enabled"], c["enabled"] ?? .bool(true))
            cur = cur.setting(["hotkey"], .object(["keyCode": c["hotkey"]?["key"] ?? .int(9), "modifiers": .int(CarbonMods.bits((c["hotkey"]?["modifiers"]?.array ?? []).compactMap(\.string)))]))
            for (to, from) in [("maxItems", "maxItems"), ("maxAgeDays", "maxAgeDays"), ("captureImages", "captureImages"), ("captureFiles", "captureFiles"),
                               ("maxImageMB", "maxImageMb"), ("maxTextKB", "maxTextKb"), ("autoPaste", "autoPaste"), ("plainTextByDefault", "plainTextByDefault")] {
                if let v = c[from] { cur = cur.setting([to], v) }
            }
            // The receiver's ignore list stays; a shared one can only add to it.
            var list = (cur["ignoredBundles"]?.array ?? T.clipboardDefaultIgnored.map { .string($0) })
            for x in c["ignoredApps"]?.array ?? [] where !list.contains(x) { list.append(x) }
            for d in T.clipboardDefaultIgnored where !list.contains(.string(d)) { list.append(.string(d)) }
            s["clipboard"] = cur.setting(["ignoredBundles"], .array(list))
        case .display:
            guard let d = doc["display"], let vals = d["values"]?.object else { return }
            var v: [String: Int] = [:]
            for (k, x) in vals { if let n = x.integer { v[k == "color" ? "colorPreset" : k] = n } }
            let model = setup.gear.indices.contains(d["monitor"]?.integer ?? -1) ? setup.gear[d["monitor"]!.integer!].model : ""
            display = DisplayPresetRequest(name: setup.title, model: model, values: v)
        }
    }

    // MARK: A part on its own

    static func presets(part: String, lines: [SetupLine], sections: [String: J], display: DisplayPresetRequest?) -> [TakenPreset] {
        func has(_ f: (LineKind) -> Bool) -> Bool { lines.contains { f($0.kind) } }
        var out: [TakenPreset] = []
        func add(_ key: String, _ title: String, _ v: J?) { if let v { out.append(TakenPreset(key: key, title: title, data: v.encoded())) } }
        let au = sections["audio"]
        switch part {
        case "audio":
            if has({ $0 == .equalizerCurve }) { add("audio.eq", "Equalizer", au?["eq"]?["defaultProfile"]) }
            if has({ $0 == .outputEffects || $0 == .outputPlugins }) {
                add("audio.outputfx", "Output effects", .object(["dynamics": au?["eq"]?["dynamics"] ?? .object([:]), "plugins": au?["eq"]?["plugins"] ?? .array([])]))
            }
            if has({ if case .keepAwake = $0 { return true }; return $0 == .keepInput }) {
                add("audio.routing", "Input and keep-awake", .object(["inputPin": au?["inputPin"] ?? .object([:]), "keepAlive": au?["keepAlive"] ?? .object([:])]))
            }
        case "microphone":
            if !lines.isEmpty, let m = au?["mic"] {
                // Split into typed pieces: one big literal of `??` expressions is too slow for the compiler to type-check.
                let gain: J = m["gainDB"] ?? .number(0)
                let highPassOn: J = m["highPassEnabled"] ?? .bool(true)
                let highPassHz: J = m["highPassHz"] ?? .number(80)
                let eq: J = m["eq"] ?? curve(nil)
                let gate: J = m["gate"] ?? .object([:])
                let comp: J = m["compressor"] ?? compressor(nil)
                let plugins: J = m["plugins"] ?? .array([])
                var chain: [String: J] = [:]
                chain["gainDB"] = gain
                chain["highPassEnabled"] = highPassOn
                chain["highPassHz"] = highPassHz
                chain["eq"] = eq
                chain["gate"] = gate
                chain["compressor"] = comp
                chain["plugins"] = plugins
                add("audio.mic", "Microphone chain", .object(chain))
            }
        case "windows": if !lines.isEmpty { add("windows", "Windows", sections["windows"]) }
        case "keys": if !lines.isEmpty { add("input", "Keys and mouse rules", sections["input"]) }
        case "clipboard": if !lines.isEmpty { add("clipboard", "Clipboard", sections["clipboard"]) }
        case "display":
            if let d = display { add("display", "Display preset", .object(["preset": .string(d.name)])) }
        default: break
        }
        return out
    }
}

// MARK: - Small JSON edits

extension JSONValue {
    /// A copy with the value at `path` set, making objects on the way.
    fileprivate func setting(_ path: [String], _ value: JSONValue) -> JSONValue {
        guard let first = path.first else { return value }
        var o = object ?? [:]
        o[first] = (o[first] ?? .object([:])).setting(Array(path.dropFirst()), value)
        return .object(o)
    }

    fileprivate func removing(_ path: [String]) -> JSONValue {
        guard let first = path.first, var o = object else { return self }
        if path.count == 1 { o[first] = nil } else if let c = o[first] { o[first] = c.removing(Array(path.dropFirst())) }
        return .object(o)
    }
}
