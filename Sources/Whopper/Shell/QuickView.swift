import SwiftUI
import AppKit
import WhopperKit
import WindowCore
import AudioCore

/// The menu-bar panel: what is happening right now and the things you reach for during the day. Nothing here needs
/// setup; "Settings…" opens the main window for that.
struct QuickView: View {
    @EnvironmentObject var features: FeatureStore
    @EnvironmentObject var input: InputController
    @EnvironmentObject var audio: AudioModel
    @EnvironmentObject var windows: WindowModel
    @EnvironmentObject var clipboard: ClipboardController
    @EnvironmentObject var display: AppModel
    @EnvironmentObject var recipes: RecipeStore
    @State private var missing: [Permission] = []
    private let checker: PermissionChecking = LivePermissionChecker()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            recipeRow
            if !missing.isEmpty { permissionBanner }
            if features.isEnabled(.remap) { keysRow }
            if features.isEnabled(.clipboard) { clipboardRow }
            if features.isEnabled(.windows) { windowsRow }
            if features.isEnabled(.audio) { outputRow; inputRow }
            if features.isEnabled(.microphone) { micRow }
            if features.isEnabled(.display) { displayRow }
            footer
        }
        .padding(16)
        .frame(width: 400)
        .tint(Brand.violetBright)
        .onAppear { refreshPermissions(); windows.refreshTrust() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark(size: 38).shadow(color: Brand.violetDeep.opacity(0.35), radius: 4, y: 2)
            Wordmark(size: 24)
            Spacer()
            Button { Shared.showWindow() } label: { Image(systemName: "gearshape").font(.system(size: 16, weight: .medium)) }
                .buttonStyle(.plain).help("Settings (⌘,)").foregroundStyle(.secondary)
        }
    }

    private var permissionBanner: some View {
        BrandCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Needs permission: \(missing.map(\.title).joined(separator: ", "))").font(Brand.subheadline)
                    Button("Review permissions") { Shared.showWindow(page: .permissions) }.buttonStyle(.brand)
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
            if recipes.isModified(a.id) { value = "Settings changed since applied" }
            else if a.devices.isEmpty { value = "Not tied to gear" }
            else if g.missing.isEmpty { value = "All gear connected" }
            else { value = "\(g.present.count) of \(a.devices.count) pieces of gear connected" }
        } else if recipes.recipes.isEmpty { value = "Save your setup for this gear" }
        return VStack(alignment: .leading, spacing: 6) {
            QuickRow(symbol: active?.symbol ?? "fork.knife", title: active?.name ?? "Recipe", value: value, opens: .recipes) {
                Menu {
                    ForEach(recipes.ranked(connected: connected)) { r in
                        Button { recipes.apply(r.id) } label: { Label(r.name, systemImage: r.id == active?.id ? "checkmark" : r.symbol) }
                    }
                    if !recipes.recipes.isEmpty { Divider() }
                    Button("New recipe from this setup…") { Shared.nav.newRecipeRequested = true; Shared.showWindow(page: .recipes) }
                    Button("Manage recipes…") { Shared.showWindow(page: .recipes) }
                } label: { Text("Switch") }.menuStyle(.button).buttonStyle(.brandQuiet).fixedSize()
            }
            if let n = recipes.notice { Text(n).font(Brand.caption).foregroundStyle(Brand.accentText).padding(.horizontal, 4) }
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

    private var windowsRow: some View {
        BrandCard {
            HStack { Text("Window").font(Brand.display(15, .semibold)); Spacer()
                Button { Shared.showWindow(page: .feature(.windows)) } label: { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open Windows settings") }
            HStack(spacing: 6) {
                ForEach([(WindowAction.leftHalf, "rectangle.lefthalf.inset.filled"), (.rightHalf, "rectangle.righthalf.inset.filled"),
                         (.topHalf, "rectangle.tophalf.inset.filled"), (.bottomHalf, "rectangle.bottomhalf.inset.filled"),
                         (.maximize, "arrow.up.left.and.arrow.down.right"), (.center, "rectangle.center.inset.filled"),
                         (.nextDisplay, "display.2"), (.restore, "arrow.uturn.backward")], id: \.0) { a, sym in
                    Button { windows.runOnPreviousApp(a) } label: {
                        Image(systemName: sym).font(.system(size: 16)).frame(maxWidth: .infinity).frame(height: 34)
                            .background(Brand.violet.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .foregroundStyle(Brand.accentText)
                    }.buttonStyle(.plain).help(a.title)
                }
            }
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
        return QuickRow(symbol: "display", title: display.selected?.identity.productName ?? "Samsung display", value: display.selected == nil ? "Open Settings to pick it" : "\(presets.count) preset\(presets.count == 1 ? "" : "s")", opens: .feature(.display)) {
            if !presets.isEmpty {
                Menu("Preset") { ForEach(presets) { p in Button(p.name) { display.apply(p) } } }
                    .menuStyle(.button).buttonStyle(.brandQuiet).fixedSize()
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { Shared.showWindow() }.buttonStyle(.brand).keyboardShortcut(",")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(Brand.subheadline).foregroundStyle(.secondary).keyboardShortcut("q")
        }
        .padding(.top, 2)
    }

    private func refreshPermissions() {
        // Camera and Microphone ask by themselves the first time they are used, so "not asked yet" is not a problem.
        missing = features.neededPermissions.sorted { $0.title < $1.title }.filter { p in
            let s = checker.status(p)
            return s == .denied || (s == .notDetermined && p != .camera && p != .microphone)
        }
    }
}

/// One line of the menu-bar panel: tile, title, value, and an optional control on the right.
struct QuickRow<Trailing: View>: View {
    var symbol: String, title: String, value: String
    /// Where a click on the row (anywhere except its own controls) opens in the main window.
    var opens: AppPage?
    @ViewBuilder var trailing: () -> Trailing
    @State private var hover = false
    var body: some View {
        BrandCard {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 36, height: 36)
                    .foregroundStyle(Brand.accentText).background(Brand.violet.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Brand.display(15, .semibold)).lineLimit(1)
                    Text(value).font(Brand.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 6)
                trailing()
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.violetBright.opacity(hover && opens != nil ? 0.55 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hover = $0 }
        .onTapGesture { if let opens { Shared.showWindow(page: opens) } }
        .help(opens == nil ? "" : "Open in Settings")
    }
}
