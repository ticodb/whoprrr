import SwiftUI
import AppKit
import Carbon.HIToolbox
import WhopperKit

/// Click, press a combination to record it. Esc cancels, Delete clears.
struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: Shortcut?
    /// Global hotkeys need a modifier; a remap output may be a bare key.
    var requireModifier = true
    var onChange: (Shortcut?) -> Void

    func makeNSView(context: Context) -> RecorderField {
        let v = RecorderField(); v.onChange = onChange; v.requireModifier = requireModifier; return v
    }
    func updateNSView(_ v: RecorderField, context: Context) { v.onChange = onChange; v.requireModifier = requireModifier; v.shortcut = shortcut; v.refresh() }

    final class RecorderField: NSButton {
        var shortcut: Shortcut?
        var onChange: ((Shortcut?) -> Void)?
        var requireModifier = true
        private var recording = false { didSet { refresh() } }

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded; controlSize = .small; font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            target = self; action = #selector(toggle)
        }
        required init?(coder: NSCoder) { fatalError() }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 104, height: 22) }

        @objc private func toggle() { recording.toggle(); if recording { window?.makeFirstResponder(self) } }
        override func resignFirstResponder() -> Bool { recording = false; return super.resignFirstResponder() }

        func refresh() { title = recording ? "Press keys…" : (shortcut?.display ?? "None") }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return false }
            keyDown(with: event); return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            let code = Int(event.keyCode)
            if code == kVK_Escape { recording = false; return }
            if code == kVK_Delete || code == kVK_ForwardDelete, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                shortcut = nil; onChange?(nil); recording = false; return
            }
            let f = event.modifierFlags
            var m: UInt32 = 0
            if f.contains(.command) { m |= Shortcut.cmd }
            if f.contains(.option) { m |= Shortcut.opt }
            if f.contains(.control) { m |= Shortcut.ctrl }
            if f.contains(.shift) { m |= Shortcut.shift }
            guard m != 0 || !requireModifier else { NSSound.beep(); return }   // a global shortcut needs at least one modifier
            let s = Shortcut(code, m)
            shortcut = s; onChange?(s); recording = false
        }
    }
}
