import Foundation

/// A private, full-fidelity copy of the settings files. Sharing uses SharedSetupExport instead.
public struct WhopperBackup: Codable, Equatable, Sendable {
    public static let fileExtension = "whoprrr-backup"
    public static let currentVersion = 1

    public enum Component: String, CaseIterable, Sendable {
        case recipes, presets, audio, input, windows, clipboard, displayPresets, displayLearned, saveDraft
    }

    public enum Problem: Error, Equatable, LocalizedError {
        case unreadable
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable: "Whoprrr could not read this backup."
            case .newerVersion: "Update Whoprrr to open this file."
            }
        }
    }

    public let formatVersion: Int
    public let madeWithKeyID: String
    public let appVersion: String
    public let createdAt: Date
    private let files: [String: Data]

    public init(madeWithKeyID: String, appVersion: String, createdAt: Date = .now, files: [Component: Data]) {
        formatVersion = Self.currentVersion
        self.madeWithKeyID = madeWithKeyID
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.files = Dictionary(uniqueKeysWithValues: files.map { ($0.key.rawValue, $0.value) })
    }

    public subscript(_ component: Component) -> Data? { files[component.rawValue] }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        struct Header: Decodable { let formatVersion: Int }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw Problem.unreadable }
        if header.formatVersion > currentVersion { throw Problem.newerVersion(header.formatVersion) }
        guard header.formatVersion == currentVersion, let backup = try? decoder.decode(Self.self, from: data),
              !backup.madeWithKeyID.isEmpty, Set(backup.files.keys).isSubset(of: Set(Component.allCases.map(\.rawValue)))
        else { throw Problem.unreadable }
        return backup
    }

    public func recipeContents() throws -> [Recipe] {
        guard let data = self[.recipes] else { return [] }
        struct Header: Decodable { let formatVersion: Int? }
        let decoder = JSONDecoder()
        if let version = try decoder.decode(Header.self, from: data).formatVersion, version > RecipeFile.currentVersion {
            throw Problem.newerVersion(version)
        }
        let file = try decoder.decode(RecipeFile.self, from: data)
        let ids = Set(file.recipes.map(\.id))
        guard ids.count == file.recipes.count, file.activeID.map(ids.contains) != false else { throw Problem.unreadable }
        return file.recipes
    }

    public func presetCount() throws -> Int {
        guard let data = self[.presets] else { return 0 }
        let file = try JSONDecoder().decode(PresetFile.self, from: data)
        return file.catalog.yours.values.reduce(0) { $0 + $1.count }
    }

    public func validateDraft() throws {
        if let data = self[.saveDraft] { _ = try JSONDecoder().decode(SaveBarDraft?.self, from: data) }
    }
}

/// Uses known local paths, never a path supplied by the imported file.
public struct WhopperBackupFiles {
    private let urls: [WhopperBackup.Component: URL]
    private let journal: URL

    public init(urls: [WhopperBackup.Component: URL], journal: URL) {
        self.urls = urls
        self.journal = journal
    }

    public func capture(keyID: String, appVersion: String) throws -> WhopperBackup {
        let files = try urls.compactMapValues { try Self.read($0) }
        return WhopperBackup(madeWithKeyID: keyID, appVersion: appVersion, files: files)
    }

    /// Keeps a standalone copy and journals the rollback before changing any live file.
    public func restore(_ backup: WhopperBackup, keeping current: WhopperBackup, at recovery: URL) throws {
        try recoverInterruptedRestore()
        let rollback = try current.encoded()
        try Self.write(rollback, to: recovery)
        try Self.write(rollback, to: journal)
        do {
            try install(backup)
            try FileManager.default.removeItem(at: journal)
        } catch {
            try recoverInterruptedRestore()
            throw error
        }
    }

    /// Run before opening the app's stores. A quit during a restore restores the prior files on launch.
    public func recoverInterruptedRestore() throws {
        guard let data = try Self.read(journal) else { return }
        try install(WhopperBackup.decode(data))
        try FileManager.default.removeItem(at: journal)
    }

    private func install(_ backup: WhopperBackup) throws {
        for component in WhopperBackup.Component.allCases {
            guard let url = urls[component] else { continue }
            if let data = backup[component] {
                try Self.write(data, to: url)
            } else {
                do { try FileManager.default.removeItem(at: url) }
                catch let error as CocoaError where error.code == .fileNoSuchFile {}
            }
        }
    }

    private static func read(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
