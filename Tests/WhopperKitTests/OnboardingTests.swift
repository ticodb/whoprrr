import XCTest
@testable import WhopperKit

@MainActor
final class OnboardingTests: XCTestCase {
    func testGrantsFollowRecipeLines() {
        XCTAssertEqual(requirements(.windows), [.accessibility])
        XCTAssertEqual(requirements(.remap), [.accessibility, .inputMonitoring])
        XCTAssertEqual(requirements(.audio), [])
        XCTAssertEqual(requirements(.audio, eq: true), [.systemAudio])
        XCTAssertEqual(requirements(.microphone, mic: true), [.microphone, .micDriver])
        XCTAssertEqual(requirements(.clipboard), [])
        XCTAssertEqual(requirements(.clipboard, paste: true), [.paste])
        XCTAssertEqual(requirements(.display), [])
        XCTAssertEqual(TasteTest.affected(by: .inputMonitoring, in: [.remap: requirements(.remap), .windows: requirements(.windows)]), [.remap])
    }

    func testSkipParksOnlyFeaturesThatNeedIt() async {
        let fake = Probe()
        let test = runner(fake, [.accessibility: .granted, .inputMonitoring: .granted])
        let windows = await test.tryFeature(.windows, grants: requirements(.windows), skipped: [.inputMonitoring], proven: [], mode: .setup)
        let remap = await test.tryFeature(.remap, grants: requirements(.remap), skipped: [.inputMonitoring], proven: [], mode: .setup)
        XCTAssertEqual(windows.result, .works)
        XCTAssertEqual(remap.result, .parked)
        XCTAssertEqual(remap.grants, [.inputMonitoring])
        XCTAssertEqual(fake.calls.map(\.0), [.windows])
    }

    func testSilentCheckOnlyRunsEligibleProbes() async {
        let fake = Probe()
        let test = runner(fake, [.systemAudio: .unknown, .accessibility: .granted, .inputMonitoring: .denied])
        let audio = await test.tryFeature(.audio, grants: [.systemAudio], skipped: [], proven: [], mode: .afterUpdate)
        let remap = await test.tryFeature(.remap, grants: requirements(.remap), skipped: [], proven: [.inputMonitoring], mode: .afterUpdate)
        let windows = await test.tryFeature(.windows, grants: requirements(.windows), skipped: [], proven: [], mode: .afterUpdate)
        XCTAssertEqual(audio.result, .needsCheck)
        XCTAssertEqual(audio.grants, [.systemAudio])
        XCTAssertEqual(remap.result, .parked)
        XCTAssertEqual(remap.grants, [.inputMonitoring])
        XCTAssertEqual(windows.result, .works)
        XCTAssertEqual(fake.calls.map(\.0), [.windows])
        XCTAssertEqual(fake.calls.last?.1, .afterUpdate)
    }

    func testGrantThatLooksOnCanFailItsTest() async {
        let fake = Probe()
        fake.answer = TasteFinding(.notWorking, grants: [.inputMonitoring], detail: "No events arrived.")
        let test = runner(fake, [.accessibility: .granted, .inputMonitoring: .granted])
        let result = await test.tryFeature(.remap, grants: requirements(.remap), skipped: [], proven: [], mode: .afterUpdate)
        XCTAssertEqual(result, fake.answer)
        XCTAssertEqual(fake.calls.count, 1)
    }

    func testProgressAndResetBudgetSurviveRelaunch() async throws {
        var setup = SetupProgress(step: .permissions)
        setup.askingAgain = .inputMonitoring
        setup.selected = [.remap, .windows]
        setup.skipped = [.accessibility]
        let resetter = Resetter()
        let test = TasteTest(checker: FakePermissionChecker(), probe: Probe(), resetter: resetter)
        XCTAssertTrue(setup.reserveReset(.inputMonitoring))
        let first = await test.reset(.inputMonitoring)
        XCTAssertTrue(first)
        let data = try JSONEncoder().encode(setup)
        var reopened = try JSONDecoder().decode(SetupProgress.self, from: data)
        XCTAssertEqual(reopened.step, .permissions)
        XCTAssertEqual(reopened.askingAgain, .inputMonitoring)
        XCTAssertEqual(reopened.selected, [.remap, .windows])
        XCTAssertEqual(reopened.skipped, [.accessibility])
        XCTAssertTrue(reopened.reserveReset(.inputMonitoring))
        let second = await test.reset(.inputMonitoring)
        XCTAssertTrue(second)
        XCTAssertFalse(reopened.reserveReset(.inputMonitoring))
        XCTAssertFalse(reopened.reserveReset(.micDriver))
        XCTAssertTrue(reopened.reserveReset(.accessibility))
        let reset = await resetter.calls
        XCTAssertEqual(reset, [.inputMonitoring, .inputMonitoring])
    }

    private func requirements(_ feature: Feature, eq: Bool = false, mic: Bool = false, paste: Bool = false) -> Set<Permission> {
        TasteTest.requirements(for: feature, audioCapture: eq, mic: mic, clipboardPrivacy: paste)
    }

    private func runner(_ fake: Probe, _ grants: [Permission: PermissionStatus]) -> TasteTest {
        TasteTest(checker: FakePermissionChecker(grants), probe: fake, resetter: Resetter())
    }

    private final class Probe: TasteProbing {
        var calls: [(Feature, TasteMode)] = []
        var answer = TasteFinding(.works, detail: "Verified.")
        func tryFeature(_ feature: Feature, mode: TasteMode) async -> TasteFinding {
            calls.append((feature, mode))
            return answer
        }
    }

    private actor Resetter: PermissionResetting {
        private(set) var calls: [Permission] = []
        func reset(_ permission: Permission) async -> Bool {
            calls.append(permission)
            return true
        }
    }
}
