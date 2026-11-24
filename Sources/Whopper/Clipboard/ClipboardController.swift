import SwiftUI
import AppKit
import ClipboardCore
import WhopperKit

@MainActor
final class ClipboardController: ObservableObject {
    private let settingsStore = JSONStore<ClipboardSettings>(name: "clipboard")
    private var store: ClipStore?
    private var watcher: PasteboardWatcher?
    private var hotkeyToken: UInt32?
    private var panel: PickerPanel?
    private(set) var active = false

    @Published var settings: ClipboardSettings { didSet { if settings != oldValue { settingsStore.save(settings); if active { registerHotkey() } } } }
    @Published private(set) var itemCount = 0
    @Published private(set) var hotkeyInUse = false
    @Published private(set) var lastNotice: String?

    init() { settings = settingsStore.load(default: ClipboardSettings()) }

    /// False when macOS 15.4+ may prompt every time we read the pasteboard.
    var pasteboardAlwaysAllowed: Bool {
        if #available(macOS 15.4, *) { return NSPasteboard.general.accessBehavior == .alwaysAllow }
        return true
    }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            do {
                let s = try ClipStore(directory: ClipStore.defaultDirectory())
                store = s
                let w = PasteboardWatcher(store: s, settings: { [weak self] in self?.settings ?? ClipboardSettings() })
                w.onCapture = { [weak self] in self?.refreshCount() }
                w.start(); watcher = w
                registerHotkey(); refreshCount()
            } catch { lastNotice = "Could not open the history database: \(error)"; active = false }
        } else {
            watcher?.stop(); watcher = nil
            if let t = hotkeyToken { HotKeyCenter.shared.unregister(t); hotkeyToken = nil }
            panel?.close(); panel = nil; store = nil
        }
    }

    private func refreshCount() { itemCount = store?.count() ?? 0 }

    private func registerHotkey() {
        if let t = hotkeyToken { HotKeyCenter.shared.unregister(t); hotkeyToken = nil }
        let r = HotKeyCenter.shared.register(settings.hotkey) { [weak self] in MainActor.assumeIsolated { self?.togglePicker() } }
        hotkeyToken = r.token; hotkeyInUse = r.result != .ok
    }

    func togglePicker() {
        guard let store else { return }
        if let p = panel, p.isVisible { p.close(); return }
        let p = PickerPanel(store: store, controller: self)
        panel = p
        p.present()
    }

    // MARK: Used by the picker

    /// Puts the item on the pasteboard and, when allowed, pastes it into the app that was in front.
    func choose(_ item: ClipItem, plain: Bool) {
        guard let store, let payload = store.payload(item.id) else { return }
        let count = Paster.write(payload, imagesDir: store.imagesDir, plain: plain || settings.plainTextByDefault && payload.kind == .text)
        watcher?.ignore(changeCount: count)
        store.markUsed(item.id)
        panel?.close()
        guard settings.autoPaste else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            if case .copiedOnly(let why) = Paster.postPaste() { self?.lastNotice = why }
        }
    }

    func addSnippet(title: String, text: String) { _ = store?.addSnippet(title: title, text: text); refreshCount() }
    func clearHistory() { store?.clearUnpinned(); refreshCount() }
}
