import AppKit
import CoreGraphics

/// Turns engine `Emit`s into real events. Everything posted carries a marker so our own tap ignores it.
public final class EventPoster: @unchecked Sendable {
    public static let marker: Int64 = 0x57484F50   // 'WHOP'
    public var onCommand: (@Sendable (String) -> Void)?
    private let source = CGEventSource(stateID: .hidSystemState)

    public init() {}

    public func post(_ emits: [Emit]) {
        for e in emits {
            switch e {
            case .key(let code, let down, let flags, let rep): key(code, down: down, flags: flags, autorepeat: rep)
            case .modifier(let m, let down): modifier(m, down: down)
            case .mouse(let b, let down): mouse(b, down: down)
            case .media(let k, let down): media(k, down: down)
            case .command(let c): onCommand?(c)
            case .openApp(let id): DispatchQueue.main.async { Self.open(app: id) }
            case .openURL(let s): DispatchQueue.main.async { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
            case .shell(let s): Self.shell(s)
            case .text(let t): text(t)
            }
        }
    }

    private func send(_ e: CGEvent?) {
        guard let e else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        e.post(tap: .cghidEventTap)
    }

    private func key(_ code: Int, down: Bool, flags: Mods, autorepeat: Bool) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
        e?.flags = flags.cgFlags
        if autorepeat { e?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        send(e)
    }

    /// Presses or releases each modifier in turn, accumulating flags like a real keyboard would.
    private func modifier(_ m: Mods, down: Bool) {
        let order: [Mods] = [.control, .option, .shift, .command, .fn].filter(m.contains)
        func flagsChanged(_ one: Mods, flags: Mods) {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(ModifierKey.code(for: one)), keyDown: down)
            e?.type = .flagsChanged
            e?.flags = flags.cgFlags
            send(e)
        }
        if down {
            var acc: Mods = []
            for one in order { acc.insert(one); flagsChanged(one, flags: acc) }
        } else {
            var remaining = Mods(order)
            for one in order.reversed() { remaining.remove(one); flagsChanged(one, flags: remaining) }
        }
    }

    private func mouse(_ b: Int, down: Bool) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        let type: CGEventType = b == 0 ? (down ? .leftMouseDown : .leftMouseUp) : b == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: loc, mouseButton: CGMouseButton(rawValue: UInt32(b)) ?? .center)
        e?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b))
        e?.setIntegerValueField(.mouseEventClickState, value: 1)
        send(e)
    }

    /// Types a string as a Unicode keystroke, so it comes out the same on any layout or regional setting.
    private func text(_ s: String) {
        let units = Array(s.utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            e?.flags = []
            e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            send(e)
        }
    }

    private func media(_ k: MediaKey, down: Bool) {
        let state = down ? 0xA : 0xB
        let data1 = (k.rawValue << 16) | (state << 8)
        let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                   timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
        send(e?.cgEvent)
    }

    static func open(app bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func shell(_ command: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", command]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

extension Mods {
    init(_ list: [Mods]) { self = list.reduce([]) { $0.union($1) } }
}
