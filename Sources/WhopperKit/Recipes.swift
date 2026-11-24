import Foundation
import Combine

// MARK: Gear

/// A peripheral a recipe was made for: a display, a microphone, speakers, a Logitech device.
public struct DeviceSignature: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case audioOutput, audioInput, display, logitech }
    public var kind: Kind
    /// Stable identifier (audio device UID, display EDID, Logitech name).
    public var key: String
    public var name: String
    public var id: String { "\(kind.rawValue):\(key)" }

    public init(kind: Kind, key: String, name: String) { self.kind = kind; self.key = key; self.name = name }

    public var symbol: String {
        switch kind {
        case .audioOutput: "speaker.wave.2"
        case .audioInput: "mic"
        case .display: "display"
        case .logitech: "computermouse"
        }
    }
}

// MARK: Recipe

/// A named setup for a set of gear: a snapshot of settings per surface (audio, windows, clipboard, keys…) that can be
/// applied in one click. Each section is that surface's own settings as JSON, so recipes survive new fields.
public struct Recipe: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var symbol: String = "fork.knife"
    public var createdAt = Date()
    public var updatedAt = Date()
    public var devices: [DeviceSignature] = []
    public var sections: [String: Data] = [:]
    /// Apply by itself when exactly this gear shows up.
    public var autoApply = false

    public init(name: String, symbol: String = "fork.knife", devices: [DeviceSignature] = [], sections: [String: Data] = [:], autoApply: Bool = false) {
        self.name = name; self.symbol = symbol; self.devices = devices; self.sections = sections; self.autoApply = autoApply
    }

    /// How the recipe's gear compares with what is connected right now.
    public func gear(connected: [DeviceSignature]) -> (present: [DeviceSignature], missing: [DeviceSignature]) {
        let have = Set(connected.map(\.id))
        return (devices.filter { have.contains($0.id) }, devices.filter { !have.contains($0.id) })
    }

    public func isComplete(connected: [DeviceSignature]) -> Bool { !devices.isEmpty && gear(connected: connected).missing.isEmpty }
}

// MARK: Surfaces

/// A part of the app that can be captured into a recipe and restored from one.
@MainActor
public protocol RecipeSurface: AnyObject {
    /// Stable key stored in recipes ("audio", "windows"…).
    var recipeKey: String { get }
    var recipeTitle: String { get }
    /// Settings as JSON (sorted keys, so equal settings give equal bytes), or nil when there is nothing to capture.
    func captureRecipeData() -> Data?
    /// Replaces this surface's settings. False if the data could not be read.
    @discardableResult func applyRecipeData(_ data: Data) -> Bool
}

public enum RecipeJSON {
    public static func encode<T: Encodable>(_ v: T) -> Data? {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try? e.encode(v)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from d: Data) -> T? { try? JSONDecoder().decode(type, from: d) }
}

// MARK: Store

struct RecipeFile: Codable, Sendable {
    var recipes: [Recipe] = []
    var activeID: UUID?
    /// Fingerprint of what each section looked like when the active recipe was applied, to tell "applied" from "modified".
    var appliedSections: [String: Data] = [:]
}

/// All recipes, which one is active, and the logic to capture, apply and auto-apply them.
@MainActor
public final class RecipeStore: ObservableObject {
    private let store: JSONStore<RecipeFile>
    private var surfaces: [String: RecipeSurface] = [:]
    @Published public private(set) var recipes: [Recipe]
    @Published public private(set) var activeID: UUID?
    /// A short note about the last automatic or manual change ("Applied Home"), for the UI to show.
    @Published public var notice: String?
    private var applied: [String: Data]

    public init(url: URL? = nil) {
        store = url.map { JSONStore<RecipeFile>(url: $0) } ?? JSONStore<RecipeFile>(name: "recipes")
        let f = store.load(default: RecipeFile())
        recipes = f.recipes; activeID = f.activeID; applied = f.appliedSections
    }

    public func register(_ s: RecipeSurface) { surfaces[s.recipeKey] = s }
    public var surfaceList: [(key: String, title: String)] {
        surfaces.values.map { ($0.recipeKey, $0.recipeTitle) }.sorted { $0.title < $1.title }
    }
    public var active: Recipe? { recipes.first { $0.id == activeID } }

    private func save() { store.save(RecipeFile(recipes: recipes, activeID: activeID, appliedSections: applied)) }

    // MARK: Capture and apply

    /// Snapshot of the current settings for the given surfaces.
    public func snapshot(_ keys: Set<String>) -> [String: Data] {
        var out: [String: Data] = [:]
        for k in keys { if let d = surfaces[k]?.captureRecipeData() { out[k] = d } }
        return out
    }

    @discardableResult
    public func create(name: String, symbol: String, includes: Set<String>, devices: [DeviceSignature], autoApply: Bool) -> Recipe {
        let r = Recipe(name: name, symbol: symbol, devices: devices, sections: snapshot(includes), autoApply: autoApply)
        recipes.append(r); activeID = r.id; applied = r.sections; save()
        return r
    }

    /// Re-captures the recipe's own sections (and optionally its gear) from the current setup.
    public func updateFromCurrent(_ id: UUID, devices: [DeviceSignature]? = nil) {
        guard let i = recipes.firstIndex(where: { $0.id == id }) else { return }
        recipes[i].sections = snapshot(Set(recipes[i].sections.keys))
        if let devices { recipes[i].devices = devices }
        recipes[i].updatedAt = Date()
        if activeID == id { applied = recipes[i].sections }
        save()
    }

    /// Applies every section of the recipe. Returns the surfaces that could not be applied.
    @discardableResult
    public func apply(_ id: UUID, automatic: Bool = false) -> [String] {
        guard let r = recipes.first(where: { $0.id == id }) else { return [] }
        var failed: [String] = []
        for (key, data) in r.sections {
            if let s = surfaces[key] { if !s.applyRecipeData(data) { failed.append(s.recipeTitle) } } else { failed.append(key) }
        }
        activeID = id
        applied = snapshot(Set(r.sections.keys))      // what the surfaces hold after applying (they may normalise)
        notice = failed.isEmpty ? (automatic ? "Switched to “\(r.name)” because its gear is connected" : "Applied “\(r.name)”") : "Applied “\(r.name)”, except \(failed.joined(separator: ", "))"
        save()
        return failed
    }

    /// True when the current settings differ from what the active recipe applied (the recipe has drifted).
    public func isModified(_ id: UUID) -> Bool {
        guard id == activeID, let r = recipes.first(where: { $0.id == id }) else { return false }
        let now = snapshot(Set(r.sections.keys))
        return now != applied
    }

    public func rename(_ id: UUID, to name: String, symbol: String? = nil) {
        guard let i = recipes.firstIndex(where: { $0.id == id }) else { return }
        recipes[i].name = name; if let symbol { recipes[i].symbol = symbol }
        save()
    }
    public func setAutoApply(_ id: UUID, _ on: Bool) {
        guard let i = recipes.firstIndex(where: { $0.id == id }) else { return }
        recipes[i].autoApply = on; save()
    }
    public func setDevices(_ id: UUID, _ devices: [DeviceSignature]) {
        guard let i = recipes.firstIndex(where: { $0.id == id }) else { return }
        recipes[i].devices = devices; save()
    }
    public func delete(_ id: UUID) {
        recipes.removeAll { $0.id == id }
        if activeID == id { activeID = nil; applied = [:] }
        save()
    }
    public func move(from: IndexSet, to: Int) {
        var r = recipes
        let moving = from.sorted().map { r[$0] }
        for i in from.sorted().reversed() { r.remove(at: i) }
        r.insert(contentsOf: moving, at: min(max(to - from.filter { $0 < to }.count, 0), r.count))
        recipes = r; save()
    }

    // MARK: Matching

    /// The recipe to switch to when the connected gear changes: an auto-apply recipe whose gear is all present, preferring the
    /// one with the most gear. Nil if the active recipe is already that one, or nothing qualifies.
    public func autoApplyCandidate(connected: [DeviceSignature]) -> Recipe? {
        let best = recipes.filter { $0.autoApply && $0.isComplete(connected: connected) }.max { $0.devices.count < $1.devices.count }
        guard let best, best.id != activeID else { return nil }
        return best
    }

    /// Recipes ordered by how well they fit the connected gear (complete matches first).
    public func ranked(connected: [DeviceSignature]) -> [Recipe] {
        func score(_ r: Recipe) -> Double {
            guard !r.devices.isEmpty else { return 0 }
            let g = r.gear(connected: connected)
            return Double(g.present.count) / Double(r.devices.count) + (g.missing.isEmpty ? 1 : 0)
        }
        return recipes.enumerated().sorted { (score($0.element), -$0.offset) > (score($1.element), -$1.offset) }.map(\.element)
    }
}

// MARK: Per-surface presets

public struct SavedPreset: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var date = Date()
    public var data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

/// Named presets for individual settings surfaces (an EQ curve, a mic chain, a set of key rules…), shared by every
/// surface's "Presets" menu. A recipe bundles whole surfaces for a set of gear; a preset is one surface on its own.
@MainActor
public final class PresetLibrary: ObservableObject {
    private let store: JSONStore<[String: [SavedPreset]]>
    @Published public private(set) var all: [String: [SavedPreset]]

    public init(url: URL? = nil) {
        store = url.map { JSONStore<[String: [SavedPreset]]>(url: $0) } ?? JSONStore<[String: [SavedPreset]]>(name: "presets")
        all = store.load(default: [:])
    }

    public func presets(for surface: String) -> [SavedPreset] { (all[surface] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    /// Saves under `name`, replacing a preset of the same name.
    @discardableResult
    public func save(_ name: String, data: Data, for surface: String) -> SavedPreset {
        var list = all[surface] ?? []
        let p = SavedPreset(name: name, data: data)
        if let i = list.firstIndex(where: { $0.name == name }) { var q = p; q.id = list[i].id; list[i] = q } else { list.append(p) }
        all[surface] = list; store.save(all)
        return p
    }
    public func delete(_ id: UUID, for surface: String) {
        all[surface]?.removeAll { $0.id == id }; store.save(all)
    }
}
