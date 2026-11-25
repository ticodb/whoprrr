import XCTest
@testable import WindowCore

final class GeometryTests: XCTestCase {
    let r = CGRect(x: 0, y: 25, width: 1200, height: 775)       // top-left coords, menu bar excluded
    let cur = CGRect(x: 100, y: 100, width: 400, height: 300)

    func f(_ a: WindowAction, gap: CGFloat = 0) -> CGRect { WindowGeometry.frame(for: a, visible: r, current: cur, gap: gap)! }

    func testHalvesAndQuarters() {
        XCTAssertEqual(f(.leftHalf), CGRect(x: 0, y: 25, width: 600, height: 775))
        XCTAssertEqual(f(.rightHalf), CGRect(x: 600, y: 25, width: 600, height: 775))
        XCTAssertEqual(f(.topHalf).height, 387.5)
        XCTAssertEqual(f(.bottomHalf).minY, 25 + 387.5)
        XCTAssertEqual(f(.topLeft), CGRect(x: 0, y: 25, width: 600, height: 387.5))
        XCTAssertEqual(f(.bottomRight), CGRect(x: 600, y: 412.5, width: 600, height: 387.5))
    }
    func testThirds() {
        XCTAssertEqual(f(.firstThird).width, 400)
        XCTAssertEqual(f(.centerThird).minX, 400)
        XCTAssertEqual(f(.lastThird).maxX, 1200)
        XCTAssertEqual(f(.firstTwoThirds).width, 800)
        XCTAssertEqual(f(.lastTwoThirds).minX, 400)
    }
    func testMaximizeCenterAndHeight() {
        XCTAssertEqual(f(.maximize), r)
        let c = f(.center)
        XCTAssertEqual(c.size, cur.size); XCTAssertEqual(c.midX, r.midX); XCTAssertEqual(c.midY, r.midY)
        let mh = f(.maximizeHeight)
        XCTAssertEqual(mh.minX, cur.minX); XCTAssertEqual(mh.height, r.height)
    }
    func testGapFullAtEdgesHalfBetween() {
        let l = f(.leftHalf, gap: 10), rr = f(.rightHalf, gap: 10)
        XCTAssertEqual(l.minX, 10); XCTAssertEqual(l.minY, 35)
        XCTAssertEqual(rr.minX - l.maxX, 10)          // gap between neighbours
        XCTAssertEqual(rr.maxX, 1190)
    }
    func testLargerSmallerStayOnScreenAndAboveMinimum() {
        let big = WindowGeometry.frame(for: .larger, visible: r, current: CGRect(x: 0, y: 25, width: 1200, height: 775))!
        XCTAssertEqual(big, CGRect(x: 0, y: 25, width: 1200, height: 775))
        let tiny = WindowGeometry.frame(for: .smaller, visible: r, current: CGRect(x: 10, y: 30, width: 210, height: 130))!
        XCTAssertGreaterThanOrEqual(tiny.width, 200); XCTAssertGreaterThanOrEqual(tiny.height, 120)
    }
    func testRestoreAndDisplayMovesAreNotGeometry() {
        XCTAssertNil(WindowGeometry.frame(for: .restore, visible: r, current: cur))
        XCTAssertNil(WindowGeometry.frame(for: .nextDisplay, visible: r, current: cur))
    }
    func testMoveBetweenDisplaysKeepsProportionAndClamps() {
        let src = CGRect(x: 0, y: 0, width: 1000, height: 800), dst = CGRect(x: 1000, y: 0, width: 2000, height: 1600)
        let m = WindowGeometry.move(CGRect(x: 500, y: 400, width: 500, height: 400), from: src, to: dst)
        XCTAssertEqual(m, CGRect(x: 2000, y: 800, width: 1000, height: 800))
        let tooBig = WindowGeometry.move(CGRect(x: 0, y: 0, width: 1000, height: 800), from: src, to: CGRect(x: 1000, y: 0, width: 500, height: 400))
        XCTAssertLessThanOrEqual(tooBig.width, 500)
    }
    func testHalfCyclesToTwoThirdsThenThirdThenBack() {
        var a = WindowGeometry.cycled(.leftHalf, current: cur, visible: r, gap: 0)
        XCTAssertEqual(a, .leftHalf)                                   // not at half yet: do the half
        var now = f(.leftHalf)
        a = WindowGeometry.cycled(.leftHalf, current: now, visible: r, gap: 0); XCTAssertEqual(a, .firstTwoThirds)
        now = f(.firstTwoThirds)
        a = WindowGeometry.cycled(.leftHalf, current: now, visible: r, gap: 0); XCTAssertEqual(a, .firstThird)
        now = f(.firstThird)
        a = WindowGeometry.cycled(.leftHalf, current: now, visible: r, gap: 0); XCTAssertEqual(a, .leftHalf)
        XCTAssertEqual(WindowGeometry.cycled(.maximize, current: now, visible: r, gap: 0), .maximize)
    }
    func testSnapZones() {
        let s = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(SnapZones.action(cursor: CGPoint(x: 1, y: 400), screen: s), .leftHalf)
        XCTAssertEqual(SnapZones.action(cursor: CGPoint(x: 999, y: 400), screen: s), .rightHalf)
        XCTAssertEqual(SnapZones.action(cursor: CGPoint(x: 500, y: 1), screen: s), .maximize)
        XCTAssertEqual(SnapZones.action(cursor: CGPoint(x: 2, y: 10), screen: s), .topLeft)
        XCTAssertEqual(SnapZones.action(cursor: CGPoint(x: 998, y: 790), screen: s), .bottomRight)
        XCTAssertEqual(SnapZones.action(cursor: CGPoint(x: 500, y: 799), screen: s), nil)   // Dock edge
        XCTAssertNil(SnapZones.action(cursor: CGPoint(x: 500, y: 400), screen: s))
    }
    func testSettingsShortcutsAndConflicts() {
        var s = WindowSettings()
        XCTAssertEqual(s.shortcut(for: .leftHalf), WindowAction.leftHalf.defaultShortcut)
        XCTAssertTrue(s.conflicts().isEmpty)
        s.custom[WindowAction.rightHalf.rawValue] = WindowAction.leftHalf.defaultShortcut
        XCTAssertEqual(s.conflicts(), [.leftHalf, .rightHalf])
        s.disabled.insert(WindowAction.leftHalf.rawValue)
        XCTAssertNil(s.shortcut(for: .leftHalf)); XCTAssertTrue(s.conflicts().isEmpty)
        s.shortcutsEnabled = false
        XCTAssertNil(s.shortcut(for: .rightHalf))
    }
    func testDefaultShortcutsAreUnique() {
        XCTAssertTrue(WindowSettings().conflicts().isEmpty)
    }

    func testDrawerDefaultsAndOldSettingsFiles() throws {
        XCTAssertEqual(WindowSettings().drawer, [.leftHalf, .rightHalf, .firstThird, .centerThird, .lastThird, .center, .nextDisplay, .restore])
        // A settings file saved before the drawer choice existed still loads, with the default set.
        let old = try JSONDecoder().decode(WindowSettings.self, from: Data(#"{"shortcutsEnabled":true,"custom":{},"disabled":[],"gap":0,"cycleHalves":true,"snapByDrag":true}"#.utf8))
        XCTAssertNil(old.drawerActions)
        XCTAssertEqual(old.drawer, WindowSettings().drawer)
        var s = WindowSettings(); s.drawerActions = ["maximize", "topLeft", "bogus"]
        XCTAssertEqual(s.drawer, [.topLeft, .maximize])   // stable grouped order, unknown names ignored
    }
}
