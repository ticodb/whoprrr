import SwiftUI
import AppKit
import InputCore
import WhopperKit

/// Click, then press a key (with modifiers), a modifier on its own, or a mouse button to use it as a trigger.
struct TriggerRecorder: View {
    @Binding var trigger: Trigger
    @Binding var mods: Mods
    /// Raw keyboard type of the last key recorded, so the rule editor can offer "only on this keyboard".
    var onKeyboard: (Int) -> Void = { _ in }
    @EnvironmentObject var input: InputController
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Press a key or mouse button…" : mods.symbols + label).frame(minWidth: 170)
            }
            Button(input.learningLogitech ? "Press the mouse button… (cancel)" : "Learn Logitech button") {
                if input.learningLogitech { input.cancelLearn() } else { input.learnLogitech { trigger = .logi($0); mods = [] } }
            }.controlSize(.regular)
            Menu("Pick…") {
                if input.logiDevices.isEmpty { Text("No Logitech device found") }
                ForEach(input.logiDevices) { d in
                    Menu(d.name) {
                        ForEach(d.controls.filter(\.isDivertable)) { c in
                            Button(c.name) { trigger = .logi(Int(c.cid)); mods = [] }
                        }
                    }
                }
            }.controlSize(.regular).fixedSize()
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if case .logi(let c) = trigger {
            for d in input.logiDevices { if let ctl = d.controls.first(where: { Int($0.cid) == c }) { return "\(d.name): \(ctl.name)" } }
        }
        return trigger.label
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { e in
            switch e.type {
            case .keyDown:
                if e.keyCode == 53 && e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { stop(); return nil }
                trigger = .key(Int(e.keyCode)); mods = Mods(cg: CGEventFlags(rawValue: UInt64(e.modifierFlags.rawValue))).intersection(.main)
                if let kb = e.cgEvent?.getIntegerValueField(.keyboardEventKeyboardType) { onKeyboard(Int(kb)) }
                stop()
                return nil
            case .flagsChanged:
                let code = Int(e.keyCode)
                if let m = ModifierKey.mods(for: code), Mods(cg: CGEventFlags(rawValue: UInt64(e.modifierFlags.rawValue))).contains(m) {
                    trigger = .key(code); mods = []; stop()
                }
                return nil
            case .otherMouseDown:
                trigger = .mouse(Int(e.buttonNumber)); mods = Mods(cg: CGEventFlags(rawValue: UInt64(e.modifierFlags.rawValue))).intersection(.main); stop()
                return nil
            default: return e
            }
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

enum OutKind: String, CaseIterable, Identifiable {
    case chord = "Key combo", text = "Type text", sequence = "Key sequence", modifiers = "Modifiers (while held)", layer = "Layer (while held)", media = "Media key",
         mouse = "Mouse button", command = "Whoprrr command", app = "Open app", url = "Open URL", shell = "Shell command", nothing = "Nothing"
    var id: String { rawValue }
    init(_ o: Output) {
        switch o {
        case .chord: self = .chord; case .modifiers: self = .modifiers; case .layer: self = .layer; case .media: self = .media
        case .mouseButton: self = .mouse; case .command: self = .command; case .openApp: self = .app; case .openURL: self = .url
        case .shell: self = .shell; case .nothing: self = .nothing
        case .text: self = .text; case .sequence: self = .sequence
        }
    }
    var blank: Output {
        switch self {
        case .chord: .chord(Chord(53)); case .modifiers: .modifiers(.control); case .layer: .layer("nav"); case .media: .media(.playPause)
        case .mouse: .mouseButton(2); case .command: .command("clipboard.open"); case .app: .openApp("com.apple.finder")
        case .url: .openURL("https://"); case .shell: .shell(""); case .nothing: .nothing
        case .text: .text("."); case .sequence: .sequence([Chord(14, .option), Chord(0)])
        }
    }
}

struct OutputEditor: View {
    @Binding var output: Output
    @EnvironmentObject var input: InputController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(get: { OutKind(output) }, set: { k in if k != OutKind(output) { output = k.blank } })) {
                ForEach(OutKind.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden()
            detail
        }
    }

    @ViewBuilder private var detail: some View {
        switch output {
        case .chord(let c):
            HStack {
                ShortcutRecorder(shortcut: Shortcut(c.key, carbon(c.mods)), requireModifier: false) { s in
                    if let s { output = .chord(Chord(Int(s.keyCode), Mods(carbon: s.modifiers))) }
                }.frame(width: 140, height: 22)
                Text("Click, then press the keys").font(Brand.caption2).foregroundStyle(.secondary)
            }
        case .text(let t):
            VStack(alignment: .leading, spacing: 3) {
                TextField("Text to type, e.g. .", text: Binding(get: { t }, set: { output = .text($0) })).textFieldStyle(.roundedBorder)
                Text("Typed as real characters, so it comes out the same on any keyboard layout or regional setting.").font(Brand.caption2).foregroundStyle(.secondary)
            }
        case .sequence(let chords):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(chords.enumerated()), id: \.offset) { i, c in
                    HStack {
                        Text("\(i + 1).").font(Brand.caption.monospacedDigit()).foregroundStyle(.secondary)
                        ShortcutRecorder(shortcut: Shortcut(c.key, carbon(c.mods)), requireModifier: false) { s in
                            if let s { var n = chords; n[i] = Chord(Int(s.keyCode), Mods(carbon: s.modifiers)); output = .sequence(n) }
                        }.frame(width: 140, height: 22)
                        Button { var n = chords; n.remove(at: i); output = .sequence(n.isEmpty ? [Chord(53)] : n) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                Button("Add key") { output = .sequence(chords + [Chord(49)]) }.buttonStyle(.brandQuiet)
                Text("Pressed one after another. ⌥E then A types á on a US layout.").font(Brand.caption2).foregroundStyle(.secondary)
            }
        case .modifiers(let m):
            HStack(spacing: 10) {
                modToggle("⌃", .control, m); modToggle("⌥", .option, m); modToggle("⇧", .shift, m); modToggle("⌘", .command, m)
                Button("Hyper") { output = .modifiers(.hyper) }.controlSize(.regular)
            }
        case .layer(let n):
            TextField("Layer name", text: Binding(get: { n }, set: { output = .layer($0) })).textFieldStyle(.roundedBorder)
        case .media(let k):
            Picker("", selection: Binding(get: { k }, set: { output = .media($0) })) { ForEach(MediaKey.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
        case .mouseButton(let b):
            Stepper("Button \(b + 1)", value: Binding(get: { b }, set: { output = .mouseButton($0) }), in: 2...15)
        case .command(let id):
            Picker("", selection: Binding(get: { id }, set: { output = .command($0) })) {
                ForEach(input.commands, id: \.id) { Text($0.title).tag($0.id) }
            }.labelsHidden()
        case .openApp(let id):
            HStack { Text(id).font(Brand.caption).lineLimit(1); Spacer(); Button("Choose…") { if let b = Self.chooseApp() { output = .openApp(b) } }.controlSize(.regular) }
        case .openURL(let u):
            TextField("https://…", text: Binding(get: { u }, set: { output = .openURL($0) })).textFieldStyle(.roundedBorder)
        case .shell(let s):
            TextField("command", text: Binding(get: { s }, set: { output = .shell($0) })).textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
        case .nothing:
            Text("The key does nothing.").font(Brand.caption2).foregroundStyle(.secondary)
        }
    }

    private func modToggle(_ label: String, _ m: Mods, _ cur: Mods) -> some View {
        Toggle(label, isOn: Binding(get: { cur.contains(m) }, set: { on in var n = cur; if on { n.insert(m) } else { n.remove(m) }; output = .modifiers(n) })).toggleStyle(.checkbox)
    }

    private func carbon(_ m: Mods) -> UInt32 {
        (m.contains(.command) ? 256 : 0) | (m.contains(.shift) ? 512 : 0) | (m.contains(.option) ? 2048 : 0) | (m.contains(.control) ? 4096 : 0)
    }

    static func chooseApp() -> String? {
        let p = NSOpenPanel(); p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, let u = p.url else { return nil }
        return Bundle(url: u)?.bundleIdentifier
    }
}
