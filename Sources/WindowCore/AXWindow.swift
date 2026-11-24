import AppKit
import ApplicationServices

/// A window reached through the Accessibility API. Frames are in top-left-origin global coordinates.
public struct AXWindow {
    public let element: AXUIElement
    public init(_ e: AXUIElement) { element = e }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    public static func focused() -> AXWindow? { focused(of: NSWorkspace.shared.frontmostApplication) }

    /// The focused window of a given app (used when our own panel is in front but the user means the app behind it).
    public static func focused(of app: NSRunningApplication?) -> AXWindow? {
        guard let app else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let w = attr(appEl, kAXFocusedWindowAttribute) else { return nil }
        return AXWindow(w as! AXUIElement)
    }

    /// The window under a point, found by walking up from the element there.
    public static func at(_ p: CGPoint) -> AXWindow? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success, var cur = el else { return nil }
        for _ in 0..<12 {
            if (attr(cur, kAXRoleAttribute) as? String) == kAXWindowRole { return AXWindow(cur) }
            guard let parent = attr(cur, kAXParentAttribute) else { return nil }
            cur = parent as! AXUIElement
        }
        return nil
    }

    public var pid: pid_t { var p: pid_t = 0; AXUIElementGetPid(element, &p); return p }

    public var frame: CGRect? {
        guard let pv = Self.attr(element, kAXPositionAttribute), let sv = Self.attr(element, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &pt), AXValueGetValue(sv as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    public var isFullScreen: Bool { (Self.attr(element, "AXFullScreen") as? Bool) == true }
    public var isMinimized: Bool { (Self.attr(element, kAXMinimizedAttribute) as? Bool) == true }

    public var canResize: Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// Size, position, size again: the first size can be clamped by the old display, the second settles it.
    @discardableResult
    public func setFrame(_ r: CGRect) -> Bool {
        let appEl = AXUIElementCreateApplication(pid)
        // Apps with "enhanced UI" (VoiceOver-style) animate and ignore quick resizes; switch it off meanwhile.
        let enhanced = Self.attr(appEl, "AXEnhancedUserInterface") as? Bool
        if enhanced == true { AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced == true { AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }

        var size = r.size, pos = r.origin
        guard let sv = AXValueCreate(.cgSize, &size), let pv = AXValueCreate(.cgPoint, &pos) else { return false }
        var ok = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sv) == .success
        ok = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pv) == .success && ok
        ok = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sv) == .success && ok
        return ok
    }

    public func isSame(as other: AXWindow) -> Bool { CFEqual(element, other.element) }
}

public enum ScreenMap {
    /// Displays in top-left coordinates, left to right.
    public static func current() -> [ScreenRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        let H = primary.frame.maxY
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }
        return NSScreen.screens.map { ScreenRect(frame: flip($0.frame), visible: flip($0.visibleFrame)) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    public static func primaryHeight() -> CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    /// Display holding most of `rect`, else the nearest one.
    public static func best(for rect: CGRect, in screens: [ScreenRect]) -> ScreenRect? {
        let byArea = screens.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
        if let b = byArea, b.frame.intersection(rect).area > 0 { return b }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        return screens.min { dist($0.frame, c) < dist($1.frame, c) }
    }

    private static func dist(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    public static func toAppKit(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight() - r.maxY, width: r.width, height: r.height)
    }
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
