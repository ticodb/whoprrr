import Foundation

/// Small atomic JSON file store under Application Support/Whopper. Corrupt or missing files fall back
/// to the default value; a corrupt file is kept aside as `.bad` (`.bad-2`, `.bad-3`… if one is already there) instead of
/// being overwritten silently.
public final class JSONStore<T: Codable & Sendable>: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public convenience init(name: String) {
        self.init(url: Self.directory().appendingPathComponent("\(name).json"))
    }

    /// `WHOPPER_DATA_DIR` points the whole app at another folder (screenshots, tests, trying things without touching real settings).
    public static func directory() -> URL {
        if let d = ProcessInfo.processInfo.environment["WHOPPER_DATA_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Whopper", isDirectory: true)
    }

    public func load(default fallback: T) -> T {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return fallback }
        if let v = try? JSONDecoder().decode(T.self, from: data) { return v }
        let kept = Self.uniqueSibling(of: url, naming: { n in url.appendingPathExtension(n == 1 ? "bad" : "bad-\(n)") })
        try? FileManager.default.moveItem(at: url, to: kept)
        return fallback
    }

    /// The first of `naming(1)`, `naming(2)`… that does not exist yet, so a file kept aside never replaces an earlier one.
    static func uniqueSibling(of url: URL, naming: (Int) -> URL) -> URL {
        var n = 1
        while FileManager.default.fileExists(atPath: naming(n).path) { n += 1 }
        return naming(n)
    }

    @discardableResult
    public func save(_ value: T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(value).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}
