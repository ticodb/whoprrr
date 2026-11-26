import Foundation

// How a shared setup fits this Mac: for a card on the shelf (author's gear against yours), and for each line once it is opened.
// All of it is worked out here, on the Mac. The shelf is never told what gear this Mac has: ranking "for your gear" is local.

public enum ShelfRanking {
    /// How one of the author's devices stands against this Mac's gear.
    public enum GearFit: Equatable, Sendable { case have, sameKind, missing }

    public struct Summary: Equatable, Sendable {
        public var matched: Int
        public var sameKind: Int
        public var total: Int
        public var perItem: [GearFit]

        /// "Fits 2 of 4", "Fits all 2", "Same kind of gear", "Not for your gear", "Not tied to gear".
        public var label: String {
            if total == 0 { return "Not tied to gear" }
            if matched == total { return total == 1 ? "Fits your gear" : "Fits all \(total)" }
            if matched > 0 { return "Fits \(matched) of \(total)" }
            if sameKind > 0 { return "Same kind of gear" }
            return "Not for your gear"
        }

        public enum Tone: Equatable, Sendable { case good, maybe, none }
        public var tone: Tone { total == 0 || matched > 0 ? .good : sameKind > 0 ? .maybe : .none }

        /// Fits nothing the person has, so it goes greyed at the bottom of "For your gear".
        public var fitsNothing: Bool { total > 0 && matched == 0 && sameKind == 0 }
    }

    /// "speakers" and "monitor" are the shelf's examples; the Mac writes "speaker" and "display". Both mean the same.
    public static func normalizedRole(_ r: String) -> String {
        let s = r.trimmingCharacters(in: .whitespaces).lowercased()
        switch s {
        case "speakers", "speaker", "headphones", "output": return "speaker"
        case "monitor", "monitors", "screen", "display", "displays": return "display"
        case "microphone", "mic", "microphones": return "microphone"
        case "mice", "mouse": return "mouse"
        case "keyboard", "keyboards": return "keyboard"
        default: return s
        }
    }

    static func same(_ a: String, _ b: String) -> Bool { a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame }

    public static func summary(_ card: ShelfCard, gear mine: [DeviceSignature]) -> Summary {
        let fits = card.gear.map { g -> GearFit in
            if mine.contains(where: { same($0.model, g.model) }) { return .have }
            if mine.contains(where: { normalizedRole($0.role.rawValue) == normalizedRole(g.role) }) { return .sameKind }
            return .missing
        }
        return Summary(matched: fits.filter { $0 == .have }.count, sameKind: fits.filter { $0 == .sameKind }.count, total: fits.count, perItem: fits)
    }

    public struct Ranked: Equatable, Sendable, Identifiable {
        public var card: ShelfCard
        public var summary: Summary
        public var id: String { card.id }
    }

    /// "For your gear": most of your gear first, then the same kind of gear, then the rest of the keeps order the shelf gave.
    /// Setups that fit none of it are not hidden: they come last, and the screen greys them.
    public static func forYourGear(_ cards: [ShelfCard], gear: [DeviceSignature]) -> (fitting: [Ranked], others: [Ranked]) {
        let all = cards.map { Ranked(card: $0, summary: summary($0, gear: gear)) }
        let indexed = all.enumerated().sorted { a, b in
            let (x, y) = (a.element.summary, b.element.summary)
            if x.matched != y.matched { return x.matched > y.matched }
            if x.sameKind != y.sameKind { return x.sameKind > y.sameKind }
            return a.offset < b.offset
        }.map(\.element)
        return (indexed.filter { !$0.summary.fitsNothing }, indexed.filter { $0.summary.fitsNothing })
    }

    /// Popular and New keep the shelf's own order; each card still says how it fits.
    public static func inShelfOrder(_ cards: [ShelfCard], gear: [DeviceSignature]) -> [Ranked] { cards.map { Ranked(card: $0, summary: summary($0, gear: gear)) } }
}

/// The fit label of one line of an opened setup, judged against this Mac's gear (not the author's). The words are the gear scan's.
public enum TakeFit {
    public static func fit(of line: SetupLine, in plan: FitPlan) -> Fit {
        if line.state.isOff { return .unavailable }
        let roles: [String]
        var gearIndex: Int?
        switch line.kind {
        case .speakerCurve(let g), .keepAwake(let g): gearIndex = g; roles = []
        case .microphoneChain, .microphonePlugins, .keepInput: roles = ["microphone"]
        case .keysLogitech, .keysMappings: roles = ["mouse", "keyboard", "other"]
        case .display: roles = ["display"]
        case .equalizerCurve: roles = ["speaker"]
        case .outputEffects, .outputPlugins, .windows, .keysSettings, .keysRules, .clipboard: roles = []
        }
        var relevant: [GearMatch] = []
        if let g = gearIndex { relevant = plan.matches.filter { $0.authorIndex == g } }
        else if !roles.isEmpty { relevant = plan.matches.filter { roles.contains(ShelfRanking.normalizedRole($0.author.role)) } }
        // Lines that do not depend on a piece of gear (windows, clipboard, key rules) are the app's own features: tested.
        if relevant.isEmpty { return line.state == .applies || roles.isEmpty ? .tested : .untested }
        let used = relevant.compactMap(\.receiver)
        if let hit = relevant.first(where: { $0.quality == .exactModel }), let r = hit.receiver, KnownGear.isTested(r.model) { return .tested }
        if used.contains(where: { KnownGear.isTested($0.model) }) && relevant.contains(where: { $0.quality == .exactModel }) { return .tested }
        return .untested
    }
}

/// What a line would change on this Mac, worked out by fitting only that line and comparing the settings before and after.
public struct LineChange: Equatable, Sendable {
    public var lineID: String
    public var changed: Int
    /// A few "what: before → after" sentences, never more than `limit`.
    public var examples: [String]
    public var more: Int { max(0, changed - examples.count) }
    public var isNoChange: Bool { changed == 0 }
}

public enum SetupDiff {
    public static let limit = 4

    /// A change per line of the plan that is switched on.
    public static func lineChanges(setup: SharedSetup, plan: FitPlan, env: ReceiverEnvironment) -> [String: LineChange] {
        var out: [String: LineChange] = [:]
        for line in plan.lines where !line.state.isOff {
            var only = plan
            only.lines = plan.lines.map { l in var l = l; if l.id != line.id { l.state = .off("") }; return l }
            let fitted = SharedSetupFit.fit(setup, plan: only, for: env)
            out[line.id] = change(line: line, before: env.sections, after: fitted.recipe.sections)
        }
        return out
    }

    static func change(line: SetupLine, before: [String: Data], after: [String: Data]) -> LineChange {
        var changed: [String] = [], added: [String] = []
        for key in Set(after.keys).sorted() {
            let a = JSONValue.parse(after[key] ?? Data()) ?? .null
            let b = before[key].flatMap { JSONValue.parse($0) } ?? .null
            var x: [String: String] = [:], y: [String: String] = [:]
            flatten(a, "", &x); flatten(b, "", &y)
            for p in x.keys.sorted() where x[p] != y[p] {
                // A value that was there and is now different reads best ("gap: 2 → 8"), so those come first.
                if let was = y[p] { changed.append("\(words(p)): \(was) → \(x[p] ?? "")") } else { added.append("\(words(p)): not set → \(x[p] ?? "")") }
            }
        }
        let all = changed + added
        return LineChange(lineID: line.id, changed: all.count, examples: Array(all.prefix(limit)))
    }

    static func flatten(_ v: JSONValue, _ path: String, _ out: inout [String: String]) {
        switch v {
        case .object(let o): for (k, x) in o { flatten(x, path.isEmpty ? k : "\(path).\(k)", &out) }
        case .array(let a): for (i, x) in a.enumerated() { flatten(x, "\(path)[\(i)]", &out) }
        case .null: if !path.isEmpty { out[path] = "none" }
        case .bool(let b): out[path] = b ? "on" : "off"
        case .number(let n): out[path] = n == n.rounded() && abs(n) < 1e9 ? String(Int(n)) : String(format: "%g", (n * 100).rounded() / 100)
        case .string(let s): out[path] = s
        }
    }

    /// "eq.defaultProfile.bands[3].gainDB" becomes "eq › default profile › bands 4 › gain DB".
    static func words(_ path: String) -> String {
        path.split(separator: ".").map { part -> String in
            var name = String(part), idx = ""
            if let b = name.firstIndex(of: "["), let n = Int(name[name.index(after: b)..<(name.lastIndex(of: "]") ?? name.endIndex)]) { idx = " \(n + 1)"; name = String(name[..<b]) }
            var s = ""
            for ch in name { if ch.isUppercase, !s.isEmpty, s.last?.isUppercase == false { s += " " }; s.append(ch) }
            return s.lowercased().replacingOccurrences(of: " db", with: " dB").replacingOccurrences(of: " hz", with: " Hz").replacingOccurrences(of: " ms", with: " ms") + idx
        }.joined(separator: " › ")
    }
}
