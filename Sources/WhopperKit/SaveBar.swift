import Foundation
import Combine

/// Runs something later and can take it back. The app uses the main queue; tests use one they advance by hand.
@MainActor
public protocol RecipeScheduler: AnyObject {
    /// Runs `work` after `seconds` unless the returned closure is called first.
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void
}

@MainActor
public final class MainQueueScheduler: RecipeScheduler {
    public init() {}
    public func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }
}

/// Maps a save-bar row to a whole recipe surface. Audio, for instance, holds several independently saved sections.
public struct SaveBarSection: Identifiable {
    public let id: String
    public let title: String
    public let recipePart: String
    let fingerprint: (Data) -> Data?
    let copy: (Data, Data) -> Data?

    public init(id: String, title: String, recipePart: String? = nil,
                fingerprint: @escaping (Data) -> Data? = { $0 },
                copy: @escaping (Data, Data) -> Data? = { source, _ in source }) {
        self.id = id
        self.title = title
        self.recipePart = recipePart ?? id
        self.fingerprint = fingerprint
        self.copy = copy
    }
}

struct SaveBarDraft: Codable, Equatable, Sendable {
    var recipeID: UUID?
    var baseline: [String: Data]
    var landOnEdit = false
}

/// Tracks changes against the last accepted settings, whether a recipe is active or not.
@MainActor
public final class SaveBarController: ObservableObject {
    public struct Confirmation: Equatable, Sendable {
        public let message: String
        public let canUndo: Bool
    }

    public let store: RecipeStore
    @Published public private(set) var changedSections: [String] = []
    @Published public private(set) var confirmation: Confirmation?
    @Published public var problem: String?

    private let scheduler: RecipeScheduler
    private let drafts: JSONStore<SaveBarDraft?>
    private var draft: SaveBarDraft
    private var persisted: SaveBarDraft?
    private var recipeBaseline: [String: Data]
    private var definitions: [SaveBarSection] = []
    private var lastLive: [String: Data] = [:]
    private var hasStarted = false
    private var performingAction = false
    private var cancelConfirmation: (() -> Void)?
    private var undo: (() -> Bool)?

    public init(store: RecipeStore, scheduler: RecipeScheduler? = nil, draftURL: URL? = nil) {
        self.store = store
        self.scheduler = scheduler ?? MainQueueScheduler()
        drafts = draftURL.map(JSONStore.init(url:)) ?? JSONStore(name: "save-draft")
        recipeBaseline = store.activeBaseline
        let stored = drafts.load(default: nil)
        persisted = stored
        draft = stored ?? SaveBarDraft(recipeID: store.activeID, baseline: store.activeBaseline)
        store.onChange = { [weak self] in self?.recipeDidChange() }
    }

    public var editedSections: [SaveBarSection] { sections.filter { changedSections.contains($0.id) } }
    public var changedTitles: [String] { editedSections.map(\.title) }

    private var sections: [SaveBarSection] {
        if !definitions.isEmpty { return definitions }
        return store.surfaceList.map { SaveBarSection(id: $0.key, title: $0.title) }
    }

    public func start(sections: [SaveBarSection] = []) {
        definitions = sections
        hasStarted = true
        let live = snapshot()
        if draft.recipeID != store.activeID {
            draft = SaveBarDraft(recipeID: store.activeID, baseline: store.activeBaseline)
        }
        draft.baseline = store.canonicalSnapshot(draft.baseline)
        refresh(live)
    }

    public func settingsDidChange() {
        guard !performingAction else { return }
        guard hasStarted else { start(); return }
        refresh(snapshot())
    }

    private func snapshot() -> [String: Data] { store.canonicalSnapshot(store.snapshot(store.surfaceKeys, sync: false)) }

    private func recipeDidChange() {
        guard !performingAction else { return }
        guard hasStarted else { start(); return }
        let live = snapshot()
        let active = store.activeID
        let next = store.activeBaseline
        if active != draft.recipeID || next != recipeBaseline {
            dismissConfirmation()
            for (key, value) in next where draft.recipeID != active || recipeBaseline[key] != value {
                draft.baseline[key] = store.canonicalSnapshot([key: value])[key]
            }
            if active == nil { draft.baseline = live }
            draft.recipeID = active
            recipeBaseline = next
        }
        refresh(live)
    }

    private func refresh(_ live: [String: Data]) {
        // A surface that became available (for example, a connected display) gets a baseline on first read.
        draft.baseline.merge(live) { saved, _ in saved }
        let changed = sections.filter { section in
            guard let before = draft.baseline[section.recipePart].flatMap(section.fingerprint),
                  let after = live[section.recipePart].flatMap(section.fingerprint) else { return false }
            return before != after
        }.map(\.id)
        if confirmation != nil, live != lastLive { dismissConfirmation() }
        lastLive = live
        if changed != changedSections {
            changedSections = changed
            if !changed.isEmpty { store.noteChange() }
        }
        if changed.isEmpty { draft.landOnEdit = false; store.clearUnsavedIfClean() }
        if draft != persisted, drafts.save(draft) { persisted = draft }
    }

    public func noteLeaving() {
        settingsDidChange()
        store.noteLeaving()
        guard !changedSections.isEmpty else { return }
        draft.landOnEdit = true
        refresh(lastLive)
    }

    public func takeLandingPart() -> String? {
        let legacy = store.takeLandingPart()
        guard draft.landOnEdit else { return legacy }
        draft.landOnEdit = false
        refresh(lastLive)
        return editedSections.first?.id ?? legacy
    }

    // MARK: Save and undo

    @discardableResult
    public func save() -> Bool {
        settingsDidChange()
        guard let active = store.active, !changedSections.isEmpty else { return false }
        let before = draft.baseline
        let applied = store.activeBaseline
        let extra = Set(editedSections.map(\.recipePart))
        performingAction = true
        let saved = store.save(active.id, including: extra)
        performingAction = false
        guard let after = store.active, saved || store.activeBaseline != applied else {
            problem = "Could not save the recipe."
            return false
        }
        acceptAll()
        confirm("Saved to recipe \(active.name)") { [weak self] in
            guard let self, self.store.undoRecipeSave(active, after: after, baseline: applied) else { return false }
            self.draft.baseline = before
            return true
        }
        return true
    }

    @discardableResult
    public func saveAsNew(name: String, devices: [DeviceSignature] = []) -> Bool {
        let before = draft.baseline
        let priorID = store.activeID
        let applied = store.activeBaseline
        performingAction = true
        let created = store.saveAsNew(from: priorID, name: name, including: store.surfaceKeys, devices: devices)
        performingAction = false
        guard let created else { problem = "Could not save the recipe."; return false }
        acceptAll()
        confirm("Saved as recipe \(created.name)") { [weak self] in
            guard let self, self.store.undoCreatedRecipe(created, priorID: priorID, baseline: applied) else { return false }
            self.draft.baseline = before
            return true
        }
        return true
    }

    /// Applying a preset is a saved choice for settings outside the active recipe.
    public func didChoosePreset(in section: String, copy: (Data, Data) -> Data?) {
        guard let part = sections.first(where: { $0.id == section }),
              store.active?.sections[part.recipePart] == nil else { settingsDidChange(); return }
        accept(part, using: snapshot(), copy: copy)
    }

    @discardableResult
    public func savePreset(_ name: String, in section: String?, copy: ((Data, Data) -> Data?)? = nil,
                           write: () -> (() -> Bool)?) -> Bool {
        settingsDidChange()
        let before = draft.baseline
        performingAction = true
        let undo = write()
        performingAction = false
        guard let undo else { return false }
        let live = snapshot()
        if let part = sections.first(where: { $0.id == section }) { accept(part, using: live, copy: copy ?? part.copy) }
        else { refresh(live) }
        confirm("Saved to preset \(name)") { [weak self] in
            guard let self, undo() else { return false }
            self.draft.baseline = before
            return true
        }
        return true
    }

    private func accept(_ section: SaveBarSection, using live: [String: Data], copy: (Data, Data) -> Data?) {
        let key = section.recipePart
        if let source = live[key] {
            let target = draft.baseline[key] ?? source
            draft.baseline[key] = copy(source, target) ?? target
        }
        recipeBaseline = store.activeBaseline
        refresh(live)
    }

    private func acceptAll() {
        let live = snapshot()
        recipeBaseline = store.activeBaseline
        draft = SaveBarDraft(recipeID: store.activeID, baseline: live)
        refresh(live)
    }

    public func putBack() {
        settingsDidChange()
        guard !changedSections.isEmpty else { return }
        let live = lastLive
        var restored: [String: Data] = [:]
        for section in editedSections {
            let key = section.recipePart
            if let before = draft.baseline[key], let target = restored[key] ?? live[key] {
                restored[key] = section.copy(before, target) ?? target
            }
        }
        let failures = store.restore(restored)
        refresh(snapshot())
        if !failures.isEmpty { problem = "Could not put back \(failures.joined(separator: ", "))." }
        confirm("Changes put back") { [weak self] in
            guard let self else { return false }
            let undo = live.filter { restored[$0.key] != nil }
            return self.store.restore(undo).isEmpty
        }
    }

    public func undoSave() {
        guard let undo else { return }
        dismissConfirmation()
        performingAction = true
        let restored = undo()
        performingAction = false
        if !restored { problem = "Could not undo the changes." }
        draft.recipeID = store.activeID
        recipeBaseline = store.activeBaseline
        refresh(snapshot())
    }

    private func confirm(_ message: String, undo: @escaping () -> Bool) {
        dismissConfirmation()
        self.undo = undo
        confirmation = Confirmation(message: message, canUndo: true)
        cancelConfirmation = scheduler.schedule(after: 4) { [weak self] in self?.dismissConfirmation() }
    }

    private func dismissConfirmation() {
        cancelConfirmation?()
        cancelConfirmation = nil
        undo = nil
        confirmation = nil
    }

    public func reloadDraft() {
        dismissConfirmation()
        let restored = drafts.load(default: nil)
        draft = restored ?? SaveBarDraft(recipeID: store.activeID, baseline: store.activeBaseline)
        persisted = restored
        recipeBaseline = store.activeBaseline
        start(sections: definitions)
    }
}
