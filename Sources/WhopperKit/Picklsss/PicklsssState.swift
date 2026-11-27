import Foundation

// What this Mac remembers about the shelf: what it took (and how the person answered "count what you keep?"), what it shared,
// the notices it has not shown yet. One small file, `picklsss.json`, in the data folder. No key, no pass, no serial numbers.

public enum CountChoice: String, Codable, Equatable, Sendable {
    /// Not asked yet: the first take asks.
    case unasked, yes, no
    public var counted: Bool { self == .yes }
}

/// A shared setup this Mac took, as a recipe of the person's own. The take token is the only credential for the day-7 answer.
public struct TakeRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { picklsssId }
    public var picklsssId: String
    public var title: String
    /// The cook, for "from lucia.r in Picklsss".
    public var handle: String
    public var version: Int
    /// The recipe the take became. Nil for a part taken on its own (it landed in the presets).
    public var recipeID: UUID?
    public var takenAt: Date
    public var counted: Bool
    /// Present only for a counted take, until the answer is given or the window passes.
    public var takeToken: String?
    public var askFrom: Date?
    public var askUntil: Date?
    /// Local calendar days (yyyy-MM-dd) on which the taken setup was the active recipe. Kept only for taken setups, and never sent.
    public var activeDays: [String]
    /// The day-7 result, worked out once and kept so a later change cannot flip it.
    public var verdict: Bool?
    public var answered: Bool
    /// The settings of the parts this take changed, as they were just before, so "Put back" can restore them.
    public var before: [String: Data]
    /// The names of those parts ("Audio"), for the words around "Put back".
    public var beforeParts: [String]

    public init(picklsssId: String, title: String, handle: String, version: Int = 1, recipeID: UUID?, takenAt: Date, counted: Bool,
                takeToken: String? = nil, askFrom: Date? = nil, askUntil: Date? = nil, before: [String: Data] = [:], beforeParts: [String] = []) {
        self.picklsssId = picklsssId; self.title = title; self.handle = handle; self.version = version; self.recipeID = recipeID
        self.takenAt = takenAt; self.counted = counted; self.takeToken = takeToken; self.askFrom = askFrom; self.askUntil = askUntil
        self.activeDays = []; self.verdict = nil; self.answered = false; self.before = before; self.beforeParts = beforeParts
    }
}

/// One of the person's own recipes that they shared.
public struct SharedRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { picklsssId }
    public var picklsssId: String
    public var recipeID: UUID?
    public var title: String
    public var state: String
    public var version: Int
    /// The parts that were switched on when it was shared, so an update sends the same ones.
    public var parts: [String]
    /// A fingerprint of the document that was last sent, to tell whether the recipe has moved on since.
    public var digest: String
    public var sharedAt: Date
    public var includesTypingLanguage: Bool?

    public init(picklsssId: String, recipeID: UUID?, title: String, state: String, version: Int, parts: [String], digest: String, sharedAt: Date,
                includesTypingLanguage: Bool? = nil) {
        self.picklsssId = picklsssId; self.recipeID = recipeID; self.title = title; self.state = state; self.version = version
        self.parts = parts; self.digest = digest; self.sharedAt = sharedAt
        self.includesTypingLanguage = includesTypingLanguage
    }
    public var isPublic: Bool { state == ShelfState.public.rawValue }
}

public struct StoredNotice: Codable, Equatable, Sendable {
    public var notice: ShelfNotice
    public var receivedAt: Date
}

public struct PicklsssState: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var count: CountChoice = .unasked
    public var takes: [TakeRecord] = []
    public var shared: [SharedRecord] = []
    public var notices: [StoredNotice] = []
    /// The handle, once the shelf made one. Public.
    public var handle: String?
    /// The UTC day (yyyy-MM-dd) the kitchen-time call was last made.
    public var lastDayCall: String?
    public var lastDaily: Date?
    /// Why sharing is closed for this key, in the owner's words, once the shelf said so.
    public var sharingClosedReason: String?
    public var milestones: MilestoneProgress?

    public init() {}

    /// A file from before milestones starts from the history it already has.
    public mutating func prepareMilestones() {
        if milestones == nil {
            milestones = MilestoneProgress(previousTakes: takes.count, previousShares: shared.count)
        }
    }

    public func take(for picklsssId: String) -> TakeRecord? { takes.first { $0.picklsssId == picklsssId } }
    public func take(forRecipe id: UUID) -> TakeRecord? { takes.first { $0.recipeID == id } }
    public func sharedRecord(forRecipe id: UUID) -> SharedRecord? { shared.first { $0.recipeID == id && $0.state != ShelfState.removed.rawValue } }
    public var hasPublicSetup: Bool { shared.contains { $0.isPublic } }
}

// MARK: The day-7 answer

/// "Kept" means: on day 7 the setup is still among the person's recipes AND was the active recipe on at least 3 different days.
/// Worked out on the Mac and sent as one yes or no with the take token, between day 7 and day 30, once. "Active on a day" is
/// remembered only for taken setups and is never sent.
public struct KeepTracker: Sendable {
    public static let daysNeeded = 3
    public var clock: @Sendable () -> Date
    public var calendar: Calendar

    public init(clock: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) { self.clock = clock; self.calendar = calendar }

    public func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Notes that `recipeID` is the active recipe today. Does nothing unless it is a taken setup that is still waiting to be judged.
    /// Returns whether anything changed.
    @discardableResult
    public func noteActive(recipeID: UUID?, in takes: inout [TakeRecord]) -> Bool {
        guard let recipeID, let i = takes.firstIndex(where: { $0.recipeID == recipeID && $0.counted && !$0.answered && $0.takeToken != nil }) else { return false }
        let key = dayKey(clock())
        if takes[i].activeDays.contains(key) { return false }
        takes[i].activeDays.append(key)
        // Three days settle it; keep a few more at most so the file never grows.
        if takes[i].activeDays.count > 40 { takes[i].activeDays.removeFirst(takes[i].activeDays.count - 40) }
        return true
    }

    /// One answer ready to send.
    public struct Answer: Equatable, Sendable {
        public var picklsssId: String
        public var takeToken: String
        public var kept: Bool
    }

    /// Looks at every counted take: forgets the ones whose window has passed, and for the ones inside it works the answer out once.
    /// `recipeIDs` is the ids of the recipes that exist now.
    public func due(takes: inout [TakeRecord], recipeIDs: Set<UUID>) -> [Answer] {
        let now = clock()
        var out: [Answer] = []
        for i in takes.indices {
            guard takes[i].counted, !takes[i].answered, let token = takes[i].takeToken, let from = takes[i].askFrom, let until = takes[i].askUntil else { continue }
            if now > until { takes[i].takeToken = nil; takes[i].verdict = nil; continue }          // too late: forget it, never ask
            guard now >= from else { continue }
            if takes[i].verdict == nil {
                let still = takes[i].recipeID.map(recipeIDs.contains) ?? false
                takes[i].verdict = still && Set(takes[i].activeDays).count >= Self.daysNeeded
            }
            out.append(Answer(picklsssId: takes[i].picklsssId, takeToken: token, kept: takes[i].verdict ?? false))
        }
        return out
    }

    /// Records how the server answered. Success and every refusal that will never change forget the token; a refusal that only
    /// means "not yet", or no answer at all, leaves everything to try again at the next check.
    public func settle(_ picklsssId: String, error: ShelfFailure?, in takes: inout [TakeRecord]) {
        guard let i = takes.firstIndex(where: { $0.picklsssId == picklsssId }) else { return }
        func forget() { takes[i].takeToken = nil; takes[i].answered = true }
        guard let error else { forget(); return }
        switch error {
        case .keptRefused(let why, _): if why.retryLater { takes[i].verdict = nil } else { forget() }
        case .unknownTake: forget()
        default: break
        }
    }
}

// MARK: The daily check

public enum DailyCheck {
    private static var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    public static func utcDay(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The daily round (notices, day-7 answers, kitchen time) is due when none ran in the last 20 hours. Twenty, not 24, so a Mac
    /// opened a little earlier each morning still gets its round every day. A clock set back counts as due.
    public static func isDue(last: Date?, now: Date, every: TimeInterval = 20 * 60 * 60) -> Bool {
        guard let last else { return true }
        let gap = now.timeIntervalSince(last)
        return gap >= every || gap < 0
    }

    /// Kitchen time: once per UTC day, and only for a person who has at least one public setup. Nobody else's app makes the call.
    public static func shouldCallDay(hasPublicSetup: Bool, lastCall: String?, now: Date) -> Bool {
        hasPublicSetup && lastCall != utcDay(now)
    }
}

// MARK: Notices

public enum NoticeBox {
    /// Adds what the server just delivered (it will not deliver it again). An update replaces an older one for the same setup.
    public static func merge(_ incoming: [ShelfNotice], into stored: inout [StoredNotice], now: Date) {
        for n in incoming where !stored.contains(where: { $0.notice.id == n.id }) {
            if n.kind == .update { stored.removeAll { $0.notice.kind == .update && $0.notice.picklsssId == n.picklsssId && $0.notice.version <= n.version } }
            stored.append(StoredNotice(notice: n, receivedAt: now))
        }
    }

    /// What to show: updates only for setups the person still has, removals always (they are plain news).
    public static func visible(_ stored: [StoredNotice], takes: [TakeRecord], recipeIDs: Set<UUID>) -> [ShelfNotice] {
        stored.map(\.notice).filter { n in
            switch n.kind {
            case .update: return takes.contains { $0.picklsssId == n.picklsssId && ($0.recipeID.map(recipeIDs.contains) ?? false) }
            case .removed: return true
            }
        }
    }

    public static func dismiss(_ id: String, from stored: inout [StoredNotice]) { stored.removeAll { $0.notice.id == id } }

    /// "Put back" is offered for a removed setup only while the Mac still holds the settings from just before the take and the recipe exists.
    public static func canPutBack(_ n: ShelfNotice, takes: [TakeRecord], recipeIDs: Set<UUID>) -> Bool {
        guard n.kind == .removed, let t = takes.first(where: { $0.picklsssId == n.picklsssId }), let id = t.recipeID else { return false }
        return recipeIDs.contains(id) && !t.before.isEmpty
    }
}

// MARK: Sharing bookkeeping

public enum ShareDigest {
    /// What a recipe holds that a shared copy would carry: its settings, parts, gear and requirements. The title and the one line are
    /// left out, so only a change to the setup itself makes a shared copy "older than your recipe".
    public static func of(setup: SharedSetup) -> String {
        let json = setup.json
        var content: [String: JSONValue] = [
            "settings": .object(setup.settings), "parts": .strings(setup.parts),
            "gear": json["gear"] ?? .null, "requirements": json["requirements"] ?? .null,
        ]
        content["typingLanguage"] = json["typingLanguage"]
        return of(.object(content))
    }

    /// A fingerprint of the exact bytes of a document, to tell whether the recipe has changed since it was shared.
    public static func of(_ document: JSONValue) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in document.encoded() { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// Checks a person's handle and text before they are sent, with the same limits the shelf holds.
public enum ShareFields {
    public static func normalizedHandle(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Nil when the handle is fine; otherwise one sentence.
    public static func handleProblem(_ raw: String) -> String? {
        let h = normalizedHandle(raw)
        if h.count < 3 || h.count > 20 { return "A handle has 3 to 20 characters." }
        if h.unicodeScalars.contains(where: { !("a"..."z").contains($0) && !("0"..."9").contains($0) && $0 != "." && $0 != "_" }) {
            return "Use only letters a to z, numbers, dots and underscores."
        }
        return nil
    }

    public static func titleProblem(_ s: String) -> String? {
        let n = s.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
        return n == 0 ? "Give it a title." : n > SharedSetupTable.titleMax ? "The title must be 1 to \(SharedSetupTable.titleMax) characters (it has \(n))." : nil
    }

    public static func lineProblem(_ s: String) -> String? {
        let n = s.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
        return n == 0 ? "Say in one line what it is for." : n > SharedSetupTable.lineMax ? "The line must be 1 to \(SharedSetupTable.lineMax) characters (it has \(n))." : nil
    }
}
