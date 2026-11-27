import SwiftUI
import AppKit
import WhopperKit

/// Sharing a recipe, sending it as a file, or sharing an update to one already shared. Everything that would leave this Mac is on
/// screen first, and the Mac's own checker has the first word: a setting past a limit never reaches the network.
@MainActor
final class ShareSession: ObservableObject, Identifiable {
    enum Mode: Equatable { case share, file, update(SharedRecord) }
    enum Step: Equatable { case goes, describe, sending, result }

    /// One row of "What goes into your picklsss".
    struct PartRow: Identifiable {
        var part: String
        var detail: String
        var left: [String]
        var violations: [SharedSetupViolation]
        /// The recipe has nothing in this part that a shared setup can hold (for example a display preset with no values on this Mac).
        var empty = false
        var changed: Bool?
        var id: String { part }
    }

    let id = UUID()
    unowned let controller: PicklsssController
    let recipe: Recipe
    let mode: Mode

    @Published var step: Step = .goes
    @Published var partsOn: Set<String> = []
    @Published var includeTypingLanguage = true
    @Published var title: String
    @Published var line = ""
    @Published var handleText = ""
    @Published var note = ""
    @Published private(set) var rows: [PartRow] = []
    @Published private(set) var export: SharedSetupExportResult?
    @Published private(set) var outcome: ShareOutcome?
    @Published var errors: [SharedSetupViolation] = []
    @Published var message: String?
    @Published var handleProblem: String?
    @Published var closedReason: String?
    /// Where a copy of the file went, when the person asked for one.
    @Published var copiedTo: URL?
    @Published private(set) var savedFile: URL?
    @Published private(set) var previous: SharedSetup?
    @Published private(set) var freeExtraNow = false
    @Published private(set) var busy = false

    init(controller: PicklsssController, recipe: Recipe, mode: Mode) {
        self.controller = controller; self.recipe = recipe; self.mode = mode
        title = recipe.name
        if case .update(let r) = mode { title = r.title }
        handleText = controller.handle ?? ""
        rebuild(initial: true)
    }

    var needsHandle: Bool { mode == .share && controller.handle == nil }
    var canIncludeTypingLanguage: Bool { mode == .file }
    var isUpdate: Bool { if case .update = mode { return true }; return false }
    var record: SharedRecord? { if case .update(let r) = mode { return r }; return nil }
    var headline: String {
        switch mode {
        case .share: "What goes into your picklsss"
        case .file: "What goes into the file"
        case .update: "Share the update"
        }
    }

    // MARK: What goes

    /// The parts a recipe can offer, by the sections it holds.
    private static func candidates(_ r: Recipe) -> [String] {
        SharedSetupTable.parts.filter { p in
            switch p {
            case "audio", "microphone": return r.sections["audio"] != nil
            case "keys": return r.sections["input"] != nil
            default: return r.sections[p] != nil
            }
        }
    }

    private static let detail: [String: String] = [
        "audio": "Equalizer, output effects and keep awake. Plugins are named, not included",
        "microphone": "Gain, high-pass, gate, compressor and equalizer. Plugins are named, not included",
        "windows": "Layouts and shortcuts",
        "keys": "Key and mouse rules, and key changes",
        "clipboard": "Settings only",
        "display": "Brightness, contrast, color and sharpness for one monitor",
    ]

    private func run(_ parts: Set<String>, includeLanguage: Bool) -> SharedSetupExportResult {
        SharedSetupExport.export(title: titleOrPlaceholder, line: lineOrPlaceholder, recipe: recipe, parts: parts,
                                 display: controller.displaySources(), includeTypingLanguage: includeLanguage)
    }
    private var titleOrPlaceholder: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Setup" : title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var lineOrPlaceholder: String { line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "A shared setup." : line.trimmingCharacters(in: .whitespacesAndNewlines) }

    func rebuild(initial: Bool = false) {
        let candidates = Self.candidates(recipe)
        if initial {
            if case .update(let r) = mode { partsOn = Set(r.parts).intersection(candidates) }
            else { partsOn = Set(candidates).subtracting(["clipboard"]) }
        }
        defer { if initial { partsOn.subtract(rows.filter(\.empty).map(\.part)); rebuild() } }
        rows = candidates.map { p in
            let one = run([p], includeLanguage: false)
            let left = one.removed.filter { $0.part == p || $0.part == nil }.map(\.summary) + one.adjusted
            // "A setup must hold at least one part" for a single part means that part came out empty: nothing to share, not a broken limit.
            let empty = one.setup == nil && !one.violations.isEmpty && one.violations.allSatisfy { $0.line == "parts" }
            return PartRow(part: p, detail: Self.detail[p] ?? "", left: left, violations: empty ? [] : one.violations, empty: empty, changed: nil)
        }
        export = partsOn.isEmpty ? nil : run(partsOn, includeLanguage: canIncludeTypingLanguage && includeTypingLanguage)
        if case .update = mode, let prev = previous, let now = export?.setup {
            rows = rows.map { r in var r = r; r.changed = prev.settings[r.part] != now.settings[r.part]; return r }
        }
    }

    func toggle(_ part: String, on: Bool) { if on { partsOn.insert(part) } else { partsOn.remove(part) }; rebuild() }

    /// Every violation of the parts that are switched on: the screen says which line and why, and nothing can be sent.
    var blocking: [SharedSetupViolation] { rows.filter { partsOn.contains($0.part) }.flatMap(\.violations) }
    var leftOut: [String] {
        let language: [String]
        if recipe.inputSourceID == nil { language = [] }
        else if !canIncludeTypingLanguage { language = ["Typing language is available when you send a setup file."] }
        else { language = includeTypingLanguage ? [] : ["Typing language"] }
        return (export?.removed.map(\.summary) ?? []) + (export?.adjusted ?? []) + language
    }
    var gearTags: [String] { export?.setup?.gear.map(\.model) ?? [] }
    var canContinue: Bool { !partsOn.isEmpty && blocking.isEmpty && export?.setup != nil }
    var fieldProblems: [String] {
        var p: [String] = []
        if let t = ShareFields.titleProblem(title) { p.append(t) }
        if !isUpdate, let l = ShareFields.lineProblem(line) { p.append(l) }
        if needsHandle, let h = ShareFields.handleProblem(handleText) { p.append(h) }
        return p
    }
    var canSend: Bool {
        guard canContinue, ShareFields.titleProblem(title) == nil else { return false }
        if case .update = mode { return changedAnything }
        return ShareFields.lineProblem(line) == nil && (!needsHandle || ShareFields.handleProblem(handleText) == nil)
    }
    var changedAnything: Bool {
        rows.contains { partsOn.contains($0.part) && $0.changed == true } || (record.map { Set($0.parts) != partsOn } ?? false)
    }

    var typingLanguageProblems: [SharedSetupViolation] {
        export?.violations.filter { $0.line.hasPrefix("typingLanguage") } ?? []
    }

    func next() { message = nil; step = .describe }
    func back() { message = nil; errors = []; step = .goes }

    // MARK: Loading what is on the shelf now (for an update's before and after)

    func loadPrevious() async {
        guard case .update(let r) = mode else { return }
        do {
            let it = try await controller.withPass { c, p in try await c.item(pass: p, id: r.picklsssId) }
            previous = SharedSetup(json: it.document)
            if line.isEmpty { line = it.card.line }
            rebuild()
        } catch let e as ShelfFailure { message = e.message } catch {}
    }

    // MARK: Sending

    func send() async {
        guard canSend, let setup = export?.setup, !busy else { return }
        busy = true; message = nil; errors = []; handleProblem = nil
        defer { busy = false }
        step = .sending
        // The same document the Mac checked, with the title and line the person wrote.
        var s = setup; s.title = titleOrPlaceholder; s.line = lineOrPlaceholder
        guard SharedSetupLimits.check(s).ok else { step = .describe; message = "This setup breaks one of Whoprrr’s limits, so it was not sent."; return }
        let handle = needsHandle ? ShareFields.normalizedHandle(handleText) : nil
        do {
            let out: ShareOutcome
            switch mode {
            case .share: out = try await controller.withPass { c, p in try await c.share(pass: p, ShareRequest(setup: s, handle: handle)) }
            case .update(let r): out = try await controller.withPass { c, p in try await c.update(pass: p, id: r.picklsssId, note: note, ShareRequest(setup: s, handle: nil)) }
            case .file: return
            }
            outcome = out
            controller.rememberHandle(out.handle)
            controller.recordShared(SharedRecord(picklsssId: out.id, recipeID: recipe.id, title: s.title, state: out.state.rawValue, version: out.version, parts: s.parts,
                                                 digest: ShareDigest.of(setup: s), sharedAt: Date()))
            step = .result
            let had = controller.hasExtra
            await controller.refreshMine()
            freeExtraNow = !had && controller.hasExtra
        } catch let e as ShelfFailure {
            switch e {
            case .refused(let m, let v): errors = v; message = m; step = .describe
            case .handleTaken(let m): handleProblem = m; step = .describe
            case .sharingClosed(let m): closedReason = m; step = .result
            case .gone(let m): message = m; step = .describe
            default: message = e.message; step = .describe
            }
        } catch { message = ShelfFailure.offline.message; step = .describe }
    }

    // MARK: The file

    var fileName: String { (titleOrPlaceholder.replacingOccurrences(of: "/", with: "-")) + ".\(SharedSetupFile.fileExtension)" }

    /// Makes the file in the Whoprrr folder, without asking. Free for everyone; nothing is uploaded.
    func saveFile() {
        guard canContinue, var s = export?.setup, ShareFields.titleProblem(title) == nil, ShareFields.lineProblem(line) == nil else { return }
        s.title = titleOrPlaceholder; s.line = lineOrPlaceholder
        switch SharedSetupFile.encode(s, madeBy: controller.license.currentPass?.kid ?? "") {
        case .failure(let p): message = p.message
        case .success(let data):
            let folder = SharedSetupFiles.folder()
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = SharedSetupFiles.freeURL(in: folder, fileName: fileName)
                try data.write(to: url, options: .atomic)
                savedFile = url; step = .result
            } catch { message = "The file could not be saved in \(folder.path)." }
        }
    }

    /// "Save a copy somewhere else…": the person picks the place. The first file stays where it is.
    func saveCopyElsewhere() {
        guard let from = savedFile, let data = try? Data(contentsOf: from) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = from.lastPathComponent
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); copiedTo = url } catch { message = "The copy could not be saved there." }
    }

    /// The file's size, for "12 KB".
    var fileSize: String {
        guard var s = export?.setup else { return "" }
        s.title = titleOrPlaceholder; s.line = lineOrPlaceholder
        if case .success(let d) = SharedSetupFile.encode(s, madeBy: controller.license.currentPass?.kid ?? "") { return ByteCountFormatter.string(fromByteCount: Int64(d.count), countStyle: .file) }
        return ""
    }
}
