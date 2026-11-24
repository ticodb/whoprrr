import SwiftUI
import AppKit
import WhopperKit

/// Which grants are needed, by which feature, and which granted ones nothing needs any more.
struct PermissionsView: View {
    @EnvironmentObject var features: FeatureStore
    private let checker: PermissionChecking = LivePermissionChecker()
    @State private var statuses: [Permission: PermissionStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader("Permissions", symbol: "lock.shield", subtitle: "What each feature needs, and why")
            ForEach(Permission.allCases) { p in
                BrandCard { row(p) }
            }
            Text("Whoprrr asks only for what your installed features need. Grants are listed, never requested, until you open the pane.")
                .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func row(_ p: Permission) -> some View {
        let users = features.features(needing: p)
        let status = statuses[p] ?? .unknown
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(status, needed: !users.isEmpty))
                .foregroundStyle(color(status, needed: !users.isEmpty)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(Brand.display(15, .semibold))
                Text(users.isEmpty
                     ? (status == .granted ? "Granted, but no installed feature uses it. You can revoke it." : "Not needed by any installed feature.")
                     : "Used by \(users.map(\.title).joined(separator: ", ")). \(p.why)")
                    .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if status != .granted && !users.isEmpty && status != .unknown {
                    Button("Grant") { PermissionRequester.request(p); refreshSoon() }.buttonStyle(.brand)
                }
                Button("Open pane") { NSWorkspace.shared.open(p.settingsURL) }.buttonStyle(.link).font(Brand.caption)
            }
        }
    }

    private func icon(_ s: PermissionStatus, needed: Bool) -> String {
        switch s {
        case .granted: needed ? "checkmark.circle.fill" : "exclamationmark.circle"
        case .denied: needed ? "xmark.circle.fill" : "circle"
        case .notDetermined: "questionmark.circle"
        case .unknown: "circle.dashed"
        }
    }
    private func color(_ s: PermissionStatus, needed: Bool) -> Color {
        switch s {
        case .granted: needed ? .green : .orange
        case .denied: needed ? .red : .secondary
        default: .secondary
        }
    }

    private func refreshSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { refresh() } }

    private func refresh() {
        statuses = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, checker.status($0)) })
    }
}
