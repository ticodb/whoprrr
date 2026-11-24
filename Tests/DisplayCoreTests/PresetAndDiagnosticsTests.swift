import XCTest
@testable import DisplayCore

final class PresetTests: XCTestCase {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sdc-\(UUID().uuidString)/presets.json") }

    func testPersistsAcrossStoreInstances() throws {
        let url = tmp()
        let p = Preset(name: "Match MacBook", identity: Fx.samsungID,
                       values: [.brightness: 42, .contrast: 60], maximums: [.brightness: 100, .contrast: 100], notes: "Color tone: Warm1 (OSD)")
        try PresetStore(url: url).save(p)
        let loaded = try PresetStore(url: url).load()      // "app restart"
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Match MacBook")
        XCTAssertEqual(loaded[0].values["brightness"], 42)
        XCTAssertEqual(loaded[0].notes, "Color tone: Warm1 (OSD)")
        XCTAssertTrue(loaded[0].identity.matches(Fx.samsungID))
    }

    func testSaveReplacesByIDAndDeletes() throws {
        let store = PresetStore(url: tmp())
        var p = Preset(name: "A", identity: Fx.samsungID, values: [.brightness: 10], maximums: [:])
        try store.save(p); p.name = "A2"; try store.save(p)
        XCTAssertEqual(try store.load().map(\.name), ["A2"])
        try store.delete(id: p.id)
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testNewerFileVersionIsRefusedNotOverwritten() throws {
        let url = tmp()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 99, "presets": []}"#.utf8).write(to: url)
        let store = PresetStore(url: url)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? PresetStoreError, .unsupportedVersion(99)) }
        let p = Preset(name: "X", identity: Fx.samsungID, values: [:], maximums: [:])
        XCTAssertThrowsError(try store.save(p))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("99"), "newer file must be left intact")
    }

    func testCorruptFileThrowsUnreadable() throws {
        let url = tmp()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try PresetStore(url: url).load()) { XCTAssertEqual($0 as? PresetStoreError, .unreadable) }
    }

    // MARK: apply

    func testPlanSkipsUnprovenAndNonPresetControls() async throws {
        let (_, c) = Fx.rig()
        let p = Preset(name: "P", identity: Fx.samsungID,
                       values: [.brightness: 40, Control(0xE0): 3, .input: 16, .volume: 10], maximums: [:])
        let plan = c.plan(p)
        XCTAssertEqual(plan.first { $0.control == .brightness }?.status, .willApply)
        for c in [Control(0xE0), .input, .volume] {
            if case .skipped = plan.first(where: { $0.control == c })!.status {} else { XCTFail("\(c) should be skipped") }
        }
    }

    func testApplyReadsBaselineThenWritesAndVerifies() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        let p = Preset(name: "P", identity: Fx.samsungID, values: [.brightness: 40, .contrast: 55, .input: 16], maximums: [:])
        let report = try await c.apply(p, to: t)
        XCTAssertEqual(report.baseline, [.brightness: 80, .contrast: 60])
        XCTAssertEqual(f.writes.map(\.control), [.brightness, .contrast], "input is never part of a preset")
        XCTAssertTrue(report.fields.allSatisfy { $0.control == .input || $0.isVerifiedSuccess })
    }

    // MARK: tone preset semantics (measured on a Samsung S34CG50)

    func testTonePresetSkipsRGBBecausePresetOverridesThem() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        let p = Preset(name: "Warm", identity: Fx.samsungID, values: [.colorPreset: 4, .red: 50, .green: 31, .blue: 6], maximums: [:])
        let r = try await c.apply(p, to: t)
        XCTAssertEqual(f.writes.map(\.control), [.colorPreset])
        XCTAssertEqual(r.baseline[.colorPreset], 5)
        XCTAssertEqual([Control.red, .green, .blue].compactMap { c in r.fields.first { $0.control == c }?.status }.count, 3)
    }

    func testCustomToneSkipsPresetWriteAndAppliesRGB() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        let p = Preset(name: "Mine", identity: Fx.samsungID, values: [.colorPreset: 5, .red: 40, .green: 41, .blue: 42], maximums: [:])
        _ = try await c.apply(p, to: t)
        XCTAssertEqual(f.writes.map(\.control), [.red, .green, .blue], "Custom (5) can only be reached through RGB writes")
    }

    func testRestoreToCustomWritesOriginalRGBNotPreset() async throws {
        let (f, c) = Fx.rig()                      // baseline tone is Custom (5) with RGB 56/56/63
        let t = try await Fx.target(c)
        let p = Preset(name: "Warm", identity: Fx.samsungID, values: [.colorPreset: 4], maximums: [:])
        let r = try await c.apply(p, to: t)
        let before = f.writes.count
        _ = await c.restore(r)
        let restoreWrites = f.writes.dropFirst(before)
        XCTAssertEqual(restoreWrites.map(\.control), [.red, .green, .blue])
        XCTAssertEqual(restoreWrites.map(\.value), [56, 56, 63])
        XCTAssertFalse(restoreWrites.contains { $0.control == .colorPreset }, "writing 5 to the preset is rejected by the display")
    }

    func testRestoreToTonePresetWritesPreset() async throws {
        let (f, c) = Fx.rig()
        f.setValue(.init(current: 2, maximum: 4), .colorPreset, uuid: "UUID-EXT")      // baseline: Normal
        let t = try await Fx.target(c)
        let p = Preset(name: "Mine", identity: Fx.samsungID, values: [.colorPreset: 5, .red: 40], maximums: [:])
        let r = try await c.apply(p, to: t)
        let before = f.writes.count
        _ = await c.restore(r)
        XCTAssertEqual(f.writes.dropFirst(before).map(\.control), [.colorPreset])
        XCTAssertEqual(f.writes.last?.value, 2)
    }

    func testQuantizedFieldDoesNotAbortApply() async throws {
        let (f, c) = Fx.rig()
        f.step[.sharpness] = 8
        let t = try await Fx.target(c)
        let p = Preset(name: "P", identity: Fx.samsungID, values: [.sharpness: 51, .brightness: 40], maximums: [:])
        let r = try await c.apply(p, to: t)
        XCTAssertEqual(f.writes.map(\.control).sorted { $0.rawValue < $1.rawValue }, [.brightness, .sharpness])
        XCTAssertTrue(r.fields.allSatisfy(\.isAccepted))
    }

    func testApplyRefusesPresetForAnotherDisplay() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        let p = Preset(name: "P", identity: Fx.otherID, values: [.brightness: 40], maximums: [:])
        do { _ = try await c.apply(p, to: t); XCTFail() } catch { XCTAssertEqual(error as? DDCFailure, .identityMismatch) }
        XCTAssertTrue(f.writes.isEmpty)
    }

    func testBaselineReadFailureWritesNothing() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        f.failReads(.brightness, with: .timeout)
        let p = Preset(name: "P", identity: Fx.samsungID, values: [.brightness: 40], maximums: [:])
        let report = try await c.apply(p, to: t)
        XCTAssertTrue(f.writes.isEmpty)
        XCTAssertEqual(report.fields.first?.status, .failed(.timeout))
    }

    func testPartialFailurePreservedAndRestoreVerifies() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        f.failWrites(.contrast, with: .timeout)
        let p = Preset(name: "P", identity: Fx.samsungID, values: [.brightness: 40, .contrast: 55], maximums: [:])
        let report = try await c.apply(p, to: t)
        XCTAssertTrue(report.fields.first { $0.control == .brightness }!.isVerifiedSuccess)
        XCTAssertEqual(report.fields.first { $0.control == .contrast }!.status, .failed(.timeout))
        let restored = await c.restore(report)
        XCTAssertEqual(restored.count, 1)
        XCTAssertTrue(restored[0].isVerifiedSuccess)
        let now = try await c.read(.brightness, target: t)
        XCTAssertEqual(now.current, 80, "restore returns the captured baseline")
    }

    func testRestoreRefusedAfterGenerationChange() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        let p = Preset(name: "P", identity: Fx.samsungID, values: [.brightness: 40], maximums: [:])
        let report = try await c.apply(p, to: t)
        let writesBefore = f.writes.count
        c.generation.bump()                                         // e.g. sleep/wake happened
        let restored = await c.restore(report)
        XCTAssertEqual(restored.first?.status, .failed(.stale))
        XCTAssertEqual(f.writes.count, writesBefore)
    }
}

final class DiagnosticsTests: XCTestCase {
    func testTimelineIsBounded() {
        let log = DiagnosticsLog()
        for i in 0..<(DiagnosticsLog.capacity + 50) { log.record(.info, "e\(i)") }
        XCTAssertEqual(log.events.count, DiagnosticsLog.capacity)
        XCTAssertEqual(log.events.first?.message, "e50")
    }

    func testExportRedactsIdentifiers() throws {
        let d = Fx.ext("0F3C9D11-7B2E-4A55-9C01-AB12CD34EF56")
        let log = DiagnosticsLog()
        log.record(.ddc, "read Brightness on 0F3C9D11-7B2E-4A55-9C01-AB12CD34EF56 serial TESTSERIAL01 sn 900000001", transport: .hardware, ok: true)
        let data = try DiagnosticsExporter.export(displays: [d], events: log.events)
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["0F3C9D11", "TESTSERIAL01", "900000001", "EDID-"] { XCTAssertFalse(text.contains(secret), "leaked \(secret)") }
        XCTAssertTrue(text.contains("S34CG50"))
        XCTAssertTrue(text.contains("\"transport\" : \"hardware\""))
    }

    func testUnredactedExportOnlyWhenAsked() throws {
        let d = Fx.ext("UUID-X")
        let data = try DiagnosticsExporter.export(displays: [d], events: [], redact: false)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("UUID-X"))
    }

    func testTokenIsStable() {
        XCTAssertEqual(Redaction.token("abc", label: "uuid"), Redaction.token("abc", label: "uuid"))
        XCTAssertNotEqual(Redaction.token("abc", label: "uuid"), Redaction.token("abd", label: "uuid"))
    }
}

final class ScrubTests: XCTestCase {
    func testShortSerialDoesNotCorruptNumbers() {
        let id = DisplayIdentity(vendor: 1, model: 2, serial: 1, alphaSerial: nil, productName: "X", manufacturer: nil)
        let d = DisplayDescriptor(uuid: "U-1", edidUUID: nil, displayID: 1, identity: id, isBuiltIn: false, hasEndpoint: true)
        XCTAssertEqual(Redaction.scrub("read = 60/100", displays: [d]), "read = 60/100")
    }
}


final class LearnTests: XCTestCase {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sdc-\(UUID().uuidString)/learned.json") }

    func testDiffFindsOnlyChangedCodesAndDropsDenied() {
        let a: ScanResult = [0x10: .init(current: 50, maximum: 100), 0xE0: .init(current: 1, maximum: 255), 0xD6: .init(current: 0, maximum: 0)]
        var b = a
        b[0xE0] = .init(current: 3, maximum: 255)
        b[0xD6] = .init(current: 4, maximum: 0)
        XCTAssertEqual(ScanDiff.changes(before: a, after: b), [ScanDiffItem(code: 0xE0, before: 1, after: 3, maximum: 255)])
    }

    func testScanAndDiffAgainstFake() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        let before = await c.scanAll(target: t)
        XCTAssertNotNil(before[0xE0]); XCTAssertNil(before[0x77])
        f.setValue(.init(current: 3, maximum: 255), Control(0xE0), uuid: "UUID-EXT")     // "user changed an OSD item"
        let after = await c.rescan(codes: Array(before.keys), target: t)
        XCTAssertEqual(ScanDiff.changes(before: before, after: after).map(\.code), [0xE0])
    }

    func testLearnedSettingPersistsAndMergesObservedValues() throws {
        let store = LearnedStore(url: tmp())
        let s1 = LearnedSetting(identity: Fx.samsungID, code: 0xE0, name: "Game mode", observed: [1, 3], maximum: 255)
        try store.save(s1)
        try store.save(LearnedSetting(identity: Fx.samsungID, code: 0xE0, name: "Game mode", observed: [3, 7], maximum: 255))
        let loaded = try LearnedStore(url: store.url).load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].observed, [1, 3, 7])
        XCTAssertEqual(store.settings(for: Fx.otherID), [], "learned settings belong to one display")
        try store.delete(id: s1.id)
        XCTAssertTrue(try store.load().isEmpty)
    }
}
