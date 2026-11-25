import SwiftUI
import WhopperKit

/// Install only what you use. Uninstalled features are not loaded and never ask for permissions.
struct FeaturesHubView: View {
    @EnvironmentObject var features: FeatureStore
    @State private var login = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader("Features", symbol: "square.grid.2x2", subtitle: "Install only what you use")
            ForEach(Feature.allCases) { f in
                BrandCard {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: f.symbol).font(.system(size: 15, weight: .semibold)).frame(width: 24, height: 24)
                            .foregroundStyle(f.isBuilt ? Brand.glyph : Color.secondary)
                            .background(Brand.violet.opacity(f.isBuilt ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(Brand.display(15, .semibold))
                            Text(f.summary).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if f.isBuilt {
                            Toggle("", isOn: Binding(get: { features.isEnabled(f) }, set: { features.setEnabled(f, $0) }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.regular)
                        } else {
                            StatusChip(text: "Planned")
                        }
                    }
                }
            }
            if LoginItem.isAvailable {
                BrandCard {
                    Toggle("Open Whoprrr at login", isOn: Binding(get: { login }, set: { login = LoginItem.set($0) ? $0 : login })).font(Brand.display(15, .semibold))
                    Text("Needed for mic pinning and keep-alive to work after a restart.").font(Brand.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
