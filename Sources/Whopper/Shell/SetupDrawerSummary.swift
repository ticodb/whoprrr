import SwiftUI
import WhopperKit

/// Setup has its own full window. The drawer keeps a compact continuation surface
/// instead of embedding that window's fixed-width rail and overflowing the drawer.
struct SetupDrawerSummary: View {
    @ObservedObject private var setup = SetupController.shared

    var body: some View {
        SetupDrawerCard(title: title, detail: detail, primaryTitle: actionTitle,
                        permissions: setup.grants.map { ($0.title, setup.isGranted($0)) },
                        primary: {
                            if setup.tasteStarted { setup.finishTaste() }
                            else if let grant = setup.currentGrant { setup.beginCurrentGrant(grant) }
                            else if setup.step == .orderUp { setup.finishSetup() }
                            else if setup.step == .complete || setup.step == .permissions { setup.finishPermissionStep() }
                            else { setup.openWindow() }
                        },
                        later: setup.step == .complete ? { setup.leaveRenewal() } : nil)
    }

    private var title: String {
        if setup.tasteStarted { return setup.checking ? "Optional checks are running" : "Optional checks finished" }
        if setup.currentGrant != nil { return "Finish permissions" }
        if setup.step == .complete || setup.step == .permissions { return "Permissions are ready" }
        if setup.step == .orderUp { return "Your setup is ready" }
        return "Finish setup"
    }
    private var detail: String {
        if setup.tasteStarted { return "You can stop these checks and return to Whoprrr at any time." }
        if setup.currentGrant != nil { return "We’ll guide you through one permission at a time. Your settings are kept." }
        if setup.step == .complete || setup.step == .permissions { return "Continue to use your features. Diagnostic checks are optional." }
        return "Your recipes and settings are kept."
    }
    private var actionTitle: String {
        if setup.tasteStarted { return setup.checking ? "Stop checks and continue" : "Continue" }
        if let grant = setup.currentGrant { return "Set up \(grant.title)…" }
        if setup.step == .orderUp { return "Open Recipes" }
        if setup.step == .complete || setup.step == .permissions { return "Continue" }
        return "Open setup window"
    }
}

struct SetupDrawerCard: View {
    let title: String
    let detail: String
    let primaryTitle: String
    var permissions: [(String, Bool)] = []
    var primary: () -> Void = {}
    var later: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PanelHeader(title, symbol: "lock.shield", subtitle: detail)
            if !permissions.isEmpty {
                BrandCard {
                    ForEach(permissions.indices, id: \.self) { index in
                        HStack {
                            Text(permissions[index].0).font(Brand.headline)
                            Spacer()
                            StatusChip(text: permissions[index].1 ? "On" : "Needs access", tone: permissions[index].1 ? .good : .warn)
                        }
                    }
                }
            }
            HStack {
                Button(primaryTitle, action: primary).buttonStyle(.brand)
                if let later { Button("Later", action: later).buttonStyle(.brandPlain) }
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(Brand.violetBright)
    }
}
