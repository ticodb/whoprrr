import XCTest
@testable import LogitechCore

final class HIDPPTests: XCTestCase {
    func testShortRequestLayout() {
        XCTAssertEqual(HIDPP.request(device: 1, feature: 0, function: 1, params: [0, 0, 0xAA]), [0x10, 1, 0, 0x17, 0, 0, 0xAA])
    }
    func testLongRequestWhenParamsExceedThree() {
        let r = HIDPP.request(device: 2, feature: 5, function: 3, params: [1, 2, 3, 4])
        XCTAssertEqual(r.count, 20); XCTAssertEqual(r[0], 0x11); XCTAssertEqual(r[3], 0x37); XCTAssertEqual(Array(r[4...7]), [1, 2, 3, 4])
    }
    func testParseMessageAndErrors() {
        guard case .message(let m)? = HIDPP.parse([0x10, 1, 0, 0x17, 4, 2, 0xAA]) else { return XCTFail() }
        XCTAssertEqual(m.deviceIndex, 1); XCTAssertEqual(m.function, 1); XCTAssertEqual(m.softwareID, 7); XCTAssertEqual(Array(m.params.prefix(3)), [4, 2, 0xAA])
        XCTAssertEqual(HIDPP.parse([0x11, 1, 0xFF, 3, 0x17, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
                       .error(deviceIndex: 1, featureIndex: 3, function: 1, code: 2))
        XCTAssertEqual(HIDPP.parse([0x10, 1, 0x8F, 0, 0x11, 1, 0]), .error10(deviceIndex: 1, subID: 0, address: 0x11, code: 1))
        XCTAssertNil(HIDPP.parse([0x02, 0, 0, 0, 0, 0, 0]))
        XCTAssertNil(HIDPP.parse([0x10, 1]))
    }
}

final class ReprogTests: XCTestCase {
    func testControlInfoParsingAndFlags() {
        let c = Reprog.parseInfo(index: 3, params: [0x00, 0xC3, 0x01, 0x23, 0x30, 0, 0, 0])!
        XCTAssertEqual(c.cid, 0x00C3); XCTAssertEqual(c.index, 3)
        XCTAssertTrue(c.isDivertable); XCTAssertTrue(c.isReprogrammable); XCTAssertFalse(c.isMouse)
        XCTAssertEqual(c.name, "Gesture button")
        XCTAssertNil(Reprog.parseInfo(index: 0, params: [0, 0, 0, 0, 0]))     // cid 0 = no control
        XCTAssertEqual(Reprog.parseInfo(index: 0, params: [0x12, 0x34, 0, 0, 0x01])!.name, "Control 0x1234")
    }
    func testDivertParams() {
        XCTAssertEqual(Reprog.divertParams(cid: 0x00C3, divert: true), [0x00, 0xC3, 0x03])
        XCTAssertEqual(Reprog.divertParams(cid: 0x00C3, divert: false), [0x00, 0xC3, 0x02])
    }
    func testPressedSetFromEvent() {
        XCTAssertEqual(Reprog.pressed(from: [0x00, 0xC3, 0x00, 0x53, 0, 0, 0, 0]), [0x00C3, 0x0053])
        XCTAssertEqual(Reprog.pressed(from: [0, 0, 0, 0, 0, 0, 0, 0]), [])
    }
}
