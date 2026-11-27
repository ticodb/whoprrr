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

/// Presentation and timing for saving changes to the active recipe.
@MainActor
public final class SaveBarController: ObservableObject {
    public static let savingDuration: TimeInterval = 0.5
    public static let reminder = "Alright! We see you cookin’… let us know when you’re done."
    private static let servedDuration: TimeInterval = 1.1
    private static let confirmationDuration: TimeInterval = 4

    public struct Confirmation: Equatable, Sendable {
        public var message: String
        public var undoRecipeID: UUID?
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case changing(recipe: String)
        case saving(recipe: String)
        case saved(Confirmation)
    }

    public let store: RecipeStore
    private let scheduler: RecipeScheduler
    private let now: () -> TimeInterval
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var reminderRecipe: String?
    @Published public private(set) var served = false

    private var canRemind = false
    private var lastLive: [String: Data]?
    private var trackedID: UUID?
    private var cancelNext: (() -> Void)?
    private var cancelServed: (() -> Void)?
    private var confirmationDeadline: TimeInterval?
    private var confirmationRemaining: TimeInterval = confirmationDuration

    public init(store: RecipeStore, scheduler: RecipeScheduler? = nil,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store
        self.scheduler = scheduler ?? MainQueueScheduler()
        self.now = now
        store.onChange = { [weak self] in self?.settingsDidChange() }
    }

    public func start() { checkSettings(recordChange: false) }

    /// Recheck after a setting or the active recipe changes. Only a new canonical snapshot rearms the reminder.
    public func settingsDidChange() { checkSettings(recordChange: true) }

    private func checkSettings(recordChange: Bool) {
        if store.activeID != trackedID {
            trackedID = store.activeID
            reset()
        }
        guard let active = store.active else { return }
        let live = store.snapshot(Set(active.sections.keys))
        if store.changedParts(live: live).isEmpty {
            if case .changing = phase { reset() }
            return
        }
        let canonical = store.canonicalSnapshot(live)
        if canonical == lastLive {
            if phase != .changing(recipe: active.name) {
                phase = .changing(recipe: active.name)
                if reminderRecipe != nil { reminderRecipe = active.name }
            }
            return
        }
        reset()
        lastLive = canonical
        canRemind = true
        if recordChange { store.noteChange() }
        phase = .changing(recipe: active.name)
    }

    public func pageDidChange() {
        settingsDidChange()
        guard canRemind, case .changing(let name) = phase else { return }
        canRemind = false
        reminderRecipe = name
    }

    public func dismissReminder() { reminderRecipe = nil }

    // MARK: Actions

    public func save() {
        guard let active = store.active else { return }
        let changed = store.save(active.id)
        confirm(saving: active.name, .init(message: "Saved to \(active.name).", undoRecipeID: changed ? active.id : nil))
    }

    public func saveAsNew(name: String) {
        guard let active = store.active, let copy = store.saveAsNew(from: active.id, name: name) else { return }
        confirm(saving: copy.name, .init(message: "Saved as “\(copy.name)”.", undoRecipeID: nil))
    }

    public func putBack() {
        guard let active = store.active else { return }
        store.putBack(active.id)
        reset()
    }

    public func undoSave() {
        guard case .saved(let confirmation) = phase, let id = confirmation.undoRecipeID else { return }
        store.goBack(id)
        reset()
    }

    public func dismissConfirmation() {
        if case .saved = phase { reset() }
    }

    public func hoverConfirmation(_ hovering: Bool) {
        guard case .saved = phase else { return }
        if hovering, let deadline = confirmationDeadline {
            confirmationRemaining = max(0, deadline - now())
            cancelNext?()
            cancelNext = nil
            confirmationDeadline = nil
        } else if !hovering, confirmationDeadline == nil {
            scheduleDismissal()
        }
    }

    private func confirm(saving name: String, _ confirmation: Confirmation) {
        reset()
        phase = .saving(recipe: name)
        cancelNext = scheduler.schedule(after: Self.savingDuration) { [weak self] in
            guard let self else { return }
            self.served = true
            self.phase = .saved(confirmation)
            self.cancelServed = self.scheduler.schedule(after: Self.servedDuration) { [weak self] in
                self?.served = false
                self?.cancelServed = nil
            }
            self.scheduleDismissal()
        }
    }

    private func scheduleDismissal() {
        confirmationDeadline = now() + confirmationRemaining
        cancelNext = scheduler.schedule(after: confirmationRemaining) { [weak self] in self?.dismissConfirmation() }
    }

    private func reset() {
        cancelNext?()
        cancelNext = nil
        cancelServed?()
        cancelServed = nil
        confirmationDeadline = nil
        confirmationRemaining = Self.confirmationDuration
        lastLive = nil
        canRemind = false
        if served { served = false }
        if reminderRecipe != nil { reminderRecipe = nil }
        if phase != .idle { phase = .idle }
        store.clearUnsavedIfClean()
    }
}
