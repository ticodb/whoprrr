import XCTest
import AudioCore
import WhopperKit
@testable import Whopper

final class MixerRecipeTests: XCTestCase {
    @MainActor
    func testAudioRecipeCapturesAppliesAndMarksChangesToTheMix() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = AudioModel(store: JSONStore(url: dir.appendingPathComponent("audio.json")))
        let recipes = RecipeStore(url: dir.appendingPathComponent("recipes.json"))
        recipes.register(audio)
        let saveBar = SaveBarController(store: recipes)
        let music = "com.apple.Music"

        audio.settings.mix.set(music, volume: 0.4, muted: false, name: "Music")
        let home = recipes.create(name: "Home Office", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
        let captured = try XCTUnwrap(home.sections["audio"].flatMap { RecipeJSON.decode(AudioSettings.self, from: $0) })
        XCTAssertEqual(captured.mix.apps[music]?.volume, 0.4)
        XCTAssertTrue(recipes.changedParts().isEmpty)

        audio.settings.mix.set(music, volume: 0.4, muted: false, name: "Renamed Music")
        saveBar.settingsDidChange()
        XCTAssertEqual(saveBar.phase, .idle)

        audio.settings.mix.set(music, volume: 0.7, muted: true, name: "Music")
        saveBar.settingsDidChange()
        XCTAssertEqual(saveBar.phase, .changing(recipe: "Home Office"))
        XCTAssertEqual(recipes.changedParts(), ["audio"])
        let cowork = recipes.create(name: "Co-work", symbol: "headphones", includes: ["audio"], devices: [], autoApply: false)

        XCTAssertTrue(recipes.apply(home.id).isEmpty)
        XCTAssertEqual(audio.settings.mix, captured.mix)
        XCTAssertEqual(saveBar.phase, .idle)
        XCTAssertTrue(recipes.apply(cowork.id).isEmpty)
        XCTAssertEqual(audio.settings.mix.apps[music]?.volume, 0.7)
        XCTAssertEqual(audio.settings.mix.apps[music]?.muted, true)
    }

    @MainActor
    func testSystemSoundPresetRestoresItsMixAndAnOldCurveKeepsTheLiveMix() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = AudioModel(store: JSONStore(url: dir.appendingPathComponent("audio.json")))
        let surface = PresetSurfaces.eq(audio)
        audio.settings.mix.set("com.apple.Music", volume: 0.35, muted: false, name: "Music")
        let mix = audio.settings.mix
        let preset = try XCTUnwrap(surface.capture())
        audio.settings.mix.reset("com.apple.Music")
        XCTAssertTrue(surface.apply(preset))
        XCTAssertEqual(audio.settings.mix, mix)

        let oldCurve = try XCTUnwrap(RecipeJSON.encode(EQProfile.tenBand([2], preampDB: -2)))
        XCTAssertTrue(surface.apply(oldCurve))
        XCTAssertEqual(audio.eqProfile.preampDB, -2)
        XCTAssertEqual(audio.settings.mix, mix)
    }
}
