import SwiftUI
import WhopperKit

/// Opening one shared setup, in the prototype's order: see how it fits, match the gear, review before and after, Cookin', applied.
struct TakeFlowView: View {
    @ObservedObject var s: TakeSession
    @ObservedObject private var c = PicklsssController.shared
    @EnvironmentObject var nav: WindowNav

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch s.stage {
            case .loading: loading
            case .failed(let m): failed(m)
            case .detail: DetailStep(s: s)
            case .match: MatchStep(s: s)
            case .review: ReviewStep(s: s)
            case .cookin: CookinStep(s: s)
            case .done: DoneStep(s: s)
            case .partPicker: PartStep(s: s)
            }
        }
        .sheet(isPresented: $s.askCount) { CountSheet(s: s) }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { c.close() } label: { Label("The shelf", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(Brand.accentText)
            BrandCard { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Opening it…").font(Brand.subheadline).foregroundStyle(.secondary) } }
        }
    }

    private func failed(_ m: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { c.close() } label: { Label("The shelf", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(Brand.accentText)
            BrandCard {
                Text("This could not be opened").font(Brand.display(15, .semibold))
                Text(m).font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                HStack { Button("Try again") { Task { await s.load() } }.buttonStyle(.brand); Button("Back to the shelf") { c.close() }.buttonStyle(.brandPlain) }
            }
        }
    }
}

// MARK: 1. Detail

private struct DetailStep: View {
    @ObservedObject var s: TakeSession
    @ObservedObject private var c = PicklsssController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { c.close() } label: { Label(s.isFile ? "Back" : "The shelf", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(Brand.accentText)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title).font(Brand.display(22, .semibold)).lineLimit(3)
                Text(byline).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let line = s.setup?.line, !line.isEmpty { Text("“\(line)”").font(Brand.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if s.isOwn && !s.canTake { ownNote }
            if s.isFile { fileNote }
            if let setup = s.setup {
                if !setup.gear.isEmpty {
                    SectionLabel("Made for")
                    GearTags(gear: setup.gear, fits: fits(setup))
                }
            }
            if !s.requirements.isEmpty { RequirementsList(rows: s.requirements) }
            if let plan = s.plan { LinesCard(s: s, plan: plan, editable: false) }
            HStack(spacing: 8) {
                Button("Fit to my gear") { s.toMatch() }.buttonStyle(.brand).disabled(!s.canTake)
                Button("Take one part") { s.openPartPicker() }.buttonStyle(.brandQuiet).disabled(!s.canTake)
            }
        }
    }

    private var byline: String {
        if let k = s.card {
            var t = PicklsssWords.cookLine(k.cook)
            if let d = k.updated { t += " · updated \(d.formatted(.relative(presentation: .named)))" }
            return t + " · " + PicklsssWords.keeps(k.keeps)
        }
        if let n = s.fileName { return "\(n) · from a file on this Mac" }
        return ""
    }

    private func fits(_ setup: SharedSetup) -> [ShelfRanking.GearFit] {
        setup.gear.map { g in
            if s.env.gear.contains(where: { ShelfRanking.same($0.model, g.model) }) { return .have }
            if s.env.gear.contains(where: { ShelfRanking.normalizedRole($0.role.rawValue) == ShelfRanking.normalizedRole(g.role) }) { return .sameKind }
            return .missing
        }
    }

    private var ownNote: some View {
        BrandCard { Text("This is your own picklsss. Only you can see it until it has been checked, so it cannot be taken yet.").font(Brand.subheadline).fixedSize(horizontal: false, vertical: true) }
    }

    private var fileNote: some View {
        BrandCard {
            let own = PicklsssLock.isOwnFile(madeBy: s.fileMadeBy, pass: c.license.currentPass)
            Text(own ? "You made this file with your own key. It opens free." : "Looking at how this fits your gear is free. Putting it on your Mac needs Picklsss (setups other people shared).")
                .font(Brand.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Every line of a setup with the fit label judged against this Mac's gear, not the author's.
private struct LinesCard: View {
    @ObservedObject var s: TakeSession
    var plan: FitPlan
    var editable: Bool

    var body: some View {
        BrandCard {
            ForEach(Array(plan.lines.enumerated()), id: \.element.id) { i, l in
                HStack(alignment: .top, spacing: 10) {
                    // A line that cannot run on this Mac has no switch: its reason and the label say so. One the person switched off keeps its switch.
                    if editable {
                        if l.state.isOff && !s.switchedOff.contains(l.id) {
                            Color.clear.frame(width: 38, height: 1)
                        } else {
                            Toggle("", isOn: Binding(get: { !l.state.isOff }, set: { s.toggle(l.id, on: $0) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .accessibilityLabel("\(PicklsssWords.partTitle(l.part)): \(l.title)")
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PicklsssWords.partTitle(l.part)).font(Brand.headline)
                        Text(l.title).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let r = l.state.reason { Text(r).font(Brand.caption).foregroundStyle(l.state.isOff ? Color.secondary : StatusChip.Tone.warn.text).fixedSize(horizontal: false, vertical: true) }
                        if editable, !l.state.isOff, let ch = s.changes[l.id] { changeView(ch) }
                    }
                    Spacer(minLength: 8)
                    FitChip(fit: s.fitLabel(l)).fixedSize()
                }
                if i < plan.lines.count - 1 { Divider() }
            }
            if plan.lines.isEmpty { Text("Nothing in this setup can be used on this Mac.").font(Brand.subheadline).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func changeView(_ ch: LineChange) -> some View {
        if ch.isNoChange { Text("No change: your settings already match.").font(Brand.caption).foregroundStyle(.secondary) }
        else {
            DisclosureGroup("\(ch.changed) \(ch.changed == 1 ? "setting changes" : "settings change") · before → after") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ch.examples, id: \.self) { Text($0).font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                    if ch.more > 0 { Text("…and \(ch.more) more").font(Brand.caption2).foregroundStyle(.secondary) }
                }.padding(.top, 2)
            }.font(Brand.caption)
        }
    }
}

struct RequirementsList: View {
    var rows: [RequirementRow]
    var body: some View {
        BrandCard {
            SectionLabel("Before you start")
            ForEach(rows) { r in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).font(Brand.headline)
                        Text(r.detail).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let n = r.pluginName, r.status == .missing, let url = TakeSession.pluginLink(n) {
                            Link("Where to get \(n)", destination: url).font(Brand.caption)
                        }
                    }
                    Spacer(minLength: 8)
                    StatusChip(text: r.status == .ready ? "Ready" : r.status == .missing ? "Missing" : "Will ask", tone: r.status == .ready ? .good : r.status == .missing ? .warn : .neutral).fixedSize()
                }
            }
            if rows.contains(where: { $0.kind == .plugin }) { Text("Whoprrr does not download or install plugins. The link opens a web search in your browser only if you click it.").font(Brand.caption2).foregroundStyle(.secondary) }
        }
    }
}

// MARK: 2. Match the gear

private struct MatchStep: View {
    @ObservedObject var s: TakeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader("Match the gear", symbol: "arrow.left.arrow.right", subtitle: "Theirs on the left, yours on the right")
            if let plan = s.plan, let setup = s.setup {
                if setup.gear.isEmpty { BrandCard { Text("This setup is not tied to any gear, so there is nothing to match.").font(Brand.subheadline) } }
                else {
                    BrandCard {
                        ForEach(Array(plan.matches.enumerated()), id: \.offset) { i, m in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.author.model).font(Brand.headline).lineLimit(2)
                                    Text(m.author.role).font(Brand.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Picker("", selection: Binding(get: { m.receiver?.id ?? "none" }, set: { id in s.choose(authorIndex: m.authorIndex, device: s.env.gear.first { $0.id == id }) })) {
                                    ForEach(s.candidates(for: m.author), id: \.id) { Text($0.model).tag($0.id) }
                                    Text("Nothing like it connected").tag("none")
                                }.labelsHidden().frame(maxWidth: .infinity)
                                .accessibilityLabel("Your device for \(m.author.model)")
                            }
                            if i < plan.matches.count - 1 { Divider() }
                        }
                    }
                    let notes = plan.lines.filter { $0.state.reason != nil }.prefix(4)
                    if !notes.isEmpty {
                        BrandCard {
                            ForEach(Array(notes), id: \.id) { Text($0.state.reason ?? "").font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
            }
            HStack(spacing: 8) { Button("Review the changes") { s.toReview() }.buttonStyle(.brand); Button("Back") { s.backToDetail() }.buttonStyle(.brandPlain) }
        }
    }
}

// MARK: 3. Review

private struct ReviewStep: View {
    @ObservedObject var s: TakeSession
    @ObservedObject private var c = PicklsssController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if s.isUpdate {
                PanelHeader("A new version of “\(s.title)”", symbol: "arrow.triangle.2.circlepath", subtitle: "by \(s.handle). Nothing changes until you choose")
                if let n = s.updateNote { Text("“\(n)”").font(Brand.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text("A plain choice: keep yours as it is, or use the new one. Yours is kept one step back in the recipe’s menu if you use the new one.")
                    .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                PanelHeader("What will change", symbol: "list.bullet.rectangle", subtitle: "Switch off anything you do not want. Nothing changes yet")
            }
            if !s.requirements.isEmpty { RequirementsList(rows: s.requirements) }
            if let plan = s.plan { LinesCard(s: s, plan: plan, editable: true) }
            if s.showLock { LockCard(headline: s.isFile ? "Taking a setup from someone else" : "Taking a picklsss", detail: s.isFile ? "Shared setups, fitted to your gear." : "Each one is fitted to your gear before it touches your Mac.", onUnlocked: { s.unlocked() }) }
            if let m = s.message { Text(m).font(Brand.subheadline).foregroundStyle(Brand.accentText).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            ViewThatFits(in: .horizontal) { HStack(spacing: 8) { buttons }; VStack(alignment: .leading, spacing: 8) { buttons } }
        }
    }

    @ViewBuilder private var buttons: some View {
        if s.isUpdate {
            Button("Use the new version") { s.requestApply() }.buttonStyle(.brand)
            Button("Keep mine") { if case .update(_, let n) = s.source { c.dismissNotice(n.id) }; c.close() }.buttonStyle(.brandQuiet)
        } else {
            Button("Apply as “\(s.plan.map { _ in clipped(s.title) } ?? s.title)”") { s.requestApply() }.buttonStyle(.brand).disabled(!s.canTake)
            Button("Back") { s.stage = .match }.buttonStyle(.brandPlain)
            Button("Not now") { c.close() }.buttonStyle(.brandPlain)
        }
    }

    private func clipped(_ t: String) -> String { t.count > 28 ? String(t.prefix(27)) + "…" : t }
}

// MARK: 4. Cookin'

private struct CookinStep: View {
    @ObservedObject var s: TakeSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader("Cookin’ \(s.title)", symbol: "flame", subtitle: "Fitting it to your gear")
            BrandCard {
                ForEach(Array(s.cookinParts.enumerated()), id: \.offset) { i, p in
                    HStack {
                        Text(PicklsssWords.partTitle(p)).font(Brand.headline)
                        Spacer()
                        if i < s.cookinDone { StatusChip(text: "Done", tone: .good) } else if i == s.cookinDone { StatusChip(text: "Cookin’…", tone: .warn) } else { StatusChip(text: "Waiting", tone: .neutral) }
                    }
                    if i < s.cookinParts.count - 1 { Divider() }
                }
            }
            HStack(spacing: 8) { CookinLabel(detail: "\(min(s.cookinDone + 1, max(s.cookinParts.count, 1))) of \(max(s.cookinParts.count, 1))") ; Spacer() }
        }
    }
}

// MARK: 5. Done

private struct DoneStep: View {
    @ObservedObject var s: TakeSession
    @ObservedObject private var c = PicklsssController.shared
    @EnvironmentObject var nav: WindowNav

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let a = s.applied {
                PanelHeader("\(a.name) is \(a.updated ? "updated" : "on")", symbol: "checkmark.circle", subtitle: s.isFile ? "Saved in your recipes, from a file" : "Saved in your recipes, from \(s.handle)")
                BrandCard {
                    Text(PicklsssWords.partList(a.parts)).font(Brand.subheadline)
                    Text("It is an ordinary recipe of yours now, so the save bar works on it. Its menu under Recipes has two ways back: the version before your own last save, and the author’s original as fitted to your gear.")
                        .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !a.failed.isEmpty { Text("Not applied: \(a.failed.joined(separator: ", ")).").font(Brand.caption).foregroundStyle(Brand.accentText) }
                    ForEach(a.notes, id: \.self) { Text($0).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                if let r = a.recipeID.flatMap({ c.recipes.recipe($0) }), !r.skipped.isEmpty {
                    BrandCard {
                        SectionLabel("Waiting")
                        ForEach(r.skipped) { l in
                            Text("\(PicklsssWords.partTitle(l.part)): \(l.title). \(l.reason)").font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !s.isFile && !a.updated { didItWork }
                HStack(spacing: 8) {
                    Button("See it in Recipes") { c.close(); nav.page = .recipes }.buttonStyle(.brand)
                    if !a.updated { Button("Put everything back") { s.putEverythingBack() }.buttonStyle(.brandQuiet) }
                    Button("Back to the shelf") { c.close() }.buttonStyle(.brandPlain)
                }
            }
        }
    }

    @ViewBuilder private var didItWork: some View {
        BrandCard {
            Text("Did it work on your gear?").font(Brand.headline)
            Text("One press helps the next person with the same gear. It sends the same models-and-results report as the gear scan, and you see it first.")
                .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch s.sending {
            case .none:
                HStack(spacing: 8) {
                    Button("It works") { s.previewReport(.works) }.buttonStyle(.brand)
                    Button("Something is off") { s.markSomethingOff() }.buttonStyle(.brandQuiet).disabled(s.flag == .asking || s.flag == .flagged)
                }
            case .preview:
                Text(s.reportText ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("Models and results only: no serial numbers, no device nicknames, nothing about your clipboard, rules or files. It is sent once, when you press Send.")
                    .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { Button("Send report") { s.sendReport() }.buttonStyle(.brand); Button("No thanks") { s.declineReport() }.buttonStyle(.brandQuiet) }
            case .sending: Text("Sending…").font(Brand.subheadline).foregroundStyle(.secondary)
            case .sent: StatusChip(text: "Sent. Thank you", tone: .good)
            case .failed: StatusChip(text: "Could not send. Nothing was sent", tone: .warn)
            }
            switch s.flag {
            case .flagged: Text("Thank you. The shelf knows something is off with this one. It carries no text and no way to say who you are.").font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .failed(let m): Text(m).font(Brand.caption).foregroundStyle(Brand.accentText)
            default: EmptyView()
            }
        }
    }
}

// MARK: One part on its own

private struct PartStep: View {
    @ObservedObject var s: TakeSession
    @ObservedObject private var c = PicklsssController.shared
    @State private var chosen: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader("Take one part", symbol: "square.and.arrow.down", subtitle: "It lands in your presets, not in a recipe")
            if let plan = s.plan, let setup = s.setup {
                BrandCard {
                    ForEach(Array(setup.parts.enumerated()), id: \.element) { i, p in
                        let lines = plan.lines.filter { $0.part == p }
                        let usable = lines.contains { !$0.state.isOff }
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: chosen == p ? "largecircle.fill.circle" : "circle").foregroundStyle(usable ? Brand.accentText : Color.secondary)
                                .onTapGesture { if usable { chosen = p } }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PicklsssWords.partTitle(p)).font(Brand.headline)
                                ForEach(lines, id: \.id) { l in
                                    Text(l.state.isOff ? "\(l.title): \(l.state.reason ?? "")" : l.title).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 8)
                            if let l = lines.first(where: { !$0.state.isOff }) { FitChip(fit: s.fitLabel(l)).fixedSize() } else { FitChip(fit: .unavailable).fixedSize() }
                        }
                        .contentShape(Rectangle()).onTapGesture { if usable { chosen = p } }
                        .opacity(usable ? 1 : 0.6)
                        .accessibilityElement(children: .combine).accessibilityAddTraits(chosen == p ? .isSelected : [])
                        if i < setup.parts.count - 1 { Divider() }
                    }
                }
            }
            if s.showLock { LockCard(headline: "Taking a picklsss", detail: "Each one is fitted to your gear before it touches your Mac.", onUnlocked: { s.unlocked() }) }
            if let m = s.message { Text(m).font(Brand.subheadline).foregroundStyle(Brand.accentText).fixedSize(horizontal: false, vertical: true) }
            if let n = s.presetNote { BrandCard { Text(n).font(Brand.subheadline).fixedSize(horizontal: false, vertical: true) } }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .onAppear { if chosen == nil, let plan = s.plan { chosen = s.setup?.parts.first { p in plan.lines.contains { $0.part == p && !$0.state.isOff } } } }
    }

    @ViewBuilder private var buttons: some View {
        Button("Add to my presets") { if let p = chosen { s.requestPart(p, tryNow: false) } }.buttonStyle(.brand).disabled(chosen == nil)
        Button("Add and try it now") { if let p = chosen { s.requestPart(p, tryNow: true) } }.buttonStyle(.brandQuiet).disabled(chosen == nil)
        Button("Back") { s.backToDetail() }.buttonStyle(.brandPlain)
    }
}

// MARK: The first-take question

struct CountSheet: View {
    @ObservedObject var s: TakeSession
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(PicklsssWords.countQuestionTitle).font(Brand.display(20, .semibold))
            Text(PicklsssWords.countQuestionBody).font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(PicklsssWords.countQuestionNote).font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("No thanks") { s.answerCount(.no) }.buttonStyle(.brandQuiet)
                Button("Yes, count mine") { s.answerCount(.yes) }.buttonStyle(.brand).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 480)
        .interactiveDismissDisabled()
    }
}
