import AppKit
import DisplayCore

/// Borderless solid-color windows that cover whole screens, used while the camera measures. Esc cancels
/// (handled by AppModel's key monitor). Colors are sRGB so macOS color-manages each panel.
private final class PatchWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class FullScreenPatches: PatchPresenter {
    private var windows: [UInt32: NSWindow] = [:]
    private let samsungID: UInt32, macID: UInt32
    private var cursorHidden = false

    init(samsungDisplayID: UInt32, macDisplayID: UInt32) { samsungID = samsungDisplayID; macID = macDisplayID }

    private func window(for id: UInt32) -> NSWindow? {
        if let w = windows[id] { return w }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) else { return nil }
        let w = PatchWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false
        w.hasShadow = false
        w.setFrame(screen.frame, display: true)
        windows[id] = w
        return w
    }

    private func color(_ level: Double?) -> NSColor {
        guard let l = level else { return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) }
        return NSColor(srgbRed: l, green: l, blue: l, alpha: 1)
    }

    func show(samsung: Double?, mac: Double?) async {
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
        for (id, level) in [(samsungID, samsung), (macID, mac)] {
            guard let w = window(for: id) else { continue }
            w.backgroundColor = color(level)
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func finish() async {
        windows.values.forEach { $0.close() }
        windows.removeAll()
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }
}
