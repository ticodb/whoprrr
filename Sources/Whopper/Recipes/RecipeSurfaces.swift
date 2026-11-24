import SwiftUI
import AudioCore
import WindowCore
import ClipboardCore
import InputCore
import WhopperKit

// MARK: Recipe surfaces (whole sections of the app, captured into recipes)

extension AudioModel: RecipeSurface {
    var recipeKey: String { "audio" }
    var recipeTitle: String { "Audio" }
    func captureRecipeData() -> Data? {
        syncPluginStates()
        var s = settings
        s.eq.permissionVerified = false       // a property of this Mac, never of a recipe
        s.knownNames = [:]
        return RecipeJSON.encode(s)
    }
    func applyRecipeData(_ data: Data) -> Bool {
        guard var s = RecipeJSON.decode(AudioSettings.self, from: data) else { return false }
        s.eq.permissionVerified = settings.eq.permissionVerified
        s.knownNames = settings.knownNames
        settings = s
        return true
    }
}

extension WindowModel: RecipeSurface {
    var recipeKey: String { "windows" }
    var recipeTitle: String { "Windows" }
    func captureRecipeData() -> Data? { RecipeJSON.encode(settings) }
    func applyRecipeData(_ data: Data) -> Bool {
        guard let s = RecipeJSON.decode(WindowSettings.self, from: data) else { return false }
        settings = s; return true
    }
}

extension ClipboardController: RecipeSurface {
    var recipeKey: String { "clipboard" }
    var recipeTitle: String { "Clipboard" }
    func captureRecipeData() -> Data? { RecipeJSON.encode(settings) }
    func applyRecipeData(_ data: Data) -> Bool {
        guard let s = RecipeJSON.decode(ClipboardSettings.self, from: data) else { return false }
        settings = s; return true
    }
}

extension InputController: RecipeSurface {
    var recipeKey: String { "input" }
    var recipeTitle: String { "Keys and mouse" }
    func captureRecipeData() -> Data? { RecipeJSON.encode(settings) }
    func applyRecipeData(_ data: Data) -> Bool {
        guard let s = RecipeJSON.decode(InputSettings.self, from: data) else { return false }
        settings = s; return true
    }
}

/// Which features are installed.
@MainActor
final class FeaturesSurface: RecipeSurface {
    let store: FeatureStore
    init(_ s: FeatureStore) { store = s }
    var recipeKey: String { "features" }
    var recipeTitle: String { "Installed features" }
    func captureRecipeData() -> Data? { RecipeJSON.encode(store.enabled.map(\.rawValue).sorted()) }
    func applyRecipeData(_ data: Data) -> Bool {
        guard let names = RecipeJSON.decode([String].self, from: data) else { return false }
        let want = Set(names.compactMap(Feature.init(rawValue:)))
        for f in Feature.allCases where f.isBuilt { store.setEnabled(f, want.contains(f)) }
        return true
    }
}

/// The external-display preset to apply (presets themselves stay in the display module).
@MainActor
final class DisplaySurface: RecipeSurface {
    let model: AppModel
    init(_ m: AppModel) { model = m }
    var recipeKey: String { "display" }
    var recipeTitle: String { "Display preset" }
    func captureRecipeData() -> Data? { model.lastPresetName.flatMap { RecipeJSON.encode(["preset": $0]) } }
    func applyRecipeData(_ data: Data) -> Bool {
        guard let d = RecipeJSON.decode([String: String].self, from: data), let name = d["preset"] else { return false }
        guard let p = model.presetsForSelected().first(where: { $0.name == name }) else { return false }
        model.apply(p); return true
    }
}

// MARK: Gear

/// What is plugged in right now, as recipe signatures.
@MainActor
enum Gear {
    static func current() -> [DeviceSignature] {
        var out: [DeviceSignature] = []
        for d in Shared.audio.devices where !d.isWhopperInternal && d.transport != .virtual && d.transport != .aggregate && d.transport != .builtIn {
            if d.hasInput { out.append(DeviceSignature(kind: .audioInput, key: d.uid, name: d.name)) }
            if d.hasOutput { out.append(DeviceSignature(kind: .audioOutput, key: d.uid, name: d.name)) }
        }
        for d in Shared.model.displays where !d.isBuiltIn {
            let key = d.edidUUID ?? "\(d.identity.vendor)-\(d.identity.model)-\(d.identity.serial)"
            out.append(DeviceSignature(kind: .display, key: key, name: d.identity.productName))
        }
        for d in Shared.input.logiDevices { out.append(DeviceSignature(kind: .logitech, key: d.name.trimmingCharacters(in: .whitespaces), name: d.name.trimmingCharacters(in: .whitespaces))) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted && !(DemoData.isOn && DemoData.isPersonal($0.name)) }
    }
}

// MARK: Per-surface presets (one panel's settings on their own)

struct PresetSurface {
    let key: String
    let title: String
    let capture: () -> Data?
    let apply: (Data) -> Bool
}

struct MicPresetPayload: Codable {
    var gainDB: Double, highPassEnabled: Bool, highPassHz: Double, eq: EQProfile, gate: GateSettings, compressor: CompressorSettings, plugins: [PluginSlot]
}
struct OutputFXPayload: Codable { var dynamics: OutputDynamicsSettings; var plugins: [PluginSlot] }
struct RoutingPayload: Codable { var inputPin: InputPinPolicy; var keepAlive: [String: KeepAliveSettings] }

@MainActor
enum PresetSurfaces {
    static func eq(_ a: AudioModel) -> PresetSurface {
        PresetSurface(key: "audio.eq", title: "Equalizer",
                      capture: { RecipeJSON.encode(a.eqProfile) },
                      apply: { d in guard let p = RecipeJSON.decode(EQProfile.self, from: d) else { return false }; a.eqProfile = p; return true })
    }
    static func outputFX(_ a: AudioModel) -> PresetSurface {
        PresetSurface(key: "audio.outputfx", title: "Output effects",
                      capture: { a.syncPluginStates(); return RecipeJSON.encode(OutputFXPayload(dynamics: a.settings.eq.dynamics, plugins: a.settings.eq.plugins)) },
                      apply: { d in
                          guard let p = RecipeJSON.decode(OutputFXPayload.self, from: d) else { return false }
                          a.settings.eq.dynamics = p.dynamics; a.settings.eq.plugins = p.plugins; return true })
    }
    static func mic(_ a: AudioModel) -> PresetSurface {
        PresetSurface(key: "audio.mic", title: "Microphone chain",
                      capture: {
                          a.syncPluginStates(); let m = a.settings.mic
                          return RecipeJSON.encode(MicPresetPayload(gainDB: m.gainDB, highPassEnabled: m.highPassEnabled, highPassHz: m.highPassHz, eq: m.eq, gate: m.gate, compressor: m.compressor, plugins: m.plugins)) },
                      apply: { d in
                          guard let p = RecipeJSON.decode(MicPresetPayload.self, from: d) else { return false }
                          a.settings.mic.gainDB = p.gainDB; a.settings.mic.highPassEnabled = p.highPassEnabled; a.settings.mic.highPassHz = p.highPassHz
                          a.settings.mic.eq = p.eq; a.settings.mic.gate = p.gate; a.settings.mic.compressor = p.compressor; a.settings.mic.plugins = p.plugins
                          return true })
    }
    static func routing(_ a: AudioModel) -> PresetSurface {
        PresetSurface(key: "audio.routing", title: "Input and keep-awake",
                      capture: { RecipeJSON.encode(RoutingPayload(inputPin: a.settings.inputPin, keepAlive: a.settings.keepAlive)) },
                      apply: { d in guard let p = RecipeJSON.decode(RoutingPayload.self, from: d) else { return false }
                          a.settings.inputPin = p.inputPin; a.settings.keepAlive = p.keepAlive; return true })
    }
    static func windows(_ w: WindowModel) -> PresetSurface {
        PresetSurface(key: "windows", title: "Windows", capture: { RecipeJSON.encode(w.settings) },
                      apply: { d in guard let s = RecipeJSON.decode(WindowSettings.self, from: d) else { return false }; w.settings = s; return true })
    }
    static func clipboard(_ c: ClipboardController) -> PresetSurface {
        PresetSurface(key: "clipboard", title: "Clipboard", capture: { RecipeJSON.encode(c.settings) },
                      apply: { d in guard let s = RecipeJSON.decode(ClipboardSettings.self, from: d) else { return false }; c.settings = s; return true })
    }
    static func input(_ i: InputController) -> PresetSurface {
        PresetSurface(key: "input", title: "Keys and mouse rules", capture: { RecipeJSON.encode(i.settings) },
                      apply: { d in guard let s = RecipeJSON.decode(InputSettings.self, from: d) else { return false }; i.settings = s; return true })
    }
}
