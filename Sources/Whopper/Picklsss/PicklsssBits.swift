import SwiftUI
import WhopperKit

// Small pieces the Picklsss and Extras pages share.

/// "Tested on this gear", "Should work, untested", "Not on this setup": the gear scan's labels.
struct FitChip: View {
    var fit: Fit
    var body: some View { StatusChip(text: fit.label, tone: fit == .tested || fit == .checked ? .good : fit == .untested ? .warn : .neutral) }
}

/// A gear tag: highlighted when this Mac has it, struck through when it does not.
struct GearTag: View {
    var model: String
    var fit: ShelfRanking.GearFit
    var body: some View {
        Text(model).font(.system(size: 12.5, weight: .medium, design: .rounded)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(fit == .have ? Color(hex: 0x1FB955).opacity(0.14) : fit == .sameKind ? Brand.violet.opacity(0.14) : Color.primary.opacity(0.07), in: Capsule())
            .foregroundStyle(fit == .have ? Color.dynamic(light: 0x0F7D37, dark: 0x4ADE80) : fit == .sameKind ? Brand.accentText : Color.secondary)
            .strikethrough(fit == .missing, color: .secondary)
            .accessibilityLabel("\(model), \(fit == .have ? "you have it" : fit == .sameKind ? "you have the same kind of gear" : "you do not have it")")
    }
}

struct GearTags: View {
    var gear: [SharedGear]
    var fits: [ShelfRanking.GearFit]
    var body: some View {
        WrapLayout(spacing: 5) { ForEach(Array(gear.enumerated()), id: \.offset) { i, g in GearTag(model: g.model, fit: i < fits.count ? fits[i] : .missing) } }
    }
}

/// The lock: what it is, what it costs, and the one way to get past it. The app never handles a card; the button opens the
/// buyer's page in the browser, and the app re-checks its pass when it comes to the front and on "Check now".
struct LockCard: View {
    /// What the person was about to do, in plain words: "Taking a picklsss", "Taking a setup from someone else".
    var headline: String
    var detail: String
    var onUnlocked: () -> Void = {}
    @ObservedObject private var c = PicklsssController.shared
    @ObservedObject private var license = LicenseController.shared
    @State private var key = ""
    @State private var enteringKey = false

    var body: some View {
        Group {
            if license.hasPicklsss { unlocked } else { locked }
        }
        .onChange(of: license.hasPicklsss) { _, on in if on { onUnlocked() } }
    }

    private var unlocked: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Picklsss (setups other people shared) is unlocked on this Mac. Thank you.").font(Brand.subheadline)
            Spacer(minLength: 0)
        }
        .padding(12).background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var locked: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Picklsss: setups other people shared").font(Brand.display(15, .semibold))
            Text("\(headline) is part of the extra. \(detail)").font(Brand.subheadline).fixedSize(horizontal: false, vertical: true)
            Text("$4, paid once, for this Mac and your others. Free if a picklsss you share is accepted. Browsing stays free.")
                .font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if c.awaitingPurchase {
                Text("whoprrr.app opened in your browser. Pay there; this window updates by itself when you come back.")
                    .font(Brand.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            BuyLinkProblem()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
            if let s = status { Text(s).font(Brand.caption).foregroundStyle(Brand.accentText).fixedSize(horizontal: false, vertical: true) }
            if enteringKey { keyEntry }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Brand.violet.opacity(0.28), Brand.violetDeep.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.violetBright.opacity(0.4)))
    }

    @ViewBuilder private var buttons: some View {
        Button(c.awaitingPurchase ? "Open it again" : "Get Picklsss · $4") { Task { await c.openBuyPage(c.awaitingPurchase ? nil : .picklsss) } }.buttonStyle(.brand).disabled(c.makingLink)
        Button(c.checkStatus == .checking ? "Checking…" : "Check now") { Task { await c.checkNow() } }.buttonStyle(.brandQuiet).disabled(c.checkStatus == .checking)
        Button("I have a key") { enteringKey.toggle() }.buttonStyle(.brandQuiet)
    }

    private var status: String? {
        switch c.checkStatus {
        case .notYet: PurchaseWords.notYet
        case .found: "Found your order."
        default: nil
        }
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A key from a purchase that includes shared setups. Your key is in the receipt email.").font(Brand.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("WHOP-XXXX-XXXX-XXXX-XXXX", text: $key).textFieldStyle(.roundedBorder).font(.system(size: 14, design: .monospaced)).frame(maxWidth: 300)
                    .onSubmit(activate).accessibilityLabel("Your key")
                Button("Use this key", action: activate).buttonStyle(.brand).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || license.busy)
            }
            if let n = license.notice { Text(n).font(Brand.caption).foregroundStyle(Brand.accentText).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func activate() { Task { await license.activate(key: key); if license.hasPicklsss { key = ""; enteringKey = false } } }
}

/// When the one-time buy link could not be made: what happened in plain words, and the old way in beside it.
struct BuyLinkProblem: View {
    @ObservedObject private var c = PicklsssController.shared

    var body: some View {
        if let message = c.linkProblem {
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(Brand.subheadline).foregroundStyle(Brand.accentText).fixedSize(horizontal: false, vertical: true)
                Button(PurchaseWords.findByEmail) { c.openPersonalPage() }.buttonStyle(.brandQuiet)
            }
        }
    }
}

/// News about what a person took: a new version (offered, never applied) or a removal (announced in plain words, with "Put back").
struct NoticesBar: View {
    @ObservedObject private var c = PicklsssController.shared
    @State private var confirming: ShelfNotice?

    var body: some View {
        if !c.notices.isEmpty {
            VStack(spacing: 8) {
                ForEach(c.notices) { n in row(n) }
            }
            .confirmationDialog("Put back “\(confirming?.title ?? "")”?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { n in
                Button("Put back", role: .destructive) { c.putBack(n) }
            } message: { n in Text(putBackWords(n)) }
        }
    }

    private func putBackWords(_ n: ShelfNotice) -> String {
        let parts = c.state.take(for: n.picklsssId)?.beforeParts ?? []
        return "Your settings for \(RecipeWording.list(parts)) go back to how they were just before you took it, and the copy you took is removed. Anything you changed in those parts since then is lost."
    }

    private func row(_ n: ShelfNotice) -> some View {
        let isUpdate = n.kind == .update
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isUpdate ? "arrow.triangle.2.circlepath" : "exclamationmark.circle.fill").font(.system(size: 16))
                .foregroundStyle(isUpdate ? Brand.accentText : StatusChip.Tone.warn.color)
            VStack(alignment: .leading, spacing: 6) {
                Text(n.message.isEmpty ? n.title : n.message).font(Brand.subheadline).fixedSize(horizontal: false, vertical: true)
                if isUpdate, !n.note.isEmpty { Text("“\(n.note)”").font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 8) {
                    if isUpdate {
                        Button("See the update") { Task { await c.seeUpdate(n) } }.buttonStyle(.brand)
                        Button("Skip") { c.dismissNotice(n.id) }.buttonStyle(.brandQuiet)
                    } else {
                        if c.canPutBack(n) { Button("Put back") { confirming = n }.buttonStyle(.brand) }
                        Button("OK") { c.dismissNotice(n.id) }.buttonStyle(.brandQuiet)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background((isUpdate ? Brand.violet : StatusChip.Tone.warn.color).opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder((isUpdate ? Brand.violetBright : StatusChip.Tone.warn.color).opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}

/// Said when sharing is closed for this key. Plain words only: the owner's reason is shown as it was written.
struct SharingClosedCard: View {
    var message: String
    var body: some View {
        BrandCard {
            Text("You can no longer share setups").font(Brand.display(16, .semibold))
            Text(message).font(Brand.subheadline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text("Your own recipes are still yours and still working.").font(Brand.caption).foregroundStyle(.secondary)
        }
    }
}
