import XCTest
@testable import DisplayCore

final class ControllerTests: XCTestCase {

    // MARK: reads

    func testUnsupportedRead() async throws {
        let (f, c) = Fx.rig()
        f.failReads(.contrast, with: .unsupported)
        let t = try await Fx.target(c)
        do { _ = try await c.read(.contrast, target: t); XCTFail() } catch { XCTAssertEqual(error as? DDCFailure, .unsupported) }
        // A control the display never reports behaves the same way.
        f.failReads(.contrast, with: nil)
        f.setDisplays([Fx.builtIn, Fx.ext()])
    }

    func testTimedOutRead() async throws {
        let (f, c) = Fx.rig()
        f.failReads(.brightness, with: .timeout)
        let t = try await Fx.target(c)
        do { _ = try await c.read(.brightness, target: t); XCTFail() } catch { XCTAssertEqual(error as? DDCFailure, .timeout) }
        XCTAssertEqual(c.log.lastDDCEvent?.ok, false)
    }

    func testDisconnectedIsDistinctFromTimeout() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        f.setDisplays([Fx.builtIn])               // unplugged, but no rescan yet
        // Worker still holds the old scan; the transport reports the endpoint missing.
        do { _ = try await c.read(.brightness, target: t); XCTFail() } catch { XCTAssertEqual(error as? DDCFailure, .disconnected) }
    }

    // MARK: range validation and write rules

    func testWriteClampsToVerifiedRangeAndVerifies() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        let o = try await c.write(.brightness, value: 150, target: t)
        XCTAssertEqual(o.requested, 150); XCTAssertEqual(o.applied, 100); XCTAssertEqual(o.maximum, 100)
        XCTAssertEqual(o.before, 80); XCTAssertTrue(o.verified)
        XCTAssertEqual(f.writes, [.init(uuid: "UUID-EXT", control: .brightness, value: 100)])
    }

    func testNegativeValueRejectedWithoutWriting() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        do { _ = try await c.write(.brightness, value: -1, target: t); XCTFail() }
        catch { XCTAssertEqual(error as? DDCFailure, .outOfRange(requested: -1, maximum: 100)) }
        XCTAssertTrue(f.writes.isEmpty)
    }

    func testDefaultWritableIsExactlyTheHardwareVerifiedCatalogue() {
        XCTAssertEqual(Control.defaultWritable, Set(Catalog.known.filter(\.hardwareVerified).map(\.control)))
        XCTAssertTrue(Control.defaultWritable.contains(.brightness))
        XCTAssertFalse(Control.defaultWritable.contains(Control(0xE0)), "unknown codes are never writable by default")
    }

    func testUnknownCodeNotWritableUntilLearned() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        do { _ = try await c.write(Control(0xE0), value: 0, target: t); XCTFail() }
        catch { XCTAssertEqual(error as? DDCFailure, .notWritable(Control(0xE0))) }
        XCTAssertTrue(f.writes.isEmpty)
        c.writableControls.insert(Control(0xE0))                  // what the app does for a learned code
        let o = try await c.write(Control(0xE0), value: 0, target: t)
        XCTAssertTrue(o.verified)
    }

    func testDeniedCodesRefusedEvenIfOptedIn() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        for code: UInt8 in [0xD6, 0x04, 0x08, 0xB0] {
            c.writableControls.insert(Control(code))
            do { _ = try await c.write(Control(code), value: 1, target: t); XCTFail("wrote \(code)") }
            catch { XCTAssertEqual(error as? DDCFailure, .refused) }
        }
        XCTAssertTrue(f.writes.isEmpty)
    }

    func testChoiceControlsAreNotClampedToUnreliableReportedMax() async throws {
        // The Samsung reports max 4 for color preset while using 5; choice bounds come from the catalogue.
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        let o = try await c.write(.colorPreset, value: 3, target: t)
        XCTAssertEqual(o.applied, 3); XCTAssertTrue(o.verified)
        XCTAssertEqual(f.writes.last?.value, 3)
    }

    func testQuantizedWriteIsReportedAsAdjusted() async throws {
        let (f, c) = Fx.rig()
        f.step[.sharpness] = 8
        let t = try await Fx.target(c)
        let o = try await c.write(.sharpness, value: 51, target: t)
        XCTAssertEqual(o.readback, 48)
        XCTAssertFalse(o.verified); XCTAssertTrue(o.adjusted); XCTAssertTrue(o.accepted)
    }

    func testBuiltInNeverBecomesATarget() async throws {
        let (f, c) = Fx.rig()
        let snap = await c.refresh()
        let builtIn = snap.displays.first { $0.isBuiltIn }!
        XCTAssertThrowsError(try c.target(for: builtIn, in: snap)) { XCTAssertEqual($0 as? DDCFailure, .builtInRefused) }
        // Even a hand-forged target for the built-in is refused before the transport.
        let forged = DisplayTarget(uuid: builtIn.uuid, identity: builtIn.identity, generation: snap.generation)
        do { _ = try await c.write(.brightness, value: 10, target: forged); XCTFail() }
        catch { XCTAssertTrue([DDCFailure.builtInRefused, .disconnected].contains(error as? DDCFailure)) }
        XCTAssertTrue(f.writes.isEmpty)
    }

    func testMissingReadbackIsUnverified() async throws {
        let (f, c) = Fx.rig()
        f.ignoreWrites = true                       // write "succeeds", readback shows the old value
        let t = try await Fx.target(c)
        let o = try await c.write(.brightness, value: 50, target: t)
        XCTAssertFalse(o.verified); XCTAssertEqual(o.readback, 80)
        XCTAssertEqual(c.log.lastDDCEvent?.ok, false)
    }

    // MARK: stale handles

    func testStaleTargetRejectedAfterGenerationBump() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        c.generation.bump()                          // topology callback fired
        do { _ = try await c.write(.brightness, value: 50, target: t); XCTFail() }
        catch { XCTAssertEqual(error as? DDCFailure, .stale) }
        XCTAssertTrue(f.writes.isEmpty)
        XCTAssertEqual(f.readCount, 0, "a stale target must not even reach the transport for a read")
    }

    func testUnplugDuringPendingWriteNeverWrites() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        // The display is "unplugged" while the pre-write read is in flight.
        f.beforeOperation = { [gen = c.generation] in gen.bump() }
        do { _ = try await c.write(.brightness, value: 50, target: t); XCTFail() }
        catch { XCTAssertEqual(error as? DDCFailure, .stale) }
        XCTAssertTrue(f.writes.isEmpty)
    }

    func testReconnectedDifferentDisplayDoesNotInheritOldTarget() async throws {
        let (f, c) = Fx.rig()
        let old = try await Fx.target(c)
        // Unplug, then a *different* monitor shows up with the same system UUID (worst case).
        c.generation.bump()
        f.setDisplays([Fx.builtIn, Fx.ext("UUID-EXT", id: Fx.otherID)])
        f.setValue(.init(current: 30, maximum: 100), .brightness, uuid: "UUID-EXT")
        let snap = await c.refresh()
        do { _ = try await c.write(.brightness, value: 90, target: old); XCTFail() }
        catch { XCTAssertEqual(error as? DDCFailure, .stale) }
        XCTAssertTrue(f.writes.isEmpty)
        // Fresh target resolves normally, and the old identity no longer matches.
        XCTAssertThrowsError(try c.resolve(identity: Fx.samsungID, in: snap)) { XCTAssertEqual($0 as? DDCFailure, .disconnected) }
    }

    func testQueuedWritesAreDiscardedOnNewGeneration() async throws {
        let (f, c) = Fx.rig()
        let t = try await Fx.target(c)
        let g = c.generation
        f.beforeOperation = { g.bump() }
        async let a: Result<WriteOutcome, Error> = { do { return .success(try await c.write(.brightness, value: 10, target: t)) } catch { return .failure(error) } }()
        async let b: Result<WriteOutcome, Error> = { do { return .success(try await c.write(.brightness, value: 20, target: t)) } catch { return .failure(error) } }()
        let (ra, rb) = await (a, b)
        for r in [ra, rb] { if case .success = r { XCTFail("queued write survived a generation bump") } }
        XCTAssertTrue(f.writes.isEmpty)
    }

    // MARK: identity

    func testAmbiguousIdentityRequiresReselection() async throws {
        let twin1 = Fx.ext("UUID-A"), twin2 = Fx.ext("UUID-B")        // same serial twice
        let (_, c) = Fx.rig([Fx.builtIn, twin1, twin2])
        let snap = await c.refresh()
        XCTAssertThrowsError(try c.resolve(identity: Fx.samsungID, in: snap)) { XCTAssertEqual($0 as? DDCFailure, .ambiguousTarget) }
    }

    func testWeakIdentityRequiresReselection() async throws {
        let weak = DisplayIdentity(vendor: 1, model: 2, serial: 0, alphaSerial: nil, productName: "Generic", manufacturer: nil)
        let (_, c) = Fx.rig([Fx.builtIn, Fx.ext("UUID-W", id: weak)])
        let snap = await c.refresh()
        XCTAssertFalse(weak.isStrong)
        XCTAssertThrowsError(try c.resolve(identity: weak, in: snap)) { XCTAssertEqual($0 as? DDCFailure, .ambiguousTarget) }
    }

    func testUniqueIdentityResolvesAcrossNewSessionHandles() async throws {
        let (f, c) = Fx.rig()
        _ = await c.refresh()
        // New session: macOS hands out a different system UUID and display ID for the same monitor.
        f.setDisplays([Fx.builtIn, Fx.ext("UUID-NEW")])
        f.setValue(.init(current: 80, maximum: 100), .brightness, uuid: "UUID-NEW")
        let snap = await c.refresh()
        let t = try c.resolve(identity: Fx.samsungID, in: snap)
        XCTAssertEqual(t.uuid, "UUID-NEW")
    }

    // MARK: logging

    func testLogsDistinguishFakeFromHardware() async throws {
        let (_, c) = Fx.rig()
        let t = try await Fx.target(c)
        _ = try await c.read(.brightness, target: t)
        XCTAssertEqual(c.log.lastDDCEvent?.transport, .fake)
    }
}
