import SwiftUI
import WhopperKit

/// Shown in place of the app while this Mac has no valid pass. Plain words only: this is a key screen.
struct LicenseView: View {
    @ObservedObject var license = LicenseController.shared
    @State private var key = ""
    @State private var enteringKey = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            LogoMark(size: 64)
            if enteringKey || license.prefersManualKey { enterKey }
            else if case .expiredOffline = license.state { offline }
            else { orderPage }
        }
        .padding(40)
        .frame(maxWidth: 520)
        .onAppear { if !license.busy { license.resetManualKeyPreference() } }
        .frame(maxWidth: .infinity)
        .tint(Brand.violetBright)
    }

    private var orderPage: some View {
        Group {
            Text("One step left on this Mac").font(Brand.display(26, .semibold)).multilineTextAlignment(.center)
            Text(license.busy ? "Activating this Mac…" : "Press Activate this Mac on your order page.")
                .font(Brand.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let message = license.notice ?? message {
                Text(message).font(Brand.callout).foregroundStyle(Brand.accentText).multilineTextAlignment(.center)
            }
            HStack {
                Button("Open my order page", action: openOrderPage).buttonStyle(.brand)
                Button("Type my key instead") { enteringKey = true }.buttonStyle(.brandPlain)
            }.disabled(license.busy)
            Text("One key works on 3 Macs. Activation needs the internet once.")
                .font(Brand.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func openOrderPage() { NSWorkspace.shared.open(PersonalPage.url(server: license.server)) }

    private var enterKey: some View {
        Group {
            Text("Enter your key").font(Brand.display(26, .semibold))
            Text(message ?? "Your key is in your receipt email. It looks like WHOP-XXXX-XXXX-XXXX-XXXX.")
                .font(Brand.body).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            TextField("WHOP-XXXX-XXXX-XXXX-XXXX", text: $key)
                .textFieldStyle(.roundedBorder).font(.system(size: 16, design: .monospaced)).frame(maxWidth: 340)
                .focused($focused).onSubmit(activate).disabled(license.busy)
                .accessibilityLabel("Your key")
            if let n = license.notice {
                Text(n).font(Brand.callout).foregroundStyle(Brand.accentText).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button(license.busy ? "Checking…" : "Activate this Mac", action: activate).buttonStyle(.brand)
                    .disabled(license.busy || key.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Open my order page", action: openOrderPage).buttonStyle(.brandPlain)
            }
            Text("One key works on 3 Macs. Activation needs the internet once; after that Whoprrr works offline.")
                .font(Brand.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { focused = true }
    }

    private var offline: some View {
        Group {
            Text("Connect to the internet to keep Whoprrr unlocked").font(Brand.display(22, .semibold)).multilineTextAlignment(.center)
            Text("This Mac’s activation needs to be refreshed and the server could not be reached. Your settings are untouched.")
                .font(Brand.body).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button(license.busy ? "Trying…" : "Try again") { Task { await license.renewIfDue(force: true) } }.buttonStyle(.brand).disabled(license.busy)
        }
    }

    /// Why the key is being asked for, when there is a reason (the server's own words after a removal).
    private var message: String? { if case .needsKey(let m) = license.state { return m }; return nil }

    private func activate() {
        Task {
            await license.activate(key: key)
            if license.isLicensed { key = "" }
        }
    }
}

/// The menu-bar panel while there is no valid pass.
struct LicenseQuickView: View {
    @ObservedObject var license = LicenseController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) { LogoMark(size: 30); Wordmark(size: 20) }
            if case .expiredOffline = license.state {
                Text("Connect to the internet to keep Whoprrr unlocked.").font(Brand.body).fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await license.renewIfDue(force: true) } }.buttonStyle(.brand)
            } else {
                Text("This Mac is not activated yet.").font(Brand.body)
                Button("Activate this Mac…") { Shared.showWindow() }.buttonStyle(.brand)
            }
            Divider()
            Button("Quit Whoprrr") { NSApp.terminate(nil) }.buttonStyle(.plain).font(Brand.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 320)
        .tint(Brand.violetBright)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.94))
    }
}

struct HandoverNotice: View {
    @ObservedObject private var license = LicenseController.shared

    var body: some View {
        if let message = license.handoverNotice {
            BrandCard {
                HStack {
                    Label(message, systemImage: "checkmark.circle").font(Brand.body)
                    Spacer()
                    Button("Use a key instead") { license.showKeyEntry() }.buttonStyle(.brandQuiet)
                    Button("Dismiss") { license.handoverNotice = nil }.buttonStyle(.brandPlain)
                }
            }
        }
    }
}
