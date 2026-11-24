import XCTest
@testable import AudioCore

final class FakeAudio: AudioSystem, @unchecked Sendable {
    var devs: [AudioDeviceInfo]
    var input: String?
    var output: String?
    var setCalls: [String] = []
    private var handlers: [@Sendable () -> Void] = []
    init(devs: [AudioDeviceInfo], input: String?) { self.devs = devs; self.input = input }
    func devices() -> [AudioDeviceInfo] { devs }
    func defaultInputUID() -> String? { input }
    func defaultOutputUID() -> String? { output }
    func setDefaultInput(uid: String) -> Bool { setCalls.append(uid); input = uid; return true }
    func observe(_ h: @escaping @Sendable () -> Void) -> @Sendable () -> Void { handlers.append(h); return {} }
}

func dev(_ uid: String, in i: Int = 0, out o: Int = 0, _ t: AudioTransport = .usb) -> AudioDeviceInfo {
    AudioDeviceInfo(objectID: 1, uid: uid, name: uid, transport: t, inputChannels: i, outputChannels: o)
}

final class InputPinTests: XCTestCase {
    let pod = dev("pod", in: 1), bt = dev("bt", in: 1, out: 2, .bluetooth), builtin = dev("mac", in: 1, out: 2, .builtIn)

    func testDisabledLeaves() {
        XCTAssertEqual(InputPinLogic.decide(policy: .init(enabled: false, preferredUIDs: ["pod"]), devices: [pod, bt], currentUID: "bt"), .leave)
    }
    func testSwitchesBackFromBluetoothHeadset() {
        XCTAssertEqual(InputPinLogic.decide(policy: .init(enabled: true, preferredUIDs: ["pod"]), devices: [pod, bt], currentUID: "bt"), .set(uid: "pod"))
    }
    func testAlreadyCorrectLeaves() {
        XCTAssertEqual(InputPinLogic.decide(policy: .init(enabled: true, preferredUIDs: ["pod"]), devices: [pod, bt], currentUID: "pod"), .leave)
    }
    func testFallsThroughPriorityWhenPreferredUnplugged() {
        let p = InputPinPolicy(enabled: true, preferredUIDs: ["pod", "mac"])
        XCTAssertEqual(InputPinLogic.decide(policy: p, devices: [bt, builtin], currentUID: "bt"), .set(uid: "mac"))
    }
    func testNoPreferredConnectedLeaves() {
        XCTAssertEqual(InputPinLogic.decide(policy: .init(enabled: true, preferredUIDs: ["pod"]), devices: [bt], currentUID: "bt"), .leave)
    }
    func testOutputOnlyDeviceIsNotAnInput() {
        let spk = dev("spk", out: 2)
        XCTAssertEqual(InputPinLogic.decide(policy: .init(enabled: true, preferredUIDs: ["spk"]), devices: [spk], currentUID: nil), .leave)
    }

    func testPinnerCorrectsAndBacksOffWhenFought() {
        let sys = FakeAudio(devs: [pod, bt], input: "bt")
        let pinner = InputPinner(system: sys, clock: { Date(timeIntervalSince1970: 1000) })
        // start() reconciles once on the pinner's own queue; let that finish so it cannot race the calls below.
        let first = expectation(description: "first reconcile")
        let once = NSLock(); nonisolated(unsafe) var fulfilled = false
        pinner.onStatus = { _ in once.lock(); defer { once.unlock() }; if !fulfilled { fulfilled = true; first.fulfill() } }
        pinner.start(policy: .init(enabled: true, preferredUIDs: ["pod"]))
        wait(for: [first], timeout: 2)
        // Something else flips the input back each time; after the budget the pinner stops fighting.
        for _ in 0..<10 { sys.input = "bt"; pinner.reconcile() }
        XCTAssertEqual(sys.setCalls.count, InputPinner.maxCorrections)
    }
}

final class ToneTests: XCTestCase {
    func testAmplitudeMatchesDecibels() {
        let g = ToneGenerator(settings: .init(enabled: true, levelDB: -60, frequencyHz: 1000), sampleRate: 48000)
        var buf = [Float](repeating: 0, count: 4800 * 2)
        buf.withUnsafeMutableBufferPointer { g.fill($0.baseAddress!, frames: 4800, channels: 2) }
        let peak = buf.map(abs).max()!
        XCTAssertEqual(peak, 0.001, accuracy: 0.0001)
    }
    func testStereoChannelsMatchAndPhaseIsContinuous() {
        let g = ToneGenerator(settings: .init(enabled: true, levelDB: -40, frequencyHz: 40), sampleRate: 48000)
        var a = [Float](repeating: 0, count: 200), b = [Float](repeating: 0, count: 200)
        a.withUnsafeMutableBufferPointer { g.fill($0.baseAddress!, frames: 100, channels: 2) }
        b.withUnsafeMutableBufferPointer { g.fill($0.baseAddress!, frames: 100, channels: 2) }
        XCTAssertEqual(a[0], a[1]); XCTAssertEqual(b[0], b[1])
        XCTAssertLessThan(abs(b[0] - a[198]), 0.01 * 0.5)   // next sample follows the last without a jump
    }
    func testPulseIsSilentBetweenBursts() {
        let g = ToneGenerator(settings: .init(enabled: true, levelDB: -40, frequencyHz: 200, pulseEverySeconds: 1, burstSeconds: 0.1), sampleRate: 1000)
        var buf = [Float](repeating: 0, count: 1000)
        buf.withUnsafeMutableBufferPointer { g.fill($0.baseAddress!, frames: 1000, channels: 1) }
        XCTAssertTrue(buf[200..<1000].allSatisfy { $0 == 0 })
        XCTAssertTrue(buf[0..<100].contains { $0 != 0 })
    }
    func testClampKeepsLevelSafe() {
        XCTAssertEqual(KeepAliveSettings(levelDB: 0).clamped.levelDB, -20)
        XCTAssertEqual(KeepAliveSettings(levelDB: -200).clamped.levelDB, -90)
    }
}

final class DSPTests: XCTestCase {
    let sr = 48000.0

    func testPeakFilterHasRequestedGainAtCenterAndIsFlatFarAway() {
        let c = BiquadCoefficients(.peak, freq: 1000, gainDB: 6, q: 1.41, sampleRate: sr)
        XCTAssertEqual(c.magnitudeDB(at: 1000, sampleRate: sr), 6, accuracy: 0.05)
        XCTAssertEqual(c.magnitudeDB(at: 30, sampleRate: sr), 0, accuracy: 0.3)
        XCTAssertEqual(c.magnitudeDB(at: 18000, sampleRate: sr), 0, accuracy: 0.5)
    }
    func testShelvesAndPasses() {
        let low = BiquadCoefficients(.lowShelf, freq: 200, gainDB: 8, q: 0.707, sampleRate: sr)
        XCTAssertEqual(low.magnitudeDB(at: 20, sampleRate: sr), 8, accuracy: 0.5)
        XCTAssertEqual(low.magnitudeDB(at: 10000, sampleRate: sr), 0, accuracy: 0.3)
        let hp = BiquadCoefficients(.highPass, freq: 100, sampleRate: sr)
        XCTAssertLessThan(hp.magnitudeDB(at: 20, sampleRate: sr), -20)
        XCTAssertEqual(hp.magnitudeDB(at: 5000, sampleRate: sr), 0, accuracy: 0.2)
    }
    func testNegativeGainCuts() {
        XCTAssertEqual(BiquadCoefficients(.peak, freq: 4000, gainDB: -9, sampleRate: sr).magnitudeDB(at: 4000, sampleRate: sr), -9, accuracy: 0.05)
    }

    private func run(_ p: EQProfile, hz: Double, amp: Float = 0.1, frames: Int = 48000) -> Float {
        let e = EQProcessor(sampleRate: sr); e.update(p)
        var l = (0..<frames).map { amp * Float(sin(2 * .pi * hz * Double($0) / sr)) }; var r = l
        // two passes: the first lets filters settle and adopts the profile
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            e.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: frames)
        } }
        _ = e.takePeak()
        l = (0..<frames).map { amp * Float(sin(2 * .pi * hz * Double($0) / sr)) }; r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            e.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: frames)
        } }
        return e.takePeak()
    }

    func testProcessorAppliesBandGainToATone() {
        var p = EQProfile.flat; p.bands[5].gainDB = 6                       // +6 dB at 1 kHz
        let out = run(p, hz: 1000)
        XCTAssertEqual(20 * log10(Double(out) / 0.1), 6, accuracy: 0.4)
    }
    func testFlatProfileIsBitTransparent() {
        XCTAssertEqual(run(.flat, hz: 440), 0.1, accuracy: 0.0001)
    }
    func testPreampScales() {
        var p = EQProfile.flat; p.preampDB = -6
        XCTAssertEqual(20 * log10(Double(run(p, hz: 440)) / 0.1), -6, accuracy: 0.1)
    }
    func testLimiterNeverExceedsFullScale() {
        var p = EQProfile.flat; p.preampDB = 18
        XCTAssertLessThanOrEqual(run(p, hz: 440, amp: 0.9), 1.0)
    }
    func testDisabledProfileBypasses() {
        var p = EQProfile.flat; p.bands[5].gainDB = 12; p.enabled = false
        XCTAssertEqual(run(p, hz: 1000), 0.1, accuracy: 0.0001)
    }
    func testAutoPreampMatchesLargestBoost() {
        XCTAssertEqual(EQProfile.tenBand([0, 0, 3, 7, 0, 0, 0, 0, 0, 0]).autoPreampDB, -7)
        XCTAssertEqual(EQProfile.flat.autoPreampDB, 0)
    }

    func testGateSilencesQuietSignalButPassesLoud() {
        let d = DynamicsProcessor(sampleRate: sr)
        var g = GateSettings(); g.enabled = true; g.thresholdDB = -40
        d.update(gate: g, compressor: CompressorSettings())
        var quiet = (0..<48000).map { 0.002 * Float(sin(2 * .pi * 300 * Double($0) / sr)) }   // about -54 dB
        quiet.withUnsafeMutableBufferPointer { d.process($0.baseAddress!, frames: 48000) }
        XCTAssertLessThan(quiet.suffix(4800).map(abs).max()!, 0.0002)
        var loud = (0..<48000).map { 0.3 * Float(sin(2 * .pi * 300 * Double($0) / sr)) }
        loud.withUnsafeMutableBufferPointer { d.process($0.baseAddress!, frames: 48000) }
        XCTAssertGreaterThan(loud.suffix(4800).map(abs).max()!, 0.25)
    }

    func testCompressorReducesLoudPeaksTowardsRatio() {
        let d = DynamicsProcessor(sampleRate: sr)
        var c = CompressorSettings(); c.enabled = true; c.thresholdDB = -20; c.ratio = 4; c.makeupDB = 0
        d.update(gate: GateSettings(), compressor: c)
        var x = (0..<96000).map { 0.5 * Float(sin(2 * .pi * 300 * Double($0) / sr)) }       // -6 dB, 14 dB over
        x.withUnsafeMutableBufferPointer { d.process($0.baseAddress!, frames: 96000) }
        let outDB = 20 * log10(Double(x.suffix(9600).map(abs).max()!))
        // 14 dB over at 4:1 leaves 3.5 dB over threshold: about -16.5 dBFS peak (the envelope follows the rectified wave, so allow slack)
        XCTAssertEqual(outDB, -16.5, accuracy: 3.0)
        XCTAssertLessThan(outDB, -9)
    }
}

final class MicSettingsTests: XCTestCase {
    func testChainProfileIncludesHighPassThenEQAndGain() {
        var m = MicSettings(); m.gainDB = 4; m.highPassHz = 100
        m.eq.bands[5].gainDB = 3
        let p = m.chainProfile
        XCTAssertEqual(p.bands.first?.kind, .highPass); XCTAssertEqual(p.bands.first?.freq, 100)
        XCTAssertEqual(p.bands.count, 11); XCTAssertEqual(p.preampDB, 4)
    }
    func testDisabledEQKeepsOnlyTheHighPass() {
        var m = MicSettings(); m.eq.enabled = false; m.eq.bands[5].gainDB = 9
        XCTAssertEqual(m.chainProfile.bands.map(\.kind), [.highPass])
        m.highPassEnabled = false
        XCTAssertTrue(m.chainProfile.bands.isEmpty)
    }
    func testHighPassActuallyCutsLowRumble() {
        let sr = 48000.0
        let e = EQProcessor(sampleRate: sr); e.update(MicSettings().chainProfile)
        var l = (0..<48000).map { 0.2 * Float(sin(2 * .pi * 30 * Double($0) / sr)) }; var r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in e.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: 48000) } }
        XCTAssertLessThan(l.suffix(4800).map(abs).max()!, 0.2 * 0.2)     // 30 Hz is well under the 80 Hz cutoff
    }
    func testSettingsRoundTripThroughJSON() throws {
        var s = AudioSettings(); s.mic.enabled = true; s.mic.sourceUID = "pod"; s.eq.enabled = true; s.eq.profiles["x"] = .tenBand([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(try JSONDecoder().decode(AudioSettings.self, from: JSONEncoder().encode(s)), s)
    }
}
