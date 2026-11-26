import XCTest
import AudioCore
import WindowCore
import ClipboardCore
import InputCore
@testable import WhopperKit

/// A person's own recipe, made from the app's real settings types, full of things that must never leave their Mac.
enum Personal {
    static let speakerUID = "AppleUSBAudioEngine:Edifier:R1280:0042"
    static let micUID = "AppleUSBAudioEngine:Shure:MV7:SN-7731"
    static let displayKey = "EDID-C02XK1234567-0001"
    static let stateBlob = Data("SECRETSTATE-/Users/ana/Library/Audio/x".utf8)

    static let speaker = DeviceSignature(kind: .audioOutput, key: speakerUID, name: "Ana’s Edifier R1280")
    static let mic = DeviceSignature(kind: .audioInput, key: micUID, name: "Ana’s Shure MV7")
    static let monitor = DeviceSignature(kind: .display, key: displayKey, name: "S34CG50")
    static let mouse = DeviceSignature(kind: .logitech, key: "MX Ergo", name: "MX Ergo")
    static let gear = [speaker, mic, monitor, mouse]

    static func plugin(_ name: String = "Pro-Q 3", maker: String = "FabFilter") -> PluginSlot {
        var p = PluginSlot(name: name, manufacturer: maker, type: 1635083896, subtype: 1349481521, manufacturerCode: 1180189518)
        p.state = stateBlob; p.inProcess = true
        return p
    }

    static func audio(band0: Double = 4, limiterOn: Bool = false, ceiling: Double = -0.5) -> AudioSettings {
        var a = AudioSettings()
        a.eq.enabled = true
        a.eq.targetUID = speakerUID
        a.eq.permissionVerified = true
        a.eq.defaultProfile = EQProfile.tenBand([band0, 3, 2, 0, 0, 0, 0, 1, 2, 2], preampDB: -3)
        a.eq.profiles[speakerUID] = EQProfile.tenBand([3, 2, 1, 0, 0, 0, 0, 0, 1, 1], preampDB: -2)
        a.eq.profiles["SOME-OTHER-SPEAKER-UID"] = EQProfile.tenBand([1, 1, 1, 0, 0, 0, 0, 0, 0, 0])
        a.eq.dynamics.limiterEnabled = limiterOn
        a.eq.dynamics.ceilingDB = ceiling
        a.eq.plugins = [plugin()]
        a.keepAlive[speakerUID] = KeepAliveSettings(enabled: true, levelDB: -60, frequencyHz: 40)
        a.keepAlive["SOME-OTHER-SPEAKER-UID"] = KeepAliveSettings(enabled: true)
        a.inputPin = InputPinPolicy(enabled: true, preferredUIDs: [micUID, "UNKNOWN-MIC-UID"])
        a.mic.enabled = true
        a.mic.sourceUID = micUID
        a.mic.gainDB = 3
        a.mic.eq = EQProfile.tenBand([0, 0, 0, 0, 0, 0, 0, 3, 0, 0])
        a.mic.compressor.enabled = true
        a.mic.plugins = [plugin("De-esser", maker: "Acme")]
        a.knownNames = [speakerUID: "Ana’s Edifier R1280", micUID: "Ana’s Shure MV7"]
        return a
    }

    static func windows() -> WindowSettings {
        var w = WindowSettings()
        w.gap = 8
        w.custom["maximize"] = Shortcut(36, Shortcut.ctrl | Shortcut.opt)
        w.custom["gone"] = Shortcut(0, Shortcut.cmd)           // an action that no longer exists
        w.drawerActions = ["leftHalf", "rightHalf", "maximize"]
        w.disabled = ["topHalf"]
        return w
    }

    static func clipboard() -> ClipboardSettings {
        var c = ClipboardSettings()
        c.ignoredBundles.append("com.private.vault")
        return c
    }

    static func input() -> InputSettings {
        var s = InputSettings()
        s.rules = [
            Rule(name: "Ana’s caps", trigger: .key(79), tap: .chord(Chord(53)), hold: .modifiers(.control)),
            Rule(name: "Greeting", trigger: .key(1), tap: .text("Hello Ana, mail me at ana@example.com")),
            Rule(name: "Site", trigger: .key(2), tap: .openURL("https://ana.example.com/secret")),
            Rule(name: "Wipe", trigger: .key(3), tap: .shell("rm -rf /Users/ana/x")),
            Rule(name: "Safari", trigger: .key(4), tap: .openApp("com.apple.Safari")),
            Rule(name: "Back", trigger: .mouse(3), tap: .command("common.back")),
            Rule(name: "Lock", trigger: .key(5), tap: .command("system.lock")),
            Rule(name: "Precision", trigger: .logi(0x00ED), tap: .command("clipboard.open")),
            Rule(name: "", trigger: .key(6), requiredMods: [.control, .shift], tap: .sequence([Chord(58, .option), Chord(0)]), scope: Scope(mode: .only, bundleIDs: ["com.apple.Notes"]), layouts: [.ansi]),
        ]
        s.hidMappings = [HIDMapping(src: HIDMapping.capsLock, dst: HIDMapping.f18), HIDMapping(src: 0x700000029, dst: 0x700000039)]
        return s
    }

    static let displayValues: [String: Int] = ["brightness": 40, "contrast": 60, "colorPreset": 2, "sharpness": 5, "input": 17, "volume": 20, "red": 50, "vcpe0": 3]
    static let display = ["Evening": SharedDisplaySource(model: "S34CG50", values: displayValues)]

    static func recipe(audio a: AudioSettings = audio(), input i: InputSettings = input(), windows w: WindowSettings = windows(), clipboard c: ClipboardSettings = clipboard()) -> Recipe {
        Recipe(name: "Ana’s desk", symbol: "house", devices: gear, sections: [
            "audio": RecipeJSON.encode(a)!, "windows": RecipeJSON.encode(w)!, "clipboard": RecipeJSON.encode(c)!, "input": RecipeJSON.encode(i)!,
            "display": RecipeJSON.encode(["preset": "Evening"])!, "features": RecipeJSON.encode(["audio", "windows"])!,
        ], autoApply: true)
    }

    static func export(_ r: Recipe = recipe(), parts: Set<String>? = nil) -> SharedSetupExportResult {
        SharedSetupExport.export(title: "Quiet desk", line: "Low volume, the right mic, windows tidied.", recipe: r, parts: parts, display: display)
    }

    /// A shared setup that exported cleanly.
    static func setup() -> SharedSetup { export().setup! }

    // MARK: The receiving Mac

    static let rxSpeaker = DeviceSignature(kind: .audioOutput, key: "RX-SPK", name: "Edifier R1280")
    static let rxMic = DeviceSignature(kind: .audioInput, key: "RX-MIC", name: "Shure MV7")
    static let rxMonitor = DeviceSignature(kind: .display, key: "RX-DISP", name: "S34CG50")
    static let rxMouse = DeviceSignature(kind: .logitech, key: "MX Ergo", name: "MX Ergo")
    static let proQ = InstalledPlugin(name: "Pro-Q 3", maker: "FabFilter", type: 1635083896, subtype: 1349481521, manufacturerCode: 1180189518)
    static let deEsser = InstalledPlugin(name: "De-esser", maker: "Acme", type: 1635083896, subtype: 7, manufacturerCode: 9)

    static func receiversOwn() -> [String: Data] {
        var a = AudioSettings()
        a.eq.permissionVerified = true
        a.eq.defaultProfile = EQProfile.tenBand([0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        a.knownNames = ["RX-SPK": "My speaker"]
        var c = ClipboardSettings(); c.ignoredBundles.append("com.receiver.notes"); c.maxItems = 500
        var w = WindowSettings(); w.gap = 2
        var i = InputSettings(); i.rules = [Rule(name: "Mine", trigger: .key(7), tap: .chord(Chord(8)))]; i.hidMappings = []
        return ["audio": RecipeJSON.encode(a)!, "clipboard": RecipeJSON.encode(c)!, "windows": RecipeJSON.encode(w)!, "input": RecipeJSON.encode(i)!]
    }

    static func env(gear: [DeviceSignature]? = nil, plugins: [InstalledPlugin]? = nil, macOS: String = "27.2",
                    permissions: [Permission: PermissionStatus] = [:]) -> ReceiverEnvironment {
        ReceiverEnvironment(gear: gear ?? [rxSpeaker, rxMic, rxMonitor, rxMouse], plugins: plugins ?? [proQ, deEsser], macOS: macOS,
                            permissions: permissions, sections: receiversOwn())
    }
}

extension Data {
    var text: String { String(decoding: self, as: UTF8.self) }
}
