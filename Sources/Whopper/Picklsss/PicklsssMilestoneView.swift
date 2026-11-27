import SwiftUI
import WhopperKit

private enum BurgerPalette {
    static let bottomBun = Color(hex: 0xE8A23B)
    static let topBun = Color(hex: 0xF0AE45)
    static let patty = Color(hex: 0x7A3B1D)
    static let cheese = Color(hex: 0xFFC857)
    static let lettuce = Color(hex: 0x3FBF5F)
    static let pickle = Color(hex: 0x7BC043)
}

struct MilestoneBurger: View {
    var rank: CookRank?
    var pickles: Int
    var scale: CGFloat = 1
    var fallingLayer: CookRank?
    var fallingPickle = false
    var landed = true

    private struct Layer: Identifiable {
        let id: CookRank
        let bottom: CGFloat
        let width: CGFloat
        let height: CGFloat
        let corners: RectangleCornerRadii
        let color: Color
    }

    private let layers = [
        Layer(id: .dishwasher, bottom: 10, width: 104, height: 20,
              corners: .init(topLeading: 6, bottomLeading: 16, bottomTrailing: 16, topTrailing: 6), color: BurgerPalette.bottomBun),
        Layer(id: .prepCook, bottom: 32, width: 112, height: 17,
              corners: .init(topLeading: 9, bottomLeading: 9, bottomTrailing: 9, topTrailing: 9), color: BurgerPalette.patty),
        Layer(id: .lineCook, bottom: 47, width: 116, height: 8,
              corners: .init(topLeading: 3, bottomLeading: 3, bottomTrailing: 3, topTrailing: 3), color: BurgerPalette.cheese),
        Layer(id: .sousChef, bottom: 54, width: 120, height: 10,
              corners: .init(topLeading: 8, bottomLeading: 8, bottomTrailing: 8, topTrailing: 8), color: BurgerPalette.lettuce),
        Layer(id: .headChef, bottom: 64, width: 108, height: 40,
              corners: .init(topLeading: 54, bottomLeading: 8, bottomTrailing: 8, topTrailing: 54), color: BurgerPalette.topBun)
    ]

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.primary.opacity(0.20))
                .frame(width: 132 * scale, height: 8 * scale)
                .position(x: 66 * scale, y: 114 * scale)
            ForEach(layers) { layer in
                let earned = layer.id.rawValue <= (rank?.rawValue ?? 0)
                let falls = fallingLayer == layer.id && !landed
                let shape = UnevenRoundedRectangle(cornerRadii: scaledCorners(layer.corners), style: .continuous)
                Group {
                    if earned {
                        shape.fill(layer.color)
                    } else {
                        shape.strokeBorder(Color.primary.opacity(0.24), style: StrokeStyle(
                            lineWidth: max(1, 1.5 * scale), dash: [4 * scale, 3 * scale]))
                    }
                }
                .frame(width: layer.width * scale, height: layer.height * scale)
                .position(x: 66 * scale, y: (118 - layer.bottom - layer.height / 2) * scale)
                .offset(y: falls ? -64 * scale : 0)
                .opacity(falls ? 0 : 1)
            }
            let pickleCount = min(4, max(0, pickles))
            let pickleBase: [CGFloat] = [10, 30, 49, 55, 64, 104]
            ForEach(0..<pickleCount, id: \.self) { index in
                let newest = index == pickleCount - 1
                let falls = newest && fallingPickle && !landed
                let center = 66 + CGFloat(index % 3 - 1) * 30
                let base = pickleBase[rank?.rawValue ?? 0] + (index == 3 ? 8 : 0)
                Capsule()
                    .fill(BurgerPalette.pickle)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(Color.black.opacity(0.16))
                            .frame(height: 2 * scale).padding(.horizontal, 2 * scale)
                    }
                    .frame(width: 22 * scale, height: 9 * scale)
                    .position(x: center * scale, y: (118 - base - 4.5) * scale)
                    .offset(y: falls ? -38 * scale : 0)
                    .opacity(falls ? 0 : 1)
            }
        }
        .frame(width: 132 * scale, height: 122 * scale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Burger with \(rank?.rawValue ?? 0) of 5 layers and \(min(4, max(0, pickles))) pickles")
    }

    private func scaledCorners(_ radii: RectangleCornerRadii) -> RectangleCornerRadii {
        .init(topLeading: radii.topLeading * scale, bottomLeading: radii.bottomLeading * scale,
              bottomTrailing: radii.bottomTrailing * scale, topTrailing: radii.topTrailing * scale)
    }
}

/// An achievement can be seen over the page without moving focus or catching any input.
struct PicklsssMilestoneView: View {
    let milestone: PicklsssMilestone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = true
    @State private var folded = false

    var body: some View {
        VStack(spacing: 10) {
            MilestoneBurger(rank: milestone.rank, pickles: milestone.pickles, fallingLayer: milestone.introducedLayer,
                            fallingPickle: milestone.dropsPickle, landed: landed)
            Text(milestone.title).font(Brand.display(19, .semibold))
            Text(milestone.detail).font(Brand.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: 310)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Brand.violet.opacity(0.44)))
        .shadow(color: .black.opacity(0.17), radius: 12, y: 5)
        .scaleEffect(x: folded ? 0.86 : 1, y: folded ? 0.20 : 1, anchor: .top)
        .opacity(folded ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { AccessibilityNotification.Announcement("\(milestone.title). \(milestone.detail)").post() }
        .task(id: milestone.id) {
            guard !reduceMotion else { return }
            landed = false
            folded = false
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, !reduceMotion else { return }
            withAnimation(.spring(response: milestone.kind == .pickle ? 0.25 : 0.48, dampingFraction: 0.68)) {
                landed = true
            }
            try? await Task.sleep(for: .seconds(milestone.duration - 0.24))
            guard !Task.isCancelled, !reduceMotion else { return }
            withAnimation(.easeIn(duration: 0.20)) { folded = true }
        }
        .onChange(of: reduceMotion) { _, still in
            if still { landed = true; folded = false }
        }
    }
}
