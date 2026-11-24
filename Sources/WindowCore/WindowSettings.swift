import Foundation
import WhopperKit

public struct WindowSettings: Codable, Equatable, Sendable {
    public var shortcutsEnabled = true
    public var custom: [String: Shortcut] = [:]
    public var disabled: Set<String> = []
    /// Points between tiled windows and between windows and screen edges.
    public var gap: Double = 0
    public var cycleHalves = true
    public var snapByDrag = true
    public init() {}

    public func shortcut(for a: WindowAction) -> Shortcut? {
        guard shortcutsEnabled, !disabled.contains(a.rawValue) else { return nil }
        return custom[a.rawValue] ?? a.defaultShortcut
    }

    /// Actions whose resolved shortcut collides with another action's.
    public func conflicts() -> Set<WindowAction> {
        var seen: [Shortcut: WindowAction] = [:], bad = Set<WindowAction>()
        for a in WindowAction.allCases {
            guard let s = shortcut(for: a) else { continue }
            if let other = seen[s] { bad.insert(a); bad.insert(other) } else { seen[s] = a }
        }
        return bad
    }
}
