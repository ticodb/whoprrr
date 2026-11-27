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

    func testUnreadableCatalogIsCopiedAndNeverOverwrittenByPresetSaves() throws {
        let dir = tmpDir()
        let url = dir.appendingPathComponent("presets.json")
        let original = Data(#"{"catalog":{"yours":{"audio.eq":"future data"}}}"#.utf8)
        try original.write(to: url)

        for _ in 0..<2 {
            let presets = PresetLibrary(url: url)
            XCTAssertTrue(presets.preservesUnreadableFile)
            XCTAssertFalse(presets.saveNew("Desk", data: Data([1]), at: location))
            XCTAssertNil(presets.save("Taken preset", data: Data([2]), for: control))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }

        let copies = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("presets.json.unreadable-") }
        XCTAssertEqual(copies.count, 2)
        for copy in copies {
            XCTAssertEqual(try Data(contentsOf: copy), original)
        }
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

    func testLegacyFactoryOverridesRemainReadableAndCanBeRestored() throws {
        let url = tmpDir().appendingPathComponent("presets.json")
        var catalog = PresetCatalog()
        let id = PresetID.factory("flat")
        catalog.edit(id, for: control, name: "Quiet", data: Data([4]))
        XCTAssertTrue(JSONStore<PresetFile>(url: url).save(PresetFile(catalog: catalog)))
        let presets = PresetLibrary(url: url)
        XCTAssertTrue(presets.select(id, at: location))
        XCTAssertEqual(groups(presets).inUse?.name, "Quiet")
        let entry = try XCTUnwrap(groups(presets).inUse)
        XCTAssertFalse(presets.rename(id, to: "Renamed", for: control))
        XCTAssertNil(presets.update(entry, with: Data([5]), at: location, recipePart: "audio", recipes: harness().store))
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
        XCTAssertTrue(h.bar.savePreset("Desk", in: "audio") {
            guard let update = presets.update(entry, with: Data([2]), at: location, recipePart: "audio", recipes: h.store) else { return nil }
            return { presets.undo(update, recipes: h.store, applyRecipe: false) }
        })
        XCTAssertEqual(h.bar.confirmation?.message, "Saved to preset Desk")
        XCTAssertTrue(h.bar.changedSections.isEmpty)
        XCTAssertEqual(h.store.recipe(recipe.id)?.sections["audio"], RecipeStore.sections(["audio": "tuned"])["audio"])
        XCTAssertEqual(groups(presets).inUse?.data, Data([2]))
        XCTAssertFalse(h.store.isModified(recipe.id))
        h.bar.undoSave()
        XCTAssertNil(h.bar.confirmation)
        XCTAssertEqual(h.store.recipe(recipe.id)?.sections, recipe.sections)
        XCTAssertEqual(h.audio.value, "tuned")
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
        XCTAssertTrue(h.bar.savePreset("Desk", in: "audio") {
            guard let update = presets.update(entry, with: Data([2]), at: location, recipePart: "audio", recipes: h.store) else { return nil }
            return { presets.undo(update, recipes: h.store, applyRecipe: false) }
        })
        XCTAssertEqual(h.bar.confirmation?.message, "Saved to preset Desk")
        XCTAssertEqual(h.bar.changedSections, ["windows"])
        h.sched.advance(4)
        XCTAssertNil(h.bar.confirmation)
        XCTAssertTrue(h.store.isModified(recipe.id))
        XCTAssertEqual(groups(presets).inUse?.data, Data([2]))
    }

    func testUpdatingOneAudioPresetLeavesTheOtherAudioSectionUnsaved() throws {
        let h = harness()
        let presets = library()
        h.audio.value = "flat/quiet"
        func pair(_ data: Data) -> [String]? {
            RecipeJSON.decode([String: String].self, from: data)?["v"]?.components(separatedBy: "/")
        }
        let mergeEQ: (Data, Data) -> Data? = { source, target in
            guard let eq = pair(source)?.first, let effects = pair(target)?.last else { return nil }
            return RecipeJSON.encode(["v": eq + "/" + effects])
        }
        h.bar.start(sections: [
            SaveBarSection(id: "audio.eq", title: "Equalizer", recipePart: "audio",
                           fingerprint: { pair($0)?.first.map { Data($0.utf8) } }, copy: mergeEQ),
            SaveBarSection(id: "audio.outputfx", title: "System effects", recipePart: "audio",
                           fingerprint: { pair($0)?.last.map { Data($0.utf8) } }),
        ])
        let recipe = h.store.create(name: "Office", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
        XCTAssertTrue(presets.saveNew("Desk", data: Data([1]), at: location))
        let entry = try XCTUnwrap(groups(presets).inUse)
        h.audio.value = "bass/loud"
        h.bar.settingsDidChange()
        XCTAssertEqual(h.bar.changedTitles, ["Equalizer", "System effects"])

        XCTAssertTrue(h.bar.savePreset("Desk", in: "audio.eq", copy: mergeEQ) {
            guard let update = presets.update(entry, with: Data([2]), at: location, recipePart: "audio",
                                              recipes: h.store, mergeRecipePart: mergeEQ) else { return nil }
            return { presets.undo(update, recipes: h.store, applyRecipe: false) }
        })
        XCTAssertEqual(h.store.active?.sections, RecipeStore.sections(["audio": "bass/quiet"]))
        XCTAssertEqual(h.bar.changedTitles, ["System effects"])
        h.bar.undoSave()
        XCTAssertEqual(h.store.active?.sections, recipe.sections)
        XCTAssertEqual(h.audio.value, "bass/loud")
        XCTAssertEqual(h.bar.changedTitles, ["Equalizer", "System effects"])
    }

    func testUpdatingADifferentRowKeepsTheRecipeUnsaved() throws {
        let h = harness()
        let presets = library()
        let recipe = h.store.create(name: "Office", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
        XCTAssertTrue(presets.saveNew("Desk", data: Data([1]), at: location))
        XCTAssertTrue(presets.saveNew("Other", data: Data([3]), at: location))
        h.audio.value = "tuned"
        let entry = try XCTUnwrap(groups(presets).yours.first { $0.name == "Desk" })
        let result = try XCTUnwrap(presets.update(entry, with: Data([2]), at: location, recipePart: "audio", recipes: h.store))
        XCTAssertEqual(result.message, "“Desk” updated.")
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
