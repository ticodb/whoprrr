import AppKit
import SwiftUI
import DisplayCore

/// Exact sRGB test fields, drawn with explicit sRGB colors so macOS color management maps each
/// display's own profile. Standard, movable, resizable windows (not full screen) so the user can
/// drag them and compare against the other panel side by side.
enum Pattern {
    /// Grayscale ramp as sRGB 8-bit codes, 0 to 255 in 11 steps (0, 10, ... 100 %).
    static let steps: [Double] = (0...10).map { Double($0) / 10.0 }
    static let neutralGray = 128.0 / 255.0     // sRGB 128 mid gray
    static let darkGray = 64.0 / 255.0
}

struct PatternView: View {
    func srgb(_ v: Double) -> Color { Color(.sRGB, red: v, green: v, blue: v, opacity: 1) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                srgb(1.0).overlay(label("sRGB 255 white", dark: true))
                srgb(Pattern.neutralGray).overlay(label("sRGB 128 neutral gray", dark: true))
                srgb(Pattern.darkGray).overlay(label("sRGB 64", dark: false))
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 0) {
                ForEach(Array(Pattern.steps.enumerated()), id: \.offset) { i, v in
                    srgb(v).overlay(Text("\(i * 10)").font(Brand.caption2.monospacedDigit())
                        .foregroundColor(v > 0.5 ? .black : .white).padding(.bottom, 6), alignment: .bottom)
                }
            }
            .frame(height: 120)
        }
        .background(Color.black)
    }
    func label(_ s: String, dark: Bool) -> some View {
        Text(s).font(Brand.callout.weight(.medium)).foregroundColor(dark ? .black.opacity(0.7) : .white.opacity(0.8))
    }
}

@MainActor
final class PatternWindows {
    private var windows: [NSWindow] = []

    /// One window per requested CGDirectDisplayID; returns how many screens were found.
    @discardableResult
    func open(on displayIDs: [UInt32]) -> Int {
        close()
        var opened = 0
        for id in displayIDs {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }) else { continue }
            let size = NSSize(width: min(900, screen.visibleFrame.width * 0.6), height: min(560, screen.visibleFrame.height * 0.6))
            let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
            let w = NSWindow(contentRect: NSRect(origin: origin, size: size),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false, screen: screen)
            w.title = "Test pattern — \(screen.localizedName)"
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = false
            w.contentView = NSHostingView(rootView: PatternView())
            w.setFrame(NSRect(origin: origin, size: size), display: true)
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
            opened += 1
        }
        NSApp.activate(ignoringOtherApps: true)
        return opened
    }

    func close() { windows.forEach { $0.close() }; windows.removeAll() }
    var isOpen: Bool { windows.contains { $0.isVisible } }
}
