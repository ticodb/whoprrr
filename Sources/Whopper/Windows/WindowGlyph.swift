import SwiftUI
import WindowCore

/// The little picture for a layout: a screen with the target zone filled in, or a symbol for the non-zone actions.
struct WindowGlyph: View {
    var action: WindowAction
    var body: some View {
        switch action {
        case .leftHalf: ZoneGlyph(x: 0, width: 0.5)
        case .rightHalf: ZoneGlyph(x: 0.5, width: 0.5)
        case .topHalf: ZoneGlyph(x: 0, width: 1, y: 0, height: 0.5)
        case .bottomHalf: ZoneGlyph(x: 0, width: 1, y: 0.5, height: 0.5)
        case .topLeft: ZoneGlyph(x: 0, width: 0.5, y: 0, height: 0.5)
        case .topRight: ZoneGlyph(x: 0.5, width: 0.5, y: 0, height: 0.5)
        case .bottomLeft: ZoneGlyph(x: 0, width: 0.5, y: 0.5, height: 0.5)
        case .bottomRight: ZoneGlyph(x: 0.5, width: 0.5, y: 0.5, height: 0.5)
        case .firstThird: ZoneGlyph(x: 0, width: 1.0 / 3)
        case .centerThird: ZoneGlyph(x: 1.0 / 3, width: 1.0 / 3)
        case .lastThird: ZoneGlyph(x: 2.0 / 3, width: 1.0 / 3)
        case .firstTwoThirds: ZoneGlyph(x: 0, width: 2.0 / 3)
        case .lastTwoThirds: ZoneGlyph(x: 1.0 / 3, width: 2.0 / 3)
        case .maximize: ZoneGlyph(x: 0, width: 1)
        case .maximizeHeight: ZoneGlyph(x: 0.35, width: 0.3)
        case .center: ZoneGlyph(x: 0.25, width: 0.5, y: 0.2, height: 0.6)
        case .larger: Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 15))
        case .smaller: Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 15))
        case .nextDisplay: Image(systemName: "display.2").font(.system(size: 16))
        case .previousDisplay: Image(systemName: "display.2").font(.system(size: 16)).scaleEffect(x: -1)
        case .restore: Image(systemName: "arrow.uturn.backward").font(.system(size: 16))
        }
    }
}
