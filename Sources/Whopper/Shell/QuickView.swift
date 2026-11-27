import SwiftUI
import AppKit
import WhopperKit
import WindowCore
import AudioCore

/// The menu-bar panel: what is happening right now and the things you reach for during the day. Nothing here needs
/// setup; the gear opens the main window for that.
struct QuickView: View {
    @EnvironmentObject var features: FeatureStore
    @EnvironmentObject var input: InputController
    @EnvironmentObject var audio: AudioModel
    @EnvironmentObject var windows: WindowModel
    @EnvironmentObject var clipboard: ClipboardController
    @EnvironmentObject var display: AppModel
    @EnvironmentObject var recipes: RecipeStore
    @EnvironmentObject private var saveBar: SaveBarController
    @ObservedObject private var typingLanguage = Shared.typingLanguage
    @ObservedObject private var setup = SetupController.shared
    @ObservedObject private var updates = UpdateController.shared
    @State private var missing: [Permission] = []
    private let checker: PermissionChecking = LivePermissionChecker()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            recipeRow
            if setup.progress.step != .complete || !setup.parkedFeatures.isEmpty { setupReminder }
            else if !missing.isEmpty { permissionBanner }
            if setup.updateOK { Text("Updated to \(AppInfo.version). Everything was checked and still works.").font(Brand.caption).foregroundStyle(.secondary) }
            else if setup.updateCheckIncomplete {
                Text("Updated to \(AppInfo.version). The check could not finish; features started as before.").font(Brand.caption).foregroundStyle(.secondary)
            }
            let runtime = SetupController.allowed(features.enabled, progress: setup.progress)
            if runtime.contains(.remap) { keysRow }
            if runtime.contains(.clipboard) { clipboardRow }
            if runtime.contains(.windows) { windowsRow }
            if runtime.contains(.audio) { outputRow; inputRow }
            if runtime.contains(.microphone) { micRow }
            if runtime.contains(.display) { displayRow }
            footer
        }
        .padding(16)
        .frame(width: 400)
        .tint(Brand.violetBright)
        // The .window menu-bar style is translucent; without a mostly opaque base, whatever is behind the drawer shows
        // through the faint card and button tints and the small text loses contrast.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.94))
        .onAppear { refreshPermissions(); windows.refreshTrust(); updates.lookQuietly() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
    }

    /// The update line says what it knows: it looks when the panel opens, then reads "Up to date" or names the new version.
    @ViewBuilder private var updateLine: some View {
        switch updates.status {
        case .available(let version):
            Button { Shared.openSection(.about) } label: { Label("Update to \(version)", systemImage: "arrow.down.circle.fill") }
                .buttonStyle(.plain).font(Brand.subheadline.weight(.semibold)).foregroundStyle(Brand.accentText)
                .help("A newer Whoprrr is ready. Click to see what is new and install it.")
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking for updates…") }
                .font(Brand.subheadline).foregroundStyle(.secondary)
        case .upToDate:
            Button { updates.look(force: true) } label: { Label("Up to date", systemImage: "checkmark.circle") }
                .buttonStyle(.plain).font(Brand.subheadline).foregroundStyle(.secondary).help("Click to check again")
        case .failed:
            Button { updates.look(force: true) } label: { Label("Could not check. Try again", systemImage: "exclamationmark.circle") }
                .buttonStyle(.plain).font(Brand.subheadline).foregroundStyle(.secondary)
        case .unknown:
            Button("Check for updates") { updates.look(force: true) }.buttonStyle(.plain).font(Brand.subheadline).foregroundStyle(.secondary)
                .disabled(!updates.canCheck)
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark(size: 38).shadow(color: Brand.violetDeep.opacity(0.35), radius: 4, y: 2)
            Wordmark(size: 24)
            Spacer()
        }
    }

    private var setupReminder: some View {
        BrandCard {
            HStack {
                let names = TasteTest.names(setup.parkedGrants)
                Text(names.isEmpty ? "Finish setup" : "Finish setup · \(names)").font(Brand.subheadline)
                Spacer()
                Button("Continue") {
                    if setup.progress.step == .complete { setup.continueParked() }
                    else { setup.openWindow() }
                }.buttonStyle(.brandQuiet)
            }
        }
    }

    private var permissionBanner: some View {
        BrandCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Needs permission: \(missing.map(\.title).joined(separator: ", "))").font(Brand.subheadline)
                    Button("Review permissions") { Shared.openSection(.permissions) }.buttonStyle(.brand)
                }
            }
        }
    }

    private var recipeRow: some View {
        let connected = Gear.current()
        let active = recipes.active
        var value = "Pick one to set everything up at once"
        if let a = active {
            let g = a.gear(connected: connected)
            if !saveBar.changedSections.isEmpty { value = "Unsaved changes · " + saveBar.changedTitles.joined(separator: ", ") }
            else if a.devices.isEmpty { value = "Not tied to gear" }
            else if g.missing.isEmpty { value = "All gear connected" }
            else { value = "\(g.present.count) of \(a.devices.count) pieces of gear connected" }
        } else if !saveBar.changedSections.isEmpty {
            value = "Unsaved changes · " + saveBar.changedTitles.joined(separator: ", ")
        } else if recipes.recipes.isEmpty { value = "Save your setup for this gear" }
        return VStack(alignment: .leading, spacing: 6) {
            QuickRow(symbol: active?.symbol ?? "fork.knife", title: active?.name ?? "Recipe", value: value, opens: .recipes) {
                if recipes.recipes.count > 1 {
                    Menu {
                        ForEach(recipes.ranked(connected: connected)) { r in
                            Button { recipes.apply(r.id) } label: { Label(r.name, systemImage: r.id == active?.id ? "checkmark" : r.symbol) }
                        }
                        Divider()
                        Button("New recipe from this setup…") { Shared.nav.newRecipeRequested = true; Shared.openSection(.recipes) }
                        Button("Manage recipes…") { Shared.openSection(.recipes) }
                    } label: { Text("Switch") }.menuStyle(.button).buttonStyle(.brandQuiet).fixedSize()
                }
            }
            let typingForThisRecipe = typingLanguage.lastAppliedRecipeID == active?.id
            if let note = (typingForThisRecipe ? typingLanguage.note : nil) ?? recipes.notice {
                Text(note).font(Brand.caption).foregroundStyle(Brand.accentText).padding(.horizontal, 4)
            }
            if typingForThisRecipe, let note = typingLanguage.skippedNote {
                Text(note).font(Brand.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }

    private var keysRow: some View {
        let paused = input.status == .paused
        let running = input.status == .running
        return QuickRow(symbol: "keyboard", title: "Keys and mouse", value: keysValue, opens: .feature(.remap)) {
            if running || paused {
                Button(paused ? "Resume" : "Pause") { input.setPaused(!paused) }.buttonStyle(.brandQuiet)
            }
        }
    }
    private var keysValue: String {
        let n = input.settings.rules.filter(\.enabled).count
        switch input.status {
        case .running: return "\(n) rule\(n == 1 ? "" : "s") active"
        case .paused: return "Paused"
        case .off: return "Off"
        case .needsAccessibility, .needsInputMonitoring: return "Needs permission"
        case .failed: return "Could not start"
        }
    }

    private var clipboardRow: some View {
        QuickRow(symbol: "doc.on.clipboard", title: "Clipboard", value: "\(clipboard.itemCount) saved · \(clipboard.settings.hotkey.display)", opens: .feature(.clipboard)) {
            Button("Open") { clipboard.togglePicker() }.buttonStyle(.brandQuiet)
        }
    }

    /// The layouts the user picked in Settings > Windows (a sensible default set until then), eight to a line.
    private var windowsRow: some View {
        let tiles = windows.settings.drawer
        let rows = stride(from: 0, to: tiles.count, by: 8).map { Array(tiles[$0..<min($0 + 8, tiles.count)]) }
        return BrandCard {
            HStack { Text("Window").font(Brand.display(15, .semibold)); Spacer()
                Button { Shared.openSection(.feature(.windows)) } label: { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Brand.accentText).help("Open Windows settings") }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(Array(row.enumerated()), id: \.element) { i, a in
                        Button { windows.runOnPreviousApp(a) } label: {
                            WindowGlyph(action: a).frame(maxWidth: .infinity).frame(height: 34)
                                .background(Brand.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .foregroundStyle(Color.white)
                        }.buttonStyle(.plain)
                            .hoverTip(windows.shortcut(a).map { "\(a.title)  \($0.display)" } ?? a.title,
                                      anchor: i < 2 ? .topLeading : (i >= row.count - 2 && row.count > 4 ? .topTrailing : .top))
                    }
                    // Keep a short last line the same tile width as a full one.
                    ForEach(0..<(row.count < 8 && rows.count > 1 ? 8 - row.count : 0), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity).frame(height: 34) }
                }
            }
            if tiles.isEmpty { Text("No layouts picked. Star some in Settings > Windows.").font(Brand.caption).foregroundStyle(.secondary) }
            if !windows.trusted { Text("Needs Accessibility to move windows.").font(Brand.caption).foregroundStyle(.orange) }
        }
    }

    private var outputRow: some View {
        let name = audio.defaultOutputUID.map(audio.name(for:)) ?? "No output"
        return QuickRow(symbol: "speaker.wave.2", title: name, value: eqValue, opens: .feature(.audio)) {
            Toggle("", isOn: Binding(get: { audio.settings.eq.enabled }, set: { audio.settings.eq.enabled = $0 })).toggleStyle(.switch).labelsHidden()
        }
    }
    private var eqValue: String {
        switch audio.eqState {
        case .off: return audio.settings.eq.enabled ? "Equalizer starting…" : "Equalizer off"
        case .running: return "Equalizer on"
        case .unavailable(let why): return why
        case .failed: return "Equalizer failed"
        }
    }

    private var inputRow: some View {
        let name = audio.defaultInputUID.map(audio.name(for:)) ?? "No input"
        return QuickRow(symbol: "mic", title: name, value: audio.settings.inputPin.enabled ? "Pinned as your input" : "Follows macOS", opens: .feature(.audio)) {
            Toggle("", isOn: Binding(get: { audio.settings.inputPin.enabled }, set: { audio.settings.inputPin.enabled = $0 })).toggleStyle(.switch).labelsHidden()
        }
    }

    private var micRow: some View {
        QuickRow(symbol: "waveform", title: "Whoprrr Mic", value: micValue, opens: .feature(.microphone)) {
            Toggle("", isOn: Binding(get: { audio.settings.mic.enabled }, set: { audio.enableMic($0) })).toggleStyle(.switch).labelsHidden()
        }
    }
    private var micValue: String {
        switch audio.micState {
        case .off: return audio.driverInstalled ? "Off" : "Driver not installed"
        case .running: return "Processing your mic"
        case .driverMissing: return "Driver not loaded"
        case .sourceMissing: return "Mic not found"
        case .failed: return "Failed"
        }
    }

    private var displayRow: some View {
        let presets = display.presetsForSelected()
        return QuickRow(symbol: "display", title: display.selected?.identity.productName ?? "External display", value: display.selected == nil ? "Open Settings to pick it" : "\(presets.count) preset\(presets.count == 1 ? "" : "s")", opens: .feature(.display)) {
            if !presets.isEmpty {
                Menu("Preset") { ForEach(presets) { p in Button(p.name) { display.apply(p) } } }
                    .menuStyle(.button).buttonStyle(.brandQuiet).fixedSize()
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Open main window") { Shared.showWindow() }.buttonStyle(.brand).keyboardShortcut("o")
                    .background {
                        Button("Open main window") { Shared.showWindow() }.keyboardShortcut(",")
                            .opacity(0).accessibilityHidden(true).allowsHitTesting(false)
                    }
                Spacer()
                Button(AppInfo.shortVersionLine) { Shared.openSection(.about) }
                    .buttonStyle(.plain).font(Brand.caption).foregroundStyle(Brand.accentText)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(Brand.subheadline).foregroundStyle(.secondary).keyboardShortcut("q")
            }
            if updates.isAvailable { updateLine }
        }
        .padding(.top, 2)
    }

    private func refreshPermissions() {
        // Camera and Microphone ask by themselves the first time they are used, and Paste can ask each time,
        // so "not asked yet" is a problem only for grants that never ask on their own.
        let grants = Set(setup.requirements(for: features.enabled).values.flatMap { $0 })
        missing = grants.sorted { $0.title < $1.title }.filter { TasteTest.definitelyBlocked($0, checker.status($0)) }
    }
}

/// One line of the menu-bar panel: tile, title, value, and an optional control on the right.
struct QuickRow<Trailing: View>: View {
    var symbol: String, title: String, value: String
    /// Where a click on the row (anywhere except its own controls) opens in the main window.
    var opens: AppPage?
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        BrandCard {
            HStack(spacing: 12) {
                if let opens {
                    Button { Shared.openSection(opens) } label: { description }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(title)")
                } else {
                    description
                }
                Spacer(minLength: 6)
                trailing()
            }
        }
    }

    private var description: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 36, height: 36)
                .foregroundStyle(Color.white).background(Brand.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Brand.display(15, .semibold)).lineLimit(1)
                Text(value).font(Brand.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Remembers which window hosts the menu-bar drawer, so the main window can open right beside it.
struct DrawerWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Reader() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class Reader: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); Shared.drawerWindow = window }
    }
}


/// A little screen with one zone filled in: where a window will go.
struct ZoneGlyph: View {
    var x: CGFloat, width: CGFloat
    var y: CGFloat = 0, height: CGFloat = 1
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(x: 0.75, y: 0.75, width: size.width - 1.5, height: size.height - 1.5)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 3.5), with: .foreground, lineWidth: 1.4)
            let inset: CGFloat = 2.5
            let inner = r.insetBy(dx: inset, dy: inset)
            let zone = CGRect(x: inner.minX + inner.width * x, y: inner.minY + inner.height * y, width: inner.width * width, height: inner.height * height)
            ctx.fill(Path(roundedRect: zone.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1.5), with: .foreground)
        }
        .frame(width: 28, height: 19)
    }
}
