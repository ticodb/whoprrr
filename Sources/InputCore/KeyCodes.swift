import Foundation
import Carbon.HIToolbox

/// Finds which physical key produces a character *while ⌘ is held* on the current keyboard layout, which is how apps match
/// keyboard shortcuts. On a US keyboard "[" is the key right of P; on a Spanish ISO layout ⌘[ is the Ñ key (the layout has a
/// separate Command mapping); Dvorak and AZERTY differ again. A shortcut sent by character therefore lands on the right key.
public enum KeyCodes {
    public static func code(for ch: Character, fallback: Int) -> Int { exactCode(for: ch) ?? fallback }

    /// The key that produces `ch` under ⌘ on the current layout, or nil if no key does.
    public static func exactCode(for ch: Character) -> Int? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let target = String(ch).lowercased()
        return data.withUnsafeBytes { raw -> Int? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8), UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &dead, 4, &length, &chars)
                if st == noErr, length == 1, String(utf16CodeUnits: chars, count: 1).lowercased() == target { return code }
            }
            return nil
        }
    }
}
