import AppKit
import InputCore

/// The everyday actions a mouse button or key is usually given: Back, Forward, tabs, copy and paste, scrolling, media.
/// Keys are looked up on the current keyboard layout, so they work on any layout.
@MainActor
enum CommonActions {
    enum Key { case char(Character, fallback: Int), code(Int) }

    struct Action: Identifiable {
        let id: String
        let title: String
        let category: String
        let symbol: String
        let key: Key
        let mods: Mods
        @MainActor func run(_ c: InputController) {
            let code: Int
            switch key { case .char(let ch, let fb): code = KeyCodes.code(for: ch, fallback: fb); case .code(let k): code = k }
            c.tapChord(code, mods)
        }
    }

    static let all: [Action] = [
        Action(id: "common.back", title: "Back", category: "Navigate", symbol: "chevron.left", key: .char("[", fallback: 33), mods: .command),
        Action(id: "common.forward", title: "Forward", category: "Navigate", symbol: "chevron.right", key: .char("]", fallback: 30), mods: .command),
        Action(id: "common.prevTab", title: "Previous tab", category: "Tabs and windows", symbol: "arrow.left.square", key: .char("[", fallback: 33), mods: [.command, .shift]),
        Action(id: "common.nextTab", title: "Next tab", category: "Tabs and windows", symbol: "arrow.right.square", key: .char("]", fallback: 30), mods: [.command, .shift]),
        Action(id: "common.newTab", title: "New tab", category: "Tabs and windows", symbol: "plus.square", key: .char("t", fallback: 17), mods: .command),
        Action(id: "common.closeTab", title: "Close tab or window", category: "Tabs and windows", symbol: "xmark.square", key: .char("w", fallback: 13), mods: .command),
        Action(id: "common.reopenTab", title: "Reopen closed tab", category: "Tabs and windows", symbol: "arrow.uturn.backward.square", key: .char("t", fallback: 17), mods: [.command, .shift]),
        Action(id: "common.switchApp", title: "Switch to the next app", category: "Tabs and windows", symbol: "square.on.square", key: .code(48), mods: .command),
        Action(id: "common.minimize", title: "Minimize window", category: "Tabs and windows", symbol: "minus.square", key: .char("m", fallback: 46), mods: .command),
        Action(id: "common.fullscreen", title: "Full screen", category: "Tabs and windows", symbol: "arrow.up.left.and.arrow.down.right", key: .char("f", fallback: 3), mods: [.command, .control]),
        Action(id: "common.copy", title: "Copy", category: "Edit", symbol: "doc.on.doc", key: .char("c", fallback: 8), mods: .command),
        Action(id: "common.paste", title: "Paste", category: "Edit", symbol: "doc.on.clipboard", key: .char("v", fallback: 9), mods: .command),
        Action(id: "common.cut", title: "Cut", category: "Edit", symbol: "scissors", key: .char("x", fallback: 7), mods: .command),
        Action(id: "common.undo", title: "Undo", category: "Edit", symbol: "arrow.uturn.backward", key: .char("z", fallback: 6), mods: .command),
        Action(id: "common.redo", title: "Redo", category: "Edit", symbol: "arrow.uturn.forward", key: .char("z", fallback: 6), mods: [.command, .shift]),
        Action(id: "common.selectAll", title: "Select all", category: "Edit", symbol: "selection.pin.in.out", key: .char("a", fallback: 0), mods: .command),
        Action(id: "common.top", title: "Scroll to top", category: "Scroll", symbol: "arrow.up.to.line", key: .code(126), mods: .command),
        Action(id: "common.bottom", title: "Scroll to bottom", category: "Scroll", symbol: "arrow.down.to.line", key: .code(125), mods: .command),
        Action(id: "common.pageUp", title: "Page up", category: "Scroll", symbol: "chevron.up.2", key: .code(116), mods: []),
        Action(id: "common.pageDown", title: "Page down", category: "Scroll", symbol: "chevron.down.2", key: .code(121), mods: []),
    ]

    static let categories = ["Navigate", "Tabs and windows", "Edit", "Scroll"]
}
