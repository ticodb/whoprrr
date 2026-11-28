import AudioCore
import XCTest
@testable import WhopperKit

@MainActor
final class WhopperBackupTests: RecipeHarnessCase {
    func testFullBackupRoundTripsRecipesPresetsAndAllDeviceBytes() throws {
        let dir = tmpDir()
        let urls: [WhopperBackup.Component: URL] = [
            .recipes: dir.appendingPathComponent("recipes.json"),
            .presets: dir.appendingPathComponent("presets.json"),
            .audio: dir.appendingPathComponent("audio.json"),
            .input: dir.appendingPathComponent("input.json"),
            .displayPresets: dir.appendingPathComponent("display.json"),
        ]
        let recipes = RecipeStore(url: urls[.recipes])
        let presets = PresetLibrary(url: urls[.presets])
        let section = PresetLocation("audio.eq", device: "headphones")
        let h = FakeSurface("audio", "headphones")
        recipes.register(h)
        let recipe = recipes.create(name: "Desk", symbol: "house", includes: ["audio"], devices: home, autoApply: true)
        recipes.setInputSource(recipe.id, sourceID: "com.apple.keylayout.Spanish-ISO", name: "Spanish – ISO")
        for i in 0..<70 {
            XCTAssertTrue(presets.saveNew("Curve \(i)", data: Data(repeating: UInt8(i), count: 2_000), at: section))
        }
        XCTAssertTrue(presets.setHidden(true, id: "flat", for: section.control))

        var settings = AudioSettings()
        settings.eq.profiles["headphones"] = .flat
        settings.eq.profiles["disconnected-device"] = .flat
        try JSONEncoder().encode(settings).write(to: XCTUnwrap(urls[.audio]))
        try Data(#"{"rules":[],"keyboardSettings":{"disconnected-keyboard":true}}"#.utf8).write(to: XCTUnwrap(urls[.input]))
        try Data(#"{"version":1,"presets":[]}"#.utf8).write(to: XCTUnwrap(urls[.displayPresets]))
        let files = WhopperBackupFiles(urls: urls, journal: dir.appendingPathComponent("pending.json"))
        let backup = try files.capture(keyID: "my-key-id", appVersion: "1.0")
        let encoded = try backup.encoded()
        XCTAssertGreaterThan(encoded.count, 65_536)
        let opened = try WhopperBackup.decode(encoded)
        XCTAssertEqual(opened, backup)
        XCTAssertEqual(try opened.recipeContents().first?.inputSourceName, "Spanish – ISO")
        XCTAssertEqual(try opened.presetCount(), 70)
        XCTAssertEqual(opened.madeWithKeyID, "my-key-id")
        XCTAssertEqual(opened[.audio], try Data(contentsOf: XCTUnwrap(urls[.audio])))

        let previousAudio = Data(#"{"old":"settings"}"#.utf8)
        try previousAudio.write(to: XCTUnwrap(urls[.audio]))
        let before = try files.capture(keyID: "my-key-id", appVersion: "1.0")
        let recovery = dir.appendingPathComponent("recovery.whoprrr-backup")
        try files.restore(opened, keeping: before, at: recovery)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(urls[.audio])), opened[.audio])
        XCTAssertEqual(try WhopperBackup.decode(Data(contentsOf: recovery))[.audio], previousAudio)
        let restoredPresets = PresetLibrary(url: urls[.presets])
        let groups = restoredPresets.groups(at: section, factory: [.init(id: "flat", name: "Flat", data: Data())],
                                            live: nil, matches: ==)
        XCTAssertEqual(groups.inUse?.name, "Curve 69")
        XCTAssertEqual(groups.hidden.map(\.name), ["Flat"])
    }

    func testNewerFormatIsRefusedBeforeReadingPayloadOrWritingFiles() throws {
        let dir = tmpDir()
        let source = dir.appendingPathComponent("newer.whoprrr-backup")
        let original = Data(#"{"formatVersion":99,"futurePayload":"keep me"}"#.utf8)
        try original.write(to: source)
        XCTAssertThrowsError(try WhopperBackup.decode(Data(contentsOf: source))) {
            XCTAssertEqual($0 as? WhopperBackup.Problem, .newerVersion(99))
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [source.lastPathComponent])
    }

    func testInterruptedRestoreRollsBackAndRemovesFilesMissingInThePriorBackup() throws {
        let dir = tmpDir()
        let audio = dir.appendingPathComponent("audio.json")
        let input = dir.appendingPathComponent("input.json")
        let journal = dir.appendingPathComponent("journal.json")
        let before = Data("saved audio".utf8)
        let files = WhopperBackupFiles(urls: [.audio: audio, .input: input], journal: journal)
        let rollback = WhopperBackup(madeWithKeyID: "key", appVersion: "1.0", files: [.audio: before])
        try rollback.encoded().write(to: journal)
        try Data("partial restore".utf8).write(to: audio)
        try Data("new file".utf8).write(to: input)
        try files.recoverInterruptedRestore()
        XCTAssertEqual(try Data(contentsOf: audio), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
}
