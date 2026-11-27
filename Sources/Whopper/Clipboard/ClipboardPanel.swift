import SwiftUI
import AppKit
import ClipboardCore
import WhopperKit

/// Settings page shown inside the menu-bar panel.
struct ClipboardPanel: View {
    @EnvironmentObject var c: ClipboardController
    @State private var newTitle = ""
    @State private var newText = ""
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader("Clipboard", symbol: "doc.on.clipboard", subtitle: "\(c.itemCount) items saved") { PresetMenu(surface: PresetSurfaces.clipboard(c)) }
            Toggle("Record clipboard history", isOn: bind(\.enabled))
            HStack {
                Text("Open history")
                Spacer()
                if c.hotkeyInUse { Image(systemName: "lock.fill").foregroundStyle(.orange).help("Another app owns this shortcut") }
                ShortcutRecorder(shortcut: c.settings.hotkey) { if let s = $0 { c.settings.hotkey = s } }.frame(width: 104, height: 22)
                Button("Show") { c.togglePicker() }.controlSize(.regular)
            }
            Toggle("Paste straight into the front app", isOn: bind(\.autoPaste))
            Toggle("Paste as plain text by default", isOn: bind(\.plainTextByDefault))
            Toggle("Keep images", isOn: bind(\.captureImages))
            Toggle("Keep copied files", isOn: bind(\.captureFiles))
            Stepper("Keep up to \(c.settings.maxItems) items", value: bind(\.maxItems), in: 100...10_000, step: 100)
            Stepper("Forget after \(c.settings.maxAgeDays) days (pinned items stay)", value: bind(\.maxAgeDays), in: 1...365)
            if let n = c.lastNotice { Text(n).font(Brand.caption).foregroundStyle(.orange) }
            accessNote
            Divider()
            Text("NEW SNIPPET").font(Brand.caption).foregroundStyle(.secondary)
            TextField("Name", text: $newTitle).textFieldStyle(.roundedBorder)
            TextField("Text to paste", text: $newText, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            Button("Add snippet") { c.addSnippet(title: newTitle, text: newText); newTitle = ""; newText = "" }
                .disabled(newTitle.isEmpty || newText.isEmpty)
            Divider()
            ignoredApps
            Divider()
            Button("Clear history…", role: .destructive) { confirmClear = true }
                .confirmationDialog("Clear all unpinned history?", isPresented: $confirmClear) {
                    Button("Clear", role: .destructive) { c.clearHistory() }
                }
        }
    }

    private func bind<T>(_ kp: WritableKeyPath<ClipboardSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { c.settings[keyPath: kp] = $0 })
    }

    @ViewBuilder private var accessNote: some View {
        if !c.pasteboardAlwaysAllowed {
            BrandCard {
                Text("macOS may ask each time Whoprrr reads what you copied. Choose Always Allow under Paste from Other Apps to stop the questions.")
                    .font(Brand.caption).fixedSize(horizontal: false, vertical: true)
                Button("Grant Paste from Other Apps") { SetupController.shared.guideGrant(.paste) }.buttonStyle(.brand)
            }
        }
    }

    private var ignoredApps: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text("NEVER RECORD COPIES FROM").font(Brand.caption).foregroundStyle(.secondary); Spacer()
                Button("Add app…") { addApp() }.controlSize(.regular) }
            ForEach(c.settings.ignoredBundles, id: \.self) { b in
                HStack { Text(appName(b)).font(Brand.caption); Spacer()
                    Button { c.settings.ignoredBundles.removeAll { $0 == b } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain) }
            }
            Text("Copies marked concealed by password managers are always skipped.").font(Brand.caption2).foregroundStyle(.secondary)
        }
    }

    private func appName(_ bundle: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { FileManager.default.displayName(atPath: $0.path) } ?? bundle
    }

    private func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications")
        if p.runModal() == .OK, let u = p.url, let id = Bundle(url: u)?.bundleIdentifier, !c.settings.ignoredBundles.contains(id) {
            c.settings.ignoredBundles.append(id)
        }
    }
}
