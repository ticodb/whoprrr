import AppKit
import SwiftUI
import WhopperKit

struct SetupView: View {
    @ObservedObject var setup = SetupController.shared
    @ObservedObject private var license = LicenseController.shared
    @State private var skipGrant: Permission?
    @State private var sharing = false

    var body: some View {
        HStack(spacing: 0) {
            rail.frame(width: 232)
            Divider()
            if rendersSnapshot { setupContent } else { ScrollView { setupContent } }
        }
        .frame(minWidth: 860, minHeight: 620)
        .tint(Brand.violetBright)
        .onAppear { setup.refreshGrants() }
        .confirmationDialog(skipGrant.map { "Skip \($0.title)?" } ?? "Skip this grant?",
                            isPresented: Binding(get: { skipGrant != nil }, set: { if !$0 { skipGrant = nil } }),
                            titleVisibility: .visible) {
            if let grant = skipGrant {
                let names = setup.users(of: grant).map(\.shortTitle).joined(separator: ", ")
                Button(names.isEmpty ? "Skip grant" : "Park \(names)") { setup.skip(grant); skipGrant = nil }
            }
            Button("Go back", role: .cancel) { skipGrant = nil }
        } message: {
            Text("The features that use this grant stay off. Your settings are kept.")
        }
    }

    private var rendersSnapshot: Bool { ProcessInfo.processInfo.environment["SDC_SNAPSHOT"] != nil }

    private var setupContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if setup.step != .key && setup.renewalVisible { renewal }
            else {
                switch setup.step {
                case .key: LicenseView()
                case .gear: gear
                case .recipe: recipe
                case .permissions: grants
                case .taste: taste
                case .orderUp: orderUp
                case .complete: EmptyView()
                }
            }
        }
        .padding(28).padding(.top, 10)
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: rendersSnapshot ? .infinity : nil, alignment: .topLeading)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) { LogoMark(size: 40); Wordmark(size: 24) }.padding(.bottom, 14)
            SectionLabel(setup.renewalVisible ? "Finish setup" : "Setup").padding(.leading, 8)
            let current = setup.renewalVisible ? (setup.progress.renewalStarted && setup.currentGrant == nil ? SetupStep.taste : .permissions) : setup.step
            ForEach(SetupStep.allCases.prefix(5), id: \.self) { step in
                HStack(spacing: 10) {
                    let parked = step == .permissions && current.rawValue > step.rawValue && !setup.parkedFeatures.isEmpty
                    Image(systemName: parked ? "pause.circle.fill" : step == current ? "circle.inset.filled" : step.rawValue < current.rawValue ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14)).foregroundStyle(parked ? StatusChip.Tone.warn.text : step == current ? Brand.accentText : step.rawValue < current.rawValue ? StatusChip.Tone.good.text : .secondary)
                    Text(step.title).font(Brand.display(15, step == current ? .semibold : .regular))
                    Spacer()
                }
                .padding(8)
                .background(step == current ? Brand.violet.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityAddTraits(step == current ? .isSelected : [])
            }
            Spacer()
        }
        .padding(16).padding(.top, 22)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035))
    }

    @ViewBuilder private var gear: some View {
        if let scan = setup.progress.scan, let plan = setup.plan {
            PanelHeader("Found on this Mac", symbol: "sparkle.magnifyingglass", subtitle: "\(scan.mac.model) · macOS \(scan.mac.os)")
            BrandCard {
                if plan.gear.isEmpty { Text("No external gear found. The proposal is for this Mac on its own.").font(Brand.body) }
                ForEach(plan.gear) { gear in
                    setupRow(gear.name, detail: gear.detail, chip: gear.fit.label,
                             tone: [.tested, .checked].contains(gear.fit) ? .good : .neutral)
                    if gear.id != plan.gear.last?.id { Divider() }
                }
            }
            HStack {
                Button("See the proposed setup") { setup.showRecipe() }.buttonStyle(.brand).disabled(setup.working)
                Button("Scan again") { Task { await setup.scanGear() } }.buttonStyle(.brandPlain).disabled(setup.working)
            }
        } else {
            let place = license.stored.slot.flatMap { slot in license.stored.of.map { "Mac \(slot) of \($0) on your key" } }
            PanelHeader("This Mac is activated", symbol: "checkmark.seal", subtitle: place)
            BrandCard {
                Text("Whoprrr looks at the screens, keyboard, mouse, microphone and speakers connected to this Mac, then proposes one setup you can review.")
                    .font(Brand.body).fixedSize(horizontal: false, vertical: true)
                Text("The scan stays on this Mac.").font(Brand.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(setup.working ? "Looking…" : "Scan my setup") { Task { await setup.scanGear() } }.buttonStyle(.brand)
                Button("Set up by hand") { setup.setUpByHand() }.buttonStyle(.brandPlain)
            }.disabled(setup.working)
        }
    }

    @ViewBuilder private var recipe: some View {
        if let plan = setup.plan {
            PanelHeader("Proposed recipe: \(plan.name)", symbol: "fork.knife", subtitle: "Made for the gear connected right now")
            BrandCard {
                ForEach(plan.lines) { line in
                    Toggle(isOn: Binding(get: { setup.progress.accepted.contains(line.id) }, set: { setup.choose(line.id, on: $0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.feature.shortTitle).font(Brand.headline)
                            Text(line.detail).font(Brand.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    if line.id != plan.lines.last?.id { Divider() }
                }
            }
            let needed = Set(setup.proposed.values.flatMap { $0 })
            BrandCard {
                Text(needed.isEmpty ? "This setup needs no grants" : "This setup needs \(needed.count) \(needed.count == 1 ? "grant" : "grants")").font(Brand.headline)
                if !needed.isEmpty { Text(TasteTest.names(needed)).font(Brand.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Apply \(plan.name) and continue") { setup.applyRecipe() }.buttonStyle(.brand)
                Button("Not now") { setup.setUpByHand() }.buttonStyle(.brandPlain)
            }
        }
    }

    @ViewBuilder private var grants: some View {
        if let grant = setup.currentGrant {
            let index = setup.grants.firstIndex(of: grant).map { "Grant \($0 + 1) of \(setup.grants.count)" }
            PanelHeader(grant.title, symbol: "lock.shield", subtitle: index)
            Text(grant.why).font(Brand.body).fixedSize(horizontal: false, vertical: true)
            if grant == .inputMonitoring { Text("Press Quit & Reopen when macOS asks. Whoprrr comes back to this step.").font(Brand.caption).foregroundStyle(.secondary) }
            if grant == .systemAudio { Text("Whoprrr plays a short chime through the equalizer. Choose Allow when macOS asks.").font(Brand.caption).foregroundStyle(.secondary) }
            if grant == .paste { Text("In System Settings, choose Always Allow for Whoprrr.").font(Brand.caption).foregroundStyle(.secondary) }
            if grant == .micDriver { Text("If Whoprrr Mic takes a restart to appear, Whoprrr comes back to this step.").font(Brand.caption).foregroundStyle(.secondary) }
            if let note = setup.note { Text(note).font(Brand.caption).foregroundStyle(StatusChip.Tone.warn.text) }
            grantRows
            HStack {
                Button(grantAction(grant)) { setup.beginCurrentGrant(grant) }.buttonStyle(.brand)
                if setup.isGranted(grant), setup.isStale(grant), setup.canReset(grant) {
                    Button("Reset and ask again") { setup.retry(grant, reset: true) }.buttonStyle(.brandQuiet)
                }
                Button("Not now") { skipGrant = grant }.buttonStyle(.brandPlain)
            }.disabled(setup.working)
        } else {
            PanelHeader("Ready for the taste test", symbol: "lock.shield")
            grantRows
            Button("Start taste test") { setup.showTaste() }.buttonStyle(.brand).disabled(setup.working)
        }
    }

    @ViewBuilder private var grantRows: some View {
        if !setup.grants.isEmpty {
            BrandCard {
                ForEach(setup.grants) { grant in
                    let skipped = setup.progress.skipped.contains(grant)
                    let current = setup.currentGrant == grant
                    let ready = setup.isGranted(grant) && !current
                    setupRow(grant.title, detail: "Used by " + setup.users(of: grant).map(\.shortTitle).joined(separator: ", "),
                             chip: skipped ? "Skipped" : ready ? "On" : current ? "Now" : "Next",
                             tone: skipped ? .warn : ready ? .good : .neutral)
                    if grant != setup.grants.last { Divider() }
                }
            }
        }
    }

    private func grantAction(_ grant: Permission) -> String {
        if grant == .micDriver { return Shared.audio.driverInstalled ? "Check for Whoprrr Mic" : "Install Whoprrr Mic" }
        if grant == .systemAudio { return "Play the chime" }
        if grant == .microphone && setup.states[grant] == .notDetermined { return "Ask for microphone access" }
        return setup.attemptedGrant == grant ? "Open the switch again" : "Open the switch for me"
    }

    @ViewBuilder private var taste: some View {
        PanelHeader("Taste test", symbol: "checkmark.seal", subtitle: "Whoprrr tries each feature once, for real")
        tasteRows(setup.activeTargets)
        ForEach(Feature.allCases.filter { setup.activeTargets.contains($0) }) { feature in
            if let result = setup.progress.findings[feature], result.result != .works, result.result != .parked,
               setup.progress.parked[feature]?.result != .parked {
                BrandCard {
                    Text(result.detail).font(Brand.body)
                    HStack {
                        if let grant = setup.ordered(result.grants).first, result.result == .needsCheck {
                            Button("Check \(grant.title)") { setup.retry(grant, reset: false) }.buttonStyle(.brand)
                        } else if let grant = setup.ordered(result.grants).first, setup.canReset(grant) {
                            Button("Reset and ask again") { setup.retry(grant, reset: true) }.buttonStyle(.brand)
                        } else {
                            Button("Try once more") { setup.runTaste(force: true) }.buttonStyle(.brandQuiet)
                            Button("Copy diagnostics") { DiagnosticsReport.copy() }.buttonStyle(.brandPlain)
                        }
                        Button("Park \(feature.shortTitle)") { setup.park(feature) }.buttonStyle(.brandPlain)
                    }
                }.disabled(setup.checking || setup.working)
            }
        }
        if setup.canFinishTaste {
            Button("Finish") { setup.finishTaste() }.buttonStyle(.brand)
        } else if !setup.checking && setup.activeTargets.contains(where: { setup.progress.findings[$0] == nil }) {
            Button("Continue taste test") { setup.runTaste() }.buttonStyle(.brand)
        }
    }

    private func tasteRows(_ features: Set<Feature>) -> some View {
        BrandCard {
            if features.isEmpty { Text("No features selected.").font(Brand.body) }
            ForEach(Feature.allCases.filter(features.contains)) { feature in
                let finding = setup.progress.parked[feature]?.result == .parked
                    ? setup.progress.parked[feature] : setup.progress.findings[feature]
                let trying = setup.trying == feature
                let detail = trying && feature == .microphone ? "Speak into your microphone." : finding?.detail
                setupRow(feature.shortTitle, detail: detail, chip: trying ? "Trying" : finding?.result.title ?? "Next",
                         tone: trying ? .neutral : finding?.result == .works ? .good : finding?.result == .notWorking ? .bad : finding == nil ? .neutral : .warn)
            }
        }
    }

    @ViewBuilder private var orderUp: some View {
        PanelHeader("Order up", symbol: "fork.knife", subtitle: "\(setup.progress.recipeName ?? "Your recipe") is on, and Whoprrr lives in the menu bar")
        tasteRows(setup.activeTargets)
        if !setup.parkedFeatures.isEmpty {
            Text("Finish setup any time from the menu bar or the parked feature’s page.").font(Brand.caption).foregroundStyle(.secondary)
        }
        if sharing, let scan = setup.progress.scan, let plan = setup.plan {
            GearReportView(scan: scan, plan: plan, accepted: setup.progress.accepted) { setup.finishSetup() }
        } else {
            HStack {
                Button("Open Recipes") { setup.finishSetup() }.buttonStyle(.brand)
                Button("Help the next person with this gear?") { sharing = true }.buttonStyle(.brandPlain)
            }
        }
    }

    @ViewBuilder private var renewal: some View {
        if !setup.progress.renewalStarted {
            let needs = setup.grants
            let requiresCheck = setup.activeTargets.contains { setup.progress.parked[$0]?.result == .needsCheck }
            PanelHeader(needs.isEmpty ? "Finish setup" : requiresCheck ? "Check permissions after the update" : "Renew \(needs.count) \(needs.count == 1 ? "grant" : "grants")",
                        symbol: "lock.shield", subtitle: "Paused: " + Feature.allCases.filter(setup.activeTargets.contains).map(\.shortTitle).joined(separator: ", "))
            if !needs.isEmpty {
                BrandCard {
                    ForEach(needs) { grant in
                        let check = setup.activeTargets.contains { setup.progress.parked[$0]?.result == .needsCheck && setup.progress.parked[$0]?.grants.contains(grant) == true }
                        setupRow(grant.title, detail: "Used by " + setup.users(of: grant).map(\.shortTitle).joined(separator: ", "),
                                 chip: check ? "Needs a check" : "Needs renewing", tone: .warn)
                    }
                }
            }
            HStack {
                Button(needs.isEmpty || requiresCheck ? "Continue" : "Renew") { setup.renew() }.buttonStyle(.brand)
                Button("Later") { setup.leaveRenewal() }.buttonStyle(.brandPlain)
            }
        } else if setup.currentGrant != nil || !setup.tasteStarted { grants }
        else { taste }
    }

    private func setupRow(_ title: String, detail: String?, chip: String, tone: StatusChip.Tone) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Brand.headline)
                if let detail, !detail.isEmpty { Text(detail).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 6)
            StatusChip(text: chip, tone: tone).fixedSize()
        }
    }
}

private struct GearReportView: View {
    var scan: GearScan
    var plan: StarterPlan
    var accepted: Set<String>
    var complete: () -> Void
    @State private var sending = false
    @State private var sent: Bool?
    @State private var copied = false

    var body: some View {
        let report = FitReport.text(app: AppInfo.version, scan: scan, plan: plan, accepted: accepted)
        BrandCard {
            Text("Help the next person with this gear?").font(Brand.headline)
            Text("Optional. This is everything Whoprrr would send.").font(Brand.caption).foregroundStyle(.secondary)
            Text(report).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            if let sent { StatusChip(text: sent ? "Sent. Thank you" : "The report could not be sent", tone: sent ? .good : .warn) }
            HStack {
                if sent != true {
                    Button(sending ? "Sending…" : "Send report") {
                        sending = true
                        Task {
                            sent = await FitSender.send(FitReport.json(app: AppInfo.version, scan: scan, plan: plan, accepted: accepted))
                            sending = false
                        }
                    }.buttonStyle(.brand).disabled(sending)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        copied = true
                    }.buttonStyle(.brandPlain)
                }
                Button(sent == true ? "Open Recipes" : "No thanks", action: complete).buttonStyle(.brandPlain)
            }
        }
    }
}
