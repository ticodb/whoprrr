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
        let windows = await test.tryFeature(.windows, grants: requirements(.windows), skipped: [.inputMonitoring], mode: .setup)
        let remap = await test.tryFeature(.remap, grants: requirements(.remap), skipped: [.inputMonitoring], mode: .setup)
        XCTAssertEqual(windows.result, .works)
        XCTAssertEqual(remap.result, .parked)
        XCTAssertEqual(remap.grants, [.inputMonitoring])
        XCTAssertEqual(fake.calls.map(\.0), [.windows])
    }

    func testSilentCheckParksOnlyDefiniteFailures() async {
        let fake = Probe()
        let test = runner(fake, [.systemAudio: .unknown, .accessibility: .granted, .inputMonitoring: .denied, .paste: .notDetermined,
                                 .microphone: .granted, .micDriver: .denied])
        let audio = await test.tryFeature(.audio, grants: [.systemAudio], skipped: [], mode: .afterUpdate)
        let remap = await test.tryFeature(.remap, grants: requirements(.remap), skipped: [], mode: .afterUpdate)
        let windows = await test.tryFeature(.windows, grants: requirements(.windows), skipped: [], mode: .afterUpdate)
        let clipboard = await test.tryFeature(.clipboard, grants: [.paste], skipped: [], mode: .afterUpdate)
        let mic = await test.tryFeature(.microphone, grants: [.microphone, .micDriver], skipped: [], mode: .afterUpdate)
        // System Audio Recording can't be read: the probe decides from the equalizer's saved proof, and nothing parks.
        XCTAssertEqual(audio.result, .works)
        XCTAssertFalse(TasteTest.parksAfterUpdate(audio))
        // An explicit deny parks, without running the feature's probe.
        XCTAssertEqual(remap.result, .notWorking)
        XCTAssertEqual(remap.grants, [.inputMonitoring])
        XCTAssertTrue(TasteTest.parksAfterUpdate(remap))
        XCTAssertEqual(windows.result, .works)
        // Paste "ask each time" worked before this build, with prompts. It is not a failure.
        XCTAssertEqual(clipboard.result, .works)
        // A missing Whoprrr Mic device is not a grant and never parks after an update.
        XCTAssertEqual(mic.result, .works)
        XCTAssertEqual(fake.calls.map(\.0), [.audio, .windows, .clipboard, .microphone])
        XCTAssertTrue(fake.calls.allSatisfy { $0.1 == .afterUpdate })
    }

    func testDefinitelyBlockedTable() {
        for grant in Permission.allCases {
            XCTAssertFalse(TasteTest.definitelyBlocked(grant, .granted))
            XCTAssertFalse(TasteTest.definitelyBlocked(grant, .unknown))
            XCTAssertEqual(TasteTest.definitelyBlocked(grant, .denied), grant != .micDriver)
        }
        XCTAssertTrue(TasteTest.definitelyBlocked(.inputMonitoring, .notDetermined))
        XCTAssertTrue(TasteTest.definitelyBlocked(.accessibility, .notDetermined))
        for grant in [Permission.paste, .microphone, .camera, .systemAudio, .micDriver] {
            XCTAssertFalse(TasteTest.definitelyBlocked(grant, .notDetermined))
        }
        XCTAssertFalse(TasteTest.parksAfterUpdate(TasteFinding(.notWorking, detail: "No display answered.")))
        XCTAssertFalse(TasteTest.parksAfterUpdate(TasteFinding(.needsCheck, grants: [.systemAudio], detail: "")))
    }

    func testAuditAfterUpdateGivesUpAtDeadlineWithoutParking() async {
        let fake = Probe()
        fake.hang = [.display]
        fake.answers[.windows] = TasteFinding(.notWorking, grants: [.accessibility], detail: "The window service did not answer.")
        let test = runner(fake, [.accessibility: .granted])
        let audit = await test.auditAfterUpdate([.windows, .display, .clipboard], needs: [.windows: [.accessibility]], deadline: .milliseconds(200))
        XCTAssertFalse(audit.finished)
        XCTAssertFalse(audit.allWork)
        XCTAssertEqual(Set(audit.park.keys), [.windows])
        XCTAssertEqual(audit.findings[.display]?.result, .needsCheck)
        XCTAssertEqual(audit.findings[.clipboard]?.result, .needsCheck)
        XCTAssertNil(audit.park[.display])
    }

    func testACheckThatNeverAnswersCanNotHoldTheTasteTest() async {
        let fake = Probe()
        fake.hang = [.display]
        let test = runner(fake, [.accessibility: .granted])
        let began = ContinuousClock.now
        let display = await test.check(.display, mode: .setup, deadline: .milliseconds(150))
        let windows = await test.tryFeature(.windows, grants: [.accessibility], skipped: [], mode: .setup)
        XCTAssertLessThan(began.duration(to: .now), .seconds(2))
        XCTAssertEqual(display.result, .needsCheck)
        XCTAssertTrue(display.grants.isEmpty)
        XCTAssertTrue(display.detail.hasPrefix("Could not check"))
        XCTAssertFalse(TasteTest.parksAfterUpdate(display))
        // The next check still runs.
        XCTAssertEqual(windows.result, .works)
        XCTAssertEqual(fake.calls.map(\.0), [.display, .windows])
    }

    func testAuditAfterUpdateAllWorking() async {
        let audit = await runner(Probe(), [.accessibility: .granted]).auditAfterUpdate([.windows, .clipboard], needs: [.windows: [.accessibility]], deadline: .seconds(5))
        XCTAssertTrue(audit.finished)
        XCTAssertTrue(audit.allWork)
        XCTAssertTrue(audit.park.isEmpty)
    }

    func testGrantThatLooksOnCanFailItsTest() async {
        let fake = Probe()
        fake.answer = TasteFinding(.notWorking, grants: [.inputMonitoring], detail: "No events arrived.")
        let test = runner(fake, [.accessibility: .granted, .inputMonitoring: .granted])
        let result = await test.tryFeature(.remap, grants: requirements(.remap), skipped: [], mode: .afterUpdate)
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
        var answers: [Feature: TasteFinding] = [:]
        var hang: Set<Feature> = []
        func tryFeature(_ feature: Feature, mode: TasteMode) async -> TasteFinding {
            calls.append((feature, mode))
            if hang.contains(feature) {
                // Like a DDC read that ignores cancellation.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
            return answers[feature] ?? answer
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
