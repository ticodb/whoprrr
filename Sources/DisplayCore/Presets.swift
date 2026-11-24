import Foundation

/// A named snapshot of monitor settings for one identified display. It records settings, not a
/// measured color calibration.
public struct Preset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var identity: DisplayIdentity
    /// Control key -> value. Unknown keys from a newer file version are ignored when applying.
    public var values: [String: Int]
    public var maximums: [String: Int]
    /// Free text, e.g. manual OSD settings the DDC link cannot reach (color tone, gamma).
    public var notes: String

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), identity: DisplayIdentity,
                values: [Control: Int], maximums: [Control: Int], notes: String = "") {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.identity = identity
        self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.key.key, $0.value) })
        self.maximums = Dictionary(uniqueKeysWithValues: maximums.map { ($0.key.key, $0.value) })
        self.notes = notes
    }
}

struct PresetFile: Codable {
    var version: Int
    var presets: [Preset]
}

public enum PresetStoreError: Error, Equatable {
    case unsupportedVersion(Int)
    case unreadable
}

/// Versioned local JSON, written atomically.
public final class PresetStore: @unchecked Sendable {
    public static let currentVersion = 1
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SamsungDisplayControl", isDirectory: true).appendingPathComponent("presets.json")
    }

    public func load() throws -> [Preset] {
        try lock.withLock { try loadLocked() }
    }

    private func loadLocked() throws -> [Preset] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { throw PresetStoreError.unreadable }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // Read the version first so a newer file is refused rather than half-parsed and overwritten.
        struct Header: Decodable { var version: Int }
        guard let header = try? dec.decode(Header.self, from: data) else { throw PresetStoreError.unreadable }
        guard header.version <= Self.currentVersion else { throw PresetStoreError.unsupportedVersion(header.version) }
        guard let file = try? dec.decode(PresetFile.self, from: data) else { throw PresetStoreError.unreadable }
        return file.presets
    }

    public func save(_ preset: Preset) throws {
        try lock.withLock {
            var all = try loadLocked()
            if let i = all.firstIndex(where: { $0.id == preset.id }) { all[i] = preset } else { all.append(preset) }
            try writeLocked(all)
        }
    }

    public func delete(id: UUID) throws {
        try lock.withLock {
            var all = try loadLocked()
            all.removeAll { $0.id == id }
            try writeLocked(all)
        }
    }

    private func writeLocked(_ presets: [Preset]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(PresetFile(version: Self.currentVersion, presets: presets))
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Preview, apply, restore

public struct PresetPlanItem: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case willApply, skipped(String) }
    public var control: Control
    public var saved: Int
    public var status: Status
}

public struct FieldResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case applied(WriteOutcome)
        case failed(DDCFailure)
        case skipped(String)
        case notRun
    }
    public var control: Control
    public var status: Status
    /// Written and read back exactly.
    public var isVerifiedSuccess: Bool {
        if case .applied(let o) = status { return o.verified }
        return false
    }
    /// Written and the display settled on a value (exactly, or a quantized step).
    public var isAccepted: Bool {
        if case .applied(let o) = status { return o.accepted }
        return false
    }
}

public struct ApplyReport: Sendable {
    public var target: DisplayTarget
    /// Values read from the display before the first write. Used for an explicit restore.
    public var baseline: [Control: Int]
    public var fields: [FieldResult]
}

private let rgb: [Control] = [.red, .green, .blue]

public extension DisplayController {
    /// Reads every catalogue control plus any extra (learned) codes, tolerating per-control failures.
    func snapshot(target: DisplayTarget, extra: [Control] = []) async -> (values: [Control: Int], maximums: [Control: Int], failures: [Control: DDCFailure]) {
        var values: [Control: Int] = [:], maxes: [Control: Int] = [:], failures: [Control: DDCFailure] = [:]
        for c in Control.allCases + extra {
            do {
                let v = try await read(c, target: target)
                values[c] = v.current; maxes[c] = v.maximum
            } catch let f as DDCFailure { failures[c] = f } catch {}
        }
        return (values, maxes, failures)
    }

    /// What applying would do, without touching hardware. Catalogue order first (tone preset before
    /// RGB), then learned codes.
    func plan(_ preset: Preset) -> [PresetPlanItem] {
        let known = Control.allCases.filter { preset.values[$0.key] != nil }
        let learned = preset.values.keys.compactMap(Control.from(key:)).filter { Catalog.spec(for: $0) == nil }
            .sorted { $0.rawValue < $1.rawValue }
        let tone = preset.values[Control.colorPreset.key]
        return (known + learned).map { c in
            let saved = preset.values[c.key]!
            func skip(_ why: String) -> PresetPlanItem { PresetPlanItem(control: c, saved: saved, status: .skipped(why)) }
            if Catalog.denied.contains(c.rawValue) { return skip("never written by this app") }
            if !writableControls.contains(c) { return skip("write not enabled until proven on this hardware") }
            if let spec = Catalog.spec(for: c), !spec.inPreset { return skip("not part of presets") }
            if c == .colorPreset, saved == Catalog.customTone { return skip("Custom tone is restored through the RGB gains") }
            if rgb.contains(c), let t = tone, Catalog.tonePresetRange.contains(t) { return skip("set by the color preset") }
            if Catalog.spec(for: c)?.kind == .slider, let m = preset.maximums[c.key], saved > m { return skip("saved value exceeds saved range") }
            return PresetPlanItem(control: c, saved: saved, status: .willApply)
        }
    }

    /// Baselines are read for every field first; if any baseline read fails nothing is written.
    /// A failing field stops the run; remaining fields are `notRun`. Never called implicitly.
    func apply(_ preset: Preset, to target: DisplayTarget) async throws -> ApplyReport {
        guard preset.identity.matches(target.identity) else { throw DDCFailure.identityMismatch }
        let items = plan(preset)
        var baseline: [Control: Int] = [:]
        var results: [FieldResult] = items.map { item in
            if case .skipped(let why) = item.status { return FieldResult(control: item.control, status: .skipped(why)) }
            return FieldResult(control: item.control, status: .notRun)
        }
        let applying = items.filter { $0.status == .willApply }

        // Baseline: everything we will write, plus the whole tone group when any of it changes, so a
        // restore can re-enter the original tone (Custom can only be reached through the RGB gains).
        var toRead = applying.map(\.control)
        if toRead.contains(where: { $0 == .colorPreset || rgb.contains($0) }) {
            for c in [Control.colorPreset] + rgb where !toRead.contains(c) { toRead.append(c) }
        }
        for c in toRead {
            do { baseline[c] = try await read(c, target: target).current }
            catch let f as DDCFailure {
                markFailed(&results, c, f)
                return ApplyReport(target: target, baseline: baseline, fields: results)
            }
        }
        for item in applying {
            do {
                let outcome = try await write(item.control, value: item.saved, target: target)
                setStatus(&results, item.control, .applied(outcome))
                if !outcome.accepted { break }
            } catch let f as DDCFailure {
                markFailed(&results, item.control, f)
                break
            }
        }
        return ApplyReport(target: target, baseline: baseline, fields: results)
    }

    /// Explicit restore of captured baseline values, only if the same target generation is still live.
    /// A restore is a hardware write and is verified like any other. The tone group is restored as
    /// a unit: original tone 1-4 -> write the preset; original Custom -> write the original RGB gains.
    func restore(_ report: ApplyReport) async -> [FieldResult] {
        var out: [FieldResult] = []
        func put(_ c: Control, _ v: Int) async {
            do { out.append(FieldResult(control: c, status: .applied(try await write(c, value: v, target: report.target)))) }
            catch let e as DDCFailure { out.append(FieldResult(control: c, status: .failed(e))) }
            catch {}
        }
        let applied = Set(report.fields.filter { if case .applied = $0.status { return true }; return false }.map(\.control))
        let toneTouched = applied.contains(.colorPreset) || !applied.isDisjoint(with: rgb)
        if toneTouched, let baseTone = report.baseline[.colorPreset] {
            if Catalog.tonePresetRange.contains(baseTone) {
                await put(.colorPreset, baseTone)
            } else {
                for c in rgb { if let v = report.baseline[c] { await put(c, v) } }
            }
        }
        for c in report.baseline.keys.sorted(by: { $0.rawValue < $1.rawValue })
        where applied.contains(c) && c != .colorPreset && !rgb.contains(c) {
            await put(c, report.baseline[c]!)
        }
        return out
    }
}

private func markFailed(_ r: inout [FieldResult], _ c: Control, _ f: DDCFailure) { setStatus(&r, c, .failed(f)) }
private func setStatus(_ r: inout [FieldResult], _ c: Control, _ s: FieldResult.Status) {
    if let i = r.firstIndex(where: { $0.control == c }) { r[i].status = s }
}
