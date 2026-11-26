import Foundation

/// Every number and name the shared-setup rules use, in one place, so the server can mirror them line for line.
/// `docs/shared-setup-format.md` lists the same values. Change one here and the test that reads the document fails until both agree.
public enum SharedSetupTable {
    public static let formatVersion = 1

    /// An inclusive range of numbers.
    public struct Span: Equatable, Sendable {
        public let lo: Double, hi: Double
        public init(_ lo: Double, _ hi: Double) { self.lo = lo; self.hi = hi }
        public func contains(_ x: Double) -> Bool { x >= lo && x <= hi }
    }

    // MARK: Size and text

    public static let maxBytes = 64 * 1024
    public static let titleMax = 60
    public static let lineMax = 160
    public static let gearMax = 20
    public static let gearRoleMax = 30
    public static let gearModelMax = 80
    public static let pluginNamesMax = 20
    public static let pluginNameMax = 40
    public static let pluginsPerChainMax = 10
    public static let permissionsMax = 10

    // MARK: The owner's limits (what a shared setup may do)

    /// No stage of the audio or microphone chain may add more than this: band, pre-amp, microphone gain, make-up gain.
    public static let maxBoostDB = 6.0
    /// The output limiter stays on, and its ceiling is never higher than this (the app's own default).
    public static let limiterCeilingMaxDB = -1.0
    /// Keep-awake tone: this level or quieter. (The app itself allows up to -20 dBFS.)
    public static let keepAwakeLevelMaxDB = -50.0
    /// Keys and mouse: more rules than this make a setup "unusual" (it is held for a look instead of going straight on the shelf).
    public static let unusualKeyRules = 40
    /// A value limited for safety is "unusual" when it lies in the top part of what is allowed: the nearest 10% of the span.
    public static let unusualFraction = 0.10

    // MARK: The app's own ranges (a value outside these cannot have been written by Whoprrr: the document was edited by hand)

    public static let bandHz = Span(10, 22000)
    public static let bandQ = Span(0.1, 10)
    public static let bandGainDB = Span(-12, 12)          // the equalizer sliders; the model itself does not clamp
    public static let preampDB = Span(-12, 6)             // the pre-amp slider
    public static let bandsMax = 16
    public static let micGainDB = Span(-12, 24)           // the microphone gain slider
    public static let micHighPassHz = Span(40, 200)
    public static let gateThresholdDB = Span(-80, -20)
    public static let gateAttackMs = Span(0.1, 100)
    public static let gateReleaseMs = Span(10, 1000)
    public static let compThresholdDB = Span(-50, 0)
    public static let compRatio = Span(1, 12)
    public static let compAttackMs = Span(1, 100)
    public static let compReleaseMs = Span(20, 1000)
    public static let compMakeupDB = Span(0, 18)
    public static let limiterCeilingDB = Span(-12, 0)
    public static let limiterReleaseMs = Span(10, 500)
    public static let keepAwakeLevelDB = Span(-90, -20)   // `KeepAliveSettings.clamped`
    public static let keepAwakeHz = Span(15, 2000)        // `KeepAliveSettings.clamped`; also the limit for shared setups
    public static let keepAwakePulseSeconds = Span(0, 600)
    public static let keepAwakeBurstSeconds = Span(0.05, 10)
    public static let windowGap = Span(0, 30)
    public static let drawerMax = 16
    public static let keyCode = Span(0, 127)
    public static let clipboardItems = Span(100, 10_000)
    public static let clipboardDays = Span(1, 365)
    public static let clipboardImageMB = Span(1, 100)
    public static let clipboardTextKB = Span(1, 10_240)
    public static let holdMs = Span(100, 600)
    public static let mouseButton = Span(0, 15)
    public static let logiControl = Span(0, 65535)
    public static let keyboardType = Span(0, 255)
    public static let displayBrightness = Span(0, 100)
    public static let displayContrast = Span(0, 100)
    public static let displaySharpness = Span(0, 100)
    public static let displayColor = Span(1, 4)           // tone presets 1 to 4; "Custom" (5) is never shared
    public static let sequenceMax = 8

    // MARK: Names

    /// The parts of a setup, in the order they are written. These are the words the shelf uses.
    public static let parts = ["audio", "microphone", "windows", "keys", "clipboard", "display"]
    public static let bandKinds = ["peak", "lowShelf", "highShelf", "highPass", "lowPass"]
    public static let modifierNames = ["shift", "control", "option", "command", "fn"]
    public static let shortcutModifiers = ["command", "control", "option", "shift"]
    /// A global shortcut needs at least one of these, or it would swallow ordinary typing.
    public static let shortcutNeedsOneOf = ["command", "control", "option"]
    public static let scopeModes = ["everywhere", "only", "except"]
    public static let layouts = ["ansi", "iso", "jis"]
    public static let mediaKeys = ["volumeUp", "volumeDown", "brightnessUp", "brightnessDown", "mute", "playPause", "next", "previous"]
    public static let permissions = ["accessibility", "inputMonitoring", "camera", "microphone", "systemAudio"]
    /// Display values a shared setup may carry. Nothing else: no input switching, no manufacturer codes, no learned codes.
    public static let displayControls = ["brightness", "contrast", "color", "sharpness"]
    /// The display values by name, with their ranges.
    public static func displayRange(_ control: String) -> Span? {
        switch control {
        case "brightness": return displayBrightness
        case "contrast": return displayContrast
        case "color": return displayColor
        case "sharpness": return displaySharpness
        default: return nil
        }
    }

    /// Layout names the window module knows (`WindowAction`).
    public static let windowActions = [
        "leftHalf", "rightHalf", "topHalf", "bottomHalf", "topLeft", "topRight", "bottomLeft", "bottomRight",
        "firstThird", "centerThird", "lastThird", "firstTwoThirds", "lastTwoThirds", "maximize", "maximizeHeight", "center",
        "larger", "smaller", "nextDisplay", "previousDisplay", "restore",
    ]

    /// Whoprrr's own commands a key may run. Not "system.lock" (a key must not lock the screen), and nothing that opens, types or runs.
    public static let commands: [String] = [
        "clipboard.open",
        "system.missionControl", "system.appExpose", "system.showDesktop", "system.spaceLeft", "system.spaceRight",
        "system.spotlight", "system.screenshot", "system.screenshotTools",
        "common.back", "common.forward", "common.prevTab", "common.nextTab", "common.newTab", "common.closeTab", "common.reopenTab",
        "common.switchApp", "common.minimize", "common.fullscreen", "common.copy", "common.paste", "common.cut", "common.undo",
        "common.redo", "common.selectAll", "common.top", "common.bottom", "common.pageUp", "common.pageDown",
    ] + windowActions.map { "window.\($0)" }

    // MARK: Keys and mouse

    /// Emergency off: Escape with all four modifiers.
    public static let emergencyKey = 53
    public static let emergencyMods = ["command", "control", "option", "shift"]
    /// Return, keypad Enter, Space, Escape, Tab, Delete, forward Delete and the four arrows: never left doing nothing.
    public static let protectedKeys = [36, 76, 49, 53, 48, 51, 117, 123, 124, 125, 126]
    /// Left click.
    public static let primaryMouseButton = 0

    /// Key mappings done by macOS itself (`hidutil`). Only the ones Whoprrr's own presets make: Caps Lock or a right-hand modifier
    /// becomes F18 or F19. Anything else (Escape, Return, the modifiers themselves…) could lock a person out.
    public static let hidFrom = ["capsLock", "rightCommand", "rightOption"]
    public static let hidTo = ["f18", "f19"]
    public static let hidCodes: [String: UInt64] = [
        "capsLock": 0x700000039, "rightCommand": 0x7000000E7, "rightOption": 0x7000000E6, "f18": 0x70000006D, "f19": 0x70000006E,
    ]

    // MARK: Clipboard

    /// The password-manager defaults of `ClipboardSettings.defaultIgnored`. A shared ignore list must always contain all of them.
    public static let clipboardDefaultIgnored = [
        "com.1password.1password", "com.1password.1password7", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc",
        "com.dashlane.dashlanephonefinal", "com.lastpass.lastpassmacdesktop", "in.sinew.Enpass-Desktop",
    ]
    public static let ignoredAppsMax = 200

    // MARK: Macs

    /// Output equalizer and system-audio capture need this macOS (the app's own message: "Needs macOS 14.2 or newer").
    public static let minMacOSForEqualizer = "14.2"
}
