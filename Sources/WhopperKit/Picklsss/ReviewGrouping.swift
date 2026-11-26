import Foundation

/// The lines of a shared setup, put in the order a person reads them: what goes on now first, then what stays off, folded under
/// the one reason it stays off. Pure data: the screens only draw what this returns. Nothing here decides what a line does or whether
/// it can go on; that stays with `SharedSetupFit`.
public struct ReviewGrouping: Equatable, Sendable {

    /// A line that can go on (it may have been switched off by the person; then `isOn` is false and it keeps its switch).
    public struct Item: Equatable, Identifiable, Sendable {
        public var id: String
        public var part: String
        public var title: String
        /// A note the line carries today ("The output limiter is switched on and stays on.").
        public var note: String?
        public var isOn: Bool
    }

    /// One part's lines among those that can go on.
    public struct PartBlock: Equatable, Identifiable, Sendable {
        public var part: String
        public var items: [Item]
        public var id: String { part }
        public var onCount: Int { items.filter(\.isOn).count }
        /// A switch for the whole part, only when it has two lines or more.
        public var showsSwitch: Bool { items.count >= 2 }
        /// Reads "on" when any of its lines is on.
        public var switchOn: Bool { items.contains(where: \.isOn) }
        /// What the part switch changes when pressed: all on when it reads off, all off when it reads on.
        public var switchTurnsOn: Bool { !switchOn }
        public var lineIDs: [String] { items.map(\.id) }
    }

    public enum StayKind: Equatable, Sendable { case gear, plugin, other }

    public struct StayLine: Equatable, Identifiable, Sendable {
        public var id: String
        public var part: String
        public var title: String
    }

    /// Lines that stay off for one reason.
    public struct StayGroup: Equatable, Identifiable, Sendable {
        public var id: String
        /// The reason, as a title: "No Edifier R1280 speakers connected".
        public var title: String
        public var kind: StayKind
        public var lines: [StayLine]
        /// The plugins this group waits for, so the screen can offer "Where to get …". Empty unless `kind == .plugin`.
        public var pluginNames: [String]
        /// Shown at the end of the opened group.
        public var footnote: String?
        /// A line's part is named after its name only when the group mixes parts.
        public var showsParts: Bool { Set(lines.map(\.part)).count > 1 }
        public var countText: String { lines.count == 1 ? "1 line" : "\(lines.count) lines" }
    }

    /// What a "Goes on now" section holds, and how it is laid out.
    public let goesOn: [Item]
    /// More than three lines go on: they are grouped under one heading per part.
    public let isGrouped: Bool
    /// The parts of `goesOn`, in the setup's order. Used when `isGrouped`.
    public let blocks: [PartBlock]
    public let stays: [StayGroup]
    /// Lines the setup holds in all.
    public let lineCount: Int

    /// Switched on of those that can go on: "2 of 2".
    public var onCount: Int { goesOn.filter(\.isOn).count }
    public var canGoOnCount: Int { goesOn.count }
    public var stayCount: Int { stays.reduce(0) { $0 + $1.lines.count } }
    /// No line can go on (every one waits for gear, a plugin or something else this Mac lacks).
    public var nothingCanGoOn: Bool { lineCount > 0 && goesOn.isEmpty }
    /// Lines the person switched off themselves.
    public var switchedOffByPerson: [Item] { goesOn.filter { !$0.isOn } }
    public var onNow: [Item] { goesOn.filter(\.isOn) }

    /// "On now" on the done page: the lines that went on, by part.
    public var onNowByPart: [PartBlock] {
        blocks.compactMap { b in
            let on = b.items.filter(\.isOn)
            return on.isEmpty ? nil : PartBlock(part: b.part, items: on)
        }
    }

    public var goesOnCountText: String { "\(onCount) of \(canGoOnCount)" }
    public var stayCountText: String { stayCount == 1 ? "1 line" : "\(stayCount) lines" }

    /// The one sentence at the top. Nil when the setup has no lines at all.
    public var summary: String? {
        guard lineCount > 0 else { return nil }
        if goesOn.isEmpty {
            return "Nothing goes on yet. Every line needs gear or a plugin this Mac does not have. You can keep the setup, and switch its lines on when you have them."
        }
        let on = onCount == 1 ? "1 thing goes on now." : "\(onCount) things go on now."
        let rest = stayCount == 0 ? "Nothing is left out." : stayCount == 1 ? "1 stays off until this Mac has the gear or plugins." : "\(stayCount) stay off until this Mac has the gear or plugins."
        return "\(on) \(rest)"
    }

    // MARK: Building it

    /// `gear` is the setup's own gear list, so a missing device can be named by its model and role.
    public init(lines: [ReviewLine], gear: [SharedGear]) {
        lineCount = lines.count
        var go: [Item] = []
        var groups: [StayGroup] = []
        for l in lines {
            if !l.isOff || l.cause == .person {
                go.append(Item(id: l.id, part: l.part, title: l.title, note: l.note, isOn: !l.isOff))
                continue
            }
            let (key, title, kind, plugins) = Self.reason(of: l, gear: gear)
            let line = StayLine(id: l.id, part: l.part, title: l.title)
            if let i = groups.firstIndex(where: { $0.id == key }) { groups[i].lines.append(line); continue }
            let foot: String? = kind == .gear ? "Switch these on from the recipe once it is connected." : kind == .plugin ? "Whoprrr never installs plugins." : nil
            groups.append(StayGroup(id: key, title: title, kind: kind, lines: [line], pluginNames: plugins, footnote: foot))
        }
        goesOn = go
        stays = groups
        isGrouped = go.count > 3
        var order: [String] = [], by: [String: [Item]] = [:]
        for i in go { if by[i.part] == nil { order.append(i.part) }; by[i.part, default: []].append(i) }
        blocks = order.map { PartBlock(part: $0, items: by[$0] ?? []) }
    }

    public init(plan: FitPlan, gear: [SharedGear]) { self.init(lines: plan.lines.map(ReviewLine.init), gear: gear) }

    private static func reason(of l: ReviewLine, gear: [SharedGear]) -> (key: String, title: String, kind: StayKind, plugins: [String]) {
        switch l.cause {
        case .gearMissing(let i)?:
            let t = gearTitle(i < gear.count && i >= 0 ? gear[i] : nil)
            return ("gear:" + t, t, .gear, [])
        case .pluginsMissing(let names)? where !names.isEmpty:
            let t = pluginTitle(names)
            return ("plugin:" + t, t, .plugin, names)
        default:
            let r = l.offReason ?? ""
            return ("reason:" + r, r, .other, [])
        }
    }

    /// "No Edifier R1280 speakers connected", "No Shure MV7 microphone connected", "No S34CG50 monitor connected".
    public static func gearTitle(_ g: SharedGear?) -> String {
        guard let g else { return "No matching gear connected" }
        let noun: String
        switch g.role {
        case "speaker": noun = "speakers"
        case "display": noun = "monitor"
        default: noun = g.role.isEmpty ? "device" : g.role
        }
        return "No \(g.model) \(noun) connected"
    }

    /// "The plugin Pro-Q 3 is not installed", "The plugins Pro-Q 3 and De-esser are not installed".
    public static func pluginTitle(_ names: [String]) -> String {
        names.count == 1 ? "The plugin \(names[0]) is not installed" : "The plugins \(list(names)) are not installed"
    }

    /// "A", "A and B", "A, B and C".
    public static func list(_ xs: [String]) -> String {
        switch xs.count {
        case 0: return ""
        case 1: return xs[0]
        default: return xs.dropLast().joined(separator: ", ") + " and " + xs.last!
        }
    }
}

/// A line as the grouping reads it. Made from a fit plan's line.
public struct ReviewLine: Equatable, Identifiable, Sendable {
    public var id: String
    public var part: String
    public var title: String
    public var note: String?
    /// Set when the line is off, in plain words.
    public var offReason: String?
    public var cause: OffCause?
    public var isOff: Bool { offReason != nil }

    public init(id: String, part: String, title: String, note: String? = nil, offReason: String? = nil, cause: OffCause? = nil) {
        self.id = id; self.part = part; self.title = title; self.note = note; self.offReason = offReason; self.cause = cause
    }

    public init(_ l: SetupLine) {
        id = l.id; part = l.part; title = l.title; cause = l.cause
        switch l.state {
        case .applies: note = nil; offReason = nil
        case .appliesWithNote(let n): note = n; offReason = nil
        case .off(let r): note = nil; offReason = r
        }
    }
}

/// "Before you start", cut down: only what is wrong stays a block; what is fine becomes one quiet sentence.
public struct ReviewRequirements: Equatable, Sendable {
    /// Rows that are not ready and are not a plugin already named under "Stays off for now". Shown above the lists, as today.
    public var blocking: [RequirementRow]
    /// "This Mac is ready for the rest: macOS 14.2 or newer, Accessibility and Microphone are allowed. Whoprrr will ask for System Audio Recording when it is needed."
    public var sentence: String?

    public init(rows: [RequirementRow], stays: [ReviewGrouping.StayGroup]) {
        let named = Set(stays.flatMap(\.pluginNames).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        blocking = rows.filter { r in
            guard r.status == .missing else { return false }
            if r.kind == .plugin, let n = r.pluginName, named.contains(n.trimmingCharacters(in: .whitespaces).lowercased()) { return false }
            return true
        }
        func subjects(_ kind: RequirementRow.Kind, _ status: RequirementRow.Status) -> [String] { rows.filter { $0.kind == kind && $0.status == status }.map(\.subject) }
        var ready: [String] = subjects(.macOS, .ready)
        let perms = subjects(.permission, .ready)
        if !perms.isEmpty { ready.append(ReviewGrouping.list(perms) + (perms.count == 1 ? " is allowed" : " are allowed")) }
        let plugins = subjects(.plugin, .ready)
        if !plugins.isEmpty { ready.append(ReviewGrouping.list(plugins) + (plugins.count == 1 ? " is installed" : " are installed")) }
        var parts: [String] = []
        if !ready.isEmpty { parts.append("This Mac is ready for the rest: " + ready.joined(separator: ", ") + ".") }
        let ask = subjects(.permission, .ask)
        if !ask.isEmpty { parts.append("Whoprrr will ask for \(ReviewGrouping.list(ask)) when it is needed.") }
        sentence = parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
