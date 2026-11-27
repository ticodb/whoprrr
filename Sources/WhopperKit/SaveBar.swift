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

/// The waits and what the window shows during them. A recipe behaves like a document, so while its settings differ from what it
/// holds the window offers to save them; this decides when, and what each moment says.
///
/// - While the settings are still being changed, only "Cookin'" shows. The save bar waits until they have been left alone for
///   `settle` seconds, so trying a slider does not flash a bar on and off.
/// - Saving shows "Cookin'" for `saving` seconds, then a confirmation for `confirmation` seconds, with Undo for as long as it shows.
@MainActor
public final class SaveBarController: ObservableObject {
    public struct Timing: Sendable {
        public var settle: TimeInterval = 2
        public var saving: TimeInterval = 0.6
        public var confirmation: TimeInterval = 10
        public init(settle: TimeInterval = 2, saving: TimeInterval = 0.6, confirmation: TimeInterval = 10) {
            self.settle = settle; self.saving = saving; self.confirmation = confirmation
        }
    }

    public struct Confirmation: Equatable, Sendable {
        public var message: String
        /// The recipe the Undo button goes back on; nil when there is nothing to undo to.
        public var undoRecipeID: UUID?
    }

    public enum Phase: Equatable, Sendable {
        /// Nothing unsaved, nothing to say.
        case idle
        /// Settings are being changed: show "Cookin'".
        case changing(recipe: String)
        /// Settings have been left alone and still differ: show the save bar.
        case unsaved(recipe: String, parts: [String])
        /// A save is under way: show "Cookin'".
        case saving(recipe: String)
        /// Saved: show the confirmation, with Undo.
        case saved(Confirmation)
    }

    public let store: RecipeStore
    private let scheduler: RecipeScheduler
    private let timing: Timing
    @Published public private(set) var phase: Phase = .idle

    private var lastLive: [String: Data]?
    private var trackedID: UUID?
    private var cancelSettle: (() -> Void)?
    private var cancelNext: (() -> Void)?

    public init(store: RecipeStore, scheduler: RecipeScheduler? = nil, timing: Timing = Timing()) {
        self.store = store
        self.scheduler = scheduler ?? MainQueueScheduler()
        self.timing = timing
        store.onChange = { [weak self] in self?.settingsDidChange() }
    }

    /// The label for a deliberate wait, or nil when nothing is waiting. One label for every wait.
    public var cookinLabel: String? {
        switch phase {
        case .changing(let r): RecipeWording.changingLabel(recipe: r)
        case .saving(let r): RecipeWording.savingLabel(recipe: r)
        default: nil
        }
    }

    /// Looks at the settings once the surfaces have loaded. Changes left unsaved last time are still there: the bar shows at once.
    public func start() {
        trackedID = store.activeID
        guard let a = store.active else { return }
        let live = store.snapshot(Set(a.sections.keys))
        let parts = store.changedPartTitles(live: live)
        if parts.isEmpty { store.clearUnsavedIfClean(); return }
        lastLive = live
        phase = .unsaved(recipe: a.name, parts: parts)
    }

    /// Something that could be a setting changed (or the active recipe did). Cheap when nothing really did.
    public func settingsDidChange() {
        if store.activeID != trackedID { trackedID = store.activeID; reset() }
        guard let a = store.active else { reset(); return }
        let live = store.snapshot(Set(a.sections.keys))
        if store.changedParts(live: live).isEmpty {
            switch phase {
            case .changing, .unsaved: reset()
            default: break
            }
            return
        }
        switch phase {
        case .changing, .unsaved: if live == lastLive { return }       // the same change seen again: nothing new
        default: break
        }
        // A new change: back to "Cookin'", and the bar waits for the settings to be left alone.
        lastLive = live
        cancelWaits()
        store.noteChange()
        phase = .changing(recipe: a.name)
        cancelSettle = scheduler.schedule(after: timing.settle) { [weak self] in self?.settled() }
    }

    private func settled() {
        cancelSettle = nil
        guard let a = store.active else { reset(); return }
        let live = store.snapshot(Set(a.sections.keys))
        let parts = store.changedPartTitles(live: live)
        if parts.isEmpty { reset(); return }
        lastLive = live
        store.noteChange(persist: true)
        phase = .unsaved(recipe: a.name, parts: parts)
    }

    // MARK: Actions

    /// Saves into the active recipe: "Cookin'" for a moment, then the confirmation with Undo.
    public func save() {
        guard let a = store.active else { return }
        cancelWaits()
        let changed = store.save(a.id)
        confirm(saving: a.name, message: "Saved to \(a.name).", undoRecipeID: changed ? a.id : nil)
    }

    /// Saves the live settings as a new recipe and makes it the active one.
    public func saveAsNew(name: String) {
        guard let a = store.active else { return }
        cancelWaits()
        guard let r = store.saveAsNew(from: a.id, name: name) else { return }
        confirm(saving: r.name, message: "Saved as “\(r.name)”.", undoRecipeID: nil)
    }

    /// Discards the unsaved change: the settings go back to what the recipe holds.
    public func putBack() {
        guard let a = store.active else { return }
        cancelWaits()
        store.putBack(a.id)
        reset()
    }

    /// Undo on the confirmation: the same swap as "Go back to the version before…" in the recipe's menu.
    public func undoSave() {
        guard case .saved(let c) = phase, let id = c.undoRecipeID else { return }
        cancelWaits()
        store.goBack(id)
        reset()
    }

    public func dismissConfirmation() {
        if case .saved = phase { cancelWaits(); phase = .idle }
    }

    private func confirm(saving name: String, message: String, undoRecipeID: UUID?) {
        trackedID = store.activeID
        lastLive = nil
        phase = .saving(recipe: name)
        cancelNext = scheduler.schedule(after: timing.saving) { [weak self] in
            guard let self else { return }
            self.phase = .saved(Confirmation(message: message, undoRecipeID: undoRecipeID))
            self.cancelNext = self.scheduler.schedule(after: self.timing.confirmation) { [weak self] in
                self?.cancelNext = nil
                if case .saved = self?.phase { self?.phase = .idle }
            }
        }
    }

    private func cancelWaits() {
        cancelSettle?(); cancelSettle = nil
        cancelNext?(); cancelNext = nil
    }

    private func reset() {
        cancelWaits()
        lastLive = nil
        if phase != .idle { phase = .idle }
        store.clearUnsavedIfClean()
    }
}
