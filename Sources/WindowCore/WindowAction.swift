import Foundation
import CoreGraphics
import Carbon.HIToolbox
import WhopperKit

public enum WindowAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, maximizeHeight, center
    case larger, smaller
    case nextDisplay, previousDisplay
    case restore

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leftHalf: "Left half"
        case .rightHalf: "Right half"
        case .topHalf: "Top half"
        case .bottomHalf: "Bottom half"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        case .firstThird: "First third"
        case .centerThird: "Center third"
        case .lastThird: "Last third"
        case .firstTwoThirds: "First two thirds"
        case .lastTwoThirds: "Last two thirds"
        case .maximize: "Maximize"
        case .maximizeHeight: "Maximize height"
        case .center: "Center"
        case .larger: "Larger"
        case .smaller: "Smaller"
        case .nextDisplay: "Next display"
        case .previousDisplay: "Previous display"
        case .restore: "Restore"
        }
    }

    public var group: String {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: "Halves"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: "Quarters"
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds: "Thirds"
        case .maximize, .maximizeHeight, .center, .larger, .smaller, .restore: "Size"
        case .nextDisplay, .previousDisplay: "Displays"
        }
    }

    /// Rectangle's defaults, so muscle memory carries over.
    public var defaultShortcut: Shortcut {
        let co = Shortcut.ctrl | Shortcut.opt
        switch self {
        case .leftHalf: return Shortcut(kVK_LeftArrow, co)
        case .rightHalf: return Shortcut(kVK_RightArrow, co)
        case .topHalf: return Shortcut(kVK_UpArrow, co)
        case .bottomHalf: return Shortcut(kVK_DownArrow, co)
        case .topLeft: return Shortcut(kVK_ANSI_U, co)
        case .topRight: return Shortcut(kVK_ANSI_I, co)
        case .bottomLeft: return Shortcut(kVK_ANSI_J, co)
        case .bottomRight: return Shortcut(kVK_ANSI_K, co)
        case .firstThird: return Shortcut(kVK_ANSI_D, co)
        case .centerThird: return Shortcut(kVK_ANSI_F, co)
        case .lastThird: return Shortcut(kVK_ANSI_G, co)
        case .firstTwoThirds: return Shortcut(kVK_ANSI_E, co)
        case .lastTwoThirds: return Shortcut(kVK_ANSI_T, co)
        case .maximize: return Shortcut(kVK_Return, co)
        case .maximizeHeight: return Shortcut(kVK_UpArrow, co | Shortcut.shift)
        case .center: return Shortcut(kVK_ANSI_C, co)
        case .larger: return Shortcut(kVK_ANSI_Equal, co)
        case .smaller: return Shortcut(kVK_ANSI_Minus, co)
        case .nextDisplay: return Shortcut(kVK_RightArrow, co | Shortcut.cmd)
        case .previousDisplay: return Shortcut(kVK_LeftArrow, co | Shortcut.cmd)
        case .restore: return Shortcut(kVK_Delete, co)
        }
    }
}

/// One display in top-left-origin global coordinates (the space the Accessibility API uses).
public struct ScreenRect: Equatable, Sendable {
    public var frame: CGRect
    public var visible: CGRect     // excludes menu bar and Dock
    public init(frame: CGRect, visible: CGRect) { self.frame = frame; self.visible = visible }
}

public enum WindowGeometry {
    public static let minSize = CGSize(width: 200, height: 120)
    public static let resizeStep: CGFloat = 30

    /// Frame a window should take for `action`. `current` is its present frame (top-left coordinates).
    /// Display moves and restore are handled by the manager, not here.
    public static func frame(for action: WindowAction, visible r: CGRect, current: CGRect, gap: CGFloat = 0) -> CGRect? {
        let w = r.width, h = r.height, x = r.minX, y = r.minY
        let raw: CGRect
        switch action {
        case .leftHalf: raw = CGRect(x: x, y: y, width: w / 2, height: h)
        case .rightHalf: raw = CGRect(x: x + w / 2, y: y, width: w / 2, height: h)
        case .topHalf: raw = CGRect(x: x, y: y, width: w, height: h / 2)
        case .bottomHalf: raw = CGRect(x: x, y: y + h / 2, width: w, height: h / 2)
        case .topLeft: raw = CGRect(x: x, y: y, width: w / 2, height: h / 2)
        case .topRight: raw = CGRect(x: x + w / 2, y: y, width: w / 2, height: h / 2)
        case .bottomLeft: raw = CGRect(x: x, y: y + h / 2, width: w / 2, height: h / 2)
        case .bottomRight: raw = CGRect(x: x + w / 2, y: y + h / 2, width: w / 2, height: h / 2)
        case .firstThird: raw = CGRect(x: x, y: y, width: w / 3, height: h)
        case .centerThird: raw = CGRect(x: x + w / 3, y: y, width: w / 3, height: h)
        case .lastThird: raw = CGRect(x: x + 2 * w / 3, y: y, width: w / 3, height: h)
        case .firstTwoThirds: raw = CGRect(x: x, y: y, width: 2 * w / 3, height: h)
        case .lastTwoThirds: raw = CGRect(x: x + w / 3, y: y, width: 2 * w / 3, height: h)
        case .maximize: raw = r
        case .maximizeHeight: raw = CGRect(x: current.minX, y: y, width: current.width, height: h)
        case .center:
            let size = CGSize(width: min(current.width, w), height: min(current.height, h))
            raw = CGRect(x: x + (w - size.width) / 2, y: y + (h - size.height) / 2, width: size.width, height: size.height)
        case .larger, .smaller:
            let d = action == .larger ? resizeStep : -resizeStep
            var n = current.insetBy(dx: -d, dy: -d)
            n.size.width = min(max(n.width, minSize.width), w); n.size.height = min(max(n.height, minSize.height), h)
            // keep it on screen
            n.origin.x = min(max(n.minX, x), r.maxX - n.width); n.origin.y = min(max(n.minY, y), r.maxY - n.height)
            return n
        case .nextDisplay, .previousDisplay, .restore: return nil
        }
        return applyGap(raw, in: r, gap: gap)
    }

    /// Full gap against screen edges, half a gap between neighbours (so two tiled windows are `gap` apart).
    public static func applyGap(_ f: CGRect, in r: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0 else { return f }
        let eps: CGFloat = 0.5
        let l = abs(f.minX - r.minX) < eps ? gap : gap / 2
        let t = abs(f.minY - r.minY) < eps ? gap : gap / 2
        let rr = abs(f.maxX - r.maxX) < eps ? gap : gap / 2
        let b = abs(f.maxY - r.maxY) < eps ? gap : gap / 2
        return CGRect(x: f.minX + l, y: f.minY + t, width: max(f.width - l - rr, 1), height: max(f.height - t - b, 1))
    }

    /// Moves a window to another display keeping its relative position and size, clamped on screen.
    public static func move(_ current: CGRect, from src: CGRect, to dst: CGRect) -> CGRect {
        let sx = dst.width / src.width, sy = dst.height / src.height
        var n = CGRect(x: dst.minX + (current.minX - src.minX) * sx, y: dst.minY + (current.minY - src.minY) * sy,
                       width: current.width * sx, height: current.height * sy)
        n.size.width = min(n.width, dst.width); n.size.height = min(n.height, dst.height)
        n.origin.x = min(max(n.minX, dst.minX), dst.maxX - n.width)
        n.origin.y = min(max(n.minY, dst.minY), dst.maxY - n.height)
        return n
    }

    /// Repeating left/right half cycles half -> two thirds -> third, like Rectangle. Stateless: the current
    /// frame says where in the cycle we are.
    public static func cycled(_ action: WindowAction, current: CGRect, visible r: CGRect, gap: CGFloat, tolerance: CGFloat = 6) -> WindowAction {
        let chains: [WindowAction: [WindowAction]] = [
            .leftHalf: [.leftHalf, .firstTwoThirds, .firstThird],
            .rightHalf: [.rightHalf, .lastTwoThirds, .lastThird],
        ]
        guard let chain = chains[action] else { return action }
        for (i, a) in chain.enumerated() {
            if let f = frame(for: a, visible: r, current: current, gap: gap), near(f, current, tolerance) {
                return chain[(i + 1) % chain.count]
            }
        }
        return action
    }

    public static func near(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= t && abs(a.minY - b.minY) <= t && abs(a.width - b.width) <= t && abs(a.height - b.height) <= t
    }
}

/// Which snap zone a dragged window's cursor is in (top-left coordinates).
public enum SnapZones {
    public static func action(cursor p: CGPoint, screen: CGRect, edge: CGFloat = 4, corner: CGFloat = 40) -> WindowAction? {
        let left = p.x <= screen.minX + edge, right = p.x >= screen.maxX - edge
        let top = p.y <= screen.minY + edge, bottom = p.y >= screen.maxY - edge
        guard left || right || top || bottom else { return nil }
        let nearL = p.x <= screen.minX + corner, nearR = p.x >= screen.maxX - corner
        let nearT = p.y <= screen.minY + corner, nearB = p.y >= screen.maxY - corner
        if (left || right) && nearT { return left ? .topLeft : .topRight }
        if (left || right) && nearB { return left ? .bottomLeft : .bottomRight }
        if (top || bottom) && nearL { return top ? .topLeft : .bottomLeft }
        if (top || bottom) && nearR { return top ? .topRight : .bottomRight }
        if left { return .leftHalf }
        if right { return .rightHalf }
        if top { return .maximize }
        return nil   // bottom edge alone does nothing: the Dock lives there
    }
}
