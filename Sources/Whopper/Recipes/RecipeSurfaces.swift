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
    func canonicalRecipeData(_ data: Data) -> Data {
        guard var s = RecipeJSON.decode(AudioSettings.self, from: data) else { return data }
        for (id, app) in s.mix.apps { s.mix.set(id, volume: app.volume, muted: app.muted, name: "") }
        return RecipeJSON.encode(s) ?? data
    }
    func applyRecipeData(_ data: Data) -> Bool {
        guard var s = RecipeJSON.decode(AudioSettings.self, from: data) else { return false }
        s.eq.permissionVerified = settings.eq.permissionVerified
        s.knownNames = settings.knownNames
        s.mix = withLiveMixNames(s.mix)
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
    func canonicalRecipeData(_ data: Data) -> Data { RecipeJSON.decode(WindowSettings.self, from: data).flatMap(RecipeJSON.encode) ?? data }
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

@MainActor
struct PresetSurface {
    let key: String
    let title: String
    var device: String? = nil
    var deviceName: String? = nil
    var factory: [FactoryPreset] = []
    var sync: () -> Void = {}
    let capture: () -> Data?
    let apply: (Data) -> Bool
    var canonical: (Data) -> Data = { $0 }
    var matches: ((Data, Data) -> Bool)? = nil
    var factoryUpdate: (() -> Data?)? = nil

    var location: PresetLocation { PresetLocation(key, device: device) }
    var locationName: String { deviceName ?? title }
    var recipePart: String { String(key.prefix { $0 != "." }) }

    func groups(in library: PresetLibrary) -> PresetGroups {
        library.groups(at: location, factory: factory, live: capture(), matches: matches ?? { canonical($0) == canonical($1) })
    }

    func captureUpdate(for entry: PresetEntry) -> Data? {
        sync()
        if entry.isFactory, let factoryUpdate { return factoryUpdate() }
        return capture()
    }
}

struct MicPresetPayload: Codable {
    var gainDB: Double, highPassEnabled: Bool, highPassHz: Double, eq: EQProfile, gate: GateSettings, compressor: CompressorSettings, plugins: [PluginSlot]
}
private struct SystemSoundPreset: Codable {
    var profile: EQProfile
    var mix: MixSettings
}

struct OutputFXPayload: Codable { var dynamics: OutputDynamicsSettings; var plugins: [PluginSlot] }
struct RoutingPayload: Codable { var inputPin: InputPinPolicy; var keepAlive: [String: KeepAliveSettings] }

@MainActor
enum PresetSurfaces {
    private static let factoryEQ = EQProfile.presets.compactMap { preset in
        RecipeJSON.encode(preset.profile).map { FactoryPreset(id: preset.name, name: preset.name, data: $0) }
    }

    private static func canonical<T: Codable>(_ type: T.Type, _ data: Data) -> Data {
        RecipeJSON.decode(type, from: data).flatMap(RecipeJSON.encode) ?? data
    }

    static func eq(_ a: AudioModel) -> PresetSurface {
        let device = a.eqPerDevice ? a.eqDeviceUID : nil
        return PresetSurface(key: "audio.eq", title: "System sound", device: device, deviceName: device.map(a.name(for:)),
                             factory: factoryEQ,
                             capture: {
                                 let profile = device.flatMap { a.settings.eq.profiles[$0] } ?? a.settings.eq.defaultProfile
                                 return RecipeJSON.encode(SystemSoundPreset(profile: profile, mix: a.settings.mix))
                             },
                             apply: { data in
                                 let preset = RecipeJSON.decode(SystemSoundPreset.self, from: data)
                                 // Older and built-in presets, including those taken from shared setups, are EQ curves.
                                 guard let profile = preset?.profile ?? RecipeJSON.decode(EQProfile.self, from: data) else { return false }
                                 var settings = a.settings
                                 if let device { settings.eq.profiles[device] = profile } else { settings.eq.defaultProfile = profile }
                                 if let preset { settings.mix = a.withLiveMixNames(preset.mix) }
                                 a.settings = settings
                                 return true
                             }, matches: { live, stored in
                                 guard let current = RecipeJSON.decode(SystemSoundPreset.self, from: live) else { return false }
                                 if let saved = RecipeJSON.decode(SystemSoundPreset.self, from: stored) {
                                     return current.profile == saved.profile && current.mix.matchesLevels(of: saved.mix)
                                 }
                                 return current.profile == RecipeJSON.decode(EQProfile.self, from: stored)
                             })
    }

    static func outputFX(_ a: AudioModel) -> PresetSurface {
        PresetSurface(key: "audio.outputfx", title: "System effects", sync: a.syncPluginStates,
                      capture: { RecipeJSON.encode(OutputFXPayload(dynamics: a.settings.eq.dynamics, plugins: a.settings.eq.plugins)) },
                      apply: { d in
                          guard let p = RecipeJSON.decode(OutputFXPayload.self, from: d) else { return false }
                          a.settings.eq.dynamics = p.dynamics
                          a.settings.eq.plugins = p.plugins
                          return true
                      }, canonical: { canonical(OutputFXPayload.self, $0) })
    }

    static func mic(_ a: AudioModel) -> PresetSurface {
        PresetSurface(key: "audio.mic", title: "Microphone", factory: factoryEQ, sync: a.syncPluginStates,
                      capture: {
                          let m = a.settings.mic
                          return RecipeJSON.encode(MicPresetPayload(gainDB: m.gainDB, highPassEnabled: m.highPassEnabled, highPassHz: m.highPassHz, eq: m.eq, gate: m.gate, compressor: m.compressor, plugins: m.plugins))
                      },
                      apply: { d in
                          // The built-ins for the mic have always been EQ curves, leaving the rest of the chain in place.
                          if var eq = RecipeJSON.decode(EQProfile.self, from: d) {
                              eq.enabled = a.settings.mic.eq.enabled
                              a.settings.mic.eq = eq
                              return true
                          }
                          guard let p = RecipeJSON.decode(MicPresetPayload.self, from: d) else { return false }
                          a.settings.mic.gainDB = p.gainDB; a.settings.mic.highPassEnabled = p.highPassEnabled; a.settings.mic.highPassHz = p.highPassHz
                          a.settings.mic.eq = p.eq; a.settings.mic.gate = p.gate; a.settings.mic.compressor = p.compressor; a.settings.mic.plugins = p.plugins
                          return true
                      }, matches: { live, stored in
                          if let profile = RecipeJSON.decode(EQProfile.self, from: stored),
                             let mic = RecipeJSON.decode(MicPresetPayload.self, from: live) {
                              var eq = profile
                              eq.enabled = mic.eq.enabled
                              return mic.eq == eq
                          }
                          return canonical(MicPresetPayload.self, live) == canonical(MicPresetPayload.self, stored)
                      }, factoryUpdate: { RecipeJSON.encode(a.settings.mic.eq) })
    }

    static func routing(_ a: AudioModel) -> PresetSurface {
        PresetSurface(key: "audio.routing", title: "Input and keep-awake",
                      capture: { RecipeJSON.encode(RoutingPayload(inputPin: a.settings.inputPin, keepAlive: a.settings.keepAlive)) },
                      apply: { d in guard let p = RecipeJSON.decode(RoutingPayload.self, from: d) else { return false }
                          a.settings.inputPin = p.inputPin; a.settings.keepAlive = p.keepAlive; return true },
                      canonical: { canonical(RoutingPayload.self, $0) })
    }

    static func windows(_ w: WindowModel) -> PresetSurface {
        PresetSurface(key: "windows", title: "Windows", capture: w.captureRecipeData,
                      apply: w.applyRecipeData, canonical: w.canonicalRecipeData)
    }

    static func clipboard(_ c: ClipboardController) -> PresetSurface {
        PresetSurface(key: "clipboard", title: "Clipboard", capture: c.captureRecipeData,
                      apply: c.applyRecipeData, canonical: { canonical(ClipboardSettings.self, $0) })
    }

    static func input(_ i: InputController) -> PresetSurface {
        PresetSurface(key: "input", title: "Keys and mouse", capture: i.captureRecipeData,
                      apply: i.applyRecipeData, canonical: { canonical(InputSettings.self, $0) })
    }
    static func surface(_ key: String) -> PresetSurface? {
        switch key {
        case "audio.eq": eq(Shared.audio)
        case "audio.outputfx": outputFX(Shared.audio)
        case "audio.mic": mic(Shared.audio)
        case "audio.routing": routing(Shared.audio)
        case "windows": windows(Shared.windows)
        case "clipboard": clipboard(Shared.clipboard)
        case "input": input(Shared.input)
        default: nil
        }
    }
}
