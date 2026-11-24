import AppKit
import ApplicationServices
import InputCore

/// Presses an app's own menu item by its keyboard shortcut ("the item that is ⌘["), through the Accessibility API. This is
/// the only way to send a shortcut that is the same on every keyboard layout: a Spanish layout has no key that types "[" the
/// way a US one does, but every app still has a "Back" menu item bound to it.
enum MenuShortcut {
    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    /// AX encoding of the modifier part of a menu shortcut: bit 0 ⇧, 1 ⌥, 2 ⌃, 3 "no ⌘".
    private static func axMods(_ m: Mods) -> Int { (m.contains(.shift) ? 1 : 0) | (m.contains(.option) ? 2 : 0) | (m.contains(.control) ? 4 : 0) }

    private struct Key: Hashable { let bundle: String; let ch: String; let mods: Int }
    /// Where the item was last found (menu index, item indices), so later presses skip the search.
    private static var cache: [Key: [Int]] = [:]

    // MARK: Layout translation

    /// macOS shows a shortcut like ⌘[ with a different character when the layout has no such key: on a Spanish layout Back is
    /// ⌘Ñ and Forward is ⌘´. Finder's Go menu always starts with Back and Forward, so its shortcut characters tell us what
    /// "[" and "]" are on the current layout. Cached briefly.
    private static var translation: (at: Date, back: String, forward: String)?
    private static func translated(_ ch: Character) -> String {
        guard ch == "[" || ch == "]" else { return String(ch) }
        if let t = translation, Date().timeIntervalSince(t.at) < 20 { return ch == "[" ? t.back : t.forward }
        var back = "[", forward = "]"
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
           let barRef = attr(AXUIElementCreateApplication(finder.processIdentifier), kAXMenuBarAttribute) {
            let tops = (attr(barRef as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            // Menu bar: Apple, Finder, File, Edit, View, Go, …; the Go menu's first two items are Back and Forward.
            for top in tops.dropFirst() {
                guard let menu = (attr(top, kAXChildrenAttribute) as? [AXUIElement])?.first else { continue }
                let items = (attr(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? []
                guard items.count >= 3, let t0 = attr(items[0], kAXTitleAttribute) as? String, !t0.isEmpty else { continue }
                let c0 = attr(items[0], "AXMenuItemCmdChar") as? String, c1 = attr(items[1], "AXMenuItemCmdChar") as? String
                let m0 = (attr(items[0], "AXMenuItemCmdModifiers") as? Int) ?? 0
                // The Go menu is the one whose first two items carry plain ⌘ shortcuts and whose third item is a keyboard arrow
                // (Enclosing Folder); it is the only Finder menu shaped like that.
                if let c0, let c1, m0 == 0, (attr(items[2], "AXMenuItemCmdVirtualKey") as? Int) == 126 { back = c0; forward = c1; break }
            }
        }
        translation = (Date(), back, forward)
        return ch == "[" ? back : forward
    }

    /// True if the app has a menu item with this shortcut (pressed if enabled; with `dryRun` nothing is pressed).
    @discardableResult
    static func press(_ ch: Character, mods: Mods, in app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication, dryRun: Bool = false) -> Bool {
        guard AXIsProcessTrusted(), let app, let bundle = app.bundleIdentifier else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let barRef = attr(root, kAXMenuBarAttribute) else { return false }
        let bar = barRef as! AXUIElement
        let want = translated(ch).lowercased(), m = axMods(mods)
        /// Found it. A disabled item (Back with no history) counts as handled: nothing should happen, and falling back to a key chord
        /// could move the text cursor instead.
        func act(_ item: AXUIElement) -> Bool {
            if dryRun || (attr(item, kAXEnabledAttribute) as? Bool) == false { return true }
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }
        let key = Key(bundle: bundle, ch: want, mods: m)

        func matches(_ item: AXUIElement) -> Bool {
            guard let c = attr(item, "AXMenuItemCmdChar") as? String, c.lowercased() == want else { return false }
            let im = (attr(item, "AXMenuItemCmdModifiers") as? Int) ?? 0
            return im == m
        }
        func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
        /// An item's submenu items (the AXMenu is the only child of the item).
        func menuItems(of e: AXUIElement) -> [AXUIElement] { children(e).first.map(children) ?? [] }

        // Remembered location first.
        if let path = cache[key] {
            var cur: AXUIElement? = bar
            let tops = children(bar)
            if path.count >= 2, path[0] < tops.count {
                cur = tops[path[0]]
                for idx in path.dropFirst() { let items = menuItems(of: cur!); guard idx < items.count else { cur = nil; break }; cur = items[idx] }
                if let item = cur, matches(item) { return act(item) }
            }
            cache[key] = nil
        }

        // Search every menu except the Apple menu, two levels deep.
        for (ti, top) in children(bar).enumerated().dropFirst() {
            for (ii, item) in menuItems(of: top).enumerated() {
                if matches(item) { cache[key] = [ti, ii]; return act(item) }
                for (si, sub) in menuItems(of: item).enumerated() where matches(sub) {
                    cache[key] = [ti, ii, si]; return act(sub)
                }
            }
        }
        return false
    }
}
