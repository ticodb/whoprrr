import SwiftUI
import WhopperKit

/// What this Mac's order includes, what can be added, how many devices are in use, and the one privacy switch of the shelf.
/// Every menu name sits beside its plain meaning. Buying always opens the buyer's page in the browser: the app never handles cards.
struct ExtrasView: View {
    @ObservedObject private var c = PicklsssController.shared
    @ObservedObject private var license = LicenseController.shared
    @State private var key = ""
    @State private var enteringKey = false

    private var pass: LicensePass? { license.currentPass }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader("Extras", symbol: "plus.rectangle.on.rectangle", subtitle: "Your order and what can be added to it")
            if c.awaitingPurchase && !license.hasPicklsss { waiting }
            if c.checkStatus == .found {
                HStack(spacing: 8) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text("Found your order. Picklsss (setups other people shared) is on.").font(Brand.subheadline); Spacer(minLength: 0) }
                    .padding(12).background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            SectionLabel("Yours")
            BrandCard { ForEach(Array(owned.enumerated()), id: \.offset) { i, r in
                row(r.0, r.1, trailing: AnyView(StatusChip(text: "Yours", tone: .good).fixedSize()))
                if i < owned.count - 1 { Divider() }
            } }
            if !addable.isEmpty {
                SectionLabel("Add to your order").padding(.top, 4)
                BrandCard { ForEach(Array(addable.enumerated()), id: \.offset) { i, r in
                    row(r.title, r.detail, trailing: r.available ? AnyView(Button("Add") { c.openPersonalPage() }.buttonStyle(.brandQuiet).accessibilityLabel("Add \(r.title)")) : AnyView(StatusChip(text: "Not yet", tone: .neutral).fixedSize()))
                    if i < addable.count - 1 { Divider() }
                } }
            }
            if !license.hasPicklsss { alreadyPaid }
            SectionLabel("Devices").padding(.top, 4)
            BrandCard {
                Text(deviceLine).font(Brand.subheadline).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Manage devices") { c.openPersonalPage() }.buttonStyle(.brandQuiet)
                    Button("I have a key") { enteringKey.toggle() }.buttonStyle(.brandQuiet)
                }
                if enteringKey { keyEntry }
            }
            SectionLabel("Count what you keep").padding(.top, 4)
            BrandCard {
                Toggle(isOn: Binding(get: { c.countChoice == .yes }, set: { c.setCount($0 ? .yes : .no) })) {
                    Text("Tell the shelf, 7 days after I take a picklsss, whether I kept it").font(Brand.headline)
                }.toggleStyle(.switch)
                Text(c.countChoice == .unasked ? "Not asked yet. You are asked once, the first time you take a picklsss. Taking works the same either way." : "Your answer is private. Taking works the same either way.")
                    .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Cooks earn their rank from people who keep their picklsss. When this is on, Whoprrr works out on this Mac whether you kept one, and sends the shelf one yes or no with a take code: never your settings, your gear or anything else. A picklsss counts as kept when, on day 7, it is still among your recipes and was the active recipe on at least 3 different days.")
                    .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await c.refreshMine() }
    }

    // MARK: What is owned, what can be added

    private var owned: [(String, String)] {
        var out: [(String, String)] = []
        let place = license.stored.slot.flatMap { s in license.stored.of.map { "This Mac is Mac \(s) of \($0)" } }
        if pass?.mac == true && pass?.tv == true { out.append(("The Combo", "Whoprrr for Mac and Whoprrr TV together" + (place.map { " · \($0)" } ?? ""))) }
        else if pass?.mac == true { out.append(("Whoprrr for Mac", place ?? "Activated on this Mac")) }
        else if license.skipped { out.append(("Development build", "The key check is skipped")) }
        out.append(("Free refills", "Every update, at no cost"))
        if license.hasPicklsss { out.append(("Picklsss", "Setups other people shared, fitted to your gear")) }
        return out
    }

    private struct Add { var title: String; var detail: String; var available: Bool }
    private var addable: [Add] {
        var out: [Add] = []
        if pass?.tv != true && pass?.mac == true { out.append(Add(title: "The Combo", detail: "Whoprrr for Mac and Whoprrr TV together", available: true)) }
        out.append(Add(title: "Frrries", detail: "4 more devices, Macs or TVs in any mix · $4", available: true))
        if !license.hasPicklsss { out.append(Add(title: "Picklsss", detail: "Setups other people shared, fitted to your gear · $4, paid once · free if a picklsss you share is accepted", available: true)) }
        out.append(Add(title: "Cookboook", detail: "Later: a curated edition, vetted setups matched to your gear automatically. Free if you bought Picklsss (setups other people shared) before it arrives.", available: false))
        return out
    }

    private var deviceLine: String {
        if let s = license.stored.slot, let o = license.stored.of { return "This Mac is Mac \(s) of \(o) on your order. Removing a device you no longer use frees its place at once; that is done on your page in the browser." }
        return license.skipped ? "Development build: no key is used." : "Your order allows up to 3 devices. Removing one you no longer use is done on your page in the browser."
    }

    private func row(_ title: String, _ detail: String, trailing: AnyView) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Brand.headline)
                Text(detail).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
    }

    // MARK: Paid, but not unlocked yet

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finish in your browser").font(Brand.display(15, .semibold))
            Text("whoprrr.app opened in your browser. Pay there; this window updates by itself when you come back.").font(Brand.subheadline).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open it again") { c.openPersonalPage() }.buttonStyle(.brandQuiet)
                Button("Cancel") { c.stopWaiting() }.buttonStyle(.brandQuiet)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.violet.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.violetBright.opacity(0.4)))
    }

    private var alreadyPaid: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Already paid?").font(Brand.subheadline)
                Button(c.checkStatus == .checking ? "Checking…" : "Check now") { Task { await c.checkNow() } }.buttonStyle(.brandQuiet).disabled(c.checkStatus == .checking)
            }
            switch c.checkStatus {
            case .notYet: Text("Nothing found yet. If you have just paid, give it a moment and press Check now again. The receipt email also carries your key, if you would rather enter it.").font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            default: Text("Whoprrr asks for a fresh pass when you press this, and by itself when you come back from paying. Nothing to restart.").font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your key is in your receipt email. Entering a key from another order activates this Mac on that order too.").font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("WHOP-XXXX-XXXX-XXXX-XXXX", text: $key).textFieldStyle(.roundedBorder).font(.system(size: 14, design: .monospaced)).frame(maxWidth: 300).onSubmit(activate).accessibilityLabel("Your key")
                Button("Use this key", action: activate).buttonStyle(.brand).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || license.busy)
            }
            if let n = license.notice { Text(n).font(Brand.caption).foregroundStyle(Brand.accentText).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func activate() { Task { await license.activate(key: key); if license.state.isLicensed, license.notice == nil { key = ""; enteringKey = false } } }
}
