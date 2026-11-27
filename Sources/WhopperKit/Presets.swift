import Foundation
import Combine

public struct SavedPreset: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var date = Date()
    public var data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

public struct FactoryPreset: Sendable {
    public let id: String
    public let name: String
    public let data: Data

    public init(id: String, name: String, data: Data) {
        self.id = id
        self.name = name
        self.data = data
    }
}

public enum PresetID: Hashable, Codable, Sendable {
    case personal(UUID)
    case factory(String)
}

public struct PresetLocation: Hashable, Codable, Sendable {
    public let control: String
    public let device: String?

    public init(_ control: String, device: String? = nil) {
        self.control = control
        self.device = device
    }
}

public struct PresetEntry: Identifiable, Equatable, Sendable {
    public let id: PresetID
    public var name: String
    public var data: Data
    public var changed = false

    public var isFactory: Bool {
        if case .factory = id { return true }
        return false
    }
}

public struct PresetGroups: Equatable, Sendable {
    public var inUse: PresetEntry?
    public var edited: Bool
    public var yours: [PresetEntry]
    public var builtIn: [PresetEntry]
    public var hidden: [PresetEntry]

    public var selectableYours: [PresetEntry] { yours.filter { $0.id != inUse?.id } }
    public var selectableBuiltIn: [PresetEntry] { builtIn.filter { $0.id != inUse?.id } }
}

struct PresetCatalog: Codable, Equatable, Sendable {
    struct Override: Codable, Equatable, Sendable {
        var name: String?
        var data: Data?
        var hidden = false
    }

    var yours: [String: [SavedPreset]] = [:]
    var overrides: [String: [String: Override]] = [:]
    var selections: [PresetLocation: PresetID] = [:]

    func groups(at location: PresetLocation, factory: [FactoryPreset], live: Data?,
                matches: (Data, Data) -> Bool) -> PresetGroups {
        let yours = (yours[location.control] ?? []).map {
            PresetEntry(id: .personal($0.id), name: $0.name, data: $0.data)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var builtIn: [PresetEntry] = []
        var hidden: [PresetEntry] = []
        for preset in factory {
            let edit = overrides[location.control]?[preset.id]
            let entry = PresetEntry(id: .factory(preset.id), name: edit?.name ?? preset.name,
                                    data: edit?.data ?? preset.data, changed: edit?.name != nil || edit?.data != nil)
            if edit?.hidden == true { hidden.append(entry) } else { builtIn.append(entry) }
        }
        let inUse = (yours + builtIn).first { $0.id == selections[location] }
        let edited = inUse.flatMap { picked in live.map { !matches($0, picked.data) } } ?? false
        return PresetGroups(inUse: inUse, edited: edited, yours: yours, builtIn: builtIn, hidden: hidden)
    }

    mutating func select(_ id: PresetID?, at location: PresetLocation) { selections[location] = id }

    mutating func save(_ name: String, data: Data, for control: String, replacing: Bool) -> SavedPreset {
        var preset = SavedPreset(name: name, data: data)
        if replacing, let index = yours[control]?.firstIndex(where: { $0.name == name }) {
            guard let existing = yours[control]?[index] else { return preset }
            preset.id = existing.id
            yours[control]?[index] = preset
        } else {
            yours[control, default: []].append(preset)
        }
        return preset
    }

    enum Record: Equatable, Sendable {
        case personal(SavedPreset)
        case factory(Override?)
    }

    func record(_ id: PresetID, for control: String) -> Record? {
        switch id {
        case .personal(let id): yours[control]?.first { $0.id == id }.map(Record.personal)
        case .factory(let id): .factory(overrides[control]?[id])
        }
    }

    mutating func restore(_ record: Record, id: PresetID, for control: String) {
        switch (id, record) {
        case (.personal(let id), .personal(let value)):
            if let index = yours[control]?.firstIndex(where: { $0.id == id }) { yours[control]?[index] = value }
        case (.factory(let id), .factory(let value)):
            overrides[control, default: [:]][id] = value
        default: break
        }
    }

    mutating func edit(_ id: PresetID, for control: String, name: String? = nil, data: Data? = nil) {
        switch record(id, for: control) {
        case .personal(var entry):
            if let name { entry.name = name }
            if let data { entry.data = data; entry.date = Date() }
            restore(.personal(entry), id: id, for: control)
        case .factory(let entry):
            var value = entry ?? Override()
            if let name { value.name = name }
            if let data { value.data = data }
            restore(.factory(value), id: id, for: control)
        case nil: break
        }
    }

    mutating func restoreFactory(_ id: String, for control: String) {
        if overrides[control]?[id]?.hidden == true {
            overrides[control]?[id] = Override(hidden: true)
        } else {
            overrides[control]?[id] = nil
        }
    }

    mutating func setHidden(_ hidden: Bool, id: String, for control: String) {
        var value = overrides[control]?[id] ?? Override()
        value.hidden = hidden
        overrides[control, default: [:]][id] = value
        if hidden { forget(.factory(id), for: control) }
    }

    mutating func delete(_ id: UUID, for control: String) {
        yours[control]?.removeAll { $0.id == id }
        forget(.personal(id), for: control)
    }

    private mutating func forget(_ id: PresetID, for control: String) {
        selections = selections.filter { $0.key.control != control || $0.value != id }
    }
}

struct PresetFile: Codable, Sendable {
    struct Pending: Codable, Sendable {
        let previous: PresetCatalog
        let recipe: PresetRecipeEdit
    }
    var catalog = PresetCatalog()
    var pending: Pending?

    init(catalog: PresetCatalog = PresetCatalog(), pending: Pending? = nil) {
        self.catalog = catalog
        self.pending = pending
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        if let current = try? fields.decode(PresetCatalog.self, forKey: .catalog) {
            catalog = current
            pending = try fields.decodeIfPresent(Pending.self, forKey: .pending)
        } else {
            catalog.yours = try decoder.singleValueContainer().decode([String: [SavedPreset]].self)
        }
    }
}

@MainActor
public final class PresetLibrary: ObservableObject {
    public struct Update {
        public let message: String
        let id: PresetID
        let control: String
        let before: PresetCatalog.Record
        let after: PresetCatalog.Record
        let recipeEdit: PresetRecipeEdit?
    }

    public struct Creation {
        let preset: SavedPreset
        let location: PresetLocation
        let previous: PresetID?
        let recipeEdit: PresetRecipeEdit?
    }

    private let store: JSONStore<PresetFile>
    public private(set) var preservesUnreadableFile = false
    @Published private var catalog: PresetCatalog

    public init(url: URL? = nil, recipes: RecipeStore? = nil) {
        store = url.map { JSONStore<PresetFile>(url: $0) } ?? JSONStore<PresetFile>(name: "presets")
        catalog = PresetCatalog()
        reloadAfterBackup(recipes: recipes)
    }

    public func reloadAfterBackup(recipes: RecipeStore?) {
        let (file, protected) = Self.load(at: store.url)
        preservesUnreadableFile = protected
        catalog = file.catalog
        if let pending = file.pending, let recipes {
            if !recipes.hasPresetVersion(pending.recipe.after) { catalog = pending.previous }
            store.save(PresetFile(catalog: catalog))
        }
    }

    private static func load(at url: URL) -> (PresetFile, Bool) {
        let manager = FileManager.default
        do {
            let data = try Data(contentsOf: url)
            return (try JSONDecoder().decode(PresetFile.self, from: data), false)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile
            && (try? manager.destinationOfSymbolicLink(atPath: url.path)) == nil {
            return (PresetFile(), false)
        } catch {
            let stamp = Date.now.ISO8601Format().replacingOccurrences(of: ":", with: "-")
            let copy = JSONStore<PresetFile>.uniqueSibling(of: url) { number in
                url.appendingPathExtension("unreadable-\(stamp)" + (number == 1 ? "" : "-\(number)"))
            }
            try? manager.copyItem(at: url, to: copy)
            return (PresetFile(), true)
        }
    }

    public func groups(at location: PresetLocation, factory: [FactoryPreset], live: Data?,
                       matches: (Data, Data) -> Bool) -> PresetGroups {
        catalog.groups(at: location, factory: factory, live: live, matches: matches)
    }

    public func presets(for surface: String) -> [SavedPreset] {
        (catalog.yours[surface] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The existing entry point for a part taken from the shelf. Taking a part does not apply it.
    @discardableResult
    public func save(_ name: String, data: Data, for surface: String) -> SavedPreset? {
        var next = catalog
        let result = next.save(name, data: data, for: surface, replacing: true)
        return commit(next) ? result : nil
    }

    @discardableResult
    public func saveNew(_ name: String, data: Data, at location: PresetLocation) -> Bool {
        create(name, data: data, at: location) != nil
    }

    public func create(_ name: String, data: Data, at location: PresetLocation, recipePart: String? = nil,
                       recipes: RecipeStore? = nil, mergeRecipePart: ((Data, Data) -> Data?)? = nil) -> Creation? {
        var next = catalog
        let previous = next.selections[location]
        let added = next.save(name, data: data, for: location.control, replacing: false)
        next.select(.personal(added.id), at: location)
        let edit = recipes?.active.flatMap { recipes?.presetSave(for: $0, part: recipePart, merge: mergeRecipePart) }
        guard commit(next, recipes: recipes, edit: edit) else { return nil }
        return Creation(preset: added, location: location, previous: previous, recipeEdit: edit)
    }

    public func undoCreation(_ creation: Creation, recipes: RecipeStore? = nil) -> Bool {
        let id = PresetID.personal(creation.preset.id)
        guard catalog.record(id, for: creation.location.control) == .personal(creation.preset),
              catalog.selections[creation.location] == id else { return false }
        var next = catalog
        next.delete(creation.preset.id, for: creation.location.control)
        next.select(creation.previous, at: creation.location)
        let edit = creation.recipeEdit.flatMap { recipes?.presetUndo($0) }
        if creation.recipeEdit != nil, edit == nil { return false }
        return commit(next, recipes: recipes, edit: edit)
    }

    @discardableResult
    public func select(_ id: PresetID, at location: PresetLocation) -> Bool {
        change { $0.select(id, at: location) }
    }

    @discardableResult
    public func rename(_ id: PresetID, to name: String, for control: String) -> Bool {
        guard case .personal = id else { return false }
        return change { $0.edit(id, for: control, name: name) }
    }

    @discardableResult
    public func duplicate(_ entry: PresetEntry, name: String, for control: String) -> Bool {
        change { _ = $0.save(name, data: entry.data, for: control, replacing: false) }
    }

    @discardableResult
    public func delete(_ id: UUID, for control: String) -> Bool {
        change { $0.delete(id, for: control) }
    }

    @discardableResult
    public func setHidden(_ hidden: Bool, id: String, for control: String) -> Bool {
        change { $0.setHidden(hidden, id: id, for: control) }
    }

    @discardableResult
    public func restoreFactory(_ id: String, for control: String) -> Bool {
        change { $0.restoreFactory(id, for: control) }
    }

    public func update(_ entry: PresetEntry, with data: Data, at location: PresetLocation,
                       recipePart: String, recipes: RecipeStore,
                       mergeRecipePart: ((Data, Data) -> Data?)? = nil) -> Update? {
        let control = location.control
        guard !entry.isFactory, let before = catalog.record(entry.id, for: control) else { return nil }
        var next = catalog
        next.edit(entry.id, for: control, data: data)
        guard let after = next.record(entry.id, for: control) else { return nil }
        // An update of a different row is a preset-only edit. It does not save unrelated live recipe changes.
        let recipe = catalog.selections[location] == entry.id ? recipes.active : nil
        let included = recipe.flatMap { $0.sections[recipePart] == nil ? nil : $0 }
        let edit = included.flatMap { recipes.presetSave(for: $0, part: recipePart, merge: mergeRecipePart) }
        guard commit(next, recipes: recipes, edit: edit) else { return nil }
        let message = included.map { "“\(entry.name)” updated and saved to \($0.name)." } ?? "“\(entry.name)” updated."
        return Update(message: message, id: entry.id, control: control, before: before, after: after, recipeEdit: edit)
    }

    public func undo(_ update: Update, recipes: RecipeStore, applyRecipe: Bool = true) -> Bool {
        guard catalog.record(update.id, for: update.control) == update.after else { return false }
        let edit = update.recipeEdit.flatMap { recipes.presetUndo($0) }
        if update.recipeEdit != nil, edit == nil { return false }
        var next = catalog
        next.restore(update.before, id: update.id, for: update.control)
        return commit(next, recipes: recipes, edit: edit, apply: applyRecipe)
    }

    private func change(_ edit: (inout PresetCatalog) -> Void) -> Bool {
        var next = catalog
        edit(&next)
        return commit(next)
    }

    @discardableResult
    private func commit(_ next: PresetCatalog, recipes: RecipeStore? = nil, edit: PresetRecipeEdit? = nil,
                        apply: Bool = false) -> Bool {
        guard !preservesUnreadableFile else { return false }
        guard let recipes, let edit else {
            guard store.save(PresetFile(catalog: next)) else { return false }
            catalog = next
            return true
        }

        // A journal in the presets file resolves interruption between the two atomic writes.
        let pending = PresetFile.Pending(previous: catalog, recipe: edit)
        guard store.save(PresetFile(catalog: next, pending: pending)) else { return false }
        guard recipes.commitPresetEdit(edit, apply: apply) else {
            store.save(PresetFile(catalog: catalog))
            return false
        }
        catalog = next
        store.save(PresetFile(catalog: next))
        return true
    }
}
