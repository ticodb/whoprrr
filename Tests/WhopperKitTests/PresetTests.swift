import XCTest
@testable import WhopperKit

@MainActor
final class PresetTests: RecipeHarnessCase {
    private let control = "audio.eq"
    private var location: PresetLocation { PresetLocation(control, device: "headphones") }
    private let factory = [FactoryPreset(id: "flat", name: "Flat", data: Data([0]))]

    private func groups(_ library: PresetLibrary, at place: PresetLocation? = nil, live: Data? = nil) -> PresetGroups {
        library.groups(at: place ?? location, factory: factory, live: live, matches: ==)
    }

    private func library() -> PresetLibrary { PresetLibrary(url: tmpDir().appendingPathComponent("presets.json")) }

    func testLoadsTodaysDictionaryFormatAndKeepsItsID() throws {
        let url = tmpDir().appendingPathComponent("presets.json")
        try Data("""
            {"audio.eq":[{"id":"FF71126A-6DCE-463A-95C3-E9D3900EA937","name":"Desk","date":0,"data":"e30="}]}
            """.utf8).write(to: url)
        let presets = PresetLibrary(url: url)
        let entry = try XCTUnwrap(groups(presets).yours.first)
        XCTAssertEqual(entry.id, .personal(try XCTUnwrap(UUID(uuidString: "FF71126A-6DCE-463A-95C3-E9D3900EA937"))))
        XCTAssertEqual(entry.data, Data("{}".utf8))
        XCTAssertTrue(presets.select(entry.id, at: location))
        XCTAssertEqual(groups(PresetLibrary(url: url)).inUse, entry)
    }

    func testSelectionsAreSeparatePerDeviceAndPersist() throws {
        let url = tmpDir().appendingPathComponent("presets.json")
        let presets = PresetLibrary(url: url)
        let speakers = PresetLocation(control, device: "speakers")
        let shared = PresetLocation(control)
        XCTAssertTrue(presets.saveNew("Desk", data: Data([1]), at: location))
        XCTAssertTrue(presets.select(.factory("flat"), at: speakers))
        let reopened = PresetLibrary(url: url)
        XCTAssertEqual(groups(reopened, live: Data([2])).inUse?.name, "Desk")
        XCTAssertTrue(groups(reopened, live: Data([2])).edited)
        XCTAssertEqual(groups(reopened, at: speakers, live: Data([0])).inUse?.name, "Flat")
        XCTAssertFalse(groups(reopened, at: speakers, live: Data([0])).edited)
        XCTAssertNil(groups(reopened, at: shared).inUse)
        XCTAssertEqual(groups(reopened).selectableBuiltIn.map(\.name), ["Flat"])
        XCTAssertTrue(groups(reopened).selectableYours.isEmpty)
    }

    func testCanonicalMatchDoesNotMarkEquivalentJSONAsEdited() {
        let presets = library()
        XCTAssertTrue(presets.saveNew("Desk", data: Data("{\"b\":2,\"a\":1}".utf8), at: location))
        let live = Data("{\"a\":1,\"b\":2}".utf8)
        let result = presets.groups(at: location, factory: factory, live: live) {
            RecipeJSON.decode([String: Int].self, from: $0) == RecipeJSON.decode([String: Int].self, from: $1)
        }
        XCTAssertFalse(result.edited)
    }

    func testFactoryEditsAreOverridesAndHideShowPreservesThem() throws {
        let presets = library()
        let h = harness()
        let id = PresetID.factory("flat")
        XCTAssertTrue(presets.rename(id, to: "Quiet", for: control))
        let entry = try XCTUnwrap(groups(presets).builtIn.first)
        XCTAssertNotNil(presets.update(entry, with: Data([4]), at: location, recipePart: "audio", recipes: h.store))
        XCTAssertTrue(presets.select(id, at: location))
        XCTAssertEqual(groups(presets).inUse?.name, "Quiet")
        XCTAssertEqual(groups(presets).inUse?.changed, true)
        XCTAssertTrue(presets.setHidden(true, id: "flat", for: control))
        XCTAssertTrue(groups(presets).builtIn.isEmpty)
        XCTAssertNil(groups(presets).inUse)
        XCTAssertEqual(groups(presets).hidden.first?.data, Data([4]))
        XCTAssertTrue(presets.setHidden(false, id: "flat", for: control))
        XCTAssertEqual(groups(presets).builtIn.first?.name, "Quiet")
        XCTAssertTrue(presets.restoreFactory("flat", for: control))
        XCTAssertEqual(groups(presets).builtIn.first?.name, "Flat")
        XCTAssertEqual(groups(presets).builtIn.first?.data, Data([0]))
        XCTAssertEqual(groups(presets).builtIn.first?.changed, false)
    }

    func testCombinedUpdateSavesAndUndoesThePresetAndRecipe() throws {
        let h = harness()
        let presets = library()
        let recipe = h.store.create(name: "Office", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
        XCTAssertTrue(presets.saveNew("Desk", data: Data([1]), at: location))
        let entry = try XCTUnwrap(groups(presets).inUse)
        h.audio.value = "tuned"
        h.bar.settingsDidChange()
        let update = try XCTUnwrap(presets.update(entry, with: Data([2]), at: location, recipePart: "audio", recipes: h.store))
        h.bar.showPresetUpdate(update, in: presets)
        XCTAssertEqual(h.bar.confirmation?.message, "“Desk” updated and saved to Office.")
        XCTAssertEqual(h.bar.phase, .idle)
        XCTAssertEqual(h.store.recipe(recipe.id)?.sections["audio"], RecipeStore.sections(["audio": "tuned"])["audio"])
        XCTAssertEqual(groups(presets).inUse?.data, Data([2]))
        XCTAssertFalse(h.store.isModified(recipe.id))
        h.bar.undoSave()
        XCTAssertNil(h.bar.confirmation)
        XCTAssertEqual(h.store.recipe(recipe.id)?.sections, recipe.sections)
        XCTAssertEqual(h.audio.value, "home-audio")
        XCTAssertEqual(groups(presets).inUse, entry)
        XCTAssertTrue(h.store.recipe(recipe.id)?.previous?.isNewer == true)
    }

    func testPresetOnlyUpdateLeavesAnUnrelatedDirtyRecipeAndTimesOut() throws {
        let h = harness()
        let presets = library()
        let recipe = h.store.create(name: "Office", symbol: "house", includes: ["windows"], devices: [], autoApply: false)
        h.windows.value = "tuned"
        h.bar.settingsDidChange()
        XCTAssertTrue(presets.saveNew("Desk", data: Data([1]), at: location))
        let entry = try XCTUnwrap(groups(presets).inUse)
        let update = try XCTUnwrap(presets.update(entry, with: Data([2]), at: location, recipePart: "audio", recipes: h.store))
        h.bar.showPresetUpdate(update, in: presets)
        XCTAssertEqual(h.bar.confirmation?.message, "“Desk” updated.")
        XCTAssertEqual(h.bar.phase, .changing(recipe: "Office"))
        h.sched.advance(4)
        XCTAssertNil(h.bar.confirmation)
        XCTAssertTrue(h.store.isModified(recipe.id))
        XCTAssertTrue(presets.undo(update, recipes: h.store))
        XCTAssertEqual(groups(presets).inUse, entry)
    }

    func testUpdatingADifferentRowKeepsTheRecipeUnsaved() throws {
        let h = harness()
        let presets = library()
        let recipe = h.store.create(name: "Office", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
        XCTAssertTrue(presets.saveNew("Desk", data: Data([1]), at: location))
        h.audio.value = "tuned"
        let entry = try XCTUnwrap(groups(presets).builtIn.first)
        let result = try XCTUnwrap(presets.update(entry, with: Data([2]), at: location, recipePart: "audio", recipes: h.store))
        XCTAssertEqual(result.message, "“Flat” updated.")
        XCTAssertTrue(h.store.isModified(recipe.id))
    }

    func testRecipeWriteFailureRollsThePresetBack() throws {
        let h = harness()
        let url = tmpDir().appendingPathComponent("presets.json")
        let presets = PresetLibrary(url: url)
        let recipe = h.store.create(name: "Office", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
        XCTAssertTrue(presets.saveNew("Desk", data: Data([1]), at: location))
        let entry = try XCTUnwrap(groups(presets).inUse)
        h.audio.value = "tuned"
        try FileManager.default.removeItem(at: h.url)
        try FileManager.default.createDirectory(at: h.url, withIntermediateDirectories: false)
        XCTAssertNil(presets.update(entry, with: Data([2]), at: location, recipePart: "audio", recipes: h.store))
        XCTAssertEqual(groups(presets).inUse, entry)
        XCTAssertEqual(groups(PresetLibrary(url: url, recipes: h.store)).inUse, entry)
        XCTAssertEqual(h.store.recipe(recipe.id)?.sections, recipe.sections)
    }
}
