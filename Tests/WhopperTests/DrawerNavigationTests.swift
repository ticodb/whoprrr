import XCTest
@testable import Whopper

final class DrawerNavigationTests: XCTestCase {
    @MainActor
    func testOpeningASectionStaysInTheDrawerAndBackRestoresOverview() {
        let navigation = WindowNav()
        navigation.drawerOpen = true
        navigation.openDrawerSection(.feature(.audio))
        XCTAssertEqual(navigation.drawerPage, .feature(.audio))
        XCTAssertEqual(navigation.page, .feature(.audio))
        XCTAssertFalse(navigation.windowOpen)
        navigation.openDrawerSection(.recipes)
        XCTAssertEqual(navigation.drawerPage, .recipes)
        navigation.returnToOverview()
        XCTAssertNil(navigation.drawerPage)
        XCTAssertTrue(navigation.drawerOpen)
        XCTAssertFalse(navigation.windowOpen)
    }
}
