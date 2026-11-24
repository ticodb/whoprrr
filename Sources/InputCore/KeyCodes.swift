import Foundation
import Carbon.HIToolbox

/// Finds which physical key types a character on the *current* keyboard layout, so "⌘[" means ⌘ and the bracket key on a US,
/// Dvorak or AZERTY keyboard alike. Falls back to the US position when the layout cannot type the character without modifiers.
public enum KeyCodes {
    public static func code(for ch: Character, fallback: Int) -> Int {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let target = String(ch).lowercased()
        return data.withUnsafeBytes { raw -> Int in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            for code in 0..<128 {
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &dead, 4, &length, &chars)
                if st == noErr, length == 1, String(utf16CodeUnits: chars, count: 1).lowercased() == target { return code }
            }
            return fallback
        }
    }
}
