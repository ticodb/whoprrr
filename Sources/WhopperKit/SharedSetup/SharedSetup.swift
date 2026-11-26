import Foundation

/// A piece of gear a shared setup was made for, in words that mean the same on any Mac: a role and a model. Never a name the
/// person gave it, never a serial number, never an identifier of this Mac.
public struct SharedGear: Codable, Hashable, Sendable {
    public var role: String
    public var model: String
    public init(role: String, model: String) { self.role = role; self.model = model }
    public init(_ d: DeviceSignature) { role = d.role.rawValue; model = KnownGear.publicName(d.model) }
}

/// What the receiving Mac needs for the setup to work.
public struct SharedRequirements: Codable, Equatable, Sendable {
    /// Names of the audio plugins the setup refers to. The plugins themselves are never included.
    public var plugins: [String]
    /// "14.2", or nil when any supported macOS will do.
    public var minMacOS: String?
    /// `Permission` raw values: "accessibility", "microphone"…
    public var permissions: [String]

    public init(plugins: [String] = [], minMacOS: String? = nil, permissions: [String] = []) {
        self.plugins = plugins; self.minMacOS = minMacOS; self.permissions = permissions
    }

    private enum CodingKeys: String, CodingKey { case plugins, minMacOS, permissions }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        plugins = try c.decode([String].self, forKey: .plugins)
        minMacOS = try c.decodeIfPresent(String.self, forKey: .minMacOS)
        permissions = try c.decode([String].self, forKey: .permissions)
    }
    /// `minMacOS` is always written, as `null` when there is none, so the shape never changes.
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(plugins, forKey: .plugins)
        if let m = minMacOS { try c.encode(m, forKey: .minMacOS) } else { try c.encodeNil(forKey: .minMacOS) }
        try c.encode(permissions, forKey: .permissions)
    }
}

/// A recipe made ready to share: Whoprrr's own settings in a plain, stable JSON shape and nothing else.
///
/// The settings per part are held as JSON (`docs/shared-setup-format.md` has the shape), so the same checks run in Swift on
/// the Mac and in JavaScript on the server. Make one with `SharedSetupExport`; open one with `SharedSetupFile`.
public struct SharedSetup: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var title: String
    /// The one line that says what it is for.
    public var line: String
    /// The parts it holds, in the order of `SharedSetupTable.parts`.
    public var parts: [String]
    public var gear: [SharedGear]
    public var requirements: SharedRequirements
    /// Settings per part, keyed by the names in `parts`.
    public var settings: [String: JSONValue]

    public init(title: String, line: String, parts: [String], gear: [SharedGear], requirements: SharedRequirements, settings: [String: JSONValue]) {
        formatVersion = SharedSetupTable.formatVersion
        self.title = title; self.line = line; self.parts = parts; self.gear = gear; self.requirements = requirements; self.settings = settings
    }

    /// The document as JSON.
    public var json: JSONValue { JSONValue.of(self) ?? .null }

    /// The exact bytes that are sent and stored: compact, keys sorted.
    public func encoded() -> Data { json.encoded() }

    /// Reads a document that already passed the checker. Nil if it cannot be read as a shared setup.
    public init?(json: JSONValue) {
        guard let s = json.decode(SharedSetup.self) else { return nil }
        self = s
    }
}

/// One thing a shared setup does that its limits do not allow.
public struct SharedSetupViolation: Codable, Equatable, Sendable {
    /// Where, as a path into the document ("settings.audio.equalizer.curve.bands[3].gainDb") or a field ("title").
    public var line: String
    /// The name of the rule ("boost-6db"). Stable: the server and the app use the same names.
    public var limit: String
    /// One plain sentence for the person.
    public var message: String
    /// True when the value is one the app could never have written (outside its own ranges, an unknown field…).
    public var tampered: Bool

    public init(line: String, limit: String, message: String, tampered: Bool = false) {
        self.line = line; self.limit = limit; self.message = message; self.tampered = tampered
    }

    private enum CodingKeys: String, CodingKey { case line, limit, message }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        line = try c.decode(String.self, forKey: .line); limit = try c.decode(String.self, forKey: .limit); message = try c.decode(String.self, forKey: .message)
        tampered = false
    }
}

/// What the checker found.
public struct SharedSetupReport: Equatable, Sendable {
    public var violations: [SharedSetupViolation]
    /// Why it is "unusual" (see `ordinary`), in plain words.
    public var unusual: [String]

    public init(violations: [SharedSetupViolation] = [], unusual: [String] = []) {
        self.violations = violations; self.unusual = unusual
    }

    /// Nothing is violated.
    public var ok: Bool { violations.isEmpty }
    /// Nothing is violated and nothing is unusual: safe to put on the shelf without a person looking at it.
    public var ordinary: Bool { ok && unusual.isEmpty }
    /// The document holds something the app could never have written, which proves it was edited by hand.
    public var tampered: Bool { violations.contains { $0.tampered } }
    /// The names of the rules that were broken, once each, sorted.
    public var limits: [String] { Array(Set(violations.map(\.limit))).sorted() }
}
