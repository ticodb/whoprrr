import XCTest
@testable import WhopperKit

@MainActor
final class FakeSurface: RecipeSurface {
    let recipeKey: String, recipeTitle: String
    var value: String
    var failApply = false
    init(_ key: String, _ value: String) { recipeKey = key; recipeTitle = key.capitalized; self.value = value }
    func captureRecipeData() -> Data? { RecipeJSON.encode(["v": value]) }
    func applyRecipeData(_ data: Data) -> Bool {
        guard !failApply, let d = RecipeJSON.decode([String: String].self, from: data), let v = d["v"] else { return false }
        value = v; return true
    }
}

/// A surface whose settings are a set written in whatever order it happens to hold, like a file saved by an earlier version.
@MainActor
final class SetSurface: RecipeSurface {
    let recipeKey = "tiles", recipeTitle = "Tiles"
    var order: [String]
    init(_ order: [String]) { self.order = order }
    func captureRecipeData() -> Data? { RecipeJSON.encode(order) }
    func applyRecipeData(_ data: Data) -> Bool { guard let a = RecipeJSON.decode([String].self, from: data) else { return false }; order = a; return true }
    func canonicalRecipeData(_ data: Data) -> Data { RecipeJSON.decode([String].self, from: data).flatMap { RecipeJSON.encode($0.sorted()) } ?? data }
}

@MainActor
final class RecipeTests: XCTestCase {
    func tmp(_ n: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("whoprrr-\(UUID().uuidString)-\(n).json") }

    let home: [DeviceSignature] = [.init(kind: .display, key: "samsung", name: "S34CG50"), .init(kind: .audioInput, key: "rode", name: "RØDE PodMic USB"), .init(kind: .logitech, key: "ergo", name: "MX Ergo")]
    let road: [DeviceSignature] = [.init(kind: .audioOutput, key: "airpods", name: "AirPods")]

    func makeStore(_ url: URL) -> (RecipeStore, FakeSurface, FakeSurface) {
        let s = RecipeStore(url: url)
        let a = FakeSurface("audio", "home-audio"), w = FakeSurface("windows", "home-windows")
        s.register(a); s.register(w)
        return (s, a, w)
    }

    func testCreateApplySwitchesEverySurfaceInOneCall() {
        let (s, a, w) = makeStore(tmp("a"))
        let homeR = s.create(name: "Home", symbol: "house", includes: ["audio", "windows"], devices: home, autoApply: true)
        a.value = "road-audio"; w.value = "road-windows"
        let roadR = s.create(name: "Road", symbol: "airplane", includes: ["audio", "windows"], devices: road, autoApply: false)
        XCTAssertEqual(s.activeID, roadR.id)

        XCTAssertTrue(s.apply(homeR.id).isEmpty)
        XCTAssertEqual(a.value, "home-audio"); XCTAssertEqual(w.value, "home-windows")
        XCTAssertEqual(s.activeID, homeR.id)
        XCTAssertEqual(s.notice, "Applied “Home”")
        XCTAssertTrue(s.apply(roadR.id).isEmpty)
        XCTAssertEqual(a.value, "road-audio")
    }

    func testSectionsOnlyCoverTheChosenSurfaces() {
        let (s, a, w) = makeStore(tmp("b"))
        let r = s.create(name: "Audio only", symbol: "x", includes: ["audio"], devices: [], autoApply: false)
        XCTAssertEqual(Set(r.sections.keys), ["audio"])
        w.value = "changed"; a.value = "other"
        s.apply(r.id)
        XCTAssertEqual(a.value, "home-audio"); XCTAssertEqual(w.value, "changed")      // windows untouched
    }

    func testModifiedDetectionAndUpdateFromCurrent() {
        let (s, a, _) = makeStore(tmp("c"))
        let r = s.create(name: "Home", symbol: "house", includes: ["audio", "windows"], devices: home, autoApply: false)
        XCTAssertFalse(s.isModified(r.id))
        a.value = "tweaked"
        XCTAssertTrue(s.isModified(r.id))
        s.updateFromCurrent(r.id)
        XCTAssertFalse(s.isModified(r.id))
        a.value = "x"; s.apply(r.id)
        XCTAssertEqual(a.value, "tweaked")                  // the updated snapshot is what applies now
    }

    func testPartialFailureIsReportedNotSwallowed() {
        let (s, _, w) = makeStore(tmp("d"))
        let r = s.create(name: "R", symbol: "x", includes: ["audio", "windows"], devices: [], autoApply: false)
        w.failApply = true
        XCTAssertEqual(s.apply(r.id), ["Windows"])
        XCTAssertTrue(s.notice?.contains("except Windows") == true)
    }

    func testGearMatchingAutoApplyAndRanking() {
        let (s, _, _) = makeStore(tmp("e"))
        let h = s.create(name: "Home", symbol: "house", includes: ["audio"], devices: home, autoApply: true)
        let r = s.create(name: "Road", symbol: "airplane", includes: ["audio"], devices: road, autoApply: true)
        s.apply(r.id)

        XCTAssertEqual(h.gear(connected: home + road).missing, [])
        XCTAssertEqual(h.gear(connected: [home[0]]).present, [home[0]])
        XCTAssertEqual(h.gear(connected: [home[0]]).missing.count, 2)

        // Plug the home gear in: Home should take over, Road is already active so it is not offered again.
        XCTAssertEqual(s.autoApplyCandidate(connected: home)?.id, h.id)
        XCTAssertNil(s.autoApplyCandidate(connected: road))              // Road already active
        XCTAssertNil(s.autoApplyCandidate(connected: [home[0]]))         // incomplete gear never auto-applies
        s.setAutoApply(h.id, false)
        XCTAssertNil(s.autoApplyCandidate(connected: home))

        // Ranking: complete matches first, then by how much is present.
        XCTAssertEqual(s.ranked(connected: road).first?.id, r.id)
        XCTAssertEqual(s.ranked(connected: home).first?.id, h.id)
    }

    func testRecipeWithoutGearNeverAutoApplies() {
        let (s, _, _) = makeStore(tmp("f"))
        let r = s.create(name: "Anywhere", symbol: "x", includes: ["audio"], devices: [], autoApply: true)
        s.apply(r.id); s.delete(r.id)
        _ = s.create(name: "Anywhere", symbol: "x", includes: ["audio"], devices: [], autoApply: true)
        XCTAssertNil(s.autoApplyCandidate(connected: home))
    }

    func testPersistsAcrossLaunchesAndDelete() {
        let url = tmp("g")
        let (s, _, _) = makeStore(url)
        let r = s.create(name: "Home", symbol: "house", includes: ["audio"], devices: home, autoApply: true)
        let (s2, _, _) = makeStore(url)
        XCTAssertEqual(s2.recipes.map(\.name), ["Home"]); XCTAssertEqual(s2.activeID, r.id)
        XCTAssertEqual(s2.recipes.first?.devices, home)
        s2.rename(r.id, to: "Home office", symbol: "desktopcomputer")
        s2.delete(r.id)
        XCTAssertTrue(s2.recipes.isEmpty); XCTAssertNil(s2.activeID)
    }

    func testPresetLibraryReplacesSameNameAndDeletes() {
        let lib = PresetLibrary(url: tmp("p"))
        lib.save("Podcast", data: Data([1]), for: "audio.mic")
        lib.save("Call", data: Data([2]), for: "audio.mic")
        lib.save("Podcast", data: Data([3]), for: "audio.mic")
        XCTAssertEqual(lib.presets(for: "audio.mic").map(\.name), ["Call", "Podcast"])
        XCTAssertEqual(lib.presets(for: "audio.mic").last?.data, Data([3]))
        XCTAssertTrue(lib.presets(for: "windows").isEmpty)
        lib.delete(lib.presets(for: "audio.mic")[0].id, for: "audio.mic")
        XCTAssertEqual(lib.presets(for: "audio.mic").map(\.name), ["Podcast"])
    }

    func testEqualSettingsInDifferentBytesAreNotAChange() {
        let (store, _, _) = makeStore(tmp("canon"))
        let tiles = SetSurface(["left", "right", "max"])
        store.register(tiles)
        let r = store.create(name: "Desk", symbol: "house", includes: ["tiles"], devices: [], autoApply: false)
        XCTAssertFalse(store.isModified(r.id))
        tiles.order = ["max", "left", "right"]          // the same set, as another launch would write it
        XCTAssertFalse(store.isModified(r.id), "the same settings in another order are not a change")
        tiles.order = ["max", "left"]                   // a real change
        XCTAssertTrue(store.isModified(r.id))
    }
}
