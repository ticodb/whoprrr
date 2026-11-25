import SwiftUI
import WhopperKit

/// First launch, and "Scan my gear" from Recipes: look at what is connected, propose one recipe, apply it on a click, and offer
/// to share what worked. Nothing changes before Apply, and one button puts everything back.
struct WelcomeView: View {
    @EnvironmentObject var nav: WindowNav
    private enum Step { case intro, found, plan, applied, share }
    private enum Sent { case no, sending, yes, failed }
    @State private var step: Step = .intro
    @State private var scan: GearScan?
    @State private var plan: StarterPlan?
    @State private var accepted: Set<String> = []
    @State private var applied: Starter.Applied?
    @State private var sent: Sent = .no
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case .intro: intro
            case .found: found
            case .plan: proposal
            case .applied: done
            case .share: share
            }
        }
        .onAppear {
            // Screenshots: WHOPPER_WELCOME_STEP=found|plan opens on that step with a scan already made.
            guard scan == nil, let want = ProcessInfo.processInfo.environment["WHOPPER_WELCOME_STEP"] else { return }
            runScan(); step = want == "plan" ? .plan : .found
        }
    }

    private func runScan() {
        let s = GearScanner.current()
        let p = StarterRecipes.plan(for: s)
        scan = s; plan = p; accepted = Set(p.lines.filter(\.on).map(\.id))
    }

    // MARK: Steps

    private var intro: some View {
        Group {
            PanelHeader("Set Whoprrr up for your gear", symbol: "sparkle.magnifyingglass", subtitle: "One scan, one setup to review")
            BrandCard {
                Text("Whoprrr looks at the screens, keyboard, mouse, microphone and speakers connected to this Mac, then proposes one setup you can review.")
                    .font(Brand.body).fixedSize(horizontal: false, vertical: true)
                Text("It reads device models and connection types. Nothing leaves your Mac during the scan, and nothing changes until you press Apply.")
                    .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Scan my setup") { runScan(); step = .found }.buttonStyle(.brand)
                Button("Set up by hand") { nav.page = .permissions }.buttonStyle(.brandQuiet)
            }
        }
    }

    private var found: some View {
        Group {
            PanelHeader("Found on this Mac", symbol: "sparkle.magnifyingglass", subtitle: scan.map { "\($0.mac.model) · macOS \($0.mac.os)" })
            if let plan {
                if plan.gear.isEmpty {
                    BrandCard { Text("No external gear found. The proposal is for this Mac on its own.").font(Brand.body).foregroundStyle(.secondary) }
                } else {
                    BrandCard {
                        ForEach(plan.gear) { g in
                            row(symbol: g.symbol, title: g.name, detail: g.detail, fit: g.fit)
                            if g.id != plan.gear.last?.id { Divider() }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("See the proposed setup") { step = .plan }.buttonStyle(.brand)
                Button("Scan again") { runScan() }.buttonStyle(.brandQuiet)
            }
        }
    }

    private var proposal: some View {
        Group {
            PanelHeader("Proposed recipe: \(plan?.name ?? "")", symbol: "fork.knife", subtitle: "Made for the gear connected right now")
            Text("Switch off any line you do not want. Nothing changes until you press Apply.").font(Brand.caption).foregroundStyle(.secondary)
            if let plan {
                BrandCard {
                    ForEach(plan.lines) { l in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("", isOn: Binding(get: { accepted.contains(l.id) }, set: { if $0 { accepted.insert(l.id) } else { accepted.remove(l.id) } }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .accessibilityLabel("\(l.feature.shortTitle): \(l.detail)")
                            row(symbol: l.feature.symbol, title: l.feature.shortTitle, detail: l.detail, fit: l.fit)
                        }
                        if l.id != plan.lines.last?.id { Divider() }
                    }
                }
                offList(plan)
                HStack(spacing: 8) {
                    Button("Apply \(plan.name)") { applied = Starter.apply(plan, accepted: accepted); step = .applied }.buttonStyle(.brand)
                    Button("Not now") { nav.page = .recipes }.buttonStyle(.brandQuiet)
                }
            }
        }
    }

    private var done: some View {
        Group {
            PanelHeader("\(applied?.name ?? "Your recipe") is on", symbol: "checkmark.circle", subtitle: "Saved under Recipes")
            BrandCard {
                Text("Whoprrr switches to this recipe by itself when this gear is connected. The features it uses still need their permissions.")
                    .font(Brand.body).fixedSize(horizontal: false, vertical: true)
            }
            if let plan { offList(plan) }
            HStack(spacing: 8) {
                Button("Continue") { step = .share }.buttonStyle(.brand)
                Button("Put everything back") { if let a = applied { Starter.undo(a) }; applied = nil; step = .plan }.buttonStyle(.brandQuiet)
            }
        }
    }

    private var share: some View {
        Group {
            PanelHeader("Help the next person with this gear?", symbol: "paperplane", subtitle: "Optional. This is everything that would be sent")
            BrandCard {
                Text(reportText).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text("Models and results only: no serial numbers, no device nicknames, nothing about your clipboard, rules or files. It is sent once, when you press Send.")
                .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch sent {
            case .yes: StatusChip(text: "Sent. Thank you", tone: .good)
            case .failed: StatusChip(text: "Could not send. Nothing was sent", tone: .warn)
            default: EmptyView()
            }
            HStack(spacing: 8) {
                if sent != .yes {
                    Button(sent == .sending ? "Sending…" : "Send report") { send() }.buttonStyle(.brand).disabled(sent == .sending)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(reportText, forType: .string); copied = true
                    }.buttonStyle(.brandQuiet)
                }
                Button(sent == .yes ? "Grant permissions" : "No thanks") { nav.page = .permissions }.buttonStyle(.brandQuiet)
            }
        }
    }

    // MARK: Pieces

    private var reportText: String {
        guard let scan, let plan else { return "" }
        return FitReport.text(app: AppInfo.version, scan: scan, plan: plan, accepted: accepted)
    }

    private func send() {
        guard let scan, let plan else { return }
        let body = FitReport.json(app: AppInfo.version, scan: scan, plan: plan, accepted: accepted)
        sent = .sending
        Task { sent = await FitSender.send(body) ? .yes : .failed }
    }

    @ViewBuilder private func offList(_ plan: StarterPlan) -> some View {
        if !plan.off.isEmpty {
            BrandCard {
                SectionLabel("Switched off for this setup")
                ForEach(plan.off) { o in row(symbol: o.feature.symbol, title: o.feature.shortTitle, detail: o.reason, fit: .unavailable) }
            }
        }
    }

    private func row(symbol: String, title: String, detail: String, fit: Fit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Brand.accentText).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Brand.headline)
                Text(detail).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            StatusChip(text: fit.label, tone: fit == .tested || fit == .checked ? .good : fit == .untested ? .warn : .neutral)
        }
    }
}
