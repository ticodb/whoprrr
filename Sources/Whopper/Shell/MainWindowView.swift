import SwiftUI
import AppKit
import WhopperKit

/// The app proper: a sidebar of features and a roomy page for each. Setup, rule editing and every setting live here;
/// the menu-bar panel (QuickView) is only for glancing and quick actions.
struct MainWindowView: View {
    @EnvironmentObject var features: FeatureStore
    @EnvironmentObject var input: InputController
    @EnvironmentObject var nav: WindowNav
    @State private var missing = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 232)
            Divider()
            ScrollView {
                PageContent(page: nav.page)
                    .padding(28)
                    .frame(maxWidth: 680, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .tint(Brand.violetBright)
        .onChange(of: features.enabled) { _, _ in
            if case .feature(let f) = nav.page, !features.isEnabled(f) { nav.page = .features }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                LogoMark(size: 40).shadow(color: Brand.violetDeep.opacity(0.35), radius: 4, y: 2)
                Wordmark(size: 24)
                if AppInfo.isBeta { Text("BETA").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(0.8).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Brand.violet.opacity(0.2), in: Capsule()).foregroundStyle(Brand.accentText) }
            }
            .padding(.bottom, 14)
            row(.recipes, symbol: "fork.knife", title: "Recipes").padding(.bottom, 8)
            SectionLabel("Features").padding(.leading, 10).padding(.bottom, 2)
            ForEach(features.enabledInOrder) { f in row(.feature(f), symbol: f.symbol, title: f.shortTitle) }
            Spacer(minLength: 12)
            SectionLabel("Whoprrr").padding(.leading, 10).padding(.bottom, 2)
            row(.features, symbol: "square.grid.2x2", title: "Features")
            row(.permissions, symbol: "lock.shield", title: "Permissions")
            row(.about, symbol: "info.circle", title: "About")
            HStack { overallStatus; Spacer() }.padding(.top, 10).padding(.horizontal, 6)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035))
    }

    @ViewBuilder private var overallStatus: some View {
        switch input.status {
        case .needsAccessibility, .needsInputMonitoring: StatusChip(text: "Needs permission", tone: .warn)
        case .paused: StatusChip(text: "Remap paused", tone: .warn)
        case .failed: StatusChip(text: "Remap failed", tone: .bad)
        default: StatusChip(text: "\(features.enabledInOrder.count) features on", tone: .good)
        }
    }

    private func row(_ p: AppPage, symbol: String, title: String) -> some View {
        let on = nav.page == p
        return Button { nav.page = p } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 24)
                Text(title).font(.system(size: 15, weight: on ? .semibold : .regular, design: .rounded)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundStyle(on ? Brand.accentText : Color.primary)
            .background(on ? AnyShapeStyle(Brand.violet.opacity(0.16)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
