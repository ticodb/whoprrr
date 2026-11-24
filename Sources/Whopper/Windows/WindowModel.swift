import SwiftUI
import WindowCore
import WhopperKit

@MainActor
final class WindowModel: ObservableObject {
    private let store = JSONStore<WindowSettings>(name: "windows")
    let manager = WindowManager()
    @Published var settings: WindowSettings { didSet { if settings != oldValue { store.save(settings); manager.apply(settings: settings); updateConflicts() } } }
    @Published private(set) var registrations: [WindowAction: HotKeyCenter.Registration] = [:]
    @Published private(set) var conflicts: Set<WindowAction> = []
    @Published private(set) var trusted = AXWindow.isTrusted
    private(set) var active = false

    init() {
        settings = store.load(default: WindowSettings())
        manager.settings = settings
        manager.onRegistrations = { [weak self] r in self?.registrations = r }
        updateConflicts()
    }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on { manager.apply(settings: settings); manager.start(); trackFrontApp() } else { manager.stop(); registrations = [:] }
    }

    func refreshTrust() { trusted = AXWindow.isTrusted }
    private func updateConflicts() { conflicts = settings.conflicts() }

    func shortcut(_ a: WindowAction) -> Shortcut? { settings.shortcut(for: a) }

    func setShortcut(_ a: WindowAction, _ s: Shortcut?) {
        if let s { settings.custom[a.rawValue] = s; settings.disabled.remove(a.rawValue) }
        else { settings.disabled.insert(a.rawValue) }
    }
    func reset(_ a: WindowAction) { settings.custom[a.rawValue] = nil; settings.disabled.remove(a.rawValue) }
    func isCustomised(_ a: WindowAction) -> Bool { settings.custom[a.rawValue] != nil || settings.disabled.contains(a.rawValue) }
    func run(_ a: WindowAction) { _ = manager.perform(a) }

    /// The app the user was in before our panel opened.
    private var lastExternalApp: NSRunningApplication?
    private var appObserver: NSObjectProtocol?

    func trackFrontApp() {
        guard appObserver == nil else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        lastExternalApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == me ? nil : $0 }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != me else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = app }
        }
    }

    /// Run from our menu-bar panel or window: acts on the last app you were in, not on Whoprrr itself.
    func runOnPreviousApp(_ a: WindowAction) {
        guard let win = AXWindow.focused(of: lastExternalApp) else { return }
        _ = manager.perform(a, on: win)
    }
}
