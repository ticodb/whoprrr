import Foundation

/// Linear-light RGB (0...1 per channel), as the camera saw it.
public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    /// Rec. 709 luminance of linear RGB.
    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

/// One camera frame, 8-bit BGRA, gamma-encoded as cameras deliver it.
public struct Frame: Sendable {
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    public var bgra: [UInt8]
    public init(width: Int, height: Int, bytesPerRow: Int? = nil, bgra: [UInt8]) {
        self.width = width; self.height = height; self.bytesPerRow = bytesPerRow ?? width * 4; self.bgra = bgra
    }
}

public struct Region: Equatable, Sendable {
    public var x0: Int, y0: Int, x1: Int, y1: Int          // x1/y1 exclusive
    public init(x0: Int, y0: Int, x1: Int, y1: Int) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
    public var area: Int { max(0, x1 - x0) * max(0, y1 - y0) }
    public func overlapFraction(with o: Region) -> Double {
        let w = max(0, min(x1, o.x1) - max(x0, o.x0)), h = max(0, min(y1, o.y1) - max(y0, o.y0))
        let inter = Double(w * h)
        return inter / Double(max(1, min(area, o.area)))
    }
}

public enum FrameAnalyzer {
    /// sRGB transfer function inverse, as a 256-entry table. Approximates the camera's encoding well
    /// enough for ratios between two screens in the same frame.
    static let linear: [Double] = (0..<256).map { i in
        let c = Double(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// The largest bright connected area (a lit screen). Works on a coarse grid so it is fast and ignores
    /// pixel noise. Returns nil when nothing is clearly lit.
    public static func brightestRegion(in f: Frame) -> Region? {
        let cell = max(2, min(f.width, f.height) / 80)
        let gw = f.width / cell, gh = f.height / cell
        guard gw > 2, gh > 2 else { return nil }
        var grid = [Double](repeating: 0, count: gw * gh)
        var maxL = 0.0
        for gy in 0..<gh { for gx in 0..<gw {
            var sum = 0.0, n = 0.0
            var y = gy * cell
            while y < (gy + 1) * cell { var x = gx * cell
                while x < (gx + 1) * cell {
                    let o = y * f.bytesPerRow + x * 4
                    sum += 0.114 * Double(f.bgra[o]) + 0.587 * Double(f.bgra[o + 1]) + 0.299 * Double(f.bgra[o + 2]); n += 1
                    x += 2 }
                y += 2 }
            let l = sum / max(n, 1); grid[gy * gw + gx] = l; maxL = max(maxL, l)
        } }
        guard maxL > 40 else { return nil }
        let thr = maxL * 0.5
        var seen = [Bool](repeating: false, count: grid.count)
        var best: (area: Int, x0: Int, y0: Int, x1: Int, y1: Int)?
        for start in 0..<grid.count where !seen[start] && grid[start] >= thr {
            var stack = [start]; seen[start] = true
            var area = 0, x0 = gw, y0 = gh, x1 = 0, y1 = 0
            while let i = stack.popLast() {
                let x = i % gw, y = i / gw
                area += 1; x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < gw && ny < gh {
                    let j = ny * gw + nx
                    if !seen[j] && grid[j] >= thr { seen[j] = true; stack.append(j) }
                }
            }
            if best == nil || area > best!.area { best = (area, x0, y0, x1, y1) }
        }
        guard let b = best, Double(b.area) / Double(grid.count) > 0.005 else { return nil }
        return Region(x0: b.x0 * cell, y0: b.y0 * cell, x1: min(b.x1 * cell, f.width), y1: min(b.y1 * cell, f.height))
    }

    /// Mean linear RGB of the inner part of a region (edges and bezel glare excluded), plus the mean
    /// encoded value of the brightest channel so callers can detect clipping.
    public static func measure(_ f: Frame, region r: Region, inset: Double = 0.25) -> (rgb: RGB, peakEncoded: Double) {
        let ix = Int(Double(r.x1 - r.x0) * inset), iy = Int(Double(r.y1 - r.y0) * inset)
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0, pr = 0.0, pg = 0.0, pb = 0.0
        var y = r.y0 + iy
        while y < r.y1 - iy {
            var x = r.x0 + ix
            while x < r.x1 - ix {
                let o = y * f.bytesPerRow + x * 4
                let b = Int(f.bgra[o]), g = Int(f.bgra[o + 1]), rr = Int(f.bgra[o + 2])
                sb += linear[b]; sg += linear[g]; sr += linear[rr]
                pb += Double(b); pg += Double(g); pr += Double(rr); n += 1
                x += 2
            }
            y += 2
        }
        guard n > 0 else { return (RGB(0, 0, 0), 0) }
        return (RGB(sr / n, sg / n, sb / n), max(pr, pg, pb) / n / 255)
    }
}
