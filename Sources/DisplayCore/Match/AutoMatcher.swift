import Foundation

/// Puts solid sRGB gray (0...1) on each display; nil = black. Real implementation: borderless windows.
public protocol PatchPresenter: AnyObject {
    func show(samsung: Double?, mac: Double?) async
    func finish() async
}

/// Latest frame from a camera that can see both screens.
public protocol FrameSource: AnyObject {
    func frame() async throws -> Frame
}

public struct MatchConfig: Sendable {
    public var gray = 0.5                   // sRGB level for measuring: bright enough to read, low enough not to clip
    public var maxIterations = 8
    public var settleSeconds = 1.2          // wait for panels and camera auto-exposure after a patch change
    public var framesPerMeasure = 3
    public var tolerance = MatchTolerance()
    public init() {}
}

public enum MatchError: Error, Equatable, CustomStringConvertible {
    case cannotLocate(String)
    case clipped
    case writeNotAccepted(Control)

    public var description: String {
        switch self {
        case .cannotLocate(let why): return "Could not find both screens in the camera view: \(why)"
        case .clipped: return "The camera image is overexposed. Move the phone back or dim the room light, then retry."
        case .writeNotAccepted(let c): return "\(c.label) write was not accepted by the monitor; stopped."
        }
    }
}

public struct MatchIteration: Sendable {
    public var index: Int
    public var eLuminance: Double, eRed: Double, eBlue: Double
    public var wrote: [Control: Int]
    public var line: String
}

public struct MatchReport: Sendable {
    public var iterations: [MatchIteration]
    public var converged: Bool
    public var limit: MatchProposal.Limit?
    /// Baseline and written values, so the same restore as presets can undo the match.
    public var apply: ApplyReport
}

/// Closed loop: locate both screens, show gray on both, measure, nudge the Samsung over DDC (every write
/// read back), repeat until the two agree or the loop gives up. Never touches the built-in display.
public final class AutoMatcher {
    let controller: DisplayController
    let target: DisplayTarget
    let presenter: PatchPresenter
    let camera: FrameSource
    let config: MatchConfig

    public init(controller: DisplayController, target: DisplayTarget, presenter: PatchPresenter,
                camera: FrameSource, config: MatchConfig = MatchConfig()) {
        self.controller = controller; self.target = target; self.presenter = presenter
        self.camera = camera; self.config = config
    }

    public func run(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> MatchReport {
        controller.log.record(.info, "auto match started")
        // Baseline for undo: tone group + brightness.
        var baseline: [Control: Int] = [:]
        var maxes: [Control: Int] = [:]
        for c in [Control.brightness, .colorPreset, .red, .green, .blue] {
            let v = try await controller.read(c, target: target)
            baseline[c] = v.current; maxes[c] = v.maximum
        }
        var fields: [Control: FieldResult] = [:]
        var iterations: [MatchIteration] = []
        var limit: MatchProposal.Limit?
        var converged = false

        do {
            let (sRegion, mRegion) = try await locate(progress)
            for i in 1...config.maxIterations {
                try Task.checkCancellation()
                progress("Measuring (round \(i))…")
                await presenter.show(samsung: config.gray, mac: config.gray)
                let (s, m) = try await measure(sRegion, mRegion)
                let cur = SamsungState(brightness: baseline[.brightness]!, maxBrightness: maxes[.brightness] ?? 100,
                                       red: baseline[.red]!, green: baseline[.green]!, blue: baseline[.blue]!, maxGain: maxes[.red] ?? 100)
                let state = try await currentState(fallback: cur, maxes: maxes)
                let p = MatchEngine.propose(samsung: s, mac: m, state: state, tolerance: config.tolerance)
                limit = p.limit
                var wrote: [Control: Int] = [:]
                var line = String(format: "round %d: Samsung vs MacBook  brightness %+.0f%%  red %+.0f%%  blue %+.0f%%", i, p.eLuminance * 100, p.eRed * 100, p.eBlue * 100)
                if p.converged {
                    converged = true
                    iterations.append(MatchIteration(index: i, eLuminance: p.eLuminance, eRed: p.eRed, eBlue: p.eBlue, wrote: [:], line: line + " — matched"))
                    progress(line + " — matched")
                    break
                }
                for (c, v, old) in [(Control.red, p.red, state.red), (.blue, p.blue, state.blue), (.green, p.green, state.green), (.brightness, p.brightness, state.brightness)] where v != old {
                    let o = try await controller.write(c, value: v, target: target)
                    fields[c] = FieldResult(control: c, status: .applied(o))
                    if !o.accepted { throw MatchError.writeNotAccepted(c) }
                    wrote[c] = o.readback ?? v
                }
                if !wrote.isEmpty {
                    line += " → " + wrote.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.label) \($0.value)" }.joined(separator: ", ")
                }
                iterations.append(MatchIteration(index: i, eLuminance: p.eLuminance, eRed: p.eRed, eBlue: p.eBlue, wrote: wrote, line: line))
                progress(line)
                if wrote.isEmpty { break }                  // nothing left to change (at a limit)
            }
        } catch {
            await presenter.finish()
            controller.log.record(.info, "auto match stopped: \(error)")
            throw error
        }
        await presenter.finish()
        controller.log.record(.info, "auto match finished, converged=\(converged)")
        let ordered = Control.allCases.compactMap { fields[$0] }
        return MatchReport(iterations: iterations, converged: converged, limit: converged ? nil : limit,
                           apply: ApplyReport(target: target, baseline: baseline, fields: ordered))
    }

    // MARK: Steps

    private func currentState(fallback: SamsungState, maxes: [Control: Int]) async throws -> SamsungState {
        var s = fallback
        s.brightness = try await controller.read(.brightness, target: target).current
        s.red = try await controller.read(.red, target: target).current
        s.green = try await controller.read(.green, target: target).current
        s.blue = try await controller.read(.blue, target: target).current
        return s
    }

    /// One screen lit at a time tells us which blob in the camera frame is which display.
    private func locate(_ progress: @Sendable (String) -> Void) async throws -> (Region, Region) {
        progress("Locating the Samsung…")
        await presenter.show(samsung: 1.0, mac: nil)
        try await settle()
        guard let s = FrameAnalyzer.brightestRegion(in: try await camera.frame()) else {
            throw MatchError.cannotLocate("no lit screen seen while the Samsung was white")
        }
        progress("Locating the MacBook…")
        await presenter.show(samsung: nil, mac: 1.0)
        try await settle()
        guard let m = FrameAnalyzer.brightestRegion(in: try await camera.frame()) else {
            throw MatchError.cannotLocate("no lit screen seen while the MacBook was white")
        }
        if s.overlapFraction(with: m) > 0.3 { throw MatchError.cannotLocate("both screens look like the same area; make sure both are in view") }
        return (s, m)
    }

    private func measure(_ sR: Region, _ mR: Region) async throws -> (RGB, RGB) {
        try await settle()
        var s = [RGB](), m = [RGB]()
        for k in 0..<config.framesPerMeasure {
            let f = try await camera.frame()
            let a = FrameAnalyzer.measure(f, region: sR), b = FrameAnalyzer.measure(f, region: mR)
            if a.peakEncoded > 0.96 || b.peakEncoded > 0.96 { throw MatchError.clipped }
            s.append(a.rgb); m.append(b.rgb)
            if k + 1 < config.framesPerMeasure, config.settleSeconds > 0 { try await Task.sleep(nanoseconds: 120_000_000) }
        }
        func avg(_ v: [RGB]) -> RGB { RGB(v.map(\.r).reduce(0, +) / Double(v.count), v.map(\.g).reduce(0, +) / Double(v.count), v.map(\.b).reduce(0, +) / Double(v.count)) }
        return (avg(s), avg(m))
    }

    private func settle() async throws {
        if config.settleSeconds > 0 { try await Task.sleep(nanoseconds: UInt64(config.settleSeconds * 1e9)) }
        try Task.checkCancellation()
    }
}
