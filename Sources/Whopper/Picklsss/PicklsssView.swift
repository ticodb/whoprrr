import SwiftUI
import WhopperKit

/// The shelf of shared setups ("Picklsss"): tabs for your gear, popular and new, search, and a card for each setup. Browsing needs
/// nothing extra and sends nothing about this Mac: ranking for your gear happens here.
struct PicklsssView: View {
    @ObservedObject private var c = PicklsssController.shared
    @EnvironmentObject var nav: WindowNav

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let t = c.take {
                TakeFlowView(s: t)
            } else if let p = c.fileProblem {
                FileProblemView(problem: p)
            } else {
                header
                if c.route == .mine { MineView() } else { shelf }
            }
        }
        .onAppear { c.refreshPassIfMissing() }
        .task {
            c.refreshGear()
            await c.refreshNotices()
            if c.route == .shelf, c.take == nil { await c.loadShelf() }
        }
        .onChange(of: c.tab) { _, _ in Task { await c.loadShelf() } }
    }

    private var header: some View {
        PanelHeader("Picklsss", symbol: "books.vertical", subtitle: "Setups other people shared, fitted to your gear") {
            if c.route == .mine { Button("Back to the shelf") { c.route = .shelf; Task { await c.loadShelf() } }.buttonStyle(.brandQuiet) }
            else { Button("My shared setups") { c.route = .mine; Task { await c.refreshMine() } }.buttonStyle(.brandQuiet) }
        }
    }

    // MARK: The shelf

    @ViewBuilder private var shelf: some View {
        Picker("Show", selection: $c.tab) {
            ForEach(PicklsssController.BrowseTab.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search by title, cook or gear", text: $c.search).textFieldStyle(.plain).font(Brand.body).onSubmit { Task { await c.loadShelf() } }
                .accessibilityLabel("Search the shelf")
            if !c.search.isEmpty { Button { c.search = ""; Task { await c.loadShelf() } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search") }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

        if c.tab == .forGear {
            Text(c.gear.isEmpty ? "No external gear found, so everything is shown in the shelf’s order." : "Ranked here on this Mac by the gear you have connected. The shelf is never told what it is.")
                .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }

        if let f = c.shelfFailure {
            BrandCard {
                Text(f.isTemporary || f == .offline ? "Could not reach the shelf" : "The shelf could not be shown").font(Brand.display(15, .semibold))
                Text(f.message).font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await c.loadShelf() } }.buttonStyle(.brand)
            }
        } else if c.loading && !c.loadedOnce {
            BrandCard { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking at the shelf…").font(Brand.subheadline).foregroundStyle(.secondary) } }
        } else if c.cards.isEmpty && c.loadedOnce {
            emptyShelf
        } else {
            let r = c.ranked
            ForEach(r.fitting) { card($0, dim: false) }
            if !r.others.isEmpty {
                SectionLabel("Made for other gear").padding(.top, 6)
                Text("These fit nothing you have connected right now. They are still here to look at.").font(Brand.caption2).foregroundStyle(.secondary)
                ForEach(r.others) { card($0, dim: true) }
            }
            if c.nextCursor != nil {
                Button(c.loading ? "Loading…" : "Show more") { Task { await c.loadMore() } }.buttonStyle(.brandQuiet).disabled(c.loading)
            }
        }
        Text("Looking is free. Taking a picklsss puts someone else’s setup on your Mac, fitted to your gear; you review every change before anything happens, and one button puts everything back.")
            .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var emptyShelf: some View {
        BrandCard {
            Text(c.search.isEmpty ? "Nothing on the shelf yet" : "Nothing matches “\(c.search)”").font(Brand.display(15, .semibold))
            Text(c.search.isEmpty
                 ? "Be the first: open one of your recipes’ menus under Recipes and choose “Share as a picklsss…”. You see exactly what would be sent before anything leaves your Mac."
                 : "Try fewer words, or a model name such as “Shure MV7”.")
                .font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !c.search.isEmpty { Button("Clear the search") { c.search = ""; Task { await c.loadShelf() } }.buttonStyle(.brandQuiet) }
        }
    }

    private func card(_ r: ShelfRanking.Ranked, dim: Bool) -> some View {
        let k = r.card
        let tone: StatusChip.Tone = r.summary.tone == .good ? .good : r.summary.tone == .maybe ? .warn : .neutral
        return Button { Task { await c.open(k) } } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "fork.knife").font(.system(size: 16, weight: .medium)).frame(width: 38, height: 38)
                    .foregroundStyle(Brand.accentText).background(Brand.violet.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(k.title).font(Brand.display(16, .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 6)
                        StatusChip(text: r.summary.label, tone: tone).fixedSize()
                    }
                    Text("\(PicklsssWords.cookLine(k.cook)) · \(PicklsssWords.keeps(k.keeps)) · \(PicklsssWords.kitchenDays(k.cook.kitchenDays))")
                        .font(Brand.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    Text(PicklsssWords.partList(k.parts)).font(Brand.caption).foregroundStyle(.secondary).lineLimit(2)
                    if !k.line.isEmpty { Text(k.line).font(Brand.caption).lineLimit(2).multilineTextAlignment(.leading) }
                    if !k.gear.isEmpty { GearTags(gear: k.gear, fits: r.summary.perItem) }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.11)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(dim ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(k.title), \(PicklsssWords.cookLine(k.cook)), \(r.summary.label)")
        .accessibilityHint("Opens it to see how it fits your gear")
    }
}

// MARK: My shared setups

struct MineView: View {
    @ObservedObject private var c = PicklsssController.shared
    @State private var downFor: ShelfCard?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = c.sharingClosedReason { SharingClosedCard(message: "Sharing setups is closed for this key. Reason: \(reason). Everything else in Whoprrr keeps working. Write to hello@whoprrr.app if you think this is a mistake.") }
            if let cook = c.mine?.cook {
                BrandCard {
                    HStack(alignment: .firstTextBaseline) {
                        Text(cook.handle).font(Brand.display(17, .semibold)).lineLimit(1)
                        if let r = cook.rank { StatusChip(text: r, tone: .good) }
                        Spacer(minLength: 0)
                    }
                    Text("\(PicklsssWords.cookKeeps(cook.keeps)) · \(PicklsssWords.kitchenDays(cook.kitchenDays))").font(Brand.subheadline).foregroundStyle(.secondary)
                    Text("Your handle, keeps and kitchen time are public. A keep is someone who took your picklsss and was still using it 7 days later. Kitchen time is the days Whoprrr was running on this Mac and checked in; it is shown beside your rank and earns nothing.")
                        .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let f = c.mineFailure { BrandCard { Text(f.message).font(Brand.subheadline).foregroundStyle(Brand.accentText); Button("Try again") { Task { await c.refreshMine() } }.buttonStyle(.brandQuiet) } }
            else if c.mineLoading && c.mine == nil { BrandCard { HStack { ProgressView().controlSize(.small); Text("Looking…").font(Brand.subheadline).foregroundStyle(.secondary) } } }
            else if (c.mine?.picklsss ?? []).isEmpty {
                BrandCard {
                    Text("You have not shared anything yet").font(Brand.display(15, .semibold))
                    Text("Open one of your recipes’ menus under Recipes and choose “Share as a picklsss…”. Sharing makes your handle, your keeps and your kitchen time public.")
                        .font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(c.mine?.picklsss ?? []) { row($0) }
            if let failure { Text(failure).font(Brand.caption).foregroundStyle(Brand.accentText) }
        }
        .task { await c.refreshMine() }
        .sheet(item: $downFor) { k in TakeDownSheet(card: k) { Task { await c.refreshMine() } } }
    }

    private func row(_ k: ShelfCard) -> some View {
        let st = k.shelfState ?? .public
        let tone: StatusChip.Tone = st == .public ? .good : st == .refused ? .bad : st == .removed ? .neutral : .warn
        let rec = c.state.shared.first { $0.picklsssId == k.id }
        let newer = rec.map(c.isNewerThanShared) ?? false
        return BrandCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(k.title).font(Brand.display(16, .semibold)).lineLimit(2)
                Spacer(minLength: 6)
                StatusChip(text: PicklsssWords.state(st), tone: tone).fixedSize()
            }
            Text(k.reason.map { st == .held ? "We’ll look at it soon. \($0.prefix(1).uppercased() + $0.dropFirst())." : $0 } ?? PicklsssWords.stateDetail(st))
                .font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text("Version \(k.version) · \(PicklsssWords.partList(k.parts)) · \(PicklsssWords.keeps(k.keeps))").font(Brand.caption).foregroundStyle(.secondary)
            if let n = k.note, !n.isEmpty { Text("Last note: “\(n)”").font(Brand.caption).foregroundStyle(.secondary) }
            if newer { Text("Your copy is newer than the shared one. Saving a recipe never shares it; this is a separate step.").font(Brand.caption).foregroundStyle(Brand.accentText) }
            HStack(spacing: 8) {
                if newer, let rec, let rid = rec.recipeID, let recipe = c.recipes.recipe(rid), st == .public {
                    Button("Share the update") { c.sharing = ShareSession(controller: c, recipe: recipe, mode: .update(rec)) }.buttonStyle(.brand)
                }
                if st == .held || st == .checking || st == .refused { Button("See the private preview") { Task { await c.openOwn(k) } }.buttonStyle(.brandQuiet) }
                if st != .removed { Button("Take it down…") { downFor = k }.buttonStyle(.brandQuiet) }
            }
        }
    }
}

struct TakeDownSheet: View {
    var card: ShelfCard
    var done: () -> Void
    @ObservedObject private var c = PicklsssController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(PicklsssWords.takedownTitle(card.title)).font(Brand.display(20, .semibold)).fixedSize(horizontal: false, vertical: true)
            Text("Remove it from Picklsss (setups other people shared)").font(Brand.display(14, .semibold))
            Text(PicklsssWords.takedownBody(keeps: card.keeps)).font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure { Text(failure).font(Brand.caption).foregroundStyle(Brand.accentText) }
            HStack {
                Spacer()
                Button("Keep it") { dismiss() }.buttonStyle(.brandQuiet).keyboardShortcut(.cancelAction)
                Button(busy ? "Taking it down…" : "Take it down") {
                    busy = true
                    Task {
                        do { try await c.takeDown(card.id); done(); dismiss() }
                        catch let e as ShelfFailure { failure = e.message; busy = false } catch { failure = ShelfFailure.offline.message; busy = false }
                    }
                }.buttonStyle(.brand).disabled(busy)
            }
        }
        .padding(24).frame(width: 460)
    }
}

/// A file that was not opened: the plain explanation, and nothing changed.
struct FileProblemView: View {
    var problem: PicklsssController.FileProblem
    @ObservedObject private var c = PicklsssController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(problem.title, symbol: "doc.badge.ellipsis", subtitle: "\(problem.name) · from a file on this Mac")
            BrandCard {
                SectionLabel("Why")
                Text(problem.why).font(Brand.subheadline).fixedSize(horizontal: false, vertical: true)
                ForEach(problem.violations.prefix(5), id: \.self) { Text("• \($0)").font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if problem.violations.count > 5 { Text("…and \(problem.violations.count - 5) more").font(Brand.caption).foregroundStyle(.secondary) }
            }
            BrandCard { SectionLabel("What happened"); Text(PicklsssWords.tamperedNothing).font(Brand.subheadline) }
            Button("OK") { c.fileProblem = nil }.buttonStyle(.brand)
        }
    }
}
