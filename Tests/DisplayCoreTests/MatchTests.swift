import XCTest
@testable import DisplayCore

/// A simulated room: a camera looking at a MacBook (right) and a Samsung (left). The Samsung's light output
/// follows the DDC values written through the fake transport, so the loop is truly closed.
final class SimRoom: PatchPresenter, FrameSource {
    let fake: FakeTransport
    let uuid: String
    var samsungLevel: Double?, macLevel: Double?
    var finished = false
    var macScale = (r: 0.80, g: 0.80, b: 0.76)            // MacBook white balance and brightness
    var panelBias = (r: 0.85, g: 1.0, b: 1.35)            // Samsung leans blue
    var panelMax = 0.9                                    // Samsung can be brighter than the MacBook
    var overlap = false
    var exposure = 1.0
    var shows: [(Double?, Double?)] = []

    init(fake: FakeTransport, uuid: String) { self.fake = fake; self.uuid = uuid }

    func show(samsung: Double?, mac: Double?) async { samsungLevel = samsung; macLevel = mac; shows.append((samsung, mac)) }
    func finish() async { finished = true }

    private func lin(_ srgb: Double) -> Double { srgb <= 0.04045 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4) }
    private func enc(_ l: Double) -> UInt8 {
        let c = min(max(l, 0), 1)
        let e = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8((e * 255).rounded())
    }

    func frame() async throws -> Frame {
        let w = 320, h = 160
        var px = [UInt8](repeating: 4, count: w * h * 4)
        func paint(_ x0: Int, _ x1: Int, _ rgb: (Double, Double, Double)) {
            for y in 30..<130 { for x in x0..<x1 {
                let o = (y * w + x) * 4
                px[o] = enc(rgb.2 * exposure); px[o + 1] = enc(rgb.1 * exposure); px[o + 2] = enc(rgb.0 * exposure); px[o + 3] = 255
            } }
        }
        let b = Double(fake.currentValue(.brightness, uuid: uuid) ?? 0) / 100
        // 50 is neutral on the real monitor (Normal preset = 50/50/50); the response exponent deliberately differs
        // from the engine's 2.2 assumption so the loop must tolerate model error.
        func g(_ c: Control) -> Double { pow(Double(fake.currentValue(c, uuid: uuid) ?? 0) / 50, 1.6) }
        let sl = lin(samsungLevel ?? 0.0), ml = lin(macLevel ?? 0.0)
        let sx0 = 20
        paint(sx0, sx0 + 140, (sl * b * panelMax * panelBias.r * g(.red), sl * b * panelMax * panelBias.g * g(.green), sl * b * panelMax * panelBias.b * g(.blue)))
        if overlap { paint(sx0, sx0 + 140, (max(sl, ml), max(sl, ml), max(sl, ml))) }   // both screens appear in the same place
        else { paint(180, 300, (ml * macScale.r, ml * macScale.g, ml * macScale.b)) }
        return Frame(width: w, height: h, bgra: px)
    }
}

final class MatchTests: XCTestCase {
    func rig(start b: Int = 100, rgb: (Int, Int, Int) = (56, 56, 63)) -> (FakeTransport, DisplayController, SimRoom) {
        let (f, c) = Fx.rig()
        f.setValue(.init(current: b, maximum: 100), .brightness, uuid: "UUID-EXT")
        f.setValue(.init(current: rgb.0, maximum: 100), .red, uuid: "UUID-EXT")
        f.setValue(.init(current: rgb.1, maximum: 100), .green, uuid: "UUID-EXT")
        f.setValue(.init(current: rgb.2, maximum: 100), .blue, uuid: "UUID-EXT")
        return (f, c, SimRoom(fake: f, uuid: "UUID-EXT"))
    }

    func quick() -> MatchConfig { var c = MatchConfig(); c.settleSeconds = 0; return c }

    // MARK: analyzer

    func testAnalyzerFindsBothScreensAndMeasuresRatio() async throws {
        let (_, _, room) = rig()
        room.samsungLevel = 0.5; room.macLevel = nil
        let s = FrameAnalyzer.brightestRegion(in: try await room.frame())!
        room.samsungLevel = nil; room.macLevel = 0.5
        let m = FrameAnalyzer.brightestRegion(in: try await room.frame())!
        XCTAssertLessThan(s.x1, m.x0, "Samsung is on the left of the camera view, the MacBook on the right")
        XCTAssertLessThan(s.overlapFraction(with: m), 0.01)
    }

    func testAnalyzerReturnsNilForADarkRoom() async throws {
        let (_, _, room) = rig()
        room.samsungLevel = nil; room.macLevel = nil
        let f = try await room.frame()
        XCTAssertNil(FrameAnalyzer.brightestRegion(in: f))
    }

    // MARK: engine

    func testEngineSeesAlreadyMatchedAsConverged() {
        let m = RGB(0.2, 0.2, 0.19)
        let p = MatchEngine.propose(samsung: m, mac: m, state: .init(brightness: 50, maxBrightness: 100, red: 50, green: 50, blue: 50, maxGain: 100))
        XCTAssertTrue(p.converged)
    }

    func testEngineLowersAStrongBlueAndTooBrightPanel() {
        let p = MatchEngine.propose(samsung: RGB(0.3, 0.4, 0.6), mac: RGB(0.3, 0.3, 0.3),
                                    state: .init(brightness: 80, maxBrightness: 100, red: 50, green: 50, blue: 50, maxGain: 100))
        XCTAssertFalse(p.converged)
        XCTAssertLessThan(p.blue, 50); XCTAssertGreaterThan(p.red, 49)
        XCTAssertLessThan(p.brightness, 80)
        XCTAssertLessThanOrEqual(max(p.red, p.green, p.blue), 100)
    }

    // MARK: closed loop

    func testConvergesFromBlueTooBrightStart() async throws {
        let (f, c, room) = rig()
        let t = try await Fx.target(c)
        let report = try await AutoMatcher(controller: c, target: t, presenter: room, camera: room, config: quick()).run()
        XCTAssertTrue(report.converged, report.iterations.map(\.line).joined(separator: "\n"))
        print("LOOP:\n" + report.iterations.map(\.line).joined(separator: "\n"))
        XCTAssertLessThanOrEqual(report.iterations.count, 8)
        let last = report.iterations.last!
        XCTAssertLessThan(abs(last.eLuminance), 0.05); XCTAssertLessThan(abs(last.eRed), 0.03); XCTAssertLessThan(abs(last.eBlue), 0.03)
        XCTAssertTrue(room.finished, "patch windows are always closed")
        // Only the Samsung's brightness and RGB were written, nothing on the built-in, nothing else.
        XCTAssertTrue(f.writes.allSatisfy { $0.uuid == "UUID-EXT" && [Control.brightness, .red, .green, .blue].contains($0.control) })
        // Blue was reduced relative to red, as it should for a blue-leaning panel.
        XCTAssertLessThan(f.currentValue(.blue, uuid: "UUID-EXT")!, f.currentValue(.red, uuid: "UUID-EXT")! + 5)
    }

    func testConvergesFromTooDimStart() async throws {
        let (_, c, room) = rig(start: 20, rgb: (50, 50, 50))
        room.panelBias = (1, 1, 1)
        let t = try await Fx.target(c)
        let report = try await AutoMatcher(controller: c, target: t, presenter: room, camera: room, config: quick()).run()
        XCTAssertTrue(report.converged, report.iterations.map(\.line).joined(separator: "\n"))
    }

    func testReportsWhenSamsungCannotBeBrightEnough() async throws {
        let (_, c, room) = rig()
        room.panelMax = 0.2                                 // far dimmer than the MacBook even at 100
        let t = try await Fx.target(c)
        var cfg = quick(); cfg.maxIterations = 4
        let report = try await AutoMatcher(controller: c, target: t, presenter: room, camera: room, config: cfg).run()
        XCTAssertFalse(report.converged)
        XCTAssertEqual(report.limit, .tooDim)
    }

    func testUndoRestoresOriginalValues() async throws {
        let (f, c, room) = rig()
        let t = try await Fx.target(c)
        let report = try await AutoMatcher(controller: c, target: t, presenter: room, camera: room, config: quick()).run()
        XCTAssertNotEqual(f.currentValue(.brightness, uuid: "UUID-EXT"), 100)
        _ = await c.restore(report.apply)
        XCTAssertEqual(f.currentValue(.brightness, uuid: "UUID-EXT"), 100)
        XCTAssertEqual([Control.red, .green, .blue].map { f.currentValue($0, uuid: "UUID-EXT")! }, [56, 56, 63])
    }

    func testOverlappingRegionsAreRejected() async throws {
        let (f, c, room) = rig()
        room.overlap = true
        let t = try await Fx.target(c)
        do { _ = try await AutoMatcher(controller: c, target: t, presenter: room, camera: room, config: quick()).run(); XCTFail() }
        catch { guard case MatchError.cannotLocate = error else { return XCTFail("\(error)") } }
        XCTAssertTrue(f.writes.isEmpty)
        XCTAssertTrue(room.finished)
    }

    func testOverexposedCameraStopsBeforeWriting() async throws {
        let (f, c, room) = rig()
        room.exposure = 40
        let t = try await Fx.target(c)
        do { _ = try await AutoMatcher(controller: c, target: t, presenter: room, camera: room, config: quick()).run(); XCTFail() }
        catch { XCTAssertEqual(error as? MatchError, .clipped) }
        XCTAssertTrue(f.writes.isEmpty); XCTAssertTrue(room.finished)
    }

    func testStaleTargetStopsTheLoop() async throws {
        let (f, c, room) = rig()
        let t = try await Fx.target(c)
        c.generation.bump()                                  // unplugged / slept mid-run
        do { _ = try await AutoMatcher(controller: c, target: t, presenter: room, camera: room, config: quick()).run(); XCTFail() }
        catch { XCTAssertEqual(error as? DDCFailure, .stale) }
        XCTAssertTrue(f.writes.isEmpty)
    }

    func testCancellationClosesPatchesAndStops() async throws {
        let (_, c, room) = rig()
        let t = try await Fx.target(c)
        var cfg = MatchConfig(); cfg.settleSeconds = 0.2
        let task = Task { try await AutoMatcher(controller: c, target: t, presenter: room, camera: room, config: cfg).run() }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
        XCTAssertTrue(room.finished)
    }
}
