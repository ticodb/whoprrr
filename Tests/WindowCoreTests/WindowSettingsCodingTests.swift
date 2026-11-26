import XCTest
@testable import WindowCore

final class WindowSettingsCodingTests: XCTestCase {
    private func bytes(_ s: WindowSettings) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(s) }

    /// Recipes compare settings by their bytes, so equal settings must always give equal bytes: sets are written sorted.
    func testSetsAreWrittenSortedSoEqualSettingsGiveEqualBytes() throws {
        var a = WindowSettings(), b = WindowSettings()
        let names = ["rightHalf", "maximize", "leftHalf", "center", "firstThird", "lastThird", "restore", "nextDisplay"]
        for n in names { a.disabled.insert(n) }
        for n in names.reversed() { b.disabled.insert(n) }
        a.drawerActions = Set(names); b.drawerActions = Set(names.shuffled())
        XCTAssertEqual(try bytes(a), try bytes(b))
        let obj = try JSONSerialization.jsonObject(with: try bytes(a)) as? [String: Any]
        XCTAssertEqual(obj?["drawerActions"] as? [String], names.sorted())
        XCTAssertEqual(obj?["disabled"] as? [String], names.sorted())
    }

    func testOlderUnsortedFilesStillReadAndNoDrawerChoiceStaysAbsent() throws {
        let old = Data(#"{"custom":{},"cycleHalves":true,"disabled":["b","a"],"drawerActions":["rightHalf","maximize","leftHalf"],"gap":21,"shortcutsEnabled":true,"snapByDrag":true}"#.utf8)
        let s = try JSONDecoder().decode(WindowSettings.self, from: old)
        XCTAssertEqual(s.drawerActions, ["leftHalf", "maximize", "rightHalf"]); XCTAssertEqual(s.disabled, ["a", "b"]); XCTAssertEqual(s.gap, 21)
        XCTAssertEqual(try JSONDecoder().decode(WindowSettings.self, from: try bytes(s)), s)
        let plain = try JSONSerialization.jsonObject(with: try bytes(WindowSettings())) as? [String: Any]
        XCTAssertNil(plain?["drawerActions"], "nil means the built-in default set, and stays nil")
    }
}
