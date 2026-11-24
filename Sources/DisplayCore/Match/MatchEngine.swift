import Foundation

public struct SamsungState: Equatable, Sendable {
    public var brightness: Int, maxBrightness: Int
    public var red: Int, green: Int, blue: Int, maxGain: Int
    public init(brightness: Int, maxBrightness: Int, red: Int, green: Int, blue: Int, maxGain: Int) {
        self.brightness = brightness; self.maxBrightness = maxBrightness
        self.red = red; self.green = green; self.blue = blue; self.maxGain = maxGain
    }
}

public struct MatchTolerance: Sendable {
    public var chroma = 0.03        // R/G and B/G ratio error
    public var luminance = 0.05     // white luminance error
    public init() {}
}

public struct MatchProposal: Equatable, Sendable {
    /// Samsung relative to MacBook: 0.10 means 10 % too strong. Chroma errors are R/G and B/G ratios.
    public var eLuminance: Double, eRed: Double, eBlue: Double
    public var converged: Bool
    public var brightness: Int, red: Int, green: Int, blue: Int
    /// The Samsung cannot go any dimmer / brighter than needed.
    public var limit: Limit?
    public enum Limit: String, Sendable { case tooDim = "Samsung is at maximum brightness and still dimmer than the MacBook", tooBright = "Samsung is at minimum brightness and still brighter than the MacBook" }
}

/// Pure control step: compare what the camera saw on each screen, propose new Samsung settings.
/// Gain-to-light is modelled as ~gain^2.2 and backlight as linear; both steps are damped and the loop
/// repeats, so the model only has to be roughly right.
public enum MatchEngine {
    static let gamma = 2.2
    static let damping = 0.85

    public static func propose(samsung s: RGB, mac m: RGB, state: SamsungState, tolerance tol: MatchTolerance = MatchTolerance()) -> MatchProposal {
        let eR = (s.r / s.g) / (m.r / m.g) - 1
        let eB = (s.b / s.g) / (m.b / m.g) - 1
        let eY = s.luminance / m.luminance - 1
        let converged = abs(eR) < tol.chroma && abs(eB) < tol.chroma && abs(eY) < tol.luminance

        // Gains: green is the reference channel; scale red and blue toward the MacBook's balance.
        let k = damping / gamma
        var gR = Double(state.red) * pow(1 / (1 + eR), k)
        var gB = Double(state.blue) * pow(1 / (1 + eB), k)
        var gG = Double(state.green)
        let top = max(gR, gG, gB)
        if top > Double(state.maxGain) { let f = Double(state.maxGain) / top; gR *= f; gG *= f; gB *= f }
        func step(_ new: Double, old: Int, err: Double) -> Int {
            var n = Int(new.rounded())
            if abs(err) > tol.chroma && n == old { n += err > 0 ? -1 : 1 }      // always make progress
            return max(0, min(state.maxGain, n))
        }
        let nR = step(gR, old: state.red, err: eR), nB = step(gB, old: state.blue, err: eB)
        let nG = max(0, min(state.maxGain, Int(gG.rounded())))

        // Brightness: predict the luminance after the gain change, then correct the remainder.
        func f(_ new: Int, _ old: Int) -> Double { old > 0 ? pow(Double(new) / Double(old), gamma) : 1 }
        let wR = 0.2126 * s.r / max(s.luminance, 1e-9), wG = 0.7152 * s.g / max(s.luminance, 1e-9), wB = 0.0722 * s.b / max(s.luminance, 1e-9)
        let yScale = wR * f(nR, state.red) + wG * f(nG, state.green) + wB * f(nB, state.blue)
        let eYAfter = s.luminance * yScale / m.luminance - 1
        let wanted = Double(state.brightness) * pow(1 / (1 + eYAfter), damping)
        var nBright = Int(wanted.rounded())
        if abs(eYAfter) > tol.luminance && nBright == state.brightness { nBright += eYAfter > 0 ? -1 : 1 }
        var limit: MatchProposal.Limit?
        if wanted > Double(state.maxBrightness) + 0.5 { limit = .tooDim }
        if wanted < -0.5 { limit = .tooBright }
        nBright = max(0, min(state.maxBrightness, nBright))

        return MatchProposal(eLuminance: eY, eRed: eR, eBlue: eB, converged: converged,
                             brightness: nBright, red: nR, green: nG, blue: nB, limit: limit)
    }
}
