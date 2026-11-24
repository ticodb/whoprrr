import AppKit
import WhopperKit

@MainActor
public final class WindowManager {
    public enum Outcome: Equatable { case done, noAccess, noWindow, notResizable, fullScreen, failed }

    public var settings = WindowSettings() { didSet { if settings != oldValue { registerHotKeys() } } }
    public private(set) var registrations: [WindowAction: HotKeyCenter.Registration] = [:]
    private var tokens: [UInt32] = []
    private var history: [(window: AXWindow, frame: CGRect)] = []
    private let hotkeys: HotKeyCenter
    private var snapper: DragSnapper?
    public private(set) var running = false
    public var onRegistrations: (([WindowAction: HotKeyCenter.Registration]) -> Void)?

    public init(hotkeys: HotKeyCenter = .shared) { self.hotkeys = hotkeys }

    // MARK: Lifecycle

    public func start() {
        running = true
        registerHotKeys()
        updateSnapper()
    }

    public func stop() {
        running = false
        tokens.forEach(hotkeys.unregister); tokens = []
        registrations = [:]
        snapper?.stop(); snapper = nil
    }

    public func apply(settings s: WindowSettings) {
        settings = s
        if running { updateSnapper() }
    }

    private func updateSnapper() {
        if settings.snapByDrag {
            if snapper == nil { snapper = DragSnapper(manager: self) }
            snapper?.start()
        } else { snapper?.stop(); snapper = nil }
    }

    private func registerHotKeys() {
        guard running else { return }
        tokens.forEach(hotkeys.unregister); tokens = []
        var result: [WindowAction: HotKeyCenter.Registration] = [:]
        let clash = settings.conflicts()
        for a in WindowAction.allCases {
            guard let s = settings.shortcut(for: a), !clash.contains(a) else { continue }
            let r = hotkeys.register(s) { [weak self] in
                MainActor.assumeIsolated { _ = self?.perform(a) }
            }
            if let t = r.token { tokens.append(t) }
            result[a] = r.result
        }
        registrations = result
        onRegistrations?(result)
    }

    // MARK: Acting on windows

    @discardableResult
    public func perform(_ action: WindowAction, on window: AXWindow? = nil) -> Outcome {
        guard AXWindow.isTrusted else { return .noAccess }
        guard let win = window ?? AXWindow.focused(), let cur = win.frame else { return .noWindow }
        if win.isFullScreen { return .fullScreen }
        guard win.canResize || action == .nextDisplay || action == .previousDisplay else { return .notResizable }
        let screens = ScreenMap.current()
        guard let here = ScreenMap.best(for: cur, in: screens) else { return .failed }

        if action == .restore {
            guard let i = history.lastIndex(where: { $0.window.isSame(as: win) }) else { return .noWindow }
            let f = history.remove(at: i).frame
            return win.setFrame(f) ? .done : .failed
        }

        let target: CGRect?
        switch action {
        case .nextDisplay, .previousDisplay:
            guard screens.count > 1, let idx = screens.firstIndex(of: here) else { return .done }
            let n = action == .nextDisplay ? (idx + 1) % screens.count : (idx + screens.count - 1) % screens.count
            target = WindowGeometry.move(cur, from: here.visible, to: screens[n].visible)
        default:
            let eff = settings.cycleHalves
                ? WindowGeometry.cycled(action, current: cur, visible: here.visible, gap: settings.gap) : action
            target = WindowGeometry.frame(for: eff, visible: here.visible, current: cur, gap: settings.gap)
        }
        guard let t = target else { return .failed }
        remember(win, cur)
        return win.setFrame(t) ? .done : .failed
    }

    /// Snap-by-drag lands here: the frame the zone resolves to on `screen`.
    func frame(for action: WindowAction, on screen: ScreenRect, current: CGRect) -> CGRect? {
        WindowGeometry.frame(for: action, visible: screen.visible, current: current, gap: settings.gap)
    }

    func remember(_ w: AXWindow, _ f: CGRect) {
        history.removeAll { $0.window.isSame(as: w) }
        history.append((w, f))
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }
}
