import AppKit
import InputCore

/// macOS actions a mouse button or key can trigger, the way Logi Options+ offered them. Mission Control, App Exposé and
/// Show Desktop go straight to the Dock, so they work even when their keyboard shortcuts are turned off in System Settings.
@MainActor
enum SystemActions {
    struct Action { let id: String; let title: String; let symbol: String; let run: (InputController) -> Void }

    static let all: [Action] = [
        Action(id: "system.missionControl", title: "Mission Control", symbol: "rectangle.3.group") { c in
            if !dock("com.apple.expose.awake") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app")) }
        },
        Action(id: "system.appExpose", title: "App Exposé", symbol: "macwindow.on.rectangle") { c in
            if !dock("com.apple.expose.front.awake") { c.tapChord(125, .control) }
        },
        Action(id: "system.showDesktop", title: "Show Desktop", symbol: "menubar.dock.rectangle") { c in
            if !dock("com.apple.showdesktop.awake") { c.tapChord(103, []) }
        },
        Action(id: "system.spaceLeft", title: "Space to the left", symbol: "arrow.left.to.line") { c in c.tapChord(123, .control) },
        Action(id: "system.spaceRight", title: "Space to the right", symbol: "arrow.right.to.line") { c in c.tapChord(124, .control) },
        Action(id: "system.spotlight", title: "Spotlight", symbol: "magnifyingglass") { c in c.tapChord(49, .command) },
        Action(id: "system.screenshot", title: "Screenshot (select area)", symbol: "camera.viewfinder") { c in c.tapChord(21, [.command, .shift]) },
        Action(id: "system.screenshotTools", title: "Screenshot and recording tools", symbol: "record.circle") { c in c.tapChord(23, [.command, .shift]) },
        Action(id: "system.lock", title: "Lock screen", symbol: "lock") { c in c.tapChord(12, [.command, .control]) },
    ]

    /// Sends a notification to the Dock (the same call Mission Control's own keys make). False if macOS no longer has it.
    static func dock(_ name: String) -> Bool {
        guard let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let sym = dlsym(h, "CoreDockSendNotification") else { return false }
        typealias Send = @convention(c) (CFString, Int32) -> Void
        unsafeBitCast(sym, to: Send.self)(name as CFString, 0)
        return true
    }
}
