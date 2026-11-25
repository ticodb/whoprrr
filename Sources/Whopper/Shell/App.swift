import SwiftUI
import AppKit
import Combine
import WhopperKit
import WindowCore

@MainActor
enum Shared {
    static let model = AppModel()
    static let features = FeatureStore()
    static let audio = AudioModel()
    static let windows = WindowModel()
    static let clipboard = ClipboardController()
    static let input = InputController()
    private static var bag = Set<AnyCancellable>()
    static let nav = WindowNav()
    static let recipes = RecipeStore()
    static let presets = PresetLibrary()
    private static let featuresSurface = FeaturesSurface(features)
    private static let displaySurface = DisplaySurface(model)
    private static var gearTimer: Timer?
    private static var lastGear: [String] = []
    private static var window: NSWindow?
    private static let windowDelegate = MainWindowDelegate()

    /// Every object the views read from the environment.
    static func wrap<V: View>(_ v: V) -> some View {
        v.environmentObject(model).environmentObject(features).environmentObject(audio).environmentObject(windows)
            .environmentObject(clipboard).environmentObject(input).environmentObject(nav).environmentObject(recipes).environmentObject(presets)
    }

    /// The window that hosts the menu-bar drawer (set by the drawer's own view).
    weak static var drawerWindow: NSWindow?

    /// The drawer's frame if it is open right now.
    private static func drawerFrame() -> NSRect? {
        guard let w = drawerWindow, w.isVisible, w !== window else { return nil }
        return w.frame
    }

    /// The main window: sidebar of features and a page for each. When it is opened from the menu-bar drawer it appears right beside
    /// the drawer (top edges aligned); otherwise it comes back where you left it. While it is open Whoprrr shows in the Dock and
    /// ⌘-Tab, and goes back to menu-bar only when it closes.
    static func showWindow(page: AppPage? = nil) {
        let drawer = drawerFrame()          // read before activating: activating can close the drawer
        if let page { nav.page = page }
        NSApp.setActivationPolicy(.regular)
        let w: NSWindow
        let wasVisible = window?.isVisible == true
        if let existing = window { w = existing } else {
            w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
            w.title = "Whoprrr"
            w.titlebarAppearsTransparent = true
            w.contentView = NSHostingView(rootView: wrap(MainWindowView()))
            w.isReleasedWhenClosed = false
            w.delegate = windowDelegate
            w.setFrameAutosaveName("WhoprrrMainWindow")
            if !w.setFrameUsingName("WhoprrrMainWindow") { w.center() }
            window = w
        }
        // A window the user already has open stays where they put it; a newly shown one goes beside the drawer.
        if !wasVisible, let drawer {
            let screen = NSScreen.screens.first { $0.frame.intersects(drawer) } ?? NSScreen.main ?? NSScreen.screens[0]
            w.setFrame(PanelPlacement.frame(beside: drawer, size: NSSize(width: 940, height: 700), visible: screen.visibleFrame), display: true)
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Makes every settings surface available to recipes, and switches recipes automatically when the connected gear changes.
    static func startRecipes() {
        for s in [audio as RecipeSurface, windows, clipboard, input, featuresSurface, displaySurface] { recipes.register(s) }
        gearTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = Gear.current()
                let ids = now.map(\.id).sorted()
                guard ids != lastGear else { return }
                lastGear = ids
                if let r = recipes.autoApplyCandidate(connected: now) { recipes.apply(r.id, automatic: true) }
            }
        }
    }

    /// Starts every installed feature's background work, and follows installs/uninstalls.
    static func startFeatures() {
        input.commands = [("clipboard.open", "Open clipboard history", { clipboard.togglePicker() })]
            + SystemActions.all.map { a in (a.id, a.title, { a.run(input) }) }
            + CommonActions.all.map { a in (a.id, a.title, { a.run(input) }) }
            + WindowAction.allCases.map { a in ("window.\(a.rawValue)", "Window: \(a.title)", { windows.run(a) }) }
        features.$enabled.sink { enabled in
            audio.setActive(enabled.contains(.audio) || enabled.contains(.microphone))
            windows.setActive(enabled.contains(.windows))
            clipboard.setActive(enabled.contains(.clipboard))
            input.setActive(enabled.contains(.remap))
        }.store(in: &bag)
    }
}

@MainActor
final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var debugWindow: NSWindow?
    func applicationWillTerminate(_ notification: Notification) { Shared.input.shutdown() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)      // menu bar only, no Dock icon
        // WHOPPER_RENDER_ICON=/dir writes the brand artwork (iconset, icns, PNGs) and exits. See docs/brand.
        if let dir = ProcessInfo.processInfo.environment["WHOPPER_RENDER_ICON"] { BrandAssets.render(to: dir); NSApp.terminate(nil); return }
        // WHOPPER_NO_START=1 renders the UI without starting any background feature (used for screenshots).
        Shared.startRecipes()
        UpdateController.shared.start()
        DemoData.seedAfterGearLoads()
        if let ap = ProcessInfo.processInfo.environment["WHOPPER_APPEARANCE"] { NSApp.appearance = NSAppearance(named: ap == "light" ? .aqua : .darkAqua) }
        if ProcessInfo.processInfo.environment["WHOPPER_NO_START"] != "1" { Shared.startFeatures() }
        // First run: open the window on Permissions so setup is the first thing you see.
        let welcomed = "gg.tico.whoprrr.welcomed"
        if !UserDefaults.standard.bool(forKey: welcomed), ProcessInfo.processInfo.environment["SDC_DEBUG_WINDOW"] != "1" {
            UserDefaults.standard.set(true, forKey: welcomed)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Shared.showWindow(page: .permissions) }
        }
        // Development aid: SDC_DEBUG_WINDOW=1 shows a view in a normal window (WHOPPER_VIEW=quick for the menu-bar panel).
        if ProcessInfo.processInfo.environment["SDC_DEBUG_WINDOW"] == "1" {
            let quick = ProcessInfo.processInfo.environment["WHOPPER_VIEW"] == "quick"
            let size = quick ? NSSize(width: 400, height: 640) : NSSize(width: 940, height: 700)
            let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = DemoData.isOn ? "Whoprrr" : "Whoprrr (debug window)"
            w.contentView = NSHostingView(rootView: quick ? AnyView(Shared.wrap(QuickView())) : AnyView(Shared.wrap(MainWindowView())))
            w.makeKeyAndOrderFront(nil)
            w.isReleasedWhenClosed = false
            debugWindow = w
            NSApp.activate(ignoringOtherApps: true)
            // SDC_SNAPSHOT=/path.png renders the view to a PNG (no screen-recording permission needed).
            if let path = ProcessInfo.processInfo.environment["SDC_SNAPSHOT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let ext = Shared.model.displays.first(where: { !$0.isBuiltIn }) { Shared.model.select(ext.uuid) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    let content: AnyView = quick ? AnyView(Shared.wrap(QuickView())) : AnyView(Shared.wrap(MainWindowView()))
                    let r = ImageRenderer(content: content.background(Color(nsColor: .windowBackgroundColor)))
                    r.scale = 2
                    if let cg = r.cgImage {
                        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

@main
struct WhopperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            Shared.wrap(QuickView())
        } label: {
            Image(nsImage: MenuBarIcon.make())
        }
        .menuBarExtraStyle(.window)
    }
}
