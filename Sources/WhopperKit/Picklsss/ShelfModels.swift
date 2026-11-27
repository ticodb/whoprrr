import Foundation

// What the shelf of shared setups says, as plain data. The contract is docs/picklsss.md in the website repository.
// Nothing here talks to the network (see ShelfClient) and nothing here is shown as it is: screens use ShelfWords.

/// A cook: the person who shared. The handle is the only thing about them that is public.
public struct ShelfCook: Codable, Equatable, Sendable {
    public var handle: String
    /// "dishwasher", "prep cook"… The app never computes it. Nil only for a cook with nothing accepted.
    public var rank: String?
    public var keeps: Int
    public var kitchenDays: Int
    /// Set (with the owner's reason) when sharing is closed for this key.
    public var sharingClosed: Closed?

    public struct Closed: Codable, Equatable, Sendable {
        public var reason: String
        public init(reason: String) { self.reason = reason }
    }

    public init(handle: String, rank: String? = nil, keeps: Int = 0, kitchenDays: Int = 0, sharingClosed: Closed? = nil) {
        self.handle = handle; self.rank = rank; self.keeps = keeps; self.kitchenDays = kitchenDays; self.sharingClosed = sharingClosed
    }

    private enum CodingKeys: String, CodingKey { case handle, rank, keeps, kitchenDays, sharingClosed }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        rank = try c.decodeIfPresent(String.self, forKey: .rank)
        keeps = try c.decodeIfPresent(Int.self, forKey: .keeps) ?? 0
        kitchenDays = try c.decodeIfPresent(Int.self, forKey: .kitchenDays) ?? 0
        sharingClosed = try c.decodeIfPresent(Closed.self, forKey: .sharingClosed)
    }
}

/// The states a shared setup goes through, as the server names them.
public enum ShelfState: String, Codable, Equatable, Sendable {
    case checking, `public`, held, refused, removed
}

/// One card of the shelf. Never carries the document.
public struct ShelfCard: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var line: String
    public var parts: [String]
    public var gear: [SharedGear]
    public var requirements: SharedRequirements
    public var cook: ShelfCook
    /// This one's keeps (the cook's own total is `cook.keeps`).
    public var keeps: Int
    public var version: Int
    public var createdAt: String
    public var updatedAt: String
    /// Only on the cook's own list (`mine`) and on `item`.
    public var state: String?
    public var reason: String?
    public var note: String?

    public init(id: String, title: String, line: String, parts: [String], gear: [SharedGear] = [], requirements: SharedRequirements = SharedRequirements(),
                cook: ShelfCook, keeps: Int = 0, version: Int = 1, createdAt: String = "", updatedAt: String = "", state: String? = nil, reason: String? = nil, note: String? = nil) {
        self.id = id; self.title = title; self.line = line; self.parts = parts; self.gear = gear; self.requirements = requirements
        self.cook = cook; self.keeps = keeps; self.version = version; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.state = state; self.reason = reason; self.note = note
    }

    private enum CodingKeys: String, CodingKey { case id, title, line, parts, gear, requirements, cook, keeps, version, createdAt, updatedAt, state, reason, note }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        line = try c.decodeIfPresent(String.self, forKey: .line) ?? ""
        parts = try c.decodeIfPresent([String].self, forKey: .parts) ?? []
        gear = try c.decodeIfPresent([SharedGear].self, forKey: .gear) ?? []
        requirements = try c.decodeIfPresent(SharedRequirements.self, forKey: .requirements) ?? SharedRequirements()
        cook = try c.decode(ShelfCook.self, forKey: .cook)
        keeps = try c.decodeIfPresent(Int.self, forKey: .keeps) ?? 0
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    public var shelfState: ShelfState? { state.flatMap(ShelfState.init(rawValue:)) }
    public var updated: Date? { ShelfDates.parse(updatedAt) }
}

/// A page of the shelf.
public struct ShelfPage: Codable, Equatable, Sendable {
    public var items: [ShelfCard]
    /// The cursor for the next page; nil on the last one.
    public var next: String?
}

/// One shared setup opened: the card and the document, exactly as the cook sent it.
public struct ShelfItem: Equatable, Sendable {
    public var card: ShelfCard
    public var document: JSONValue
    public var formatVersion: Int

    public var id: String { card.id }
}

public struct ShelfCount: Codable, Equatable, Sendable {
    public var count: Int
    public var gearTypes: Int
}

/// What a take answered. The token is the only credential for the day-7 answer: it is shown nowhere and sent nowhere else.
public struct TakeReceipt: Equatable, Sendable {
    public var again: Bool
    public var takeToken: String?
    public var counted: Bool
    public var askFrom: Date?
    public var askUntil: Date?
}

public enum ShelfNoticeKind: String, Codable, Equatable, Sendable { case update, removed }

public struct ShelfNotice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ShelfNoticeKind
    public var picklsssId: String
    public var title: String
    public var version: Int
    public var note: String
    public var at: String
    /// Plain words from the server, safe to show as they are.
    public var message: String

    public init(id: String, kind: ShelfNoticeKind, picklsssId: String, title: String, version: Int = 1, note: String = "", at: String = "", message: String = "") {
        self.id = id; self.kind = kind; self.picklsssId = picklsssId; self.title = title; self.version = version; self.note = note; self.at = at; self.message = message
    }
}

public struct ShareOutcome: Codable, Equatable, Sendable {
    public var id: String
    public var state: ShelfState
    public var version: Int
    public var reason: String?
    public var handle: String
}

/// The cook's own page.
public struct ShelfMine: Equatable, Sendable {
    public var cook: ShelfCook?
    public var picklsss: [ShelfCard]
}

/// What `share` and `update` carry beside the document.
public struct ShareRequest: Equatable, Sendable {
    public var handle: String?
    public var title: String
    public var line: String
    public var parts: [String]
    public var gear: [SharedGear]
    public var requirements: SharedRequirements
    public var document: JSONValue
    public var formatVersion: Int
    public init(handle: String?, title: String, line: String, parts: [String], gear: [SharedGear], requirements: SharedRequirements, document: JSONValue, formatVersion: Int = SharedSetupTable.formatVersion) {
        self.handle = handle; self.title = title; self.line = line; self.parts = parts; self.gear = gear
        self.requirements = requirements; self.document = document; self.formatVersion = formatVersion
    }

    /// The request for a checked setup: the card fields are the document's own, so they cannot disagree.
    public init(setup: SharedSetup, handle: String?) {
        self.init(handle: handle, title: setup.title, line: setup.line, parts: setup.parts, gear: setup.gear, requirements: setup.requirements,
                  document: setup.json, formatVersion: setup.formatVersion)
    }
}

public enum ShelfTab: String, Equatable, Sendable { case popular, new }

public enum ShelfDates {
    public static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
