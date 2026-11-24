import AppKit

/// Menu-bar glyph: domed bun, a dashed "signal" line, a waveform patty, bottom bun. One colour, so macOS tints it for
/// light and dark menu bars. Same geometry as docs/brand/assets/whoprrr-glyph.svg (24-unit grid, drawn at 0.75).
enum MenuBarIcon {
    static func make() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let s: CGFloat = 0.75
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
            NSColor.black.setFill()

            let top = NSBezierPath()
            top.move(to: p(1.8, 9.2)); top.curve(to: p(12, 2.8), controlPoint1: p(1.8, 5), controlPoint2: p(6, 2.8))
            top.curve(to: p(22.2, 9.2), controlPoint1: p(18, 2.8), controlPoint2: p(22.2, 5)); top.close(); top.fill()

            // Signal line: six chunky dashes.
            let dash: CGFloat = 2.6, gap: CGFloat = 0.64
            for i in 0..<6 {
                let x = 2.6 + CGFloat(i) * (dash + gap)
                NSBezierPath(roundedRect: NSRect(x: x * s, y: 10.15 * s, width: dash * s, height: 1.5 * s), xRadius: 0.5 * s, yRadius: 0.5 * s).fill()
            }

            // Waveform patty: nine mirrored bars.
            let heights: [CGFloat] = [2, 3.5, 5, 3.2, 5.6, 3.2, 5, 3.5, 2]
            let w: CGFloat = 1.6, pitch: CGFloat = 2.2
            let x0 = (24 - (8 * pitch + w)) / 2
            for (i, h) in heights.enumerated() {
                NSBezierPath(roundedRect: NSRect(x: (x0 + CGFloat(i) * pitch) * s, y: (15.4 - h / 2) * s, width: w * s, height: h * s),
                             xRadius: 0.8 * s, yRadius: 0.8 * s).fill()
            }

            NSBezierPath(roundedRect: NSRect(x: 2.6 * s, y: 19.5 * s, width: 18.8 * s, height: 2.3 * s), xRadius: 1.15 * s, yRadius: 1.15 * s).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Whoprrr"
        return img
    }
}
