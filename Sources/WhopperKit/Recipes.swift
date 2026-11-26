import Foundation
import Combine

// MARK: Gear

/// What a piece of gear is for, in words that mean the same on any Mac: "microphone", "speaker", "display"…
/// An open set, so a file from a newer Whoprrr with a role this one does not know still reads and writes back unchanged.
public struct DeviceRole: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let microphone = DeviceRole(rawValue: "microphone")
    public static let speaker = DeviceRole(rawValue: "speaker")
    public static let display = DeviceRole(rawValue: "display")
    public static let keyboard = DeviceRole(rawValue: "keyboard")
    public static let mouse = DeviceRole(rawValue: "mouse")
    public static let other = DeviceRole(rawValue: "other")

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }

    /// The role of a device from what the Mac reports about it. For audio and displays the kind already says it (the gear scan
    /// separates inputs from outputs the same way); for Logitech devices the name does.
    public static func of(kind: DeviceSignature.Kind, name: String) -> DeviceRole {
        switch kind {
        case .audioInput: return .microphone
        case .audioOutput: return .speaker
        case .display: return .display
        case .logitech:
            let n = name.lowercased()
            if n.contains("keys") || n.contains("keyboard") || n.contains("craft") { return .keyboard }
            if n.contains("mx master") || n.contains("mx ergo") || n.contains("mx anywhere") || n.contains("mx vertical")
                || n.contains("mouse") || n.contains("trackball") || n.contains("lift") { return .mouse }
            return .other
        }
    }
}

/// A peripheral a recipe was made for: a display, a microphone, speakers, a Logitech device.
///
/// `kind` + `key` is what this Mac uses to recognise the device (an audio UID, a display EDID); `role` + `model` say what it
/// is in words, so a recipe file still makes sense on another Mac. Only `kind` + `key` decide whether gear is connected.
public struct DeviceSignature: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case audioOutput, audioInput, display, logitech }
    public var kind: Kind
    /// Stable identifier on this Mac (audio device UID, display EDID, Logitech name).
    public var key: String
    public var name: String
    /// What it is for: "microphone", "speaker", "display"…
    public var role: DeviceRole
    /// The model, without a person's name in it ("AirPods Pro", not "Ana’s AirPods Pro").
    public var model: String
    public var id: String { "\(kind.rawValue):\(key)" }

    public init(kind: Kind, key: String, name: String, role: DeviceRole? = nil, model: String? = nil) {
        self.kind = kind; self.key = key; self.name = name
        self.role = role ?? DeviceRole.of(kind: kind, name: name)
        self.model = model ?? KnownGear.publicName(name)
    }

    private enum CodingKeys: String, CodingKey { case kind, key, name, role, model }

    /// Files from before roles and models existed have neither; they are worked out from the name, so nothing is lost.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind), key = try c.decode(String.self, forKey: .key), name = try c.decode(String.self, forKey: .name)
        self.init(kind: kind, key: key, name: name,
                  role: try c.decodeIfPresent(DeviceRole.self, forKey: .role), model: try c.decodeIfPresent(String.self, forKey: .model))
    }

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

/// One earlier state of a recipe's settings, kept so the last save can be undone, and the undo undone.
public struct RecipeVersion: Codable, Equatable, Sendable {
    public var sections: [String: Data]
    /// When this content was saved.
    public var savedAt: Date
    /// When it stopped being the recipe's content (the save that replaced it, or the swap that put it aside).
    public var replacedAt: Date
    /// True when this content is newer than what the recipe holds now: it is what going back just put aside.
    public var isNewer: Bool

    public init(sections: [String: Data], savedAt: Date, replacedAt: Date, isNewer: Bool = false) {
        self.sections = sections; self.savedAt = savedAt; self.replacedAt = replacedAt; self.isNewer = isNewer
    }
}

/// A line of a taken shared setup that was switched off when it was fitted to this Mac, and why, so it can be switched on later.
public struct SkippedLine: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// The part it belongs to ("audio", "keys"…).
    public var part: String
    public var title: String
    /// In plain words: "Plugin “Pro-Q 3” is not installed".
    public var reason: String
    public init(id: String, part: String, title: String, reason: String) { self.id = id; self.part = part; self.title = title; self.reason = reason }
}

/// The setup as its author made it and as it first fitted this Mac. Kept only on recipes taken from a shared setup, and apart
/// from `previous`: saving, going back and going forward never touch it.
public struct AuthorsOriginal: Codable, Equatable, Sendable {
    public var title: String
    /// Opaque: who made it, as the shelf or the file said.
    public var madeBy: String?
    /// The shared setup document, as taken (`SharedSetup` JSON).
    public var setup: Data
    /// The recipe's settings as they first fitted this Mac.
    public var fittedSections: [String: Data]
    public var takenAt: Date
    public init(title: String, madeBy: String?, setup: Data, fittedSections: [String: Data], takenAt: Date) {
        self.title = title; self.madeBy = madeBy; self.setup = setup; self.fittedSections = fittedSections; self.takenAt = takenAt
    }
}

/// A named setup for a set of gear: a snapshot of settings per surface (audio, windows, clipboard, keys…) that can be
/// applied in one click. Each section is that surface's own settings as JSON, so recipes survive new fields.
/// It behaves like a document: the settings are saved into it, and it keeps one previous version.
public struct Recipe: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var symbol: String = "fork.knife"
    public var createdAt = Date()
    /// When the settings in `sections` were saved.
    public var updatedAt = Date()
    public var devices: [DeviceSignature] = []
    public var sections: [String: Data] = [:]
    /// Apply by itself when exactly this gear shows up.
    public var autoApply = false
    /// The version before the last save (or the one a "go back" put aside). One only, swapped with the current one.
    public var previous: RecipeVersion?
    /// Only for recipes taken from a shared setup: the author's version, as first fitted. A second slot, apart from `previous`.
    public var authorsOriginal: AuthorsOriginal?
    /// Only for recipes taken from a shared setup: the lines that were switched off for this Mac.
    public var skippedLines: [SkippedLine]?

    public init(name: String, symbol: String = "fork.knife", devices: [DeviceSignature] = [], sections: [String: Data] = [:], autoApply: Bool = false) {
        self.name = name; self.symbol = symbol; self.devices = devices; self.sections = sections; self.autoApply = autoApply
    }

    /// The lines of the taken setup that are still switched off.
    public var skipped: [SkippedLine] { skippedLines ?? [] }

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
    /// The same settings in the one form this surface writes today, for comparing. A recipe saved by an earlier version, or in
    /// another launch, may hold equal settings in different bytes (a set in another order); this brings both to the same bytes.
    func canonicalRecipeData(_ data: Data) -> Data
}
public extension RecipeSurface {
    func canonicalRecipeData(_ data: Data) -> Data { data }
}

public enum RecipeJSON {
    public static func encode<T: Encodable>(_ v: T) -> Data? {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try? e.encode(v)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from d: Data) -> T? { try? JSONDecoder().decode(type, from: d) }
}

// MARK: Auto-switch

/// What to do about an auto-apply recipe whose gear has just shown up.
public enum AutoSwitchDecision: Equatable, Sendable {
    /// Nothing qualifies, or the recipe is already active.
    case none
    /// Switch now: there is nothing unsaved to lose.
    case switchNow(UUID)
    /// The active recipe has unsaved changes; ask first.
    case ask(PendingSwitch)
}

/// The question put to the person when an automatic switch would leave unsaved changes behind.
public struct PendingSwitch: Equatable, Identifiable, Sendable {
    public var candidateID: UUID
    public var candidateName: String
    public var currentID: UUID
    public var currentName: String
    /// Titles of the parts with unsaved changes ("Audio").
    public var parts: [String]
    public var id: String { "\(currentID)>\(candidateID)" }
}

public enum AutoSwitchChoice: Sendable {
    /// Keep the work in the current recipe, then switch.
    case saveThenSwitch
    /// Switch and leave the unsaved changes behind.
    case switchWithoutSaving
    /// Do not switch.
    case stay
}

// MARK: Store

/// All recipes, which one is active, and the logic to capture, apply, save and auto-apply them.
@MainActor
public final class RecipeStore: ObservableObject {
    private let fileStore: RecipeFileStore
    private let now: () -> Date
    private var surfaces: [String: RecipeSurface] = [:]
    @Published public private(set) var recipes: [Recipe]
    @Published public private(set) var activeID: UUID?
    /// A short note about the last automatic or manual change ("Applied Home"), for the UI to show.
    @Published public var notice: String?
    /// Set while the active recipe has changes left unsaved with the window closed or the app quit.
    @Published public private(set) var stove: LeftOnStove?
    /// Set when an automatic switch is waiting for an answer.
    @Published public private(set) var pendingSwitch: PendingSwitch?
    private var applied: [String: Data]
    private var changedAt: Date?
    /// How the file was found at launch.
    public let loadOutcome: RecipeLoadOutcome
    private let canWrite: Bool
    private var capturing = 0
    /// Called after anything that changes which recipe is active or what it holds, so a controller can re-check.
    public var onChange: (() -> Void)?

    public init(url: URL? = nil, now: @escaping () -> Date = { Date() }) {
        self.now = now
        fileStore = RecipeFileStore(url: url ?? JSONStore<RecipeFile>(name: "recipes").url)
        let (f, outcome) = fileStore.load()
        recipes = f.recipes; activeID = f.activeID; applied = f.appliedSections; changedAt = f.changedAt; stove = f.stove
        loadOutcome = outcome
        switch outcome {
        case .migrationBlocked, .newerFormat, .unreadable: canWrite = false
        default: canWrite = true
        }
    }

    public func register(_ s: RecipeSurface) { surfaces[s.recipeKey] = s }
    public var surfaceList: [(key: String, title: String)] {
        surfaces.values.map { ($0.recipeKey, $0.recipeTitle) }.sorted { $0.title < $1.title }
    }
    public var active: Recipe? { recipes.first { $0.id == activeID } }
    public func recipe(_ id: UUID) -> Recipe? { recipes.first { $0.id == id } }
    public func title(forPart key: String) -> String { surfaces[key]?.recipeTitle ?? key }

    private func save() {
        guard canWrite else { return }
        _ = fileStore.save(RecipeFile(recipes: recipes, activeID: activeID, appliedSections: applied, changedAt: changedAt, stove: stove))
    }

    // MARK: Capture and apply

    /// True while a surface is being read. Reading some surfaces can touch their own state, so change notifications that
    /// arrive during it are not the person's doing and should be ignored.
    public var isCapturing: Bool { capturing > 0 }

    /// Snapshot of the current settings for the given surfaces.
    public func snapshot(_ keys: Set<String>) -> [String: Data] {
        capturing += 1; defer { capturing -= 1 }
        var out: [String: Data] = [:]
        for k in keys { if let d = surfaces[k]?.captureRecipeData() { out[k] = d } }
        return out
    }

    @discardableResult
    public func create(name: String, symbol: String, includes: Set<String>, devices: [DeviceSignature], autoApply: Bool) -> Recipe {
        var r = Recipe(name: name, symbol: symbol, devices: devices, sections: snapshot(includes), autoApply: autoApply)
        r.createdAt = now(); r.updatedAt = r.createdAt
        recipes.append(r); activeID = r.id; applied = r.sections; clearUnsaved(); save()
        onChange?()
        return r
    }

    /// Adds a recipe made from a shared setup (see `SharedSetupFit`). It does not become active and does not switch by itself.
    @discardableResult
    public func addTaken(_ recipe: Recipe) -> Recipe {
        var r = recipe
        r.autoApply = false; r.createdAt = now(); r.updatedAt = r.createdAt
        recipes.append(r)
        save()
        onChange?()
        return r
    }

    /// Replaces a recipe's stored copy (for example after a skipped line was switched on). Keeps its previous version and the author's original.
    public func replaceTaken(_ recipe: Recipe) {
        guard let i = recipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        recipes[i] = recipe
        save()
        onChange?()
    }

    /// Applies each section of the recipe to its surface. Returns the surfaces that could not be applied.
    private func applySections(_ r: Recipe) -> [String] {
        var failed: [String] = []
        for (key, data) in r.sections {
            if let s = surfaces[key] { if !s.applyRecipeData(data) { failed.append(s.recipeTitle) } } else { failed.append(key) }
        }
        return failed
    }

    /// Applies every section of the recipe. Returns the surfaces that could not be applied.
    @discardableResult
    public func apply(_ id: UUID, automatic: Bool = false) -> [String] {
        guard let r = recipes.first(where: { $0.id == id }) else { return [] }
        let failed = applySections(r)
        activeID = id
        applied = snapshot(Set(r.sections.keys))      // what the surfaces hold after applying (they may normalise)
        clearUnsaved()
        notice = failed.isEmpty ? (automatic ? "Switched to “\(r.name)” because its gear is connected" : "Applied “\(r.name)”") : "Applied “\(r.name)”, except \(failed.joined(separator: ", "))"
        save()
        onChange?()
        return failed
    }

    /// Puts back settings captured earlier with `snapshot`, without changing which recipe is active. Returns the surfaces that failed.
    @discardableResult
    public func restore(_ sections: [String: Data]) -> [String] {
        var failed: [String] = []
        for (key, data) in sections { if let s = surfaces[key] { if !s.applyRecipeData(data) { failed.append(s.recipeTitle) } } else { failed.append(key) } }
        return failed
    }

    /// Keys of every registered surface.
    public var surfaceKeys: Set<String> { Set(surfaces.keys) }

    // MARK: Unsaved changes

    /// The parts (surface keys, in display order) where the live settings differ from what the active recipe applied.
    /// Pass `live` when the snapshot is already in hand.
    public func changedParts(live: [String: Data]? = nil) -> [String] {
        guard let r = active else { return [] }
        let now = live ?? snapshot(Set(r.sections.keys))
        let same = { (k: String) -> Bool in
            guard let a = now[k], let b = self.applied[k] else { return now[k] == self.applied[k] }
            if a == b { return true }
            guard let s = self.surfaces[k] else { return false }
            return s.canonicalRecipeData(a) == s.canonicalRecipeData(b)
        }
        return Set(now.keys).union(applied.keys).filter { !same($0) }
            .sorted { (title(forPart: $0), $0) < (title(forPart: $1), $1) }
    }

    /// Titles of `changedParts`.
    public func changedPartTitles(live: [String: Data]? = nil) -> [String] { changedParts(live: live).map(title(forPart:)) }

    /// True when the current settings differ from what the active recipe applied (the recipe has drifted).
    public func isModified(_ id: UUID) -> Bool {
        guard id == activeID, active != nil else { return false }
        return !changedParts().isEmpty
    }

    /// The live settings of the parts the active recipe holds, for telling one change from the next.
    public func liveSnapshot() -> [String: Data]? { active.map { snapshot(Set($0.sections.keys)) } }

    /// Records that the settings were just changed. `persist` writes it down so it survives a quit.
    public func noteChange(persist: Bool = false) {
        changedAt = now()
        if persist { save() }
    }

    /// Forgets the unsaved state and any reminder: there is nothing left unsaved.
    public func clearUnsaved() {
        changedAt = nil
        stove = nil
    }

    /// Clears the unsaved state, and writes that down, if the settings turn out to match what the recipe holds after all
    /// (put back, saved, or changed back by hand).
    public func clearUnsavedIfClean() {
        guard changedAt != nil || stove != nil, changedParts().isEmpty else { return }
        clearUnsaved(); save()
    }

    /// The window closed, the app is quitting, or the app just started: if the active recipe has unsaved changes, remember that
    /// they were left on the stove, so the next opening can say so.
    public func noteLeaving() {
        let parts = changedParts()
        guard let a = active, !parts.isEmpty else {
            if stove != nil || changedAt != nil { clearUnsaved(); save() }
            return
        }
        let when = changedAt ?? stove?.changedAt ?? now()
        changedAt = when
        stove = LeftOnStove(recipeID: a.id, parts: parts, changedAt: when, landed: false)
        save()
    }

    /// Takes the key of the part to land on the first time the window opens after something was left on the stove.
    public func takeLandingPart() -> String? {
        guard var s = stove, !s.landed, s.recipeID == activeID else { return nil }
        s.landed = true; stove = s; save()
        return s.parts.first
    }

    // MARK: Saving, going back

    /// Saves the live settings into the recipe's own sections, keeping the content they replace as its previous version.
    /// Returns whether anything changed; saving settings that match what the recipe holds keeps the earlier version as it was.
    @discardableResult
    public func save(_ id: UUID, devices: [DeviceSignature]? = nil) -> Bool {
        guard let i = recipes.firstIndex(where: { $0.id == id }) else { return false }
        let fresh = snapshot(Set(recipes[i].sections.keys))
        let t = now()
        var changed = false
        if fresh != recipes[i].sections {
            recipes[i].previous = RecipeVersion(sections: recipes[i].sections, savedAt: recipes[i].updatedAt, replacedAt: t)
            recipes[i].sections = fresh
            recipes[i].updatedAt = t
            changed = true
        }
        if let devices { recipes[i].devices = devices }
        if activeID == id { applied = recipes[i].sections; clearUnsaved() }
        save()
        onChange?()
        return changed
    }

    /// Re-captures the recipe's own sections (and optionally its gear) from the current setup.
    public func updateFromCurrent(_ id: UUID, devices: [DeviceSignature]? = nil) { save(id, devices: devices) }

    /// A name for a copy of a recipe: "Desk 2", "Desk 3"…
    public func suggestedCopyName(of id: UUID) -> String {
        StarterRecipes.uniqueName(recipe(id)?.name ?? "Recipe", existing: recipes.map(\.name))
    }

    /// "Save as new": the live settings of the recipe's parts become a recipe of their own, which becomes the active one.
    /// The original keeps what it held. The new recipe has the same icon and gear, and does not switch automatically.
    @discardableResult
    public func saveAsNew(from id: UUID, name: String) -> Recipe? {
        guard let i = recipes.firstIndex(where: { $0.id == id }) else { return nil }
        let src = recipes[i]
        var r = Recipe(name: name, symbol: src.symbol, devices: src.devices, sections: snapshot(Set(src.sections.keys)), autoApply: false)
        r.createdAt = now(); r.updatedAt = r.createdAt
        recipes.insert(r, at: i + 1)
        activeID = r.id; applied = r.sections; clearUnsaved()
        save()
        onChange?()
        return r
    }

    /// Discards unsaved changes: applies again what the recipe holds. Returns the surfaces that could not be applied.
    @discardableResult
    public func putBack(_ id: UUID) -> [String] {
        guard let r = recipe(id) else { return [] }
        let failed = applySections(r)
        if activeID == id { applied = snapshot(Set(r.sections.keys)); clearUnsaved() }
        save()
        onChange?()
        return failed
    }

    public func canGoBack(_ id: UUID) -> Bool { recipe(id)?.previous != nil }

    /// Swaps the recipe's content with its previous version. When the recipe is active, the settings change to match, so the
    /// person hears and sees the version they asked for. Doing it twice returns to where it started. Nil if there is no previous version.
    @discardableResult
    public func goBack(_ id: UUID) -> [String]? {
        guard let i = recipes.firstIndex(where: { $0.id == id }), let prev = recipes[i].previous else { return nil }
        let aside = RecipeVersion(sections: recipes[i].sections, savedAt: recipes[i].updatedAt, replacedAt: now(), isNewer: !prev.isNewer)
        recipes[i].sections = prev.sections
        recipes[i].updatedAt = prev.savedAt
        recipes[i].previous = aside
        var failed: [String] = []
        if activeID == id {
            failed = applySections(recipes[i])
            applied = snapshot(Set(recipes[i].sections.keys)); clearUnsaved()
        }
        save()
        onChange?()
        return failed
    }

    // MARK: The author's original

    /// True for a recipe taken from a shared setup whose original, as first fitted to this Mac, is still held.
    public func canGoToAuthorsOriginal(_ id: UUID) -> Bool { recipe(id)?.authorsOriginal?.fittedSections.isEmpty == false }

    /// Puts the recipe's content aside in its one previous-version slot and takes the author's original as first fitted to this Mac.
    /// Like going back, it swaps: the version just put aside is what "Go forward" returns to. The original itself is never
    /// changed by saving, going back or this. Returns the surfaces that could not be applied, or nil when there is no original.
    @discardableResult
    public func goToAuthorsOriginal(_ id: UUID) -> [String]? {
        guard let i = recipes.firstIndex(where: { $0.id == id }), let orig = recipes[i].authorsOriginal, !orig.fittedSections.isEmpty else { return nil }
        // Only what the original set: parts it never had (a skipped line later switched on elsewhere) stay as they are.
        var sections = recipes[i].sections
        for (k, v) in orig.fittedSections { sections[k] = v }
        let t = now()
        recipes[i].previous = RecipeVersion(sections: recipes[i].sections, savedAt: recipes[i].updatedAt, replacedAt: t, isNewer: true)
        recipes[i].sections = sections
        recipes[i].updatedAt = orig.takenAt
        var failed: [String] = []
        if activeID == id {
            failed = applySections(recipes[i])
            applied = snapshot(Set(recipes[i].sections.keys)); clearUnsaved()
        }
        save()
        onChange?()
        return failed
    }

    // MARK: Editing

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
        if activeID == id { activeID = nil; applied = [:]; clearUnsaved() }
        if pendingSwitch?.currentID == id || pendingSwitch?.candidateID == id { pendingSwitch = nil }
        save()
        onChange?()
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

    /// Whether the gear that is connected calls for a switch, and whether it can happen without losing unsaved changes.
    public func autoSwitchDecision(connected: [DeviceSignature]) -> AutoSwitchDecision {
        guard let candidate = autoApplyCandidate(connected: connected) else { return .none }
        guard let current = active else { return .switchNow(candidate.id) }
        let parts = changedPartTitles()
        if parts.isEmpty { return .switchNow(candidate.id) }
        return .ask(PendingSwitch(candidateID: candidate.id, candidateName: candidate.name, currentID: current.id, currentName: current.name, parts: parts))
    }

    /// Acts on the gear change: switches when that loses nothing, otherwise puts the question in `pendingSwitch` and changes nothing
    /// until it is answered. Gear that no longer calls for a switch withdraws the question.
    @discardableResult
    public func considerAutoSwitch(connected: [DeviceSignature]) -> AutoSwitchDecision {
        let d = autoSwitchDecision(connected: connected)
        switch d {
        case .none: pendingSwitch = nil
        case .switchNow(let id): pendingSwitch = nil; apply(id, automatic: true)
        case .ask(let p): pendingSwitch = p
        }
        return d
    }

    /// Answers the pending question. Ignored if the situation has moved on (another recipe became active, or one was deleted).
    public func resolveSwitch(_ choice: AutoSwitchChoice) {
        guard let p = pendingSwitch else { return }
        pendingSwitch = nil
        guard choice != .stay, activeID == p.currentID, recipe(p.candidateID) != nil else { return }
        if choice == .saveThenSwitch { save(p.currentID) }
        apply(p.candidateID, automatic: true)
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
