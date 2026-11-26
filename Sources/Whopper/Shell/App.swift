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
    static let saveBar = SaveBarController(store: recipes)
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
            .environmentObject(clipboard).environmentObject(input).environmentObject(nav).environmentObject(recipes).environmentObject(saveBar).environmentObject(presets)
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
        let wasVisible = window?.isVisible == true
        if let page { nav.page = page }
        // Something was left unsaved when the window last closed: land on the page that changed (the reminder itself shows there).
        else if !wasVisible, let part = recipes.takeLandingPart() { nav.page = AppPage.page(forRecipePart: part, features: features) }
        nav.windowOpen = true
        NSApp.setActivationPolicy(.regular)
        let w: NSWindow
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
        watchSettingsForSaveBar()
        // Anything still unsaved from last time was left on the stove: remember that, and show the bar as soon as the window opens.
        recipes.noteLeaving()
        saveBar.start()
        PicklsssController.shared.start()
        gearTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = Gear.current()
                let ids = now.map(\.id).sorted()
                guard ids != lastGear else { return }
                lastGear = ids
                // Switches by itself when that loses nothing; with unsaved changes it asks first (the question shows in the main window).
                if LicenseController.shared.isLicensed { recipes.considerAutoSwitch(connected: now) }
            }
        }
    }

    /// Tells the save bar whenever a setting a recipe holds may have changed. Notifications are merged into one check a moment later,
    /// and ignored while a surface is being read for a recipe (reading some of them touches their own state).
    private static var checkPending = false
    private static func watchSettingsForSaveBar() {
        let ping: () -> Void = {
            guard !recipes.isCapturing, !checkPending else { return }
            checkPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { checkPending = false; saveBar.settingsDidChange() }
        }
        audio.$settings.dropFirst().sink { _ in ping() }.store(in: &bag)
        windows.$settings.dropFirst().sink { _ in ping() }.store(in: &bag)
        clipboard.$settings.dropFirst().sink { _ in ping() }.store(in: &bag)
        input.$settings.dropFirst().sink { _ in ping() }.store(in: &bag)
        features.$enabled.dropFirst().sink { _ in ping() }.store(in: &bag)
        model.$lastPresetName.dropFirst().sink { _ in ping() }.store(in: &bag)
    }

    /// Starts every installed feature's background work, and follows installs/uninstalls.
    static func startFeatures() {
        input.commands = [("clipboard.open", "Open clipboard history", { clipboard.togglePicker() })]
            + SystemActions.all.map { a in (a.id, a.title, { a.run(input) }) }
            + CommonActions.all.map { a in (a.id, a.title, { a.run(input) }) }
            + WindowAction.allCases.map { a in ("window.\(a.rawValue)", "Window: \(a.title)", { windows.run(a) }) }
        // Without a valid pass nothing runs in the background; features come back the moment one arrives, with no restart.
        let license = LicenseController.shared
        features.$enabled.combineLatest(license.$state).sink { enabled, state in
            let ok = license.skipped || state.isLicensed
            audio.setActive(ok && (enabled.contains(.audio) || enabled.contains(.microphone)))
            windows.setActive(ok && enabled.contains(.windows))
            clipboard.setActive(ok && enabled.contains(.clipboard))
            input.setActive(ok && enabled.contains(.remap))
        }.store(in: &bag)
    }
}

@MainActor
final class MainWindowDelegate: NSObject, NSWindowDelegate {
    /// Closing the window asks nothing. The app keeps running, and anything unsaved stays live and is remembered as left on the stove.
    func windowWillClose(_ notification: Notification) {
        Shared.nav.windowOpen = false
        Shared.recipes.noteLeaving()
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var debugWindow: NSWindow?
    func applicationWillTerminate(_ notification: Notification) {
        Shared.recipes.noteLeaving()          // unsaved changes are still there next time, with the reminder
        Shared.input.shutdown()
    }

    /// A `.whoprrr-setup` file opened from Finder or dropped on the app. The checker runs every time; opening is free to look at.
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.pathExtension == SharedSetupFile.fileExtension { PicklsssController.shared.openFile(u) }
    }

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
        LicenseController.shared.start()
        #if DEBUG
        // Debug only: open a file at launch, as if it had been double-clicked (scripts cannot drive Finder).
        if let f = ProcessInfo.processInfo.environment["WHOPRRR_OPEN_FILE"] { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { PicklsssController.shared.openFile(URL(fileURLWithPath: f)) } }
        #endif
        #if DEBUG
        DebugDriver.startIfRequested()
        #endif
        // First run: open the window on the gear scan, which proposes a starter recipe and then leads to Permissions.
        // Without a valid pass the window opens on "Enter your key" instead, and the gear scan follows the activation.
        let welcomed = "gg.tico.whoprrr.welcomed"
        if ProcessInfo.processInfo.environment["SDC_DEBUG_WINDOW"] != "1" {
            if !LicenseController.shared.isLicensed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Shared.showWindow() }
            } else if !UserDefaults.standard.bool(forKey: welcomed) {
                UserDefaults.standard.set(true, forKey: welcomed)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Shared.showWindow(page: .welcome) }
            }
        }
        // Development aid: SDC_DEBUG_WINDOW=1 shows a view in a normal window (WHOPPER_VIEW=quick for the menu-bar panel).
        if ProcessInfo.processInfo.environment["SDC_DEBUG_WINDOW"] == "1" {
            let quick = ProcessInfo.processInfo.environment["WHOPPER_VIEW"] == "quick"
            var size = quick ? NSSize(width: 400, height: 640) : NSSize(width: 940, height: 700)
            // Screenshots of long pages: WHOPRRR_WINDOW_SIZE=940x1500 makes the debug window taller.
            if let v = ProcessInfo.processInfo.environment["WHOPRRR_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), v.count == 2 { size = NSSize(width: v[0], height: v[1]) }
            let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = DemoData.isOn ? "Whoprrr" : "Whoprrr (debug window)"
            w.contentView = NSHostingView(rootView: quick ? AnyView(Shared.wrap(QuickView())) : AnyView(Shared.wrap(MainWindowView())))
            w.makeKeyAndOrderFront(nil)
            w.isReleasedWhenClosed = false
            Shared.nav.windowOpen = !quick
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

/// The menu-bar panel, or the short "not activated" panel while there is no valid pass.
struct QuickRoot: View {
    @ObservedObject private var license = LicenseController.shared
    var body: some View { if license.isLicensed { QuickView() } else { LicenseQuickView() } }
}

@main
struct WhopperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            Shared.wrap(QuickRoot())
        } label: {
            Image(nsImage: MenuBarIcon.make())
        }
        .menuBarExtraStyle(.window)
    }
}
