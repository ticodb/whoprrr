import XCTest
@testable import WindowCore

final class PanelPlacementTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 3440, height: 1380)          // visible area under the menu bar
    let drawer = CGRect(x: 3000, y: 640, width: 400, height: 740)       // hangs from the menu bar at the right

    func testSitsLeftOfTheDrawerWithTopEdgesAligned() {
        let f = PanelPlacement.frame(beside: drawer, size: CGSize(width: 940, height: 700), visible: screen)
        XCTAssertEqual(f.maxX, drawer.minX - 8)
        XCTAssertEqual(f.maxY, drawer.maxY)
        XCTAssertEqual(f.size, CGSize(width: 940, height: 700))
    }

    func testShrinksToFitUnderTheDrawerTop() {
        let short = CGRect(x: 3000, y: 900, width: 400, height: 480)     // drawer top at 1380, room below it is plenty
        let f = PanelPlacement.frame(beside: short, size: CGSize(width: 940, height: 2000), visible: screen)
        XCTAssertLessThanOrEqual(f.height, screen.height); XCTAssertEqual(f.maxY, 1380)
    }

    func testNeverLeavesTheScreen() {
        let narrow = CGRect(x: 0, y: 0, width: 1200, height: 780)
        let d = CGRect(x: 800, y: 40, width: 400, height: 740)
        let f = PanelPlacement.frame(beside: d, size: CGSize(width: 940, height: 700), visible: narrow)
        XCTAssertGreaterThanOrEqual(f.minX, narrow.minX); XCTAssertLessThanOrEqual(f.maxX, narrow.maxX)
        XCTAssertGreaterThanOrEqual(f.minY, narrow.minY); XCTAssertLessThanOrEqual(f.maxY, narrow.maxY)
    }

    func testUsesTheRightSideWhenTheLeftHasNoRoom() {
        let d = CGRect(x: 20, y: 40, width: 400, height: 740)            // drawer near the left edge
        let f = PanelPlacement.frame(beside: d, size: CGSize(width: 940, height: 700), visible: screen)
        XCTAssertEqual(f.minX, d.maxX + 8)
    }
}
