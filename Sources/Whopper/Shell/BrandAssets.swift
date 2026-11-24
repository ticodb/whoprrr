import SwiftUI
import AppKit

/// Renders the app icon and logo PNGs straight from the SwiftUI artwork, so the shipped icon and the in-app logo cannot drift apart.
@MainActor
enum BrandAssets {
    static func render(to dir: String) {
        let fm = FileManager.default
        let set = dir + "/AppIcon.iconset"
        try? fm.removeItem(atPath: set)
        try? fm.createDirectory(atPath: set, withIntermediateDirectories: true)

        // macOS icon grid: the plate is 80.5% of the canvas, with a soft shadow in the margin.
        func plate(_ px: CGFloat) -> some View {
            LogoMark(size: px * 0.805)
                .shadow(color: .black.opacity(0.3), radius: px * 0.014, y: px * 0.012)
                .frame(width: px, height: px)
        }
        let sizes: [(String, CGFloat)] = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
                                          ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
        for (name, px) in sizes { write(plate(px), px: px, to: "\(set)/\(name).png") }

        write(LogoMark(size: 1024), px: 1024, to: dir + "/whoprrr-icon-1024.png")
        write(LogoMark(size: 512, withBackground: false), px: 512, to: dir + "/whoprrr-logo-512.png")
        writeGlyph(to: dir + "/whoprrr-glyph@4x.png")

        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", set, "-o", dir + "/AppIcon.icns"]
        try? p.run(); p.waitUntilExit()
    }

    private static func write<V: View>(_ view: V, px: CGFloat, to path: String) {
        let r = ImageRenderer(content: view)
        r.scale = 1; r.proposedSize = .init(width: px, height: px)
        guard let cg = r.cgImage else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// The menu-bar glyph at 4x (72 px), black on clear, as a template would be.
    private static func writeGlyph(to path: String) {
        let img = MenuBarIcon.make()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
