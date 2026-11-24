import Foundation
import Carbon.HIToolbox

/// A key plus modifiers, in Carbon terms (what global hotkeys use).
public struct Shortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32   // Carbon: cmdKey, shiftKey, optionKey, controlKey

    public init(_ keyCode: Int, _ modifiers: UInt32) { self.keyCode = UInt32(keyCode); self.modifiers = modifiers }

    public static let cmd = UInt32(cmdKey), shift = UInt32(shiftKey), opt = UInt32(optionKey), ctrl = UInt32(controlKey)

    public var display: String {
        var s = ""
        if modifiers & Shortcut.ctrl != 0 { s += "⌃" }
        if modifiers & Shortcut.opt != 0 { s += "⌥" }
        if modifiers & Shortcut.shift != 0 { s += "⇧" }
        if modifiers & Shortcut.cmd != 0 { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }
}

public enum KeyNames {
    private static let special: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_CapsLock: "⇪", kVK_Function: "fn", kVK_ANSI_KeypadEnter: "⌤",
    ]

    /// Name of a key under the current layout (letters, digits, punctuation) or a symbol for special keys.
    public static func name(for keyCode: UInt32) -> String {
        if let s = special[Int(keyCode)] { return s }
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "Key \(keyCode)" }
        let layout = unsafeBitCast(ptr, to: CFData.self)
        let data = CFDataGetBytePtr(layout)!
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let err = data.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        guard err == noErr, len > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}
