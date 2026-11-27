import SwiftUI
import AppKit
import WhopperKit

/// Which grants are needed, by which feature, and which granted ones nothing needs any more.
struct PermissionsView: View {
    @EnvironmentObject var features: FeatureStore
    @ObservedObject private var setup = SetupController.shared
    private let checker: PermissionChecking = SetupPermissionChecker()
    @State private var statuses: [Permission: PermissionStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader("Permissions", symbol: "lock.shield", subtitle: "What each feature needs, and why")
            ForEach(listedPermissions) { p in
                BrandCard { row(p) }
            }
            Text("Whoprrr asks only for what your installed features need. Grants are listed, never requested, until you open the pane.")
                .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var listedPermissions: [Permission] {
        if #available(macOS 15.4, *) { return Permission.setupOrder }
        return Permission.setupOrder.filter { $0 != .paste }
    }

    private func row(_ p: Permission) -> some View {
        let current = setup.requirements(for: features.enabled)
        let users = p == .camera ? features.features(needing: p) : Feature.allCases.filter { current[$0]?.contains(p) == true }
        let parked = Set(setup.parkedFeatures.filter { setup.progress.parked[$0]?.grants.contains(p) == true })
        let findings = users.compactMap { setup.progress.findings[$0] }
        let failed = findings.first { $0.result == .notWorking && $0.grants.contains(p) }
        let checked = findings.contains { $0.result == .works }

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
                if failed != nil { StatusChip(text: TasteResult.notWorking.title, tone: .bad) }
                else if !parked.isEmpty { StatusChip(text: TasteResult.parked.title, tone: .warn) }
                else if checked && (status == .granted || status == .unknown) { StatusChip(text: TasteResult.works.title, tone: .good) }
                if !parked.isEmpty {
                    Button("Continue setup") { setup.continueParked(parked) }.buttonStyle(.brand)
                } else if !users.isEmpty && status != .granted && (!checked || status != .unknown) && p != .camera {
                    Button("Grant") { setup.guideGrant(p); refreshSoon() }.buttonStyle(.brand)
                }
                if p != .micDriver {
                    Button("Open pane") { NSWorkspace.shared.open(p.settingsURL) }.buttonStyle(.link).font(Brand.caption)
                }
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
