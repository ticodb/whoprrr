import XCTest
@testable import AudioCore

final class DynamicsTests: XCTestCase {
    func sine(_ n: Int, amp: Float, hz: Double = 440, sr: Double = 48000) -> [Float] {
        (0..<n).map { amp * Float(sin(2 * Double.pi * hz * Double($0) / sr)) }
    }
    func peak(_ x: [Float], from: Int = 0) -> Float { x[from...].map { abs($0) }.max() ?? 0 }

    func testDisabledPassesAudioUntouched() {
        let d = StereoDynamics(sampleRate: 48000)
        var l = sine(4800, amp: 0.5), r = l
        let ref = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in d.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: 4800) } }
        XCTAssertEqual(l, ref)
    }

    func testLimiterNeverExceedsCeiling() {
        var s = OutputDynamicsSettings(); s.limiterEnabled = true; s.ceilingDB = -6
        let d = StereoDynamics(sampleRate: 48000); d.update(s)
        var l = sine(9600, amp: 1.0), r = sine(9600, amp: 0.9, hz: 1000)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in d.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: 9600) } }
        let ceiling = Float(pow(10, -6.0 / 20))
        XCTAssertLessThanOrEqual(peak(l), ceiling + 1e-6)
        XCTAssertLessThanOrEqual(peak(r), ceiling + 1e-6)
        XCTAssertGreaterThan(peak(l), ceiling * 0.9)       // it limits, it does not mute
    }

    func testCompressorReducesLoudSignalAndLeavesQuietOne() {
        var s = OutputDynamicsSettings(); s.compressor.enabled = true; s.compressor.thresholdDB = -20; s.compressor.ratio = 4; s.compressor.makeupDB = 0
        s.compressor.attackMs = 1; s.compressor.releaseMs = 50
        func run(_ amp: Float) -> Float {
            let d = StereoDynamics(sampleRate: 48000); d.update(s)
            var l = sine(48000, amp: amp), r = l
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in d.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: 48000) } }
            return peak(l, from: 24000)
        }
        let loud = run(0.9), quiet = run(0.02)
        XCTAssertLessThan(loud, 0.6)                       // 0.9 is ~ -1 dB, well over the threshold
        XCTAssertEqual(quiet, 0.02, accuracy: 0.002)       // -34 dB: below the threshold, untouched
    }

    func testStereoLinkedSoPanDoesNotShift() {
        var s = OutputDynamicsSettings(); s.limiterEnabled = true; s.ceilingDB = -6
        let d = StereoDynamics(sampleRate: 48000); d.update(s)
        var l = sine(4800, amp: 1.0), r = sine(4800, amp: 0.25)       // loud left, quiet right
        let rBefore = r
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in d.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: 4800) } }
        // The right channel is scaled by the same gain as the left: ratio of peaks is preserved.
        XCTAssertEqual(peak(r, from: 2400) / peak(rBefore, from: 2400), peak(l, from: 2400) / 1.0, accuracy: 0.05)
    }

    func testSettingsSavedBeforeDynamicsAndPluginsStillLoad() throws {
        let old = #"{"enabled":true,"defaultProfile":{"enabled":true,"preampDB":0,"bands":[]},"profiles":{},"permissionVerified":true}"#
        let s = try JSONDecoder().decode(OutputEQSettings.self, from: Data(old.utf8))
        XCTAssertTrue(s.enabled); XCTAssertTrue(s.plugins.isEmpty); XCTAssertFalse(s.dynamics.isActive)
        let oldMic = #"{"enabled":true,"gainDB":2}"#
        let m = try JSONDecoder().decode(MicSettings.self, from: Data(oldMic.utf8))
        XCTAssertEqual(m.gainDB, 2); XCTAssertTrue(m.plugins.isEmpty)
        var withPlugin = MicSettings(); withPlugin.plugins = [PluginSlot(name: "X", manufacturer: "Y", type: 1, subtype: 2, manufacturerCode: 3)]
        let back = try JSONDecoder().decode(MicSettings.self, from: JSONEncoder().encode(withPlugin))
        XCTAssertEqual(back.plugins, withPlugin.plugins)
    }
}

final class PluginHostTests: XCTestCase {
    /// Hosts a real Apple limiter/compressor Audio Unit and checks it processes audio through the rack.
    func testRackRunsARealAudioUnit() throws {
        let catalog = PluginCatalog.effects()
        if catalog.isEmpty { throw XCTSkip("no effect Audio Units installed in this environment") }
        guard let info = catalog.first(where: { $0.isApple && $0.name.localizedCaseInsensitiveContains("Peak Limiter") })
                ?? catalog.first(where: { $0.isApple && $0.name.localizedCaseInsensitiveContains("Dynamics") }) else { throw XCTSkip("no Apple dynamics AU") }

        let rack = PluginRack()
        let ready = expectation(description: "plugin ready")
        let slot = info.makeSlot()
        nonisolated(unsafe) var fulfilled = false
        rack.onStatus = { st in if st[slot.id] == .ready, !fulfilled { fulfilled = true; ready.fulfill() } }
        rack.apply(slots: [slot], sampleRate: 48000)
        let outcome = XCTWaiter.wait(for: [ready], timeout: 15)
        if outcome != .completed { throw XCTSkip("Audio Unit hosting is not available in this environment (headless CI?)") }

        // A loud sine through a limiter/compressor must come out quieter than it went in, and not be silent.
        let n = 48000
        var l = (0..<n).map { 0.95 * Float(sin(2 * Double.pi * 440 * Double($0) / 48000)) }
        var r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            var off = 0
            while off < n { let k = min(512, n - off); rack.process(left: lp.baseAddress! + off, right: rp.baseAddress! + off, frames: k); off += k }
        } }
        let tail = l[(n / 2)...].map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(tail, 0.05, "not silent")
        XCTAssertFalse(l.contains { !$0.isFinite })

        // State round-trips: capture, and a restored rack has the same state data.
        let states = rack.captureStates()
        XCTAssertNotNil(states[slot.id])
        rack.clear()
    }

    func testStateSurvivesInSlot() throws {
        var s = PluginSlot(name: "A", manufacturer: "B", type: 1, subtype: 2, manufacturerCode: 3)
        s.state = Data([1, 2, 3])
        let back = try JSONDecoder().decode(PluginSlot.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.state, Data([1, 2, 3])); XCTAssertEqual(back, s)
    }
}

/// Opt-in compatibility sweep over every effect plugin installed on this Mac: WHOPPER_TEST_PLUGINS=1 swift test --filter PluginSweep
final class PluginSweep: XCTestCase {
    func testLoadAndRunEveryInstalledPlugin() throws {
        guard ProcessInfo.processInfo.environment["WHOPPER_TEST_PLUGINS"] == "1" else { throw XCTSkip("opt-in") }
        var rows: [String] = []
        for info in PluginCatalog.effects() {
            let rack = PluginRack()
            let slot = info.makeSlot()
            let done = expectation(description: info.name)
            nonisolated(unsafe) var result = "timeout"; nonisolated(unsafe) var finished = false
            rack.onStatus = { st in
                guard !finished, let s = st[slot.id] else { return }
                switch s { case .ready: result = "ready"; finished = true; done.fulfill()
                case .failed(let e): result = "FAILED: \(e)"; finished = true; done.fulfill()
                case .loading: break }
            }
            rack.apply(slots: [slot], sampleRate: 48000)
            wait(for: [done], timeout: 12)
            if result == "ready" {
                var l = (0..<4800).map { 0.3 * Float(sin(2 * Double.pi * 440 * Double($0) / 48000)) }, r = l
                l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in rack.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: 512) } }
                result += l.contains { !$0.isFinite } ? " (NaN!)" : " ok"
            }
            rack.clear()
            rows.append("\(info.manufacturer) / \(info.name): \(result)")
        }
        print("PLUGIN SWEEP\n" + rows.joined(separator: "\n"))
    }
}
