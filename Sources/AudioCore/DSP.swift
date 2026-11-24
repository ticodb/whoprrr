import Foundation

/// Second-order IIR section (RBJ cookbook), direct form II transposed. One instance per channel.
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    public static let identity = BiquadCoefficients()

    public enum Kind: String, Codable, Sendable, CaseIterable { case peak, lowShelf, highShelf, highPass, lowPass }

    public init() {}

    public init(_ kind: Kind, freq: Double, gainDB: Double = 0, q: Double = 0.707, sampleRate: Double) {
        let f = min(max(freq, 10), sampleRate * 0.49)
        let w0 = 2 * Double.pi * f / sampleRate, cw = cos(w0), sw = sin(w0)
        let A = pow(10, gainDB / 40), alpha = sw / (2 * max(q, 0.05))
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch kind {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
        case .lowShelf:
            let t = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cw + t); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - t)
            a0 = (A + 1) + (A - 1) * cw + t; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - t
        case .highShelf:
            let t = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cw + t); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - t)
            a0 = (A + 1) - (A - 1) * cw + t; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - t
        case .highPass:
            b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .lowPass:
            b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        }
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0; self.a1 = a1 / a0; self.a2 = a2 / a0
    }

    /// Magnitude response in dB at `freq`.
    public func magnitudeDB(at freq: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * freq / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }
}

struct BiquadState { var z1 = 0.0, z2 = 0.0 }

public struct EQBand: Codable, Equatable, Sendable, Identifiable {
    public var id: Double { freq }
    public var freq: Double
    public var gainDB: Double
    public var q: Double = 1.41
    public var kind: BiquadCoefficients.Kind = .peak
    public init(freq: Double, gainDB: Double = 0, q: Double = 1.41, kind: BiquadCoefficients.Kind = .peak) {
        self.freq = freq; self.gainDB = gainDB; self.q = q; self.kind = kind
    }
}

public struct EQProfile: Codable, Equatable, Sendable {
    public static let tenBandFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    public var enabled = true
    public var preampDB = 0.0
    public var bands: [EQBand]
    public init(enabled: Bool = true, preampDB: Double = 0, bands: [EQBand]? = nil) {
        self.enabled = enabled; self.preampDB = preampDB
        self.bands = bands ?? Self.tenBandFrequencies.map { EQBand(freq: $0) }
    }

    public static func tenBand(_ gains: [Double], preampDB: Double = 0) -> EQProfile {
        EQProfile(preampDB: preampDB, bands: zip(tenBandFrequencies, gains).map { EQBand(freq: $0, gainDB: $1) })
    }

    public static let flat = EQProfile()
    public static let presets: [(name: String, profile: EQProfile)] = [
        ("Flat", .flat),
        ("Bass boost", .tenBand([5, 4.5, 3.5, 2, 0.5, 0, 0, 0, 0, 0], preampDB: -3)),
        ("Treble boost", .tenBand([0, 0, 0, 0, 0, 0.5, 2, 3.5, 4.5, 5], preampDB: -3)),
        ("Vocal", .tenBand([-2, -1.5, -1, 0, 1.5, 3, 3.5, 2.5, 0.5, 0], preampDB: -3)),
        ("Loudness", .tenBand([5, 4, 2, 0, -1, -0.5, 0, 2, 4, 5], preampDB: -4)),
        ("Small speakers", .tenBand([-4, -2, 2, 3, 2, 0, 0, 1, 2, 2], preampDB: -3)),
    ]

    /// Gain to keep the loudest band from clipping: a flat negative preamp equal to the largest boost.
    public var autoPreampDB: Double { -max(bands.map(\.gainDB).max() ?? 0, 0) }
}

/// Stereo EQ + preamp + soft limiter. `process` is real-time safe; `update` may be called from any thread.
public final class EQProcessor: @unchecked Sendable {
    private let sampleRate: Double
    private var sections: [BiquadCoefficients] = []
    private var stateL: [BiquadState] = [], stateR: [BiquadState] = []
    private var gain: Float = 1
    private var bypass = true
    private var pending: (sections: [BiquadCoefficients], gain: Float, bypass: Bool)?
    private var lock = os_unfair_lock()
    /// Highest absolute sample seen since the last read; the UI meter and the signal check read it.
    public private(set) var peak: Float = 0

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    public func update(_ p: EQProfile) {
        let active = p.bands.filter { abs($0.gainDB) >= 0.05 || $0.kind == .highPass || $0.kind == .lowPass }
        let secs = active.map { BiquadCoefficients($0.kind, freq: $0.freq, gainDB: $0.gainDB, q: $0.q, sampleRate: sampleRate) }
        let g = Float(pow(10, p.preampDB / 20))
        let byp = !p.enabled || (secs.isEmpty && abs(p.preampDB) < 0.01)
        os_unfair_lock_lock(&lock); pending = (secs, g, byp); os_unfair_lock_unlock(&lock)
    }

    /// Takes any new settings if the lock is free (never blocks the audio thread).
    private func adopt() {
        guard os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }
        guard let p = pending else { return }
        pending = nil
        if p.sections.count != sections.count { stateL = Array(repeating: BiquadState(), count: p.sections.count); stateR = stateL }
        sections = p.sections; gain = p.gain; bypass = p.bypass
    }

    public func takePeak() -> Float { let p = peak; peak = 0; return p }

    /// In-place on two channel buffers.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        adopt()
        var pk: Float = 0
        if bypass {
            for i in 0..<frames { pk = max(pk, abs(left[i]), abs(right[i])) }
            peak = max(peak, pk); return
        }
        for (k, c) in sections.enumerated() {
            var sl = stateL[k], sr = stateR[k]
            for i in 0..<frames {
                let xl = Double(left[i]), yl = c.b0 * xl + sl.z1
                sl.z1 = c.b1 * xl - c.a1 * yl + sl.z2; sl.z2 = c.b2 * xl - c.a2 * yl; left[i] = Float(yl)
                let xr = Double(right[i]), yr = c.b0 * xr + sr.z1
                sr.z1 = c.b1 * xr - c.a1 * yr + sr.z2; sr.z2 = c.b2 * xr - c.a2 * yr; right[i] = Float(yr)
            }
            stateL[k] = sl; stateR[k] = sr
        }
        for i in 0..<frames {
            left[i] = Self.softLimit(left[i] * gain); right[i] = Self.softLimit(right[i] * gain)
            pk = max(pk, abs(left[i]), abs(right[i]))
        }
        peak = max(peak, pk)
    }

    /// Transparent below 0.9, a smooth knee above it, never beyond 1.0.
    @inline(__always) static func softLimit(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 0.9 else { return x }
        let y = 0.9 + 0.1 * tanhf((a - 0.9) / 0.1)
        return x < 0 ? -y : y
    }
}

// MARK: Dynamics for the microphone chain

public struct GateSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var thresholdDB = -55.0
    public var attackMs = 3.0, releaseMs = 120.0
    public init() {}
}

public struct CompressorSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var thresholdDB = -20.0
    public var ratio = 3.0
    public var attackMs = 8.0, releaseMs = 150.0
    public var makeupDB = 3.0
    public init() {}
}

/// Noise gate then compressor on a mono signal; envelope followers, no lookahead (so no added latency).
public final class DynamicsProcessor: @unchecked Sendable {
    private let sr: Double
    private var gate = GateSettings(), comp = CompressorSettings()
    private var gEnv = 0.0, gGain = 1.0, cEnv = 0.0
    private var lock = os_unfair_lock()
    private var pending: (GateSettings, CompressorSettings)?

    public init(sampleRate: Double) { sr = sampleRate }

    public func update(gate: GateSettings, compressor: CompressorSettings) {
        os_unfair_lock_lock(&lock); pending = (gate, compressor); os_unfair_lock_unlock(&lock)
    }

    private func coef(_ ms: Double) -> Double { exp(-1.0 / (max(ms, 0.1) * 0.001 * sr)) }

    public func process(_ x: UnsafeMutablePointer<Float>, frames: Int) {
        if os_unfair_lock_trylock(&lock) { if let p = pending { gate = p.0; comp = p.1; pending = nil }; os_unfair_lock_unlock(&lock) }
        guard gate.enabled || comp.enabled else { return }
        let gA = coef(gate.attackMs), gR = coef(gate.releaseMs), cA = coef(comp.attackMs), cR = coef(comp.releaseMs)
        let thrG = pow(10, gate.thresholdDB / 20), makeup = pow(10, comp.makeupDB / 20)
        for i in 0..<frames {
            var s = Double(x[i]); let a = abs(s)
            if gate.enabled {
                gEnv = a > gEnv ? gA * gEnv + (1 - gA) * a : gR * gEnv + (1 - gR) * a
                let target = gEnv >= thrG ? 1.0 : 0.0
                gGain = target > gGain ? gA * gGain + (1 - gA) * target : gR * gGain + (1 - gR) * target
                s *= gGain
            }
            if comp.enabled {
                let l = abs(s)
                cEnv = l > cEnv ? cA * cEnv + (1 - cA) * l : cR * cEnv + (1 - cR) * l
                let dB = 20 * log10(max(cEnv, 1e-9))
                let over = dB - comp.thresholdDB
                let reductionDB = over > 0 ? over * (1 - 1 / max(comp.ratio, 1)) : 0
                s *= pow(10, -reductionDB / 20) * makeup
            }
            x[i] = EQProcessor.softLimit(Float(s))
        }
    }
}

// MARK: Output dynamics

/// Compressor and limiter for the system output. Basic by design: the compressor evens out loud and quiet parts, the
/// limiter stops peaks from clipping the speakers.
public struct OutputDynamicsSettings: Codable, Equatable, Sendable {
    public var compressor = CompressorSettings()
    public var limiterEnabled = false
    /// Highest level the limiter lets through.
    public var ceilingDB = -1.0
    public var limiterReleaseMs = 80.0
    public init() {}
    public var isActive: Bool { compressor.enabled || limiterEnabled }

    private enum CodingKeys: String, CodingKey { case compressor, limiterEnabled, ceilingDB, limiterReleaseMs }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        compressor = try c.decodeIfPresent(CompressorSettings.self, forKey: .compressor) ?? CompressorSettings()
        limiterEnabled = try c.decodeIfPresent(Bool.self, forKey: .limiterEnabled) ?? false
        ceilingDB = try c.decodeIfPresent(Double.self, forKey: .ceilingDB) ?? -1
        limiterReleaseMs = try c.decodeIfPresent(Double.self, forKey: .limiterReleaseMs) ?? 80
    }
}

/// Stereo-linked compressor followed by a peak limiter. One gain for both channels, so the stereo image does not move.
public final class StereoDynamics: @unchecked Sendable {
    private let sr: Double
    private var s = OutputDynamicsSettings()
    private var cEnv = 0.0, limGain = 1.0
    private var lock = os_unfair_lock()
    private var pending: OutputDynamicsSettings?

    public init(sampleRate: Double) { sr = sampleRate }

    public func update(_ settings: OutputDynamicsSettings) {
        os_unfair_lock_lock(&lock); pending = settings; os_unfair_lock_unlock(&lock)
    }

    private func coef(_ ms: Double) -> Double { exp(-1.0 / (max(ms, 0.1) * 0.001 * sr)) }

    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        if os_unfair_lock_trylock(&lock) { if let p = pending { s = p; pending = nil }; os_unfair_lock_unlock(&lock) }
        guard s.isActive else { cEnv = 0; limGain = 1; return }
        let comp = s.compressor
        let cA = coef(comp.attackMs), cR = coef(comp.releaseMs), lR = coef(s.limiterReleaseMs)
        let makeup = comp.enabled ? pow(10, comp.makeupDB / 20) : 1
        let ceiling = pow(10, s.ceilingDB / 20)
        for i in 0..<frames {
            var l = Double(left[i]), r = Double(right[i])
            if comp.enabled {
                let level = max(abs(l), abs(r))
                cEnv = level > cEnv ? cA * cEnv + (1 - cA) * level : cR * cEnv + (1 - cR) * level
                let over = 20 * log10(max(cEnv, 1e-9)) - comp.thresholdDB
                let reduction = over > 0 ? over * (1 - 1 / max(comp.ratio, 1)) : 0
                let g = pow(10, -reduction / 20) * makeup
                l *= g; r *= g
            }
            if s.limiterEnabled {
                let peak = max(abs(l), abs(r))
                let need = peak > ceiling ? ceiling / peak : 1
                // Instant attack so nothing overshoots; smooth release so it does not pump.
                limGain = need < limGain ? need : lR * limGain + (1 - lR) * need
                l *= limGain; r *= limGain
                l = min(max(l, -ceiling), ceiling); r = min(max(r, -ceiling), ceiling)
            }
            left[i] = Float(l); right[i] = Float(r)
        }
    }
}
