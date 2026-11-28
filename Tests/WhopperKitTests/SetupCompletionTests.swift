import XCTest
@testable import WhopperKit

final class SetupCompletionTests: XCTestCase {
    private let needs: [Feature: Set<Permission>] = [.windows: [.accessibility], .remap: [.accessibility, .inputMonitoring]]

    private func renewal() -> SetupProgress {
        var p = SetupProgress(step: .complete)
        p.renewal = [.windows, .remap]
        p.renewalStarted = true
        p.parked[.windows] = TasteFinding(.notWorking, grants: [.accessibility], detail: "Accessibility was off.")
        p.parked[.remap] = TasteFinding(.notWorking, grants: [.accessibility, .inputMonitoring], detail: "Grants were off.")
        return p
    }

    func testBeta9SavedRenewalCanFinishWithoutSyntheticChecks() throws {
        var p = renewal()
        p.renewedGrants = [.accessibility, .inputMonitoring]
        // Reproduce the persisted state in the report, not any live user files.
        p = try JSONDecoder().decode(SetupProgress.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(p.resumeRenewedFeatures(requirements: needs, isGranted: { _ in true }), [.windows, .remap])
        XCTAssertTrue(p.parked.isEmpty)
        XCTAssertTrue(p.renewal.isEmpty)
        XCTAssertFalse(p.renewalStarted)
        XCTAssertEqual(p.allowed([.windows, .remap]), [.windows, .remap])
        XCTAssertEqual(p.findings[.windows]?.result, .needsCheck) // Permission proof doesn't claim functional proof.
        XCTAssertEqual(p.findings[.remap]?.result, .needsCheck)
    }

    func testSharedGrantResumesOnlyFeaturesWhoseWholeRequirementsAreReady() {
        var p = renewal()
        p.renewedGrants = [.accessibility]
        XCTAssertEqual(p.resumeRenewedFeatures(requirements: needs, isGranted: { $0 == .accessibility }), [.windows])
        XCTAssertNotNil(p.parked[.remap])
        XCTAssertEqual(p.renewal, [.remap])
        XCTAssertTrue(p.renewalStarted)
        p.renewedGrants.insert(.inputMonitoring)
        XCTAssertTrue(p.resumeRenewedFeatures(requirements: needs, isGranted: { $0 != .inputMonitoring }).isEmpty)
        XCTAssertEqual(p.allowed([.windows, .remap]), [.windows]) // A pending restart/denial still blocks remapping.
    }

    func testAnOnButStaleGrantStillRequiresDeliberateRenewal() {
        var p = renewal()
        XCTAssertTrue(p.resumeRenewedFeatures(requirements: needs, isGranted: { _ in true }).isEmpty)
        XCTAssertEqual(p.parked.count, 2)
        p.renewedGrants = [.accessibility, .inputMonitoring]
        p.skipped = [.inputMonitoring]
        XCTAssertEqual(p.resumeRenewedFeatures(requirements: needs, isGranted: { _ in true }), [.windows])
        XCTAssertNotNil(p.parked[.remap])
    }

    func testExplicitlyPausedFeatureCanResumeWithoutDiagnosticGate() {
        var p = renewal()
        p.parked[.windows] = TasteFinding(.parked, grants: [.accessibility], detail: "Paused by user.")
        XCTAssertEqual(p.resumeRenewedFeatures(requirements: needs, isGranted: { _ in true }), [.windows])
        XCTAssertNotNil(p.parked[.remap])
    }

    func testFailedOptionalProbeDoesNotPauseAFeatureWithGrantedPermissions() {
        var p = SetupProgress(step: .orderUp)
        p.recordDiagnostic(TasteFinding(.notWorking, grants: [.accessibility], detail: "Synthetic move did not answer."),
                           for: .windows, requirements: [.accessibility], states: [.accessibility: .granted])
        XCTAssertEqual(p.findings[.windows]?.result, .notWorking)
        XCTAssertNil(p.parked[.windows])
        XCTAssertEqual(p.allowed([.windows]), [.windows])
        p.recordDiagnostic(TasteFinding(.needsCheck, detail: "Timed out."), for: .windows,
                           requirements: [.accessibility], states: [.accessibility: .granted])
        XCTAssertNil(p.parked[.windows])
    }

    func testOptionalChecksStillRespectRealDenialsAndExplicitSkips() {
        var p = SetupProgress(step: .complete)
        p.recordDiagnostic(TasteFinding(.notWorking, detail: "Could not check."), for: .remap,
                           requirements: [.accessibility, .inputMonitoring],
                           states: [.accessibility: .granted, .inputMonitoring: .denied])
        XCTAssertEqual(p.parked[.remap]?.grants, [.inputMonitoring])
        XCTAssertTrue(p.allowed([.remap]).isEmpty)
        p.recordDiagnostic(TasteFinding(.parked, grants: [.accessibility], detail: "Skipped by user."), for: .windows,
                           requirements: [.accessibility], states: [.accessibility: .granted])
        XCTAssertEqual(p.parked[.windows]?.result, .parked)
    }

    func testClosingChecksReleasesTheRunAndOldCompletionCannotAffectARetry() throws {
        var run = SetupCheckRun()
        let first = try XCTUnwrap(run.begin())
        XCTAssertNil(run.begin())
        run.cancel()
        XCTAssertNil(run.active)
        let retry = try XCTUnwrap(run.begin())
        XCTAssertNotEqual(first, retry)
        XCTAssertFalse(run.finish(first))
        XCTAssertEqual(run.active, retry)
        XCTAssertTrue(run.finish(retry))
        XCTAssertNil(run.active)
        XCTAssertNotNil(run.begin())
    }
}
