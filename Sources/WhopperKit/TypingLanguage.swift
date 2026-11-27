import Foundation

public struct SharedTypingLanguage: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A person’s switch takes precedence over automatic recipe changes until the next manual apply.
public struct TypingLanguageRule: Codable, Equatable, Sendable {
    public private(set) var lastSourceID: String?
    public private(set) var manualOverride = false

    public init() {}

    public mutating func observe(_ sourceID: String?, recipeActive: Bool) {
        if let sourceID, let lastSourceID, sourceID != lastSourceID, recipeActive { manualOverride = true }
        if let sourceID { lastSourceID = sourceID }
        if !recipeActive { manualOverride = false }
    }

    public mutating func permitsSwitch(automatic: Bool) -> Bool {
        if !automatic { manualOverride = false }
        return !manualOverride
    }

    /// Record our own successful selection before the distributed notification is delivered.
    public mutating func selectedByRecipe(_ sourceID: String) { lastSourceID = sourceID }
}
