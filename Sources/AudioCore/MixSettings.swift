import Foundation

/// Only apps whose playback differs from the default are kept.
public struct MixSettings: Codable, Equatable, Sendable {
    public struct Adjustment: Codable, Equatable, Sendable {
        public let volume: Double
        public let muted: Bool
        public let name: String

        fileprivate init(volume: Double, muted: Bool, name: String) {
            self.volume = volume.isFinite ? min(max(volume, 0), 1) : 1
            self.muted = muted
            self.name = name
        }

        var isAdjusted: Bool { volume < 1 || muted }
        var gain: Float { muted ? 0 : Float(volume) }
    }

    public private(set) var apps: [String: Adjustment] = [:]
    public init() {}

    public mutating func set(_ bundleID: String, volume: Double, muted: Bool, name: String) {
        let adjustment = Adjustment(volume: volume, muted: muted, name: name)
        apps[bundleID] = adjustment.isAdjusted ? adjustment : nil
    }

    public mutating func reset(_ bundleID: String) { apps.removeValue(forKey: bundleID) }

    /// A renamed app retains its setting without counting as an edit to a recipe or preset.
    public func matchesLevels(of other: Self) -> Bool {
        apps.count == other.apps.count && apps.allSatisfy { id, adjustment in
            guard let saved = other.apps[id] else { return false }
            return adjustment.volume == saved.volume && adjustment.muted == saved.muted
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        for (bundleID, adjustment) in try container.decode([String: Adjustment].self) {
            set(bundleID, volume: adjustment.volume, muted: adjustment.muted, name: adjustment.name)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(apps)
    }
}
