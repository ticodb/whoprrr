import SwiftUI
import AppKit
import AudioCore
import DisplayCore
import WhopperKit

/// One shared setup being looked at and (maybe) taken: from the shelf, from a file, or as an update to one already taken.
/// Opening it, matching gear and the review change nothing. The lock appears at the first action that changes this Mac.
@MainActor
final class TakeSession: ObservableObject, Identifiable {
    enum Source { case shelf(ShelfCard), file(name: String, madeBy: String?), update(TakeRecord, ShelfNotice) }
    enum Stage: Equatable { case loading, failed(String), detail, match, review, cookin, done, partPicker }
    enum Sending: Equatable { case none, preview(TakeReport.Outcome), sending, sent, failed }
    enum Flag: Equatable { case none, asking, flagged, failed(String) }

    /// What a take did, so one button can put everything back.
    struct Applied { var recipeID: UUID?; var name: String; var before: [String: Data]; var parts: [String]; var failed: [String]; var notes: [String]; var updated: Bool; var savedOnly = false; /* the recipe holds it, but it was not put on this Mac yet */ var notLive = false }

    let id = UUID()
    unowned let controller: PicklsssController
    let source: Source
    var isOwn = false

    @Published var stage: Stage = .loading
    @Published private(set) var item: ShelfItem?
    @Published private(set) var setup: SharedSetup?
    @Published private(set) var env = ReceiverEnvironment()
    @Published var overrides: [Int: GearOverride] = [:]
    @Published var switchedOff: Set<String> = []
    @Published private(set) var plan: FitPlan?
    @Published private(set) var changes: [String: LineChange] = [:]
    @Published var showLock = false
    @Published var askCount = false
    @Published var message: String?
    @Published private(set) var cookinDone = 0
    @Published private(set) var cookinParts: [String] = []
    @Published private(set) var applied: Applied?
    @Published var sending: Sending = .none
    @Published var flag: Flag = .none
    @Published var presetNote: String?
    @Published private(set) var busy = false
    /// The "Stays off for now" groups the person has opened (by group id).
    @Published var openGroups: Set<String> = []
    private var pendingPart: (part: String, tryNow: Bool)?

    init(controller: PicklsssController, card: ShelfCard) { self.controller = controller; source = .shelf(card) }
    init(controller: PicklsssController, file: SharedSetup, madeBy: String?, name: String) {
        self.controller = controller; source = .file(name: name, madeBy: madeBy); setup = file
    }
    init(controller: PicklsssController, updating: TakeRecord, notice: ShelfNotice) { self.controller = controller; source = .update(updating, notice) }

    // MARK: What it is

    var card: ShelfCard? {
        switch source { case .shelf(let c): return item?.card ?? c; case .update: return item?.card; case .file: return nil }
    }
    var title: String {
        switch source {
        case .shelf(let c): return setup?.title ?? c.title
        case .update(let t, _): return setup?.title ?? t.title
        case .file(let name, _): return setup?.title ?? name
        }
    }
    var handle: String {
        switch source {
        case .shelf(let c): return c.cook.handle
        case .update(let t, _): return t.handle
        case .file: return ""
        }
    }
    var isFile: Bool { if case .file = source { return true }; return false }
    var isUpdate: Bool { if case .update = source { return true }; return false }
    var fileMadeBy: String? { if case .file(_, let m) = source { return m }; return nil }
    var updateNote: String? { if case .update(_, let n) = source { return n.note.isEmpty ? nil : n.note }; return nil }
    var fileName: String? { if case .file(let n, _) = source { return n }; return nil }
    /// A setup its own cook looks at while it is being checked cannot be taken yet.
    var canTake: Bool { !(isOwn && card?.shelfState != .public) }

    var requirements: [RequirementRow] { setup.map { Requirements.rows($0.requirements, env: env) } ?? [] }

    /// The plan's lines in the order a person reads them: what goes on now, then what stays off, folded by reason.
    var grouping: ReviewGrouping? { plan.map { ReviewGrouping(plan: $0, gear: setup?.gear ?? []) } }

    /// "Before you start", cut down to what is wrong, plus one quiet sentence for what is fine.
    var reviewRequirements: ReviewRequirements? { grouping.map { ReviewRequirements(rows: requirements, stays: $0.stays) } }

    /// Nothing can go on: the main button says "Save it for later" and the recipe is saved with every line waiting, not applied.
    var savesForLater: Bool { !isUpdate && (grouping?.nothingCanGoOn ?? false) }
    var partsOnStage: [String] { setup?.parts ?? [] }

    // MARK: Loading

    func load() async {
        stage = .loading
        guard let id = card?.id ?? { if case .update(let t, _) = source { return t.picklsssId }; return nil }() else { return }
        do {
            let it = try await controller.withPass { c, p in try await c.item(pass: p, id: id) }
            // The Mac checks every setup it opens, whoever vouched for it.
            let report = SharedSetupLimits.check(value: it.document)
            guard report.ok, let s = SharedSetup(json: it.document) else {
                stage = .failed("This shared setup breaks Whoprrr’s limits, so it was not opened. Nothing on this Mac changed."); return
            }
            item = it; setup = s
            prepare()
        } catch let e as ShelfFailure { stage = .failed(e.message) } catch { stage = .failed(ShelfFailure.offline.message) }
    }

    func prepare() {
        env = controller.receiverEnvironment()
        overrides = [:]; switchedOff = []; openGroups = []
        replan()
        stage = isUpdate ? .review : .detail
    }

    func replan() {
        guard let setup else { return }
        let p = SharedSetupFit.plan(setup, for: env, overrides: overrides, switchedOff: switchedOff)
        plan = p
        changes = SetupDiff.lineChanges(setup: setup, plan: p, env: env)
    }

    // MARK: Moving between steps

    func toMatch() { stage = .match }
    func toReview() { replan(); stage = .review }
    func backToDetail() { stage = isUpdate ? .review : .detail }

    func choose(authorIndex: Int, device: DeviceSignature?) {
        overrides[authorIndex] = device.map { .device($0.id) } ?? GearOverride.none
        replan()
    }

    func toggle(_ lineID: String, on: Bool) {
        if on { switchedOff.remove(lineID) } else { switchedOff.insert(lineID) }
        replan()
    }

    /// One switch for a whole part: every line of it that can go on, together.
    func toggle(_ lineIDs: [String], on: Bool) {
        for id in lineIDs { if on { switchedOff.remove(id) } else { switchedOff.insert(id) } }
        replan()
    }

    func toggleGroup(_ id: String) { if openGroups.contains(id) { openGroups.remove(id) } else { openGroups.insert(id) } }

    /// The gear the person may stand in for one of the author's devices: the same kind, from what is connected.
    func candidates(for g: SharedGear) -> [DeviceSignature] {
        env.gear.filter { ShelfRanking.normalizedRole($0.role.rawValue) == ShelfRanking.normalizedRole(g.role) }
    }

    func fitLabel(_ line: SetupLine) -> Fit { plan.map { TakeFit.fit(of: line, in: $0) } ?? .untested }
    func tone(_ f: Fit) -> StatusChip.Tone { f == .tested || f == .checked ? .good : f == .untested ? .warn : .neutral }

    // MARK: The lock and the first-take question

    private var lockAction: PicklsssLock.Action {
        isFile ? .takeFromFile(madeBy: fileMadeBy) : .take
    }

    /// Applying is the first action that changes the Mac. Without the extra the lock card shows; with it, the first take asks
    /// whether to count what the person keeps.
    func requestApply() { pendingPart = nil; gate() }
    func requestPart(_ part: String, tryNow: Bool) { pendingPart = (part, tryNow); gate() }

    private func gate() {
        message = nil
        let action: PicklsssLock.Action = pendingPart != nil ? (isFile ? .takeFromFile(madeBy: fileMadeBy) : .takePart) : lockAction
        #if DEBUG
        // Debug builds only: lets the step runner reach the screens after the lock without a server that sells the extra.
        let skipLock = ProcessInfo.processInfo.environment["WHOPRRR_DEBUG_NO_LOCK"] == "1"
        #else
        let skipLock = false
        #endif
        if !skipLock, PicklsssLock.decision(action, pass: controller.license.currentPass) == .locked { showLock = true; return }
        showLock = false
        if !isFile, controller.countChoice == .unasked { askCount = true; return }
        Task { await commit() }
    }

    func answerCount(_ choice: CountChoice) {
        controller.setCount(choice); askCount = false
        Task { await commit() }
    }

    /// The lock card resumes here when the pass learns of the extra: the person is back where they were, review in hand.
    func unlocked() { showLock = false }

    // MARK: Taking

    private func commit() async {
        guard let setup, let plan, !busy else { return }
        busy = true
        defer { busy = false }
        let part = pendingPart?.part
        var receipt: TakeReceipt?
        if !isFile, let id = card?.id ?? { if case .update(let t, _) = source { return t.picklsssId }; return nil }() {
            let counted = controller.countChoice.counted
            do { receipt = try await controller.withPass { c, p in try await c.take(pass: p, id: id, counted: counted, part: part) } }
            catch ShelfFailure.needsExtra { showLock = true; stage = pendingPart != nil ? .partPicker : .review; return }
            catch let e as ShelfFailure { message = e.message; stage = pendingPart != nil ? .partPicker : .review; return }
            catch { message = ShelfFailure.offline.message; return }
        }
        if let pp = pendingPart { await takePart(pp.part, tryNow: pp.tryNow, setup: setup, plan: plan, receipt: receipt); return }

        // Cookin': each part its own beat, about a second in all. Then the Mac changes.
        let parts = setup.parts.filter { p in plan.lines.contains { $0.part == p && !$0.state.isOff } }
        cookinParts = parts; cookinDone = 0; stage = .cookin
        for beat in CookinBeats.beats(parts: parts.count) {
            try? await Task.sleep(nanoseconds: UInt64(beat * 1_000_000_000))
            cookinDone += 1
        }
        let result = applyWhole(setup: setup, plan: plan, receipt: receipt, parts: parts, saveOnly: savesForLater)
        applied = result
        stage = .done
        controller.recomputeNotices()
    }

    private func applyWhole(setup: SharedSetup, plan: FitPlan, receipt: TakeReceipt?, parts: [String], saveOnly: Bool = false) -> Applied {
        let recipes = controller.recipes
        let madeBy: String = isFile ? (fileMadeBy ?? "a file") : (handle.isEmpty ? nil : handle) ?? "the shelf"
        var fit = SharedSetupFit.fit(setup, plan: plan, for: env, madeBy: madeBy)
        var notes: [String] = []
        if let dp = fit.displayPreset {
            let key = plan.matches.first { ShelfRanking.normalizedRole($0.author.role) == "display" }?.receiver?.key
            if let key, let saved = Shared.model.addSharedPreset(name: dp.name, displayKey: key, values: dp.values) {
                let data = JSONValue.object(["preset": .string(saved)]).encoded()
                fit.recipe.sections["display"] = data; fit.recipe.authorsOriginal?.fittedSections["display"] = data
            } else {
                fit.recipe.sections["display"] = nil; fit.recipe.authorsOriginal?.fittedSections["display"] = nil
                notes.append("The monitor settings were not added: that monitor is not connected right now.")
            }
        }
        let keys = Set(fit.recipe.sections.keys)
        let before = recipes.snapshot(keys)
        for p in parts { if let f = Self.feature(p), !Shared.features.isEnabled(f) { notes.append("\(PicklsssWords.partTitle(p)) is switched off under Features, so you will not see its page until you turn it on.") } }
        let beforeParts = keys.map { recipes.title(forPart: $0) }.sorted()

        if case .update(let t, _) = source, let rid = t.recipeID, let old = recipes.recipe(rid) {
            // A plain choice between yours and the new one: the recipe takes the new content, and what it held is one step away.
            var r = old
            r.sections = fit.recipe.sections; r.devices = fit.recipe.devices; r.skippedLines = fit.recipe.skippedLines; r.authorsOriginal = fit.recipe.authorsOriginal
            r.previous = RecipeVersion(sections: old.sections, savedAt: old.updatedAt, replacedAt: Date(), isNewer: false)
            r.updatedAt = Date()
            recipes.replaceTaken(r)
            var failed: [String] = []
            var notLive = false
            if recipes.activeID == rid, !recipes.isModified(rid) { failed = recipes.apply(rid) }
            else { notLive = true; notes.append("It is saved in “\(old.name)”. Apply that recipe when you are ready.") }
            if let n = item?.card.version { controller.updateVersion(t.picklsssId, n) }
            if case .update(_, let n) = source { controller.dismissNotice(n.id) }
            return Applied(recipeID: rid, name: old.name, before: [:], parts: parts, failed: failed, notes: notes, updated: true, notLive: notLive)
        }

        fit.recipe.name = StarterRecipes.uniqueName(setup.title, existing: recipes.recipes.map(\.name))
        let added = recipes.addTaken(fit.recipe)
        // "Save it for later": every line is waiting, so there is nothing to put on this Mac. The recipe is saved the same way and is not applied.
        let failed = saveOnly ? [] : recipes.apply(added.id)
        if !isFile, let c = card {
            var rec = TakeRecord(picklsssId: c.id, title: c.title, handle: c.cook.handle, version: c.version, recipeID: added.id, takenAt: Date(),
                                 counted: receipt?.counted ?? false, takeToken: receipt?.takeToken, askFrom: receipt?.askFrom, askUntil: receipt?.askUntil,
                                 before: before, beforeParts: beforeParts)
            if receipt?.again == true { rec.counted = false; rec.takeToken = nil }       // the first take's token and counting stand
            controller.record(rec)
        }
        return Applied(recipeID: added.id, name: added.name, before: before, parts: parts, failed: failed, notes: notes, updated: false, savedOnly: saveOnly)
    }

    static func feature(_ part: String) -> Feature? {
        switch part {
        case "audio": .audio
        case "microphone": .microphone
        case "windows": .windows
        case "keys": .remap
        case "clipboard": .clipboard
        case "display": .display
        default: nil
        }
    }

    /// One button puts everything back: the parts the take changed go back to how they were, and the copy is removed.
    func putEverythingBack() {
        guard let a = applied, !a.updated, let id = a.recipeID else { return }
        controller.recipes.restore(a.before)
        controller.recipes.delete(id)
        controller.recipes.notice = "Put everything back. “\(a.name)” is off this Mac."
        applied = nil
        stage = .review
        replan()
    }

    // MARK: One part on its own

    private func takePart(_ part: String, tryNow: Bool, setup: SharedSetup, plan: FitPlan, receipt: TakeReceipt?) async {
        pendingPart = nil
        let presets = SharedSetupFit.take(part: part, of: setup, plan: plan, for: env)
        var landed: [String] = []
        let name = handle.isEmpty ? setup.title : "\(setup.title) from \(handle)"
        for tp in presets {
            if tp.key == "display" {
                // Display values are made into a preset for the monitor, which is where those live.
                var only = plan
                only.lines = plan.lines.map { l in var l = l; if l.part != "display" { l.state = .off("") }; return l }
                let f = SharedSetupFit.fit(setup, plan: only, for: env)
                guard let dp = f.displayPreset, let key = plan.matches.first(where: { ShelfRanking.normalizedRole($0.author.role) == "display" })?.receiver?.key,
                      let saved = Shared.model.addSharedPreset(name: dp.name, displayKey: key, values: dp.values) else { continue }
                landed.append("External displays: “\(saved)”")
                if tryNow, let p = Shared.model.presetsForSelected().first(where: { $0.name == saved }) { Shared.model.apply(p) }
                continue
            }
            guard let saved = Shared.presets.save(name, data: tp.data, for: tp.key) else { continue }
            landed.append("\(tp.title): “\(name)”")
            if tryNow, let surface = PresetSurfaces.surface(tp.key), surface.apply(tp.data) {
                Shared.presets.select(.personal(saved.id), at: surface.location)
            }
        }
        presetNote = landed.isEmpty ? "Nothing in that part could be added to this Mac." : "Added to your presets: " + landed.joined(separator: ", ") + (tryNow ? ". It is on now. Open “Cookin’” to save it to the active recipe." : ".")
        if !isFile, let c = card, !landed.isEmpty {
            var rec = TakeRecord(picklsssId: c.id, title: c.title, handle: c.cook.handle, version: c.version, recipeID: nil, takenAt: Date(), counted: receipt?.counted ?? false,
                                 takeToken: receipt?.takeToken, askFrom: receipt?.askFrom, askUntil: receipt?.askUntil)
            if receipt?.again == true { rec.counted = false; rec.takeToken = nil }
            controller.record(rec)
        }
        stage = .partPicker
    }



    func openPartPicker() { presetNote = nil; message = nil; stage = .partPicker }

    // MARK: Did it work? Something is off

    var reportText: String? {
        guard let setup, let plan, case .preview(let o) = sending else { return nil }
        _ = setup
        return TakeReport.text(app: AppInfo.version, scan: GearScanner.current(), plan: plan, switchedOn: switchedOn(plan), outcome: o)
    }

    private func switchedOn(_ plan: FitPlan) -> Set<String> { Set(plan.lines.filter { !$0.state.isOff }.map(\.id)) }

    func previewReport(_ o: TakeReport.Outcome) { sending = .preview(o) }

    func sendReport() {
        guard let plan, case .preview(let o) = sending else { return }
        let body = TakeReport.json(app: AppInfo.version, scan: GearScanner.current(), plan: plan, switchedOn: switchedOn(plan), outcome: o)
        sending = .sending
        Task { sending = await FitSender.send(body) ? .sent : .failed }
    }

    func declineReport() { sending = .none }

    /// "Something is off": tells the shelf. It carries no text and no way to say who; three different buyers take a setup off the shelf.
    func markSomethingOff() {
        guard let id = card?.id else { return }
        flag = .asking
        Task {
            do { try await controller.withPass { c, p in try await c.flag(pass: p, id: id) }; flag = .flagged; sending = .preview(.somethingOff) }
            catch let e as ShelfFailure { flag = .failed(e.message) } catch { flag = .failed(ShelfFailure.offline.message) }
        }
    }

    /// A link the person clicks, never a download: the plugin's author is found by name.
    static func pluginLink(_ name: String) -> URL? {
        var c = URLComponents(string: "https://duckduckgo.com/")
        c?.queryItems = [URLQueryItem(name: "q", value: "\(name) audio unit plugin")]
        return c?.url
    }
}
