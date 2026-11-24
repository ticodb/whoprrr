import AppKit

/// Snap by dragging: drag a window's title bar to a screen edge or corner, see a preview, release to snap.
/// Mouse-only global monitors; the Accessibility API does the actual window reading and moving.
@MainActor
final class DragSnapper {
    private unowned let manager: WindowManager
    private var monitors: [Any] = []
    private var tracked: AXWindow?
    private var startFrame: CGRect?
    private var dragging = false
    private var zone: (action: WindowAction, screen: ScreenRect)?
    private var lastCheck = Date.distantPast
    private let preview = PreviewWindow()

    init(manager: WindowManager) { self.manager = manager }

    func start() {
        guard monitors.isEmpty else { return }
        let m1 = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.down() }
        }
        let m2 = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.drag() }
        }
        let m3 = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.up() }
        }
        monitors = [m1, m2, m3].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        reset()
    }

    private func cursor() -> CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: ScreenMap.primaryHeight() - p.y)
    }

    private func down() {
        reset()
        guard AXWindow.isTrusted, let w = AXWindow.at(cursor()), let f = w.frame, !w.isFullScreen else { return }
        tracked = w; startFrame = f
    }

    private func drag() {
        guard let w = tracked, let start = startFrame else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 0.03 else { return }
        lastCheck = now
        if !dragging {
            // A window drag moves the origin without changing the size; selecting text or resizing does not.
            guard let f = w.frame, f.size == start.size, f.origin != start.origin else { return }
            dragging = true
        }
        let c = cursor()
        let screens = ScreenMap.current()
        guard let screen = screens.first(where: { $0.frame.contains(c) }),
              let a = SnapZones.action(cursor: c, screen: screen.frame),
              let f = manager.frame(for: a, on: screen, current: startFrame ?? .zero) else {
            zone = nil; preview.hide(); return
        }
        zone = (a, screen)
        preview.show(ScreenMap.toAppKit(f))
    }

    private func up() {
        defer { reset() }
        guard dragging, let w = tracked, let z = zone, let start = startFrame else { return }
        if let f = manager.frame(for: z.action, on: z.screen, current: start) {
            manager.remember(w, start)
            w.setFrame(f)
        }
    }

    private func reset() {
        tracked = nil; startFrame = nil; dragging = false; zone = nil
        preview.hide()
    }
}

@MainActor
final class PreviewWindow {
    private var window: NSWindow?

    func show(_ frame: CGRect) {
        if window == nil {
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.ignoresMouseEvents = true; w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
            v.layer?.borderWidth = 2; v.layer?.cornerRadius = 10
            v.autoresizingMask = [.width, .height]
            w.contentView = v
            window = w
        }
        window?.setFrame(frame, display: true)
        window?.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }
}
