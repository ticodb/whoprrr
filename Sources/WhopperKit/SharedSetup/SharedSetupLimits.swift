import Foundation

/// The checks a shared setup has to pass. They run when sharing, on the server, and every time a setup or a file is opened,
/// and they are the same checks each time: this code walks the document as plain JSON (`JSONValue`), never as Swift types, so
/// the server can mirror it in JavaScript. The rules and their numbers are in `SharedSetupTable` and in
/// `docs/shared-setup-format.md`; the test vectors in `Tests/WhopperKitTests/Fixtures/shared-setup-vectors.json` pin them.
public enum SharedSetupLimits {
    public static func check(_ setup: SharedSetup) -> SharedSetupReport { check(value: setup.json) }

    /// Checks bytes as they arrived. Anything that is not a JSON object is refused.
    public static func check(json data: Data) -> SharedSetupReport {
        guard let v = JSONValue.parse(data), v.object != nil else {
            return SharedSetupReport(violations: [SharedSetupViolation(line: "", limit: "shape", message: "This is not a shared setup: it could not be read.", tampered: true)])
        }
        return check(value: v)
    }

    public static func check(value: JSONValue) -> SharedSetupReport {
        var c = Checker()
        c.run(value)
        return c.report()
    }
}

// MARK: - The walk

private typealias Span = SharedSetupTable.Span
private typealias T = SharedSetupTable

private struct Checker {
    var violations: [SharedSetupViolation] = []
    var unusual: [String] = []
    /// The gear roles by index, for checking that a part points at the right kind of device.
    var gearRoles: [String] = []
    var gearModels: [String] = []

    func report() -> SharedSetupReport {
        let sorted = violations.sorted { ($0.line, $0.limit, $0.message) < ($1.line, $1.limit, $1.message) }
        return SharedSetupReport(violations: sorted, unusual: unusual)
    }

    mutating func add(_ line: String, _ limit: String, _ message: String, tampered: Bool = false) {
        let v = SharedSetupViolation(line: line, limit: limit, message: message, tampered: tampered)
        if !violations.contains(v) { violations.append(v) }
    }

    // MARK: Words

    func num(_ x: Double) -> String {
        if x == x.rounded(), abs(x) < 1e12 { return String(Int(x)) }
        var s = String(format: "%.2f", x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
    func signed(_ x: Double) -> String { x > 0 ? "+" + num(x) : num(x) }
    func join(_ p: String, _ k: String) -> String { p.isEmpty ? k : p + "." + k }
    func idx(_ p: String, _ i: Int) -> String { "\(p)[\(i)]" }

    func bandName(_ hz: Double) -> String { hz < 250 ? "bass" : hz < 2000 ? "mids" : hz < 6000 ? "presence" : "treble" }

    // MARK: Typed reads (each reports a wrong shape as a hand-edit)

    mutating func fields(_ v: JSONValue?, _ path: String, required: [String], optional: [String] = [], what: String) -> [String: JSONValue]? {
        guard let o = v?.object else {
            add(path, "shape", "\(what) is missing or is not in the form Whoprrr writes.", tampered: true)
            return nil
        }
        for k in o.keys.sorted() where !required.contains(k) && !optional.contains(k) {
            add(join(path, k), "shape", "\(what) has a field called “\(k)”, which Whoprrr does not write, so it is not allowed.", tampered: true)
        }
        for k in required where o[k] == nil {
            add(join(path, k), "shape", "\(what) is missing “\(k)”.", tampered: true)
        }
        return o
    }

    /// A number inside the app's own range. Returns it even when out of range, so the safety limit can still speak about it.
    mutating func number(_ o: [String: JSONValue], _ key: String, _ path: String, _ span: Span, what: String, unit: String = "", whole: Bool = false) -> Double? {
        let p = join(path, key)
        guard let v = o[key] else { return nil }
        guard let x = v.number, x.isFinite else {
            add(p, "shape", "\(what) is not a number.", tampered: true); return nil
        }
        if whole, v.integer == nil {
            add(p, "shape", "\(what) must be a whole number (it is \(num(x))).", tampered: true); return nil
        }
        if !span.contains(x) {
            add(p, "range", "\(what) is \(num(x))\(unit.isEmpty ? "" : " " + unit), outside the \(num(span.lo)) to \(num(span.hi)) that Whoprrr itself allows. The setup was changed outside the app.", tampered: true)
        }
        return x
    }

    mutating func bool(_ o: [String: JSONValue], _ key: String, _ path: String, what: String) -> Bool? {
        guard let v = o[key] else { return nil }
        guard let b = v.bool else { add(join(path, key), "shape", "\(what) must be on or off.", tampered: true); return nil }
        return b
    }

    mutating func choice(_ o: [String: JSONValue], _ key: String, _ path: String, _ allowed: [String], what: String) -> String? {
        guard let v = o[key] else { return nil }
        guard let s = v.string, allowed.contains(s) else {
            add(join(path, key), "shape", "\(what) is not one Whoprrr writes.", tampered: true); return nil
        }
        return s
    }

    mutating func list(_ o: [String: JSONValue], _ key: String, _ path: String, max: Int, what: String) -> [JSONValue]? {
        guard let v = o[key] else { return nil }
        guard let a = v.array else { add(join(path, key), "shape", "\(what) must be a list.", tampered: true); return nil }
        if a.count > max { add(join(path, key), "range", "\(what) has \(a.count) items; the most Whoprrr writes is \(max).", tampered: true) }
        return a
    }

    mutating func names(_ o: [String: JSONValue], _ key: String, _ path: String, _ allowed: [String], max: Int, what: String, unique: Bool = true) -> [String]? {
        guard let a = list(o, key, path, max: max, what: what) else { return nil }
        var out: [String] = []
        for (i, x) in a.enumerated() {
            guard let s = x.string, allowed.contains(s) else { add(idx(join(path, key), i), "shape", "\(what) has an entry Whoprrr does not write.", tampered: true); continue }
            if unique, out.contains(s) { add(idx(join(path, key), i), "shape", "\(what) lists “\(s)” twice.", tampered: true); continue }
            out.append(s)
        }
        return out
    }

    /// A reference to an item of `gear`, which must be there and be the right kind of device.
    mutating func gearIndex(_ v: JSONValue, _ p: String, role: String, what: String) -> Int? {
        guard let i = v.integer else { add(p, "shape", "\(what) does not point at a piece of gear.", tampered: true); return nil }
        guard i >= 0, i < gearRoles.count else { add(p, "gear-ref", "\(what) points at gear number \(i + 1), but the setup lists \(gearRoles.count).", tampered: true); return nil }
        if gearRoles[i] != role { add(p, "gear-ref", "\(what) points at a \(gearRoles[i]) where a \(role) is expected.", tampered: true) }
        return i
    }

    mutating func gearRef(_ o: [String: JSONValue], _ key: String, _ path: String, role: String, what: String) -> Int? {
        guard let v = o[key] else { return nil }
        return gearIndex(v, join(path, key), role: role, what: what)
    }

    func deviceName(_ i: Int?) -> String { i.flatMap { gearModels.indices.contains($0) ? gearModels[$0] : nil } ?? "" }

    // MARK: Personal text

    /// Web addresses, file paths and Mac identifiers, in a text that should be a plain name.
    func looksPrivate(_ s: String, serials: Bool) -> String? {
        let l = s.lowercased()
        if l.contains("://") || l.contains("www.") || l.contains("mailto:") { return "a web address" }
        if s.hasPrefix("/") || s.hasPrefix("~") || s.contains("\\")
            || s.range(of: #"/(Users|Library|Volumes|private|var|System|Applications|tmp)/"#, options: .regularExpression) != nil { return "a file path" }
        if serials {
            if s.range(of: #"['’]s\s"#, options: .regularExpression) != nil { return "a person’s name" }
            if l.contains("serial") || l.contains("s/n") { return "a serial number" }
            if s.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, options: .regularExpression) != nil { return "an identifier of a device" }
            if s.contains(":") { return "an identifier of a device" }
            for tok in s.split(whereSeparator: { $0 == " " }) where tok.count >= 8 && tok.filter(\.isNumber).count >= 6 { return "a serial number" }
        }
        return nil
    }

    /// `personal` turns on the check for addresses, paths and identifiers. It is off for the title and the description, which the
    /// server looks at itself (an address there holds the setup for the owner instead of refusing it).
    mutating func text(_ o: [String: JSONValue], _ key: String, _ path: String, min: Int = 1, max: Int, what: String, personal: Bool = true, serials: Bool = false) -> String? {
        guard let v = o[key] else { return nil }
        let p = join(path, key)
        guard let s = v.string else { add(p, "shape", "\(what) must be text.", tampered: true); return nil }
        let n = s.utf16.count
        if n < min || n > max { add(p, "text-length", "\(what) must be \(min == max ? "\(max)" : "\(min) to \(max)") characters (it has \(n)).") }
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { add(p, "text-length", "\(what) cannot hold line breaks or control characters.") }
        if personal, let why = looksPrivate(s, serials: serials) {
            add(p, "no-personal-text", "\(what) holds \(why). Shared setups carry model names only: no addresses, paths, serial numbers or names of people.")
        }
        return s
    }

    // MARK: The document

    mutating func run(_ doc: JSONValue) {
        guard let top = doc.object else {
            add("", "shape", "This is not a shared setup: it could not be read.", tampered: true); return
        }
        if let v = top["formatVersion"], v.integer != T.formatVersion {
            let newer = (v.number ?? 0) > Double(T.formatVersion)
            add("formatVersion", "format", newer ? "This setup was made with a newer Whoprrr. Update Whoprrr to open it." : "This setup is in a format Whoprrr does not know.")
            return
        }
        guard let o = fields(doc, "", required: ["formatVersion", "title", "line", "parts", "gear", "requirements", "settings"], what: "The setup") else { return }
        if top["formatVersion"] == nil { return }

        _ = text(o, "title", "", max: T.titleMax, what: "The title", personal: false)
        _ = text(o, "line", "", max: T.lineMax, what: "The description", personal: false)

        let parts = names(o, "parts", "", T.parts, max: T.parts.count, what: "The list of parts") ?? []
        if let a = o["parts"]?.array, a.isEmpty { add("parts", "shape", "A setup must hold at least one part.", tampered: true) }
        if parts != T.parts.filter(parts.contains) { add("parts", "shape", "The parts are not listed in the order Whoprrr writes them.", tampered: true) }

        checkGear(o)
        checkRequirements(o)

        // Settings: exactly the parts that are listed.
        guard let s = o["settings"]?.object else { add("settings", "shape", "The settings are missing or not in the form Whoprrr writes.", tampered: true); return }
        for k in s.keys.sorted() {
            if !T.parts.contains(k) { add(join("settings", k), "shape", "“\(k)” is not a part Whoprrr knows, so it is not allowed. A newer format needs a newer version number.", tampered: true) }
            else if !parts.contains(k) { add(join("settings", k), "shape", "The settings hold “\(k)”, which the list of parts does not name.", tampered: true) }
        }
        for k in parts where s[k] == nil { add(join("settings", k), "shape", "The list of parts names “\(k)”, but its settings are missing.", tampered: true) }

        for k in T.parts {
            guard let v = s[k] else { continue }
            switch k {
            case "audio": audio(v, "settings.audio")
            case "microphone": microphone(v, "settings.microphone")
            case "windows": windows(v, "settings.windows")
            case "keys": keys(v, "settings.keys")
            case "clipboard": clipboard(v, "settings.clipboard")
            case "display": display(v, "settings.display")
            default: break
            }
        }

        let size = doc.encoded().count
        if size > T.maxBytes { add("", "size", "This setup is \(size / 1024) KB. The most a shared setup can be is \(T.maxBytes / 1024) KB.") }
    }

    // MARK: Gear and requirements

    mutating func checkGear(_ o: [String: JSONValue]) {
        guard let a = list(o, "gear", "", max: T.gearMax, what: "The gear list") else { return }
        for (i, g) in a.enumerated() {
            let p = idx("gear", i)
            guard let go = fields(g, p, required: ["role", "model"], what: "Gear item \(i + 1)") else { gearRoles.append(""); gearModels.append(""); continue }
            var role = "", model = ""
            if let r = go["role"]?.string {
                role = r
                if r.range(of: #"^[a-z]{1,30}\z"#, options: .regularExpression) == nil { add(join(p, "role"), "gear-role", "Gear item \(i + 1) has a role that is not a short lowercase word (up to \(T.gearRoleMax) letters).") }
            } else if go["role"] != nil { add(join(p, "role"), "shape", "Gear item \(i + 1) has a role that is not text.", tampered: true) }
            model = text(go, "model", p, max: T.gearModelMax, what: "The model of gear item \(i + 1)", serials: true) ?? ""
            gearRoles.append(role); gearModels.append(model)
        }
    }

    mutating func checkRequirements(_ o: [String: JSONValue]) {
        guard let r = fields(o["requirements"], "requirements", required: ["plugins", "minMacOS", "permissions"], what: "The requirements") else { return }
        if let a = list(r, "plugins", "requirements", max: T.pluginNamesMax, what: "The plugin list") {
            for (i, x) in a.enumerated() {
                guard let s = x.string else { add(idx("requirements.plugins", i), "shape", "A plugin name must be text.", tampered: true); continue }
                if s.utf16.count < 1 || s.utf16.count > T.pluginNameMax { add(idx("requirements.plugins", i), "text-length", "A plugin name must be 1 to \(T.pluginNameMax) characters.") }
                if let why = looksPrivate(s, serials: false) { add(idx("requirements.plugins", i), "no-personal-text", "A plugin name holds \(why). Plugins are named, never included.") }
            }
        }
        if let m = r["minMacOS"], !m.isNull {
            if let s = m.string, s.range(of: #"^[0-9]{1,2}(\.[0-9]{1,2})?\z"#, options: .regularExpression) != nil {} else {
                add("requirements.minMacOS", "shape", "The macOS version must look like 14 or 14.2, or be empty.", tampered: true)
            }
        }
        _ = names(r, "permissions", "requirements", T.permissions, max: T.permissionsMax, what: "The permission list")
    }

    // MARK: Audio

    mutating func audio(_ v: JSONValue, _ p: String) {
        guard let o = fields(v, p, required: ["equalizer", "effects", "keepAwake", "keepInput"], what: "The audio part") else { return }

        let ep = join(p, "equalizer")
        if let e = fields(o["equalizer"], ep, required: ["enabled", "curve", "speakerCurves"], what: "The equalizer") {
            _ = bool(e, "enabled", ep, what: "The equalizer switch")
            curve(e["curve"], join(ep, "curve"), ctx: "Equalizer", device: nil)
            if let a = list(e, "speakerCurves", ep, max: T.gearMax, what: "The per-speaker curves") {
                for (i, x) in a.enumerated() {
                    let ip = idx(join(ep, "speakerCurves"), i)
                    guard let c = fields(x, ip, required: ["gear", "curve"], what: "Speaker curve \(i + 1)") else { continue }
                    let g = gearRef(c, "gear", ip, role: "speaker", what: "Speaker curve \(i + 1)")
                    curve(c["curve"], join(ip, "curve"), ctx: "Equalizer" + (g.map { " (\(deviceName($0)))" } ?? ""), device: g)
                }
            }
        }

        let fp = join(p, "effects")
        if let f = fields(o["effects"], fp, required: ["compressor", "limiter", "plugins"], what: "The output effects") {
            compressor(f["compressor"], join(fp, "compressor"), ctx: "Output compressor")
            limiter(f["limiter"], join(fp, "limiter"))
            plugins(f, "plugins", fp, ctx: "Output effects")
        }

        let kp = join(p, "keepAwake")
        if let a = list(o, "keepAwake", p, max: T.gearMax, what: "The keep-awake list") {
            for (i, x) in a.enumerated() {
                let ip = idx(kp, i)
                guard let k = fields(x, ip, required: ["gear", "enabled", "levelDb", "frequencyHz", "pulseEverySeconds", "burstSeconds"], what: "Keep-awake item \(i + 1)") else { continue }
                let g = gearRef(k, "gear", ip, role: "speaker", what: "Keep-awake item \(i + 1)")
                let who = g.map { " for \(deviceName($0))" } ?? ""
                _ = bool(k, "enabled", ip, what: "The keep-awake switch")
                if let level = number(k, "levelDb", ip, T.keepAwakeLevelDB, what: "The keep-awake tone level", unit: "dBFS") {
                    if level > T.keepAwakeLevelMaxDB {
                        add(join(ip, "levelDb"), "keepawake-level", "Keep-awake tone\(who): \(num(level)) dBFS. Shared setups keep this tone at \(num(T.keepAwakeLevelMaxDB)) dBFS or quieter, so it is never something you hear.")
                    } else if level >= T.keepAwakeLevelMaxDB - T.unusualFraction * (T.keepAwakeLevelMaxDB - T.keepAwakeLevelDB.lo) {
                        unusual.append("Keep-awake tone\(who) is \(num(level)) dBFS, close to the \(num(T.keepAwakeLevelMaxDB)) dBFS limit.")
                    }
                }
                if let hz = number(k, "frequencyHz", ip, T.keepAwakeHz, what: "The keep-awake tone frequency", unit: "Hz"), !T.keepAwakeHz.contains(hz) {
                    add(join(ip, "frequencyHz"), "keepawake-frequency", "Keep-awake tone\(who): \(num(hz)) Hz. The tone must stay between \(num(T.keepAwakeHz.lo)) and \(num(T.keepAwakeHz.hi)) Hz.")
                }
                _ = number(k, "pulseEverySeconds", ip, T.keepAwakePulseSeconds, what: "The keep-awake pulse", unit: "s")
                _ = number(k, "burstSeconds", ip, T.keepAwakeBurstSeconds, what: "The keep-awake burst", unit: "s")
            }
        }

        let ip = join(p, "keepInput")
        if let k = fields(o["keepInput"], ip, required: ["enabled", "gear"], what: "The keep-this-microphone setting") {
            _ = bool(k, "enabled", ip, what: "The keep-this-microphone switch")
            if let a = list(k, "gear", ip, max: T.gearMax, what: "The preferred microphones") {
                for (i, x) in a.enumerated() { _ = gearIndex(x, idx(join(ip, "gear"), i), role: "microphone", what: "Preferred microphone \(i + 1)") }
            }
        }
    }

    /// One gain-like value: limited to +6 dB. Returns after speaking about it.
    mutating func boost(_ x: Double, _ path: String, ctx: String, what: String) {
        if x > T.maxBoostDB {
            add(path, "boost-6db", "\(ctx): \(what) \(signed(x)) dB. Shared setups cannot boost more than +\(num(T.maxBoostDB)) dB, so nobody’s speakers or ears are hurt.")
        } else if x >= T.maxBoostDB - T.unusualFraction * T.maxBoostDB {
            unusual.append("\(ctx): \(what) \(signed(x)) dB is close to the +\(num(T.maxBoostDB)) dB limit.")
        }
    }

    mutating func curve(_ v: JSONValue?, _ p: String, ctx: String, device: Int?) {
        guard let c = fields(v, p, required: ["enabled", "preampDb", "bands"], what: "\(ctx): the curve") else { return }
        _ = bool(c, "enabled", p, what: "The curve switch")
        var preamp: Double?
        if let x = number(c, "preampDb", p, T.preampDB, what: "\(ctx): the pre-amp", unit: "dB") { preamp = x; boost(x, join(p, "preampDb"), ctx: ctx, what: "pre-amp") }
        var biggest = 0.0
        if let a = list(c, "bands", p, max: T.bandsMax, what: "\(ctx): the bands") {
            for (i, b) in a.enumerated() {
                let bp = idx(join(p, "bands"), i)
                guard let bo = fields(b, bp, required: ["hz", "gainDb", "q", "kind"], what: "\(ctx): band \(i + 1)") else { continue }
                let hz = number(bo, "hz", bp, T.bandHz, what: "\(ctx): the frequency of band \(i + 1)", unit: "Hz")
                _ = number(bo, "q", bp, T.bandQ, what: "\(ctx): the width of band \(i + 1)")
                _ = choice(bo, "kind", bp, T.bandKinds, what: "\(ctx): the kind of band \(i + 1)")
                if let g = number(bo, "gainDb", bp, T.bandGainDB, what: "\(ctx): the gain of band \(i + 1)", unit: "dB") {
                    biggest = max(biggest, g)
                    let name = hz.map { "\(bandName($0)) \(signed(g)) dB at \(num($0)) Hz" } ?? "\(signed(g)) dB"
                    if g > T.maxBoostDB {
                        add(join(bp, "gainDb"), "boost-6db", "\(ctx): \(name). Shared setups cannot boost more than +\(num(T.maxBoostDB)) dB, so nobody’s speakers or ears are hurt.")
                    } else {
                        boost(g, join(bp, "gainDb"), ctx: ctx, what: "the \(name.replacingOccurrences(of: " at ", with: " at "))")
                    }
                }
            }
        }
        // The pre-amp and the biggest band act together on one curve (addition to the owner's list).
        if let pre = preamp, pre <= T.maxBoostDB, biggest <= T.maxBoostDB, pre + biggest > T.maxBoostDB {
            add(p, "boost-curve", "\(ctx): the pre-amp (\(signed(pre)) dB) and the biggest boost (\(signed(biggest)) dB) add up to \(signed(pre + biggest)) dB. Shared setups cannot boost more than +\(num(T.maxBoostDB)) dB in total on one curve.")
        }
    }

    mutating func compressor(_ v: JSONValue?, _ p: String, ctx: String) {
        guard let c = fields(v, p, required: ["enabled", "thresholdDb", "ratio", "attackMs", "releaseMs", "makeupDb"], what: "\(ctx)") else { return }
        _ = bool(c, "enabled", p, what: "\(ctx) switch")
        _ = number(c, "thresholdDb", p, T.compThresholdDB, what: "\(ctx) threshold", unit: "dB")
        _ = number(c, "ratio", p, T.compRatio, what: "\(ctx) ratio")
        _ = number(c, "attackMs", p, T.compAttackMs, what: "\(ctx) attack", unit: "ms")
        _ = number(c, "releaseMs", p, T.compReleaseMs, what: "\(ctx) release", unit: "ms")
        if let m = number(c, "makeupDb", p, T.compMakeupDB, what: "\(ctx) make-up gain", unit: "dB") { boost(m, join(p, "makeupDb"), ctx: ctx, what: "make-up gain") }
    }

    mutating func limiter(_ v: JSONValue?, _ p: String) {
        guard let l = fields(v, p, required: ["enabled", "ceilingDb", "releaseMs"], what: "The output limiter") else { return }
        if let on = bool(l, "enabled", p, what: "The limiter switch"), !on {
            add(join(p, "enabled"), "limiter-on", "The output limiter is switched off. It stays on in a shared setup, so a loud peak can never reach somebody’s speakers.", tampered: true)
        }
        if let c = number(l, "ceilingDb", p, T.limiterCeilingDB, what: "The limiter ceiling", unit: "dB"), c > T.limiterCeilingMaxDB {
            add(join(p, "ceilingDb"), "limiter-ceiling", "The limiter ceiling is \(num(c)) dB. A shared setup cannot raise it above \(num(T.limiterCeilingMaxDB)) dB.", tampered: true)
        }
        _ = number(l, "releaseMs", p, T.limiterReleaseMs, what: "The limiter release", unit: "ms")
    }

    /// A list of `{name, maker, enabled}`.
    mutating func plugins(_ o: [String: JSONValue], _ key: String, _ path: String, ctx: String) {
        guard let a = list(o, key, path, max: T.pluginsPerChainMax, what: "\(ctx): the plugins") else { return }
        for (i, x) in a.enumerated() {
            let ip = idx(join(path, key), i)
            guard let po = fields(x, ip, required: ["name", "maker", "enabled"], what: "\(ctx): plugin \(i + 1)") else { continue }
            _ = text(po, "name", ip, max: T.pluginNameMax, what: "The name of plugin \(i + 1)")
            _ = text(po, "maker", ip, min: 0, max: T.pluginNameMax, what: "The maker of plugin \(i + 1)")
            _ = bool(po, "enabled", ip, what: "The switch of plugin \(i + 1)")
        }
    }

    // MARK: Microphone

    mutating func microphone(_ v: JSONValue, _ p: String) {
        guard let o = fields(v, p, required: ["enabled", "source", "gainDb", "highPass", "equalizer", "gate", "compressor", "plugins"], what: "The microphone part") else { return }
        _ = bool(o, "enabled", p, what: "The microphone switch")
        if let s = o["source"], !s.isNull { _ = gearRef(o, "source", p, role: "microphone", what: "The microphone source") }
        if let g = number(o, "gainDb", p, T.micGainDB, what: "The microphone gain", unit: "dB") { boost(g, join(p, "gainDb"), ctx: "Microphone", what: "gain") }
        let hp = join(p, "highPass")
        if let h = fields(o["highPass"], hp, required: ["enabled", "hz"], what: "The rumble filter") {
            _ = bool(h, "enabled", hp, what: "The rumble filter switch")
            _ = number(h, "hz", hp, T.micHighPassHz, what: "The rumble filter frequency", unit: "Hz")
        }
        curve(o["equalizer"], join(p, "equalizer"), ctx: "Microphone equalizer", device: nil)
        let gp = join(p, "gate")
        if let g = fields(o["gate"], gp, required: ["enabled", "thresholdDb", "attackMs", "releaseMs"], what: "The noise gate") {
            _ = bool(g, "enabled", gp, what: "The noise gate switch")
            _ = number(g, "thresholdDb", gp, T.gateThresholdDB, what: "The noise gate threshold", unit: "dB")
            _ = number(g, "attackMs", gp, T.gateAttackMs, what: "The noise gate attack", unit: "ms")
            _ = number(g, "releaseMs", gp, T.gateReleaseMs, what: "The noise gate release", unit: "ms")
        }
        compressor(o["compressor"], join(p, "compressor"), ctx: "Microphone compressor")
        plugins(o, "plugins", p, ctx: "Microphone")
    }

    // MARK: Windows

    /// A global shortcut: needs a real modifier and cannot be emergency off.
    mutating func shortcut(key: Double?, mods: [String]?, _ path: String, what: String) {
        guard let k = key, let m = mods else { return }
        if Int(k) == T.emergencyKey, T.emergencyMods.allSatisfy(m.contains) {
            add(path, "shortcut-safe", "\(what) uses ⌃⌥⇧⌘⎋, which is reserved for Emergency off.", tampered: true)
        } else if !m.contains(where: T.shortcutNeedsOneOf.contains) {
            add(path, "shortcut-safe", "\(what) has no ⌘, ⌃ or ⌥ in it, so it would take over ordinary typing. A shared shortcut needs at least one of them.")
        }
    }

    mutating func windows(_ v: JSONValue, _ p: String) {
        guard let o = fields(v, p, required: ["shortcutsEnabled", "gapPoints", "cycleHalves", "snapByDrag", "drawer", "disabled", "shortcuts"], what: "The windows part") else { return }
        _ = bool(o, "shortcutsEnabled", p, what: "The shortcuts switch")
        _ = number(o, "gapPoints", p, T.windowGap, what: "The gap between windows", unit: "points")
        _ = bool(o, "cycleHalves", p, what: "The cycle-halves switch")
        _ = bool(o, "snapByDrag", p, what: "The snap-by-drag switch")
        if let d = o["drawer"], !d.isNull { _ = names(o, "drawer", p, T.windowActions, max: T.drawerMax, what: "The drawer layouts") }
        _ = names(o, "disabled", p, T.windowActions, max: T.windowActions.count, what: "The switched-off layouts")
        let sp = join(p, "shortcuts")
        if let a = list(o, "shortcuts", p, max: T.windowActions.count, what: "The window shortcuts") {
            var seen = Set<String>()
            for (i, x) in a.enumerated() {
                let ip = idx(sp, i)
                guard let s = fields(x, ip, required: ["action", "key", "modifiers"], what: "Window shortcut \(i + 1)") else { continue }
                if let act = choice(s, "action", ip, T.windowActions, what: "The layout of window shortcut \(i + 1)"), !seen.insert(act).inserted {
                    add(join(ip, "action"), "shape", "Two shortcuts are set for “\(act)”.", tampered: true)
                }
                let key = number(s, "key", ip, T.keyCode, what: "The key of window shortcut \(i + 1)", whole: true)
                let mods = names(s, "modifiers", ip, T.shortcutModifiers, max: 4, what: "The modifiers of window shortcut \(i + 1)")
                shortcut(key: key, mods: mods, ip, what: "Window shortcut \(i + 1)")
            }
        }
    }

    // MARK: Clipboard

    mutating func clipboard(_ v: JSONValue, _ p: String) {
        guard let o = fields(v, p, required: ["enabled", "hotkey", "maxItems", "maxAgeDays", "captureImages", "captureFiles", "maxImageMb", "maxTextKb", "autoPaste", "plainTextByDefault"],
                             optional: ["ignoredApps"], what: "The clipboard part") else { return }
        _ = bool(o, "enabled", p, what: "The clipboard switch")
        let hp = join(p, "hotkey")
        if let h = fields(o["hotkey"], hp, required: ["key", "modifiers"], what: "The clipboard shortcut") {
            let key = number(h, "key", hp, T.keyCode, what: "The clipboard shortcut key", whole: true)
            let mods = names(h, "modifiers", hp, T.shortcutModifiers, max: 4, what: "The clipboard shortcut modifiers")
            shortcut(key: key, mods: mods, hp, what: "The clipboard shortcut")
        }
        _ = number(o, "maxItems", p, T.clipboardItems, what: "The number of items kept", whole: true)
        _ = number(o, "maxAgeDays", p, T.clipboardDays, what: "The days items are kept", unit: "days", whole: true)
        _ = bool(o, "captureImages", p, what: "The images switch")
        _ = bool(o, "captureFiles", p, what: "The files switch")
        _ = number(o, "maxImageMb", p, T.clipboardImageMB, what: "The largest image kept", unit: "MB", whole: true)
        _ = number(o, "maxTextKb", p, T.clipboardTextKB, what: "The largest text kept", unit: "KB", whole: true)
        _ = bool(o, "autoPaste", p, what: "The paste-straight-in switch")
        _ = bool(o, "plainTextByDefault", p, what: "The plain-text switch")
        // The ignore list is never exported. If one arrives it may only add to the password-manager defaults.
        if o["ignoredApps"] != nil, let a = list(o, "ignoredApps", p, max: T.ignoredAppsMax, what: "The ignored apps") {
            var have = Set<String>()
            for (i, x) in a.enumerated() {
                guard let s = x.string, s.range(of: #"^[A-Za-z0-9][A-Za-z0-9.\-]{0,99}\z"#, options: .regularExpression) != nil else {
                    add(idx(join(p, "ignoredApps"), i), "shape", "An ignored app is not written as an app identifier.", tampered: true); continue
                }
                have.insert(s)
            }
            let missing = T.clipboardDefaultIgnored.filter { !have.contains($0) }
            if !missing.isEmpty {
                add(join(p, "ignoredApps"), "clipboard-ignore-list", "The clipboard ignore list leaves out \(missing.count) password manager\(missing.count == 1 ? "" : "s") that Whoprrr always ignores. A shared setup can add apps to the list, never remove one.", tampered: true)
            }
        }
    }

    // MARK: Keys and mouse

    mutating func keys(_ v: JSONValue, _ p: String) {
        guard let o = fields(v, p, required: ["enabled", "invertMouseWheel", "rules", "hid"], what: "The keys and mouse part") else { return }
        _ = bool(o, "enabled", p, what: "The keys and mouse switch")
        _ = bool(o, "invertMouseWheel", p, what: "The mouse wheel switch")
        if let hid = list(o, "hid", p, max: 8, what: "The key mappings") {
            for (i, x) in hid.enumerated() {
                let ip = idx(join(p, "hid"), i)
                guard let h = fields(x, ip, required: ["from", "to"], what: "Key mapping \(i + 1)") else { continue }
                let from = h["from"]?.string, to = h["to"]?.string
                if from == nil || to == nil { add(ip, "shape", "Key mapping \(i + 1) is not in the form Whoprrr writes.", tampered: true) }
                else if !T.hidFrom.contains(from!) || !T.hidTo.contains(to!) {
                    add(ip, "keys-hid", "Key mapping \(i + 1) changes “\(from!)” into “\(to!)”. Shared setups only make the mappings Whoprrr’s own presets make (Caps Lock or a right-hand ⌘ or ⌥ becoming F18 or F19); anything else could lock a keyboard.", tampered: true)
                }
            }
        }
        guard let rules = list(o, "rules", p, max: 500, what: "The rules") else { return }
        if rules.count > T.unusualKeyRules { unusual.append("It has \(rules.count) key and mouse rules (more than \(T.unusualKeyRules)).") }
        for (i, r) in rules.enumerated() { rule(r, idx(join(p, "rules"), i), n: i + 1) }
    }

    func modsOf(_ v: JSONValue?) -> [String]? { v?.array?.compactMap(\.string) }

    mutating func rule(_ v: JSONValue, _ p: String, n: Int) {
        let what = "Rule \(n)"
        guard let r = fields(v, p, required: ["enabled", "trigger", "mods", "anyExtraMods", "tap", "holdMs", "scope"],
                             optional: ["hold", "layer", "layouts", "keyboardTypes"], what: what) else { return }
        _ = bool(r, "enabled", p, what: "\(what) switch")
        _ = bool(r, "anyExtraMods", p, what: "\(what) extra-modifiers switch")
        _ = number(r, "holdMs", p, T.holdMs, what: "\(what) hold time", unit: "ms", whole: true)
        let mods = names(r, "mods", p, T.modifierNames, max: 5, what: "\(what) modifiers") ?? []
        var trigKind = "", trigCode = -1
        let tp = join(p, "trigger")
        if let t = r["trigger"]?.object {
            switch t["type"]?.string {
            case "key":
                if let to = fields(r["trigger"], tp, required: ["type", "code"], what: "\(what) trigger") { trigKind = "key"; trigCode = Int(number(to, "code", tp, T.keyCode, what: "\(what) key", whole: true) ?? -1) }
            case "mouse":
                if let to = fields(r["trigger"], tp, required: ["type", "button"], what: "\(what) trigger") { trigKind = "mouse"; trigCode = Int(number(to, "button", tp, T.mouseButton, what: "\(what) mouse button", whole: true) ?? -1) }
            case "logi":
                if let to = fields(r["trigger"], tp, required: ["type", "control"], what: "\(what) trigger") { trigKind = "logi"; trigCode = Int(number(to, "control", tp, T.logiControl, what: "\(what) Logitech control", whole: true) ?? -1) }
            default: add(tp, "shape", "\(what) trigger is not one Whoprrr writes.", tampered: true)
            }
        } else { add(tp, "shape", "\(what) trigger is missing.", tampered: true) }

        let tapNothing = output(r["tap"], join(p, "tap"), what: "\(what) action")
        var holdNothing = false
        if r["hold"] != nil { holdNothing = output(r["hold"], join(p, "hold"), what: "\(what) hold action") }

        if let s = r["scope"] {
            let sp = join(p, "scope")
            if let so = fields(s, sp, required: ["mode", "apps"], what: "\(what) scope") {
                _ = choice(so, "mode", sp, T.scopeModes, what: "\(what) scope mode")
                if let a = list(so, "apps", sp, max: 50, what: "\(what) apps") {
                    for (i, x) in a.enumerated() where x.string?.range(of: #"^[A-Za-z0-9][A-Za-z0-9.\-]{0,99}\z"#, options: .regularExpression) == nil {
                        add(idx(join(sp, "apps"), i), "shape", "\(what) names an app in a form Whoprrr does not write.", tampered: true)
                    }
                }
            }
        }
        if let l = r["layer"] {
            if let s = l.string, s.range(of: #"^[A-Za-z0-9 _\-]{1,24}\z"#, options: .regularExpression) != nil {} else {
                add(join(p, "layer"), "layer-name", "\(what) uses a layer name that is not 1 to 24 letters, digits, spaces, dashes or underscores.")
            }
        }
        if r["layouts"] != nil { _ = names(r, "layouts", p, T.layouts, max: 3, what: "\(what) keyboard layouts") }
        if let a = list(r, "keyboardTypes", p, max: 8, what: "\(what) keyboard types") {
            for (i, x) in a.enumerated() {
                if let n = x.integer, T.keyboardType.contains(Double(n)) {} else { add(idx(join(p, "keyboardTypes"), i), "range", "\(what) has a keyboard type outside 0 to 255.", tampered: true) }
            }
        }

        // The safety rules.
        if trigKind == "key", trigCode == T.emergencyKey, T.emergencyMods.allSatisfy(mods.contains) {
            add(tp, "keys-emergency-off", "\(what) uses ⌃⌥⇧⌘⎋, which is Emergency off. Emergency off can never be remapped or switched off.", tampered: true)
        }
        if trigKind == "key", T.protectedKeys.contains(trigCode), mods.isEmpty, tapNothing || holdNothing {
            add(tp, "keys-protected-key", "\(what) makes a key do nothing: Return, Space, Escape, Tab, Delete and the arrow keys must always work.")
        }
        if trigKind == "mouse", trigCode == T.primaryMouseButton {
            add(tp, "keys-primary-click", "\(what) takes over the main mouse click. A shared setup cannot do that, or nobody could click it back.")
        }
    }

    /// Checks an action. Returns true when it does nothing at all.
    mutating func output(_ v: JSONValue?, _ p: String, what: String) -> Bool {
        guard let o = v?.object else { add(p, "shape", "\(what) is missing.", tampered: true); return false }
        switch o["type"]?.string {
        case "chord":
            if let c = fields(v, p, required: ["type", "key", "mods"], what: what) {
                _ = number(c, "key", p, T.keyCode, what: "\(what) key", whole: true)
                _ = names(c, "mods", p, T.modifierNames, max: 5, what: "\(what) modifiers")
            }
        case "modifiers":
            if let c = fields(v, p, required: ["type", "mods"], what: what) { _ = names(c, "mods", p, T.modifierNames, max: 5, what: "\(what) modifiers") }
        case "layer":
            if let c = fields(v, p, required: ["type", "name"], what: what) {
                if let s = c["name"]?.string, s.range(of: #"^[A-Za-z0-9 _\-]{1,24}\z"#, options: .regularExpression) != nil {} else {
                    add(join(p, "name"), "layer-name", "\(what) uses a layer name that is not 1 to 24 letters, digits, spaces, dashes or underscores.")
                }
            }
        case "media":
            if let c = fields(v, p, required: ["type", "key"], what: what) { _ = choice(c, "key", p, T.mediaKeys, what: "\(what) media key") }
        case "mouseButton":
            if let c = fields(v, p, required: ["type", "button"], what: what) { _ = number(c, "button", p, T.mouseButton, what: "\(what) mouse button", whole: true) }
        case "command":
            if let c = fields(v, p, required: ["type", "id"], what: what) {
                if let s = c["id"]?.string, T.commands.contains(s) {} else {
                    add(join(p, "id"), "keys-command", "\(what) runs a command (“\(c["id"]?.string ?? "?")”) that a shared setup may not run. Only Whoprrr’s own window, clipboard, navigation and Mission Control actions are allowed.", tampered: true)
                }
            }
        case "sequence":
            if let c = fields(v, p, required: ["type", "chords"], what: what), let a = list(c, "chords", p, max: T.sequenceMax, what: "\(what) key sequence") {
                for (i, x) in a.enumerated() {
                    let ip = idx(join(p, "chords"), i)
                    if let ch = fields(x, ip, required: ["key", "mods"], what: "\(what) step \(i + 1)") {
                        _ = number(ch, "key", ip, T.keyCode, what: "\(what) step \(i + 1) key", whole: true)
                        _ = names(ch, "mods", ip, T.modifierNames, max: 5, what: "\(what) step \(i + 1) modifiers")
                    }
                }
                return a.isEmpty
            }
        case "nothing":
            _ = fields(v, p, required: ["type"], what: what)
            return true
        case "text", "openURL", "openApp", "shell":
            add(p, "keys-no-run", "\(what) would \(o["type"]?.string == "text" ? "type text" : o["type"]?.string == "openURL" ? "open a web address" : o["type"]?.string == "openApp" ? "open an app" : "run a command"). A shared setup cannot type text, open addresses, launch apps or run commands.", tampered: true)
        default:
            add(p, "shape", "\(what) is not one Whoprrr writes.", tampered: true)
        }
        return false
    }

    // MARK: Display

    mutating func display(_ v: JSONValue, _ p: String) {
        unusual.append("It changes monitor settings.")
        guard let o = fields(v, p, required: ["monitor", "values"], what: "The display part") else { return }
        _ = gearRef(o, "monitor", p, role: "display", what: "The monitor")
        let vp = join(p, "values")
        guard let vals = o["values"]?.object else { add(vp, "shape", "The display values are missing.", tampered: true); return }
        if vals.isEmpty { add(vp, "shape", "The display part holds no values.", tampered: true) }
        for k in vals.keys.sorted() {
            guard T.displayControls.contains(k) else {
                add(join(vp, k), "display-codes", "Display: “\(k)” cannot be shared. Shared setups carry only brightness, contrast, color and sharpness: never input switching, manufacturer codes or codes learned by scanning.", tampered: true)
                continue
            }
            _ = number(vals, k, vp, T.displayRange(k)!, what: "The \(k)", whole: true)
        }
    }
}
