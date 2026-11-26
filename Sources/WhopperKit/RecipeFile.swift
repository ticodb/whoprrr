import Foundation

/// A recipe left unsaved while nobody was looking: the window was closed, or the app quit, with changes still live.
public struct LeftOnStove: Codable, Equatable, Sendable {
    public var recipeID: UUID
    /// Surface keys that differ from what the recipe holds ("audio", "windows"…), in display order.
    public var parts: [String]
    /// When the last of those changes was made.
    public var changedAt: Date
    /// True once the window has opened on the page that changed, so it does that once per leaving.
    public var landed: Bool

    public init(recipeID: UUID, parts: [String], changedAt: Date, landed: Bool = false) {
        self.recipeID = recipeID; self.parts = parts; self.changedAt = changedAt; self.landed = landed
    }
}

/// What `recipes.json` looks like on disk.
///
/// - Version 1 (no `formatVersion` key): recipes with gear as (kind, key, name), the active recipe, and the baseline.
/// - Version 2: gear also carries a role and a model, a recipe keeps one previous version, and the unsaved state is kept so it
///   survives a quit.
struct RecipeFile: Codable, Sendable {
    static let currentVersion = 2

    /// Nil only in files written before the field existed (version 1).
    var formatVersion: Int?
    var recipes: [Recipe]
    var activeID: UUID?
    /// Fingerprint of what each section looked like when the active recipe was applied, to tell "applied" from "modified".
    var appliedSections: [String: Data]
    /// When the unsaved change was last touched, while the active recipe differs from its saved settings.
    var changedAt: Date?
    var stove: LeftOnStove?

    init(recipes: [Recipe] = [], activeID: UUID? = nil, appliedSections: [String: Data] = [:], changedAt: Date? = nil, stove: LeftOnStove? = nil) {
        formatVersion = Self.currentVersion
        self.recipes = recipes; self.activeID = activeID; self.appliedSections = appliedSections
        self.changedAt = changedAt; self.stove = stove
    }
}

/// How the recipes file was found at launch.
public enum RecipeLoadOutcome: Equatable, Sendable {
    /// No file yet.
    case fresh
    /// Read as is.
    case current
    /// An older format was converted; the original is kept at `backup`.
    case migrated(from: Int, backup: URL)
    /// The original could not be copied aside, so nothing was converted or written. Recipes work in memory only.
    case migrationBlocked
    /// The file could not be read as recipes. It was moved to `kept`, untouched, and recipes start empty.
    case recovered(kept: URL)
    /// Written by a newer Whoprrr. It is left exactly as it is and not written to.
    case newerFormat(Int)
    /// The file exists but could not be read (permissions). It is left alone and not written to.
    case unreadable
}

/// Reads and writes the recipes file: converts old formats once (keeping the original), never overwrites a backup,
/// and keeps anything it cannot read where it was found.
struct RecipeFileStore {
    let store: JSONStore<RecipeFile>
    var url: URL { store.url }

    init(url: URL) { store = JSONStore<RecipeFile>(url: url) }

    /// False when writing could overwrite something that was not read (see `RecipeLoadOutcome`).
    func load() -> (file: RecipeFile, outcome: RecipeLoadOutcome) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return (RecipeFile(), .fresh) }
        guard let data = try? Data(contentsOf: url) else { return (RecipeFile(), .unreadable) }

        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            return (RecipeFile(), recover())
        }
        let version = dict["formatVersion"] as? Int
        if let v = version, v > RecipeFile.currentVersion { return (RecipeFile(), .newerFormat(v)) }
        guard var file = try? JSONDecoder().decode(RecipeFile.self, from: data) else { return (RecipeFile(), recover()) }

        guard (version ?? 1) < RecipeFile.currentVersion else { return (file, .current) }

        // An older file: keep the original beside the new one, then write the converted file.
        let from = version ?? 1
        let backup = JSONStore<RecipeFile>.uniqueSibling(of: url, naming: { n in
            let stem = url.deletingPathExtension().lastPathComponent
            return url.deletingLastPathComponent().appendingPathComponent("\(stem).backup-v\(from)\(n == 1 ? "" : "-\(n)").json")
        })
        do {
            try data.write(to: backup, options: .withoutOverwriting)
            guard (try? Data(contentsOf: backup)) == data else { return (convert(file), .migrationBlocked) }
        } catch { return (convert(file), .migrationBlocked) }
        file = convert(file)
        if !store.save(file) { return (file, .migrationBlocked) }
        return (file, .migrated(from: from, backup: backup))
    }

    func save(_ file: RecipeFile) -> Bool { store.save(file) }

    /// Version 1 to version 2. Everything the old file held is kept; the new fields start empty.
    private func convert(_ f: RecipeFile) -> RecipeFile {
        var out = f
        out.formatVersion = RecipeFile.currentVersion
        return out
    }

    private func recover() -> RecipeLoadOutcome {
        let kept = JSONStore<RecipeFile>.uniqueSibling(of: url, naming: { n in url.appendingPathExtension(n == 1 ? "bad" : "bad-\(n)") })
        do { try FileManager.default.moveItem(at: url, to: kept); return .recovered(kept: kept) } catch { return .unreadable }
    }
}
