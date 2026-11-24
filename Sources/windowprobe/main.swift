import AppKit
import WindowCore

// Applies each action to this tool's own window through the real Accessibility path and prints the result.
// Never touches other apps' windows.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let win = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 500, height: 350), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    win.title = "windowprobe"
    win.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    let mgr = WindowManager()
    print("AX trusted:", AXWindow.isTrusted)
    var failed = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let screens = ScreenMap.current()
        print("screens:", screens.map { "\($0.frame) visible \($0.visible)" })
        for a in [WindowAction.leftHalf, .rightHalf, .topLeft, .maximize, .center, .firstThird, .restore] {
            let out = mgr.perform(a)
            Thread.sleep(forTimeInterval: 0.3)
            let f = AXWindow.focused()?.frame
            print(a.rawValue, out, f.map { "\($0)" } ?? "nil")
            if out != .done { failed = true }
        }
        exit(failed ? 1 : 0)
    }
    app.run()
}
