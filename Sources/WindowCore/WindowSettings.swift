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
    /// Layouts shown as tiles in the menu-bar drawer; nil means the built-in default set.
    public var drawerActions: Set<String>?
    public static let drawerDefault: Set<String> = Set([WindowAction.leftHalf, .rightHalf, .firstThird, .centerThird, .lastThird, .center, .nextDisplay, .restore].map(\.rawValue))
    public static let drawerLimit = 16
    public init() {}

    /// The drawer's layouts in a stable, grouped order.
    public var drawer: [WindowAction] {
        let picked = drawerActions ?? Self.drawerDefault
        return WindowAction.allCases.filter { picked.contains($0.rawValue) }
    }

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
