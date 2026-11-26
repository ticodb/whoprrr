import SwiftUI
import AppKit

/// Whoprrr's look: one violet, three signal colours, rounded type. The manual is docs/brand/brand-manual.html.
enum Brand {
    static let violet = Color(hex: 0x5B2BD8)
    static let violetBright = Color(hex: 0x7C4DFF)
    static let violetDeep = Color(hex: 0x221060)
    /// Icon tiles: the "on switch" violet as a solid fill with a white glyph, so they match the buttons and never read as dimmed.
    static let tile = violetBright
    static let patty = Color(hex: 0xFF4F81)
    static let bun = Color(hex: 0xFFC857)
    static let seed = Color(hex: 0xFFF0B8)
    static let red = Color(hex: 0xFF3B4A)
    static let green = Color(hex: 0x2EE66B)
    static let blue = Color(hex: 0x4DA3FF)
    static let rgb: [Color] = [red, green, blue]

    /// Accent for text and icons on the panel background: deeper violet on light, lighter on dark, so small text keeps 4.5:1.
    static let accentText = Color.dynamic(light: 0x5B2BD8, dark: 0xA98BFF)

    static var gradient: LinearGradient {
        LinearGradient(colors: [violet, violetDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Type scale (points). Nothing in the interface is smaller than caption2.
    static let caption2 = Font.system(size: 12)
    static let caption = Font.system(size: 13)
    static let subheadline = Font.system(size: 14)
    static let callout = Font.system(size: 14.5)
    static let body = Font.system(size: 15)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let title3 = Font.system(size: 17, weight: .semibold)
    static let title2 = Font.system(size: 20, weight: .semibold)
    static let title = Font.system(size: 24, weight: .semibold)

    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight, design: .rounded) }
}

extension Color {
    /// A colour that follows the system appearance.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let h = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        })
    }
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: Logo

/// The Whoprrr burger: bun, a row of RGB subpixels, a waveform patty, bun. Same geometry as docs/brand/assets/whoprrr-icon.svg.
struct LogoMark: View {
    var size: CGFloat
    var withBackground = true

    static let bars: [CGFloat] = [4, 7, 10, 7, 12, 8, 11, 13, 11, 8, 12, 7, 10, 7, 4]

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 100
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            if withBackground {
                let r = RoundedRectangle(cornerRadius: 22.5 * s, style: .continuous).path(in: CGRect(origin: .zero, size: sz))
                ctx.fill(r, with: .linearGradient(Gradient(colors: [Brand.violet, Brand.violetDeep]), startPoint: .zero, endPoint: CGPoint(x: sz.width, y: sz.height)))
            }
            // Burger sits 10.5% larger than the 76-wide drawing so it fills the square.
            let k: CGFloat = withBackground ? 1.105 : 1.31
            let t = CGAffineTransform(translationX: 50 * s, y: 50 * s).scaledBy(x: k, y: k).translatedBy(x: -50 * s, y: -50 * s)
            func T(_ p: Path) -> Path { p.applying(t) }

            var top = Path()
            top.move(to: pt(12, 43)); top.addCurve(to: pt(50, 17), control1: pt(12, 27), control2: pt(28, 17))
            top.addCurve(to: pt(88, 43), control1: pt(72, 17), control2: pt(88, 27)); top.closeSubpath()
            ctx.fill(T(top), with: .color(Brand.bun))

            for (x, y, r) in [(28.0, 33.0, -25.0), (39, 26.5, -12), (50, 24, 0), (61, 26.5, 12), (72, 33, 25), (33, 38.5, -8), (44, 35, -4), (56, 35, 4), (67, 38.5, 8)] {
                let e = Path(ellipseIn: CGRect(x: -3.2 * s, y: -1.7 * s, width: 6.4 * s, height: 3.4 * s))
                    .applying(CGAffineTransform(rotationAngle: r * .pi / 180)).applying(CGAffineTransform(translationX: x * s, y: y * s))
                ctx.fill(T(e), with: .color(Brand.seed))
            }

            let w = 4.8, pitch = (76 - w) / 11
            for i in 0..<12 {
                let rect = CGRect(x: (12 + Double(i) * pitch) * s, y: 46 * s, width: w * s, height: 9 * s)
                ctx.fill(T(Path(roundedRect: rect, cornerRadius: 1.6 * s)), with: .color(Brand.rgb[i % 3]))
            }

            for (i, h) in Self.bars.enumerated() {
                let rect = CGRect(x: (13.2 + CGFloat(i) * 5) * s, y: (64 - h / 2) * s, width: 3.6 * s, height: h * s)
                ctx.fill(T(Path(roundedRect: rect, cornerRadius: 1.8 * s)), with: .color(Brand.patty))
            }

            var bottom = Path()
            bottom.move(to: pt(14, 74)); bottom.addLine(to: pt(86, 74)); bottom.addLine(to: pt(86, 76))
            bottom.addCurve(to: pt(77, 83), control1: pt(86, 81), control2: pt(82, 83)); bottom.addLine(to: pt(23, 83))
            bottom.addCurve(to: pt(14, 76), control1: pt(18, 83), control2: pt(14, 81)); bottom.closeSubpath()
            ctx.fill(T(bottom), with: .color(Brand.bun))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Whoprrr")
    }
}

/// "Whoprrr" with the rrr split into red and blue, like a mis-registered screen.
struct Wordmark: View {
    var size: CGFloat = 20
    var body: some View {
        HStack(spacing: 0) {
            Text("Whop").foregroundStyle(.primary)
            Text("rrr").foregroundStyle(Brand.violetBright)
                .shadow(color: Brand.red.opacity(0.55), radius: 0, x: size * 0.07, y: 0)
                .shadow(color: Brand.blue.opacity(0.6), radius: 0, x: -size * 0.07, y: 0)
        }
        .font(Brand.display(size, .heavy)).kerning(-size * 0.03)
        .accessibilityLabel("Whoprrr")
    }
}

// MARK: Building blocks

struct SectionLabel: View {
    var text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 12, weight: .semibold, design: .rounded)).tracking(0.9).foregroundStyle(.secondary)
    }
}

/// Icon tile + title for the top of each feature panel.
struct PanelHeader<Trailing: View>: View {
    var symbol: String
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, symbol: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title; self.symbol = symbol; self.subtitle = subtitle; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(Brand.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Brand.display(19, .semibold))
                if let subtitle { Text(subtitle).font(Brand.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

struct BrandCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.11)))
    }
}

struct StatusChip: View {
    enum Tone { case good, warn, bad, neutral
        var color: Color { switch self { case .good: Color(hex: 0x1FB955); case .warn: Color(hex: 0xE08A00); case .bad: Brand.red; case .neutral: .secondary } }
        /// Text colour with enough contrast on the tinted chip, in both appearances.
        var text: Color {
            switch self {
            case .good: .dynamic(light: 0x0F7D37, dark: 0x4ADE80)
            case .warn: .dynamic(light: 0x9A5B00, dark: 0xF2B450)
            case .bad: .dynamic(light: 0xD0222F, dark: 0xFF7A84)
            case .neutral: .secondary
            }
        }
    }
    var text: String
    var tone: Tone = .neutral
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone.color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 13, weight: .medium, design: .rounded))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tone.color.opacity(0.12), in: Capsule())
        .foregroundStyle(tone.text)
    }
}

struct BrandButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .padding(.horizontal, 13).padding(.vertical, 6)
            .foregroundStyle(kind == .plain ? Color.primary : Color.white)
            // Primary is the deeper violet, quiet is the "on switch" violet: both solid with white text, so neither reads as dimmed.
            // Plain is for the ways out of a step (Back, Not now, Cancel): neutral, so the step's own action is the one that stands out.
            .background(kind == .plain ? AnyShapeStyle(Color.primary.opacity(0.12)) : AnyShapeStyle(kind == .primary ? Brand.violet : Brand.violetBright), in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}
extension ButtonStyle where Self == BrandButtonStyle {
    static var brand: BrandButtonStyle { BrandButtonStyle(kind: .primary) }
    static var brandQuiet: BrandButtonStyle { BrandButtonStyle(kind: .secondary) }
    static var brandPlain: BrandButtonStyle { BrandButtonStyle(kind: .plain) }
}

/// Takes its content's height up to `maxHeight`, then scrolls. (A ScrollView proposed no height reports its content size.)
struct AutoScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        if snapshotMode { content() } else {
            ScrollView(.vertical, showsIndicators: false) { content() }.frame(maxHeight: maxHeight)
        }
    }
}

private let snapshotMode = ProcessInfo.processInfo.environment["SDC_SNAPSHOT"] != nil

/// A tooltip drawn by SwiftUI. The system `.help` tooltip often never appears in a menu-bar panel (it is not the key
/// window), so controls there use this instead. It shows after a short hover and sits above the view.
struct HoverTip: ViewModifier {
    var text: String
    var anchor: Alignment = .top
    @State private var show = false
    @State private var pending: Task<Void, Never>?
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    pending = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if !Task.isCancelled { withAnimation(.easeOut(duration: 0.12)) { show = true } }
                    }
                } else { show = false }
            }
            .overlay(alignment: anchor) {
                if show {
                    Text(text).font(Brand.caption.weight(.medium)).foregroundStyle(.white).lineLimit(1).fixedSize()
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
                        .offset(y: -32)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .zIndex(show ? 1 : 0)
    }
}
extension View {
    func hoverTip(_ text: String, anchor: Alignment = .top) -> some View { modifier(HoverTip(text: text, anchor: anchor)) }
}
