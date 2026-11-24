import CoreGraphics

/// Where the main window goes when it is opened from the menu-bar drawer: beside it, top edges aligned, never off screen.
/// Coordinates are AppKit's (origin bottom-left).
public enum PanelPlacement {
    public static func frame(beside drawer: CGRect, size: CGSize, visible: CGRect, gap: CGFloat = 8) -> CGRect {
        let w = min(size.width, visible.width)
        // As tall as wanted, but not taller than the room under the drawer's top edge.
        let h = min(size.height, max(drawer.maxY - visible.minY, 200), visible.height)
        // Left of the drawer if it fits; otherwise flush with the left screen edge (the window then overlaps the drawer, which is fine).
        var x = drawer.minX - gap - w
        if x < visible.minX {
            // Not enough room on the left: try the right of the drawer, else the left edge.
            let right = drawer.maxX + gap
            x = right + w <= visible.maxX ? right : visible.minX
        }
        let y = min(max(drawer.maxY - h, visible.minY), visible.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
