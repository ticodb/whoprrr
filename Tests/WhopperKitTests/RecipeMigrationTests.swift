import XCTest
@testable import WhopperKit

/// The shape of the old file, read independently of the new types, to hold the conversion to "nothing lost".
private struct V1File: Decodable {
    struct Device: Decodable { var kind: String; var key: String; var name: String }
    struct R: Decodable {
        var id: UUID; var name: String; var symbol: String; var createdAt: Double; var updatedAt: Double
        var devices: [Device]; var sections: [String: Data]; var autoApply: Bool
    }
    var recipes: [R]; var activeID: UUID?; var appliedSections: [String: Data]
}

/// A surface that holds exactly the bytes it is given, like the real ones hold their settings JSON.
@MainActor
final class RawSurface: RecipeSurface {
    let recipeKey: String, recipeTitle: String
    var data: Data?
    init(_ key: String, _ title: String, _ data: Data? = nil) { recipeKey = key; recipeTitle = title; self.data = data }
    func captureRecipeData() -> Data? { data }
    func applyRecipeData(_ d: Data) -> Bool { data = d; return true }
}

@MainActor
final class RecipeMigrationTests: RecipeHarnessCase {
    func writeV1(_ dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("recipes.json")
        try Data(RecipeFixtures.v1.utf8).write(to: url)
        return url
    }
    func backups(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains("backup") }.sorted()
    }
    func rawStore(_ url: URL) -> (RecipeStore, [String: RawSurface]) {
        let s = RecipeStore(url: url)
        let surfaces = ["audio": RawSurface("audio", "Audio"), "windows": RawSurface("windows", "Windows"), "features": RawSurface("features", "Installed features"), "display": RawSurface("display", "Display preset")]
        surfaces.values.forEach { s.register($0) }
        return (s, surfaces)
    }
    func json(_ url: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }

    // MARK: Conversion

    func testOldFileIsConvertedAndTheOriginalIsKeptBesideIt() throws {
        let dir = tmpDir(); let url = try writeV1(dir)
        let original = try Data(contentsOf: url)
        let s = RecipeStore(url: url)

        guard case .migrated(let from, let backup) = s.loadOutcome else { return XCTFail("expected a migration, got \(s.loadOutcome)") }
        XCTAssertEqual(from, 1)
        XCTAssertEqual(backup.lastPathComponent, "recipes.backup-v1.json")
        XCTAssertEqual(backup.deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(try Data(contentsOf: backup), original)                         // byte for byte
        XCTAssertEqual(try json(url)["formatVersion"] as? Int, 2)                      // the new file says what it is
        XCTAssertNil(try json(backup)["formatVersion"])
    }

    func testNothingTheOldFileHeldIsLost() throws {
        let url = try writeV1(tmpDir())
        let old = try JSONDecoder().decode(V1File.self, from: Data(contentsOf: url))
        let s = RecipeStore(url: url)
        let again = RecipeStore(url: url)                                              // and what was written reads back the same
        for store in [s, again] {
            XCTAssertEqual(store.activeID, old.activeID)
            XCTAssertEqual(store.recipes.count, old.recipes.count)
            for (r, o) in zip(store.recipes, old.recipes) {
                XCTAssertEqual(r.id, o.id); XCTAssertEqual(r.name, o.name); XCTAssertEqual(r.symbol, o.symbol)
                XCTAssertEqual(r.createdAt.timeIntervalSinceReferenceDate, o.createdAt); XCTAssertEqual(r.updatedAt.timeIntervalSinceReferenceDate, o.updatedAt)
                XCTAssertEqual(r.sections, o.sections); XCTAssertEqual(r.autoApply, o.autoApply)
                XCTAssertEqual(r.devices.map(\.kind.rawValue), o.devices.map(\.kind)); XCTAssertEqual(r.devices.map(\.key), o.devices.map(\.key)); XCTAssertEqual(r.devices.map(\.name), o.devices.map(\.name))
                XCTAssertNil(r.previous)
            }
        }
        let (_, surfaces) = rawStore(url)
        _ = surfaces
        // the baseline is kept too: read through the behaviour it drives
        let (st, raw) = rawStore(url)
        for (k, v) in old.appliedSections { raw[k]?.data = v }
        XCTAssertFalse(st.isModified(RecipeFixtures.deskID))
    }

    func testGearGainsRoleAndModelAndKeepsWhatThisMacNeeds() throws {
        let url = try writeV1(tmpDir())
        let s = RecipeStore(url: url)
        let desk = s.recipes[0].devices
        XCTAssertEqual(desk.map(\.role.rawValue), ["display", "microphone", "speaker", "mouse"])
        XCTAssertEqual(desk.map(\.model), ["S34CG50", "RØDE PodMic USB", "Xiaomi Speaker", "MX Ergo"])
        XCTAssertEqual(desk.map(\.key), ["EDID-0000-1111", "AppleUSBAudioEngine:Rode:PodMic:42", "BT-XIAOMI", "MX Ergo"])
        XCTAssertEqual(s.recipes[1].devices[0].model, "AirPods Pro")                   // a person's name stays on this Mac
        XCTAssertEqual(s.recipes[1].devices[0].name, "Ana’s AirPods Pro")
        // and the file itself says it, in words another Mac can read
        let first = ((try json(url)["recipes"] as! [[String: Any]])[0]["devices"] as! [[String: Any]])[1]
        XCTAssertEqual(first["role"] as? String, "microphone"); XCTAssertEqual(first["model"] as? String, "RØDE PodMic USB")
        XCTAssertEqual(first["key"] as? String, "AppleUSBAudioEngine:Rode:PodMic:42")
    }

    func testApplyAutoApplyAndModifiedBehaveAsBefore() throws {
        let url = try writeV1(tmpDir())
        let old = try JSONDecoder().decode(V1File.self, from: Data(contentsOf: url))
        let (s, raw) = rawStore(url)
        let deskID = RecipeFixtures.deskID
        let deskGear = [DeviceSignature(kind: .display, key: "EDID-0000-1111", name: "S34CG50"),
                        DeviceSignature(kind: .audioInput, key: "AppleUSBAudioEngine:Rode:PodMic:42", name: "RØDE PodMic USB"),
                        DeviceSignature(kind: .audioOutput, key: "BT-XIAOMI", name: "Xiaomi Speaker"),
                        DeviceSignature(kind: .logitech, key: "MX Ergo", name: "MX Ergo")]
        let roadID = s.recipes[1].id

        // isModified: the baseline in the old file differs from what Desk holds for audio, as in the app that wrote it.
        XCTAssertEqual(s.activeID, deskID)
        for (k, v) in old.appliedSections { raw[k]?.data = v }
        XCTAssertFalse(s.isModified(deskID))
        raw["audio"]?.data = old.recipes[0].sections["audio"]
        XCTAssertTrue(s.isModified(deskID))
        XCTAssertEqual(s.changedParts(), ["audio"])

        // apply: every section lands on its surface, byte for byte, and the baseline follows
        s.apply(roadID)
        XCTAssertEqual(raw["audio"]?.data, old.recipes[1].sections["audio"]); XCTAssertEqual(raw["windows"]?.data, old.recipes[1].sections["windows"])
        XCTAssertFalse(s.isModified(roadID))
        raw["windows"]?.data = Data("{}".utf8)
        XCTAssertTrue(s.isModified(roadID))

        // auto-apply matching: Desk's gear all connected switches to Desk; one piece missing does not; a recipe without gear never does
        s.apply(roadID)
        XCTAssertEqual(s.autoApplyCandidate(connected: deskGear)?.id, deskID)
        XCTAssertNil(s.autoApplyCandidate(connected: Array(deskGear.dropLast())))
        XCTAssertNil(s.autoApplyCandidate(connected: [DeviceSignature(kind: .audioOutput, key: "AIRPODS-1", name: "Ana’s AirPods Pro")]))
        XCTAssertEqual(s.recipes[0].gear(connected: deskGear).missing, [])
        XCTAssertEqual(s.recipes[0].gear(connected: [deskGear[0]]).present.map(\.key), ["EDID-0000-1111"])
        XCTAssertEqual(s.ranked(connected: deskGear).first?.id, deskID)
    }

    func testASecondLaunchDoesNotConvertAgainOrTouchTheBackup() throws {
        let dir = tmpDir(); let url = try writeV1(dir)
        let first = RecipeStore(url: url)
        guard case .migrated(_, let backup) = first.loadOutcome else { return XCTFail() }
        let backupBytes = try Data(contentsOf: backup)
        let attrs = try FileManager.default.attributesOfItem(atPath: backup.path)

        first.rename(first.recipes[2].id, to: "Anywhere 2")                             // work done on the new file
        let second = RecipeStore(url: url)
        XCTAssertEqual(second.loadOutcome, .current)
        XCTAssertEqual(second.recipes[2].name, "Anywhere 2")
        XCTAssertEqual(backups(dir), ["recipes.backup-v1.json"])
        XCTAssertEqual(try Data(contentsOf: backup), backupBytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.modificationDate] as? Date, attrs[.modificationDate] as? Date)
    }

    func testAnOldFileThatReappearsDoesNotReplaceAnExistingBackup() throws {
        let dir = tmpDir(); let url = try writeV1(dir)
        _ = RecipeStore(url: url)
        let firstBackup = dir.appendingPathComponent("recipes.backup-v1.json")
        let firstBytes = try Data(contentsOf: firstBackup)
        // an older build of the app opens the new file and writes the old shape back
        var old = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        old["formatVersion"] = nil; old["recipes"] = []
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        let s = RecipeStore(url: url)
        guard case .migrated(_, let second) = s.loadOutcome else { return XCTFail() }
        XCTAssertEqual(second.lastPathComponent, "recipes.backup-v1-2.json")
        XCTAssertEqual(try Data(contentsOf: firstBackup), firstBytes)
        XCTAssertEqual(backups(dir).count, 2)
    }

    func testUnsavedStateOfAnOldFileIsStillThereAfterConversion() throws {
        // The fixture's baseline differs from Desk's audio section: that is an unsaved change, and conversion keeps it.
        let url = try writeV1(tmpDir())
        let (s, raw) = rawStore(url)
        raw["audio"]?.data = s.recipes[0].sections["audio"]; raw["windows"]?.data = s.recipes[0].sections["windows"]
        raw["features"]?.data = s.recipes[0].sections["features"]; raw["display"]?.data = s.recipes[0].sections["display"]
        XCTAssertTrue(s.isModified(RecipeFixtures.deskID))
        XCTAssertEqual(s.changedPartTitles(), ["Audio"])
    }

    // MARK: Files that cannot be read

    func testHalfWrittenFileIsKeptAsItIsAndRecipesStartEmpty() throws {
        let dir = tmpDir(); let url = dir.appendingPathComponent("recipes.json")
        let whole = Data(RecipeFixtures.v1.utf8)
        let half = whole.prefix(whole.count / 2)
        try half.write(to: url)
        let s = RecipeStore(url: url)
        guard case .recovered(let kept) = s.loadOutcome else { return XCTFail("got \(s.loadOutcome)") }
        XCTAssertEqual(try Data(contentsOf: kept), Data(half))                          // not a byte lost
        XCTAssertTrue(s.recipes.isEmpty)
        XCTAssertTrue(backups(dir).isEmpty)                                             // nothing was "converted"
        _ = s.create(name: "New", symbol: "x", includes: [], devices: [], autoApply: false)
        XCTAssertEqual(RecipeStore(url: url).recipes.map(\.name), ["New"])              // and the app works normally
        XCTAssertEqual(try Data(contentsOf: kept), Data(half))
    }

    func testASecondBrokenFileDoesNotReplaceTheFirstOneKeptAside() throws {
        let dir = tmpDir(); let url = dir.appendingPathComponent("recipes.json")
        try Data("{\"recipes\": [".utf8).write(to: url)
        let first = RecipeStore(url: url)
        guard case .recovered(let k1) = first.loadOutcome else { return XCTFail() }
        try Data("{\"formatVersion\": 2, \"recipes\": \"oops\"}".utf8).write(to: url)     // valid JSON, wrong shape
        let second = RecipeStore(url: url)
        guard case .recovered(let k2) = second.loadOutcome else { return XCTFail("got \(second.loadOutcome)") }
        XCTAssertNotEqual(k1, k2)
        XCTAssertEqual(try Data(contentsOf: k1), Data("{\"recipes\": [".utf8))
        XCTAssertEqual(try Data(contentsOf: k2), Data("{\"formatVersion\": 2, \"recipes\": \"oops\"}".utf8))
    }

    func testAFileFromANewerWhoprrrIsNeverWrittenTo() throws {
        let dir = tmpDir(); let url = dir.appendingPathComponent("recipes.json")
        let future = Data("{\"formatVersion\": 9, \"recipes\": [], \"somethingNew\": true}".utf8)
        try future.write(to: url)
        let s = RecipeStore(url: url)
        XCTAssertEqual(s.loadOutcome, .newerFormat(9))
        _ = s.create(name: "Temporary", symbol: "x", includes: [], devices: [], autoApply: false)
        XCTAssertEqual(try Data(contentsOf: url), future)
        XCTAssertTrue(backups(dir).isEmpty)
    }

    func testWhenTheBackupCannotBeMadeNothingIsConvertedOrOverwritten() throws {
        let dir = tmpDir(); let url = try writeV1(dir)
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)      // nothing can be created here
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        guard (try? Data("x".utf8).write(to: dir.appendingPathComponent("probe"))) == nil else { throw XCTSkip("this account can write anywhere") }
        let s = RecipeStore(url: url)
        XCTAssertEqual(s.loadOutcome, .migrationBlocked)
        XCTAssertEqual(s.recipes.map(\.name), ["Desk", "On the road", "Anywhere"])        // still usable
        s.rename(s.recipes[0].id, to: "Renamed")
        XCTAssertEqual(try Data(contentsOf: url), original)                             // the original is exactly as it was
    }

    func testMissingFileStartsFresh() {
        let s = RecipeStore(url: tmpDir().appendingPathComponent("recipes.json"))
        XCTAssertEqual(s.loadOutcome, .fresh)
        XCTAssertTrue(s.recipes.isEmpty)
    }

    func testNewFilesAreWrittenWithTheVersionField() throws {
        let url = tmpDir().appendingPathComponent("recipes.json")
        let s = RecipeStore(url: url)
        _ = s.create(name: "A", symbol: "x", includes: [], devices: [DeviceSignature(kind: .audioInput, key: "k", name: "RØDE PodMic USB")], autoApply: false)
        XCTAssertEqual(try json(url)["formatVersion"] as? Int, 2)
        XCTAssertEqual(RecipeStore(url: url).loadOutcome, .current)
    }

    // MARK: Gear in words

    func testRolesAndModels() {
        XCTAssertEqual(DeviceSignature(kind: .audioInput, key: "uid", name: "RØDE PodMic USB").role, .microphone)
        XCTAssertEqual(DeviceSignature(kind: .audioInput, key: "uid", name: "RØDE PodMic USB").model, "RØDE PodMic USB")
        XCTAssertEqual(DeviceSignature(kind: .audioOutput, key: "u", name: "Ana’s AirPods Pro").role, .speaker)
        XCTAssertEqual(DeviceSignature(kind: .audioOutput, key: "u", name: "Ana’s AirPods Pro").model, "AirPods Pro")
        XCTAssertEqual(DeviceSignature(kind: .display, key: "e", name: "S34CG50").role, .display)
        XCTAssertEqual(DeviceSignature(kind: .logitech, key: "MX Keys S", name: "MX Keys S").role, .keyboard)
        XCTAssertEqual(DeviceSignature(kind: .logitech, key: "MX Master 3S", name: "MX Master 3S").role, .mouse)
        XCTAssertEqual(DeviceSignature(kind: .logitech, key: "Zone Vibe", name: "Zone Vibe").role, .other)
    }

    func testGearIsRecognisedByWhatThisMacNeedsNotByRoleOrModel() {
        let a = DeviceSignature(kind: .audioInput, key: "uid-1", name: "RØDE PodMic USB")
        var b = a; b.role = DeviceRole(rawValue: "podcast-mic"); b.model = "Something else"
        XCTAssertEqual(a.id, b.id)
        let r = Recipe(name: "R", devices: [a])
        XCTAssertTrue(r.isComplete(connected: [b]))
    }

    func testARoleThisVersionDoesNotKnowSurvivesAReadAndWrite() throws {
        let d = try JSONDecoder().decode(DeviceSignature.self, from: Data(#"{"kind":"audioInput","key":"k","name":"n","role":"capture-card","model":"m"}"#.utf8))
        XCTAssertEqual(d.role.rawValue, "capture-card")
        let back = try JSONDecoder().decode(DeviceSignature.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
    }
}
