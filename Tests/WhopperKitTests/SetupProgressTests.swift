import XCTest
@testable import WhopperKit

@MainActor
final class SetupProgressTests: XCTestCase {
    func testResetServicesAreTheTCCNames() {
        XCTAssertEqual(Permission.accessibility.resetService, "Accessibility")
        XCTAssertEqual(Permission.inputMonitoring.resetService, "ListenEvent")
        XCTAssertEqual(Permission.systemAudio.resetService, "AudioCapture")
        XCTAssertEqual(Permission.microphone.resetService, "Microphone")
        XCTAssertEqual(Permission.camera.resetService, "Camera")
        XCTAssertNil(Permission.paste.resetService)
        XCTAssertNil(Permission.micDriver.resetService)
    }

    func testParkedAndFindingsRoundTrip() throws {
        var progress = SetupProgress(step: .complete)
        progress.parked = [.remap: TasteFinding(.notWorking, grants: [.inputMonitoring], detail: "No test key arrived.")]
        progress.findings = [.windows: TasteFinding(.works, detail: "Moved."), .remap: progress.parked[.remap]!]
        progress.resetAttempts = [.accessibility: 1]
        progress.renewal = [.remap]
        progress.updateCheckIncomplete = true
        let reopened = try JSONDecoder().decode(SetupProgress.self, from: JSONEncoder().encode(progress))
        XCTAssertEqual(reopened.parked, progress.parked)
        XCTAssertEqual(reopened.findings, progress.findings)
        XCTAssertEqual(reopened.resetAttempts, [.accessibility: 1])
        XCTAssertEqual(reopened.renewal, [.remap])
        XCTAssertTrue(reopened.updateCheckIncomplete)
    }

    func testOlderFileMissingFieldsKeepsWhatItHas() throws {
        var progress = SetupProgress(step: .complete)
        progress.parked = [.audio: TasteFinding(.parked, grants: [.systemAudio], detail: "Waiting.")]
        progress.resetAttempts = [.inputMonitoring: 2]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) as? [String: Any])
        // A file from a build before these fields existed.
        for field in ["updateCheckIncomplete", "renewedGrants", "renewalStarted", "updateOKUntil", "build"] { json[field] = nil }
        // A field a later build may add.
        json["somethingNew"] = ["a": 1]
        let reopened = try JSONDecoder().decode(SetupProgress.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(reopened.step, .complete)
        XCTAssertEqual(reopened.parked, progress.parked)
        XCTAssertEqual(reopened.resetAttempts, [.inputMonitoring: 2])
        XCTAssertFalse(reopened.updateCheckIncomplete)
        XCTAssertTrue(reopened.renewedGrants.isEmpty)
        let finding = try JSONDecoder().decode(TasteFinding.self, from: Data(#"{"result":"works"}"#.utf8))
        XCTAssertEqual(finding, TasteFinding(.works, detail: ""))
    }

    func testAllowedRunsEverythingExceptParkedOnceSetUp() {
        var progress = SetupProgress(step: .permissions)
        let enabled: Set<Feature> = [.windows, .remap, .clipboard]
        XCTAssertEqual(progress.allowed(enabled), [])
        progress.step = .orderUp
        XCTAssertEqual(progress.allowed(enabled), enabled)
        progress.step = .complete
        progress.parked[.remap] = TasteFinding(.notWorking, grants: [.inputMonitoring], detail: "")
        XCTAssertEqual(progress.allowed(enabled), [.windows, .clipboard])
    }

    func testCurrentGrantSkipsGrantedSkippedAndBlockedFeatures() {
        var progress = SetupProgress(step: .permissions)
        let needs: [Feature: Set<Permission>] = [.remap: [.accessibility, .inputMonitoring], .windows: [.accessibility], .audio: [.systemAudio]]
        let order = Permission.setupOrder.filter { [.accessibility, .inputMonitoring, .systemAudio].contains($0) }
        let targets = Set(needs.keys)
        var granted: Set<Permission> = []
        XCTAssertEqual(progress.currentGrant(order: order, requirements: needs, targets: targets, isGranted: granted.contains), .accessibility)
        granted.insert(.accessibility)
        XCTAssertEqual(progress.currentGrant(order: order, requirements: needs, targets: targets, isGranted: granted.contains), .inputMonitoring)
        progress.skipped = [.inputMonitoring]
        XCTAssertEqual(progress.currentGrant(order: order, requirements: needs, targets: targets, isGranted: granted.contains), .systemAudio)
        progress.askingAgain = .accessibility
        XCTAssertEqual(progress.currentGrant(order: order, requirements: needs, targets: targets, isGranted: granted.contains), .accessibility)
        progress.askingAgain = nil
        granted.insert(.systemAudio)
        XCTAssertNil(progress.currentGrant(order: order, requirements: needs, targets: targets, isGranted: granted.contains))
    }

    func testStaleGrantIsAskedAgainUntilRenewed() {
        var progress = SetupProgress(step: .complete)
        progress.parked[.windows] = TasteFinding(.notWorking, grants: [.accessibility], detail: "")
        let needs: [Feature: Set<Permission>] = [.windows: [.accessibility]]
        XCTAssertTrue(progress.isStale(.accessibility, targets: [.windows]))
        XCTAssertFalse(progress.isStale(.accessibility, targets: [.remap]))
        XCTAssertEqual(progress.currentGrant(order: [.accessibility], requirements: needs, targets: [.windows], isGranted: { _ in true }), .accessibility)
        progress.renewedGrants = [.accessibility]
        XCTAssertFalse(progress.isStale(.accessibility, targets: [.windows]))
        XCTAssertNil(progress.currentGrant(order: [.accessibility], requirements: needs, targets: [.windows], isGranted: { _ in true }))
        progress.parked[.windows] = TasteFinding(.parked, grants: [.accessibility], detail: "")
        progress.renewedGrants = []
        XCTAssertFalse(progress.isStale(.accessibility, targets: [.windows]))
    }

    func testFirstSetupRecipeAddsEqualizerAndLeavesOptInLinesOff() {
        let mac = GearScan.Mac(model: "MacBookAir10,1", appleSilicon: true, os: "27.2")
        let laptop = GearScan.Screen(name: "Built-in", width: 2560, height: 1600, builtIn: true, answers: nil)
        let scan = GearScan(mac: mac, screens: [laptop],
                            audio: [.init(uid: "spk", name: "Speakers", transport: "builtIn", hasInput: false, hasOutput: true),
                                    .init(uid: "rode", name: "RØDE PodMic USB", transport: "usb", hasInput: true, hasOutput: true)])
        let first = StarterRecipes.plan(for: scan, firstSetup: true)
        let later = StarterRecipes.plan(for: scan)
        XCTAssertEqual(first.lines.first { $0.id == "audio.eq" }?.action, .outputEQ)
        XCTAssertNil(later.lines.first { $0.id == "audio.eq" })
        XCTAssertEqual(first.lines.first { $0.id == "mic.source" }?.on, false)
        XCTAssertEqual(later.lines.first { $0.id == "mic.source" }?.on, true)
        XCTAssertEqual(first.lines.first { $0.id == "clipboard.history" }?.on, false)
        XCTAssertEqual(later.lines.first { $0.id == "clipboard.history" }?.on, true)
    }

    func testSetEnabledSetFiltersUnbuiltAndPersists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SetupProgressTests.\(UUID().uuidString)"))
        let store = FeatureStore(defaults: defaults)
        store.setEnabled([.windows, .remap])
        XCTAssertEqual(store.enabled, Set([Feature.windows, .remap].filter(\.isBuilt)))
        XCTAssertEqual(FeatureStore(defaults: defaults).enabled, store.enabled)
        store.setEnabled([])
        XCTAssertTrue(FeatureStore(defaults: defaults).enabled.isEmpty)
        let unbuilt = Feature.allCases.filter { !$0.isBuilt }
        store.setEnabled(Set(unbuilt))
        XCTAssertTrue(store.enabled.isEmpty)
    }

    func testAuditOnlyMarksRenewalAndNeverStartsIt() {
        var progress = SetupProgress(step: .complete)
        // State left over from an earlier renewal must not carry into this update.
        progress.renewalStarted = true
        progress.askingAgain = .accessibility
        progress.renewedGrants = [.accessibility]
        let blocked = TasteFinding(.notWorking, grants: [.accessibility], detail: "Accessibility is off for Whoprrr.")
        let audit = UpdateAudit(findings: [.windows: blocked, .display: TasteFinding(.needsCheck, detail: "Could not check.")],
                                park: [.windows: blocked], finished: true)
        let next = progress.applyingAudit(audit, build: "81", now: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(next.renewalStarted)
        XCTAssertNil(next.askingAgain)
        XCTAssertTrue(next.renewedGrants.isEmpty)
        XCTAssertEqual(next.renewal, [.windows])
        XCTAssertEqual(Set(next.parked.keys), [.windows])
        XCTAssertNil(next.parked[.display])
        XCTAssertNil(next.updateOKUntil)
        XCTAssertEqual(next.build, "81")
    }

    func testAuditWithEverythingWorkingShowsOneLineForADay() {
        let audit = UpdateAudit(findings: [.windows: TasteFinding(.works, detail: "")], park: [:], finished: true)
        let next = SetupProgress(step: .complete).applyingAudit(audit, build: "81", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(next.updateOKUntil, Date(timeIntervalSince1970: 86_400))
        XCTAssertTrue(next.renewal.isEmpty)
        XCTAssertFalse(next.renewalStarted)
    }

    func testRenewNeedsADeliberatePressInTheFocusedWindow() {
        let shown = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(RenewalStart.allowed(shownAt: shown, now: shown.addingTimeInterval(5), windowIsKey: false))
        XCTAssertFalse(RenewalStart.allowed(shownAt: shown, now: shown.addingTimeInterval(0.2), windowIsKey: true))
        XCTAssertTrue(RenewalStart.allowed(shownAt: shown, now: shown.addingTimeInterval(1.5), windowIsKey: true))
        XCTAssertTrue(RenewalStart.allowed(shownAt: nil, now: shown, windowIsKey: true))
    }
}
