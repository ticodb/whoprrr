import SwiftUI
import WhopperKit

// The grouped list of a shared setup's lines: what goes on now, then what stays off and why. The helper (`ReviewGrouping`)
// decides the order and the groups; these views only draw it.

/// "GOES ON NOW" and "2 of 2".
struct SectionHead: View {
    var title: String
    var count: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionLabel(title)
            Spacer(minLength: 8)
            Text(count).font(Brand.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one sentence at the top of the list.
struct ReviewSummary: View {
    var text: String
    var body: some View {
        Text(text).font(Brand.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.violet.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// "Audio", "Windows": a part named small, after a line's name.
struct PartTag: View {
    var part: String
    var body: some View {
        Text(PicklsssWords.partTitle(part)).font(Brand.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(Color.primary.opacity(0.09), in: Capsule())
    }
}

/// "3 settings change · before → after", opening to the examples. As it always was.
struct ChangeDisclosure: View {
    var ch: LineChange
    var body: some View {
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

/// "Goes on now": the lines that can go on, each with its switch on the review. A line the person switched off stays here, switch off.
struct GoesOnSection: View {
    @ObservedObject var s: TakeSession
    var g: ReviewGrouping
    /// The review has switches and the before-and-after; the detail page shows a fit label instead.
    var editable: Bool

    var body: some View {
        if !g.goesOn.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHead(title: "Goes on now", count: editable ? g.goesOnCountText : (g.canGoOnCount == 1 ? "1 line" : "\(g.canGoOnCount) lines"))
                BrandCard {
                    if g.isGrouped {
                        ForEach(Array(g.blocks.enumerated()), id: \.element.id) { bi, b in
                            if bi > 0 { Divider() }
                            partHeading(b)
                            ForEach(Array(b.items.enumerated()), id: \.element.id) { i, item in
                                if i > 0 { Divider().padding(.leading, editable ? 48 : 0) }
                                row(item, tag: false)
                            }
                        }
                    } else {
                        ForEach(Array(g.goesOn.enumerated()), id: \.element.id) { i, item in
                            if i > 0 { Divider() }
                            row(item, tag: true)
                        }
                    }
                }
            }
        }
    }

    private func partHeading(_ b: ReviewGrouping.PartBlock) -> some View {
        HStack(spacing: 10) {
            if editable {
                if b.showsSwitch {
                    Toggle("", isOn: Binding(get: { b.switchOn }, set: { s.toggle(b.lineIDs, on: $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityLabel("All of \(PicklsssWords.partTitle(b.part))")
                } else { Color.clear.frame(width: 38, height: 1) }
            }
            Text(PicklsssWords.partTitle(b.part)).font(Brand.headline)
            Spacer(minLength: 8)
            Text(editable ? "\(b.onCount) of \(b.items.count)" : (b.items.count == 1 ? "1 line" : "\(b.items.count) lines")).font(Brand.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func row(_ item: ReviewGrouping.Item, tag: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if editable {
                Toggle("", isOn: Binding(get: { item.isOn }, set: { s.toggle(item.id, on: $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel(item.title)
            }
            VStack(alignment: .leading, spacing: 3) {
                if tag {
                    WrapLayout(spacing: 6) { Text(item.title).font(Brand.headline); PartTag(part: item.part) }
                } else {
                    Text(item.title).font(Brand.headline).fixedSize(horizontal: false, vertical: true)
                }
                if let n = item.note { Text(n).font(Brand.caption).foregroundStyle(StatusChip.Tone.warn.text).fixedSize(horizontal: false, vertical: true) }
                if editable, item.isOn, let ch = s.changes[item.id] { ChangeDisclosure(ch: ch) }
            }
            Spacer(minLength: 8)
            if !editable, let line = s.plan?.line(item.id) { FitChip(fit: s.fitLabel(line)).fixedSize() }
        }
    }
}

/// "Stays off for now": one row per reason, closed until clicked.
struct StaysOffSection: View {
    @ObservedObject var s: TakeSession
    var g: ReviewGrouping

    var body: some View {
        if !g.stays.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHead(title: "Stays off for now", count: g.stayCountText)
                BrandCard {
                    ForEach(Array(g.stays.enumerated()), id: \.element.id) { i, grp in
                        if i > 0 { Divider() }
                        group(grp)
                    }
                }
            }
        }
    }

    private func group(_ grp: ReviewGrouping.StayGroup) -> some View {
        let open = s.openGroups.contains(grp.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.12)) { s.toggleGroup(grp.id) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 14)
                    Text(grp.title).font(Brand.headline).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(grp.countText).font(Brand.caption).foregroundStyle(.secondary).fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(grp.title), \(grp.countText)")
            .accessibilityValue(open ? "Open" : "Closed")
            .accessibilityHint(open ? "Hides the lines" : "Shows the lines")
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(grp.lines) { l in
                        HStack(spacing: 6) {
                            Text(l.title).font(Brand.subheadline).fixedSize(horizontal: false, vertical: true)
                            if grp.showsParts { Text("· \(PicklsssWords.partTitle(l.part))").font(Brand.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if let f = grp.footnote { Text(f).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 2) }
                    ForEach(grp.pluginNames, id: \.self) { n in
                        if let url = TakeSession.pluginLink(n) { Link("Where to get \(n)", destination: url).font(Brand.caption) }
                    }
                }
                .padding(.leading, 22).padding(.bottom, 2)
            }
        }
    }
}

/// Both sections, for the review and for the detail page, with the sentence on top when the review wants it.
struct GroupedLines: View {
    @ObservedObject var s: TakeSession
    var plan: FitPlan
    var editable: Bool

    var body: some View {
        if let g = s.grouping {
            VStack(alignment: .leading, spacing: 12) {
                if editable, let sum = g.summary { ReviewSummary(text: sum) }
                if let rr = s.reviewRequirements, !rr.blocking.isEmpty { RequirementsList(rows: rr.blocking) }
                GoesOnSection(s: s, g: g, editable: editable)
                StaysOffSection(s: s, g: g)
                if plan.lines.isEmpty { BrandCard { Text("Nothing in this setup can be used on this Mac.").font(Brand.subheadline).foregroundStyle(.secondary) } }
                if let t = s.reviewRequirements?.sentence { Text(t).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

/// On the done page: what went on, by part, and what is off for now, one line per reason.
struct WaitingCards: View {
    @ObservedObject var s: TakeSession
    var body: some View {
        if let g = s.grouping, g.lineCount > 0 {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHead(title: s.applied?.notLive == true ? "Goes on when you apply the recipe" : "On now", count: "\(g.onNow.count)")
                    BrandCard {
                        if g.onNow.isEmpty { Text("Nothing yet").font(Brand.caption).foregroundStyle(.secondary) }
                        ForEach(g.onNowByPart) { b in
                            (Text("\(PicklsssWords.partTitle(b.part)): ").font(Brand.caption.weight(.semibold)) + Text(b.items.map(\.title).joined(separator: ", ")).font(Brand.caption))
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                let mine = g.switchedOffByPerson
                if !g.stays.isEmpty || !mine.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHead(title: "Off for now", count: "\(g.stayCount + mine.count)")
                        BrandCard {
                            if !mine.isEmpty {
                                (Text("You switched off: ").font(Brand.caption.weight(.semibold)) + Text(mine.map(\.title).joined(separator: ", ")).font(Brand.caption))
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(g.stays) { grp in
                                (Text("\(grp.title): ").font(Brand.caption.weight(.semibold)) + Text(grp.lines.map(\.title).joined(separator: ", ")).font(Brand.caption))
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}
