import SwiftUI
import AppKit
import ClipboardCore

/// The floating history picker. Non-activating: the app you were typing in stays in front, so a paste
/// lands where you were.
@MainActor
final class PickerPanel: NSPanel {
    let model: PickerModel
    private var keyMonitor: Any?

    init(store: ClipStore, controller: ClipboardController) {
        model = PickerModel(store: store, controller: controller)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        level = .popUpMenu; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: PickerView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 460)
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.midY - frame.height / 2 + f.height * 0.1))
        }
        model.reload()
        makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isKeyWindow else { return e }
            return self.model.handle(e) ? nil : e
        }
    }

    override func resignKey() { super.resignKey(); close() }

    override func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        super.close()
    }
}

@MainActor
final class PickerModel: ObservableObject {
    private let store: ClipStore
    private unowned let controller: ClipboardController
    @Published var query = "" { didSet { if query != oldValue { reload() } } }
    @Published var filter: ClipListFilter = .all { didSet { if filter != oldValue { reload() } } }
    @Published private(set) var items: [ClipItem] = []
    @Published var selected: Int64?

    init(store: ClipStore, controller: ClipboardController) { self.store = store; self.controller = controller }

    func reload() {
        items = store.list(filter: filter, query: query, limit: 300)
        if let s = selected, items.contains(where: { $0.id == s }) { return }
        selected = items.first?.id
    }

    var selectedItem: ClipItem? { items.first { $0.id == selected } }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let i = items.firstIndex { $0.id == selected } ?? 0
        selected = items[min(max(i + delta, 0), items.count - 1)].id
    }

    func choose(_ item: ClipItem, plain: Bool = false) { controller.choose(item, plain: plain) }

    func togglePin(_ item: ClipItem) { store.setPinned(item.id, !item.pinned); reload() }
    func delete(_ item: ClipItem) {
        let i = items.firstIndex { $0.id == item.id } ?? 0
        store.delete(item.id); reload()
        if !items.isEmpty { selected = items[min(i, items.count - 1)].id }
    }

    /// Returns true when the key was consumed.
    func handle(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 126: move(-1); return true                                    // up
        case 125: move(1); return true                                     // down
        case 36, 76: if let s = selectedItem { choose(s, plain: shift) }; return true   // return
        case 53: NSApp.keyWindow?.close(); return true                     // esc
        case 48: cycleFilter(shift ? -1 : 1); return true                  // tab
        case 51 where cmd: if let s = selectedItem { delete(s) }; return true   // cmd-delete
        default: break
        }
        if cmd, let ch = e.charactersIgnoringModifiers {
            if ch == "p", let s = selectedItem { togglePin(s); return true }
            if let n = Int(ch), (1...9).contains(n), n <= items.count { choose(items[n - 1], plain: shift); return true }
        }
        return false
    }

    private func cycleFilter(_ d: Int) {
        let all = ClipListFilter.allCases
        let i = all.firstIndex(of: filter) ?? 0
        filter = all[(i + d + all.count) % all.count]
    }
}
