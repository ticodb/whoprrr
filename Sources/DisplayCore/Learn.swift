import Foundation

/// A display feature discovered by diffing scans while the user changes one OSD item. This is how
/// Samsung manufacturer-specific codes (0xE0-0xFF) become controllable without vendor documentation.
public struct LearnedSetting: Codable, Identifiable, Equatable, Sendable {
    public var id: String { "\(identity.alphaSerial ?? String(identity.serial))-\(code)" }
    public var identity: DisplayIdentity
    public var code: UInt8
    public var name: String
    /// Values seen while learning; the UI offers them as one-tap choices.
    public var observed: [Int]
    public var maximum: Int
    public var control: Control { Control(code) }
    public init(identity: DisplayIdentity, code: UInt8, name: String, observed: [Int], maximum: Int) {
        self.identity = identity; self.code = code; self.name = name; self.observed = observed; self.maximum = maximum
    }
}

public struct ScanDiffItem: Equatable, Sendable {
    public var code: UInt8
    public var before: Int
    public var after: Int
    public var maximum: Int
    public init(code: UInt8, before: Int, after: Int, maximum: Int) {
        self.code = code; self.before = before; self.after = after; self.maximum = maximum
    }
}

public typealias ScanResult = [UInt8: ControlValue]

public extension DisplayController {
    /// Reads every VCP code. Slow (~20 s on the Samsung): run once, then re-read only `codes` for diffs.
    func scanAll(target: DisplayTarget, progress: (@Sendable (Int) -> Void)? = nil) async -> ScanResult {
        var out: ScanResult = [:]
        for code in 0...255 {
            if let v = try? await read(Control(UInt8(code)), target: target, logFailures: false) { out[UInt8(code)] = v }
            progress?(code)
        }
        log.record(.info, "full scan: \(out.count) codes answered")
        return out
    }

    func rescan(codes: [UInt8], target: DisplayTarget) async -> ScanResult {
        var out: ScanResult = [:]
        for code in codes {
            if let v = try? await read(Control(code), target: target, logFailures: false) { out[code] = v }
        }
        return out
    }
}

public enum ScanDiff {
    /// Codes whose current value changed. Identity/version and counter-like codes the app already knows
    /// to be noise are excluded, as are denied codes.
    public static func changes(before: ScanResult, after: ScanResult) -> [ScanDiffItem] {
        after.keys.sorted().compactMap { code in
            guard let a = after[code], let b = before[code], a.current != b.current, !Catalog.denied.contains(code) else { return nil }
            return ScanDiffItem(code: code, before: b.current, after: a.current, maximum: max(a.maximum, b.maximum))
        }
    }
}

/// Learned settings, stored next to presets (versioned, atomic).
public final class LearnedStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    struct File: Codable { var version: Int; var settings: [LearnedSetting] }
    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        PresetStore.defaultURL().deletingLastPathComponent().appendingPathComponent("learned.json")
    }

    public func load() throws -> [LearnedSetting] {
        try lock.withLock { try loadLocked() }
    }

    private func loadLocked() throws -> [LearnedSetting] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) else {
            throw PresetStoreError.unreadable
        }
        guard f.version <= 1 else { throw PresetStoreError.unsupportedVersion(f.version) }
        return f.settings
    }

    /// Merges observed values when the same display+code is learned again.
    public func save(_ s: LearnedSetting) throws {
        try lock.withLock {
            var all = try loadLocked()
            var s = s
            if let i = all.firstIndex(where: { $0.id == s.id }) {
                s.observed = Array(Set(all[i].observed + s.observed)).sorted()
                all[i] = s
            } else { all.append(s) }
            try write(all)
        }
    }

    public func delete(id: String) throws {
        try lock.withLock {
            var all = try loadLocked()
            all.removeAll { $0.id == id }
            try write(all)
        }
    }

    private func write(_ all: [LearnedSetting]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(File(version: 1, settings: all)).write(to: url, options: .atomic)
    }

    public func settings(for identity: DisplayIdentity) -> [LearnedSetting] {
        ((try? load()) ?? []).filter { $0.identity.matches(identity) }
    }
}
