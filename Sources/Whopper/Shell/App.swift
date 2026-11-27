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
    static let typingLanguage = TypingLanguageController()
    static let backups = BackupController()
    static let saveBar = SaveBarController(store: recipes)
    static let presets = PresetLibrary(recipes: recipes)
    static let presetActions = PresetActions()
    private static let featuresSurface = FeaturesSurface(features)
    private static let displaySurface = DisplaySurface(model)
    private static var gearTimer: Timer?
    private static var lastGear: [String] = []
    private static var window: NSWindow?
    private static let windowDelegate = MainWindowDelegate()

    /// Every object the views read from the environment.
    static func wrap<V: View>(_ v: V) -> some View {
        v.environmentObject(model).environmentObject(features).environmentObject(audio).environmentObject(windows)
            .environmentObject(clipboard).environmentObject(input).environmentObject(nav).environmentObject(recipes).environmentObject(saveBar).environmentObject(presets).environmentObject(presetActions)
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
    /// `activate: false` puts the window on screen without taking focus from the app the person is typing in,
    /// so no keystroke meant for another app can press a button here.
    static var windowIsKey: Bool { window?.isKeyWindow == true && NSApp.isActive }

    static func showWindow(page: AppPage? = nil, activate: Bool = true) {
        SetupController.shared.refreshGrants()
        SetupController.shared.reconcileSetupGrants()
        let drawer = drawerFrame()          // read before activating: activating can close the drawer
        let wasVisible = window?.isVisible == true
        let movesSpace = wasVisible && window?.isOnActiveSpace == false
        if drawer != nil { drawerWindow?.orderOut(nil) }
        if movesSpace { window?.orderOut(nil) }
        if let page { nav.page = page }
        else if !wasVisible, let part = saveBar.takeLandingPart() {
            nav.page = AppPage.page(forRecipePart: part, features: features)
        }
        nav.windowOpen = true
        NSApp.setActivationPolicy(.regular)
        let w: NSWindow
        if let existing = window { w = existing } else {
            w = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
            w.title = "Whoprrr"
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.titlebarAppearsTransparent = true
            w.contentView = NSHostingView(rootView: wrap(MainWindowView()))
            w.isReleasedWhenClosed = false
            w.delegate = windowDelegate
            w.setFrameAutosaveName("WhoprrrMainWindow")
            if !w.setFrameUsingName("WhoprrrMainWindow") { w.center() }
            window = w
        }
        if (!wasVisible || movesSpace), let drawer,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(drawer) }) ?? NSScreen.main {
            w.setFrame(PanelPlacement.frame(beside: drawer, size: w.frame.size, visible: screen.visibleFrame), display: true)
        }
        if activate {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            w.orderFrontRegardless()
        }
    }

    /// Makes every settings surface available to recipes, and switches recipes automatically when the connected gear changes.
    static func startRecipes() {
        for s in [audio as RecipeSurface, windows, clipboard, input, featuresSurface, displaySurface] { recipes.register(s) }
        watchSettingsForSaveBar()
        if ProcessInfo.processInfo.environment["WHOPPER_NO_START"] != "1" {
            typingLanguage.start()
            recipes.onApplyRecipe = { recipe, automatic, hadActiveRecipe in
                typingLanguage.apply(recipe, automatic: automatic, hadActiveRecipe: hadActiveRecipe)
            }
        }
        saveBar.start(sections: SaveBarSurfaces.sections)
        recipes.additionalDraftSections = {
            saveBar.settingsDidChange()
            return Dictionary(saveBar.editedSections.map { ($0.recipePart, $0.title) }, uniquingKeysWith: { $0 + ", " + $1 })
        }
        saveBar.noteLeaving()
        PicklsssController.shared.start()
        gearTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard LicenseController.shared.isLicensed, SetupController.shared.canAutoSwitch else { return }
                let now = Gear.current()
                let ids = now.map(\.id).sorted()
                guard ids != lastGear else { return }
                lastGear = ids
                // Switches by itself when that loses nothing; with unsaved changes it asks first (the question shows in the main window).
                recipes.considerAutoSwitch(connected: now)
            }
        }
    }

    /// Coalesces synchronous changes and reads the resulting settings after their publishers finish.
    private static var checkPending = false
    private static func watchSettingsForSaveBar() {
        let ping: () -> Void = {
            guard !recipes.isCapturing, !checkPending else { return }
            checkPending = true
            DispatchQueue.main.async { checkPending = false; saveBar.settingsDidChange() }
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
        let setup = SetupController.shared
        features.$enabled.combineLatest(setup.$progress, license.$state).sink { enabled, progress, state in
            let runtime = license.skipped || state.isLicensed ? SetupController.allowed(enabled, progress: progress) : []
            audio.setActive(audio: runtime.contains(.audio), mic: runtime.contains(.microphone))
            windows.setActive(runtime.contains(.windows))
            clipboard.setActive(runtime.contains(.clipboard))
            input.setActive(runtime.contains(.remap))
        }.store(in: &bag)
    }

    static func startSetup() {
        let license = LicenseController.shared
        let setup = SetupController.shared
        license.$state.map { license.skipped || $0.isLicensed }.removeDuplicates().sink { licensed in
            guard licensed else { return }
            // The publisher emits before the stored state changes.
            Task { @MainActor in
                guard license.isLicensed else { return }
                model.startDevices()
                audio.startDevices()
                setup.beginLicensedLaunch()
                backups.openAfterActivation()
            }
        }.store(in: &bag)
    }
}

/// A document shortcut that also works when the save mark is outside the scroll viewport.
final class MainWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard attachedSheet == nil, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s":
            if Shared.saveBar.save() { return true }
        case "u":
            if let (surface, entry) = Shared.presetActions.editedPreset(on: Shared.nav.page, in: Shared.presets) {
                Shared.presetActions.update(entry, on: surface)
                return true
            }
        default: break
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class MainWindowDelegate: NSObject, NSWindowDelegate {
    /// Closing the window asks nothing. The app keeps running, and anything unsaved stays live and is remembered as left on the stove.
    func windowWillClose(_ notification: Notification) {
        SetupController.shared.windowClosed()
        Shared.nav.windowOpen = false
        Shared.saveBar.noteLeaving()
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var debugWindow: NSWindow?
    private var backupRecoveryFailed = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        do { try BackupController.recoverInterruptedRestore() }
        catch { backupRecoveryFailed = true }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !backupRecoveryFailed else { return }
        Shared.saveBar.noteLeaving()
        Shared.input.shutdown()
    }

    /// Document files opened from Finder or dropped on the app are checked before presenting any actions.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !backupRecoveryFailed else { return }
        for url in urls {
            if url.scheme?.lowercased() == "whoprrr" {
                // Any web page can open this scheme. A malformed link is ignored without showing anything.
                guard let code = SetupCode.fromActivationURL(url) else { continue }
                Shared.showWindow()
                Task { await LicenseController.shared.activate(setupCode: code) }
            } else if url.isFileURL, url.pathExtension == SharedSetupFile.fileExtension {
                PicklsssController.shared.openFile(url)
            } else if url.isFileURL, url.pathExtension == WhopperBackup.fileExtension {
                Shared.backups.open(url)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if backupRecoveryFailed {
            let alert = NSAlert()
            alert.messageText = "Whoprrr could not finish recovering its settings"
            alert.informativeText = "Check that the Whopper folder in Application Support is writable and reopen Whoprrr. The pre-restore copy is in Backup Recovery."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)      // menu bar only, no Dock icon
        // WHOPPER_RENDER_ICON=/dir writes the brand artwork (iconset, icns, PNGs) and exits. See docs/brand.
        if let dir = ProcessInfo.processInfo.environment["WHOPPER_RENDER_ICON"] { BrandAssets.render(to: dir); NSApp.terminate(nil); return }
        // WHOPPER_NO_START=1 renders the UI without starting any background feature (used for screenshots).
        Shared.startRecipes()
        UpdateController.shared.start()
        DemoData.seedAfterGearLoads()
        if let ap = ProcessInfo.processInfo.environment["WHOPPER_APPEARANCE"] { NSApp.appearance = NSAppearance(named: ap == "light" ? .aqua : .darkAqua) }
        if ProcessInfo.processInfo.environment["WHOPPER_NO_START"] != "1" { Shared.startFeatures() }
        Shared.startSetup()
        LicenseController.shared.start()
        #if DEBUG
        // Debug only: open a file at launch, as if it had been double-clicked (scripts cannot drive Finder).
        if let f = ProcessInfo.processInfo.environment["WHOPRRR_OPEN_FILE"] { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { PicklsssController.shared.openFile(URL(fileURLWithPath: f)) } }
        #endif
        #if DEBUG
        DebugDriver.startIfRequested()
        #endif
        if ProcessInfo.processInfo.environment["SDC_DEBUG_WINDOW"] != "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if SetupController.shared.showsSetup { Shared.showWindow() }
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
