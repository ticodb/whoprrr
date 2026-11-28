import XCTest
@testable import WhopperKit

final class PermissionFlowTests: XCTestCase {
    func testOpeningAnAssistantDoesNotStartTheGrantAndContinueCanOnlyRunOnce() {
        var flow = PermissionFlow(.inputMonitoring, repair: true)
        XCTAssertEqual(flow.stage, .prepare)
        XCTAssertTrue(flow.begin())
        XCTAssertFalse(flow.begin())
        flow.wait()
        XCTAssertFalse(flow.begin())
        flow.finish()
        XCTAssertEqual(flow.stage, .ready)
        XCTAssertFalse(flow.begin())
        XCTAssertEqual(flow.permission, .inputMonitoring) // Success never advances to another grant.
    }

    func testInterruptedRepairAndFinishLaterRoundTripWithoutRepeatingReset() throws {
        var setup = SetupProgress(step: .permissions)
        var flow = PermissionFlow(.inputMonitoring, repair: true)
        flow.begin()
        setup.permissionFlow = flow
        let reopened = try JSONDecoder().decode(SetupProgress.self, from: JSONEncoder().encode(setup))
        flow = try XCTUnwrap(reopened.permissionFlow)
        flow.reopened()
        XCTAssertEqual(flow.stage, .waiting)
        XCTAssertFalse(flow.begin())
        flow.suspended = true
        var resumed = try JSONDecoder().decode(PermissionFlow.self, from: JSONEncoder().encode(flow))
        resumed.suspended = false
        XCTAssertEqual(resumed.stage, .waiting)
        XCTAssertFalse(resumed.begin())
    }

    func testAudioNeedsItsOwnCheckAndUnstartedGrantsCannotFinish() {
        var flow = PermissionFlow(.systemAudio, tracksSetup: false)
        flow.finish()
        XCTAssertEqual(flow.stage, .prepare)
        flow.begin()
        flow.wait()
        flow.needsAudioCheck()
        XCTAssertEqual(flow.stage, .checkAudio)
        flow.finish()
        XCTAssertEqual(flow.stage, .ready)
        XCTAssertFalse(flow.tracksSetup)
    }

    func testOldSetupProgressHasNoPermissionAssistant() throws {
        let old = Data(#"{"step":6,"askingAgain":"inputMonitoring"}"#.utf8)
        let setup = try JSONDecoder().decode(SetupProgress.self, from: old)
        XCTAssertNil(setup.permissionFlow)
    }
}
