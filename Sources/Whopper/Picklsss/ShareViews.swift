import SwiftUI
import AppKit
import WhopperKit

/// "Share as a picklsss…", "Send as a file…" and "Share the update", from a recipe's menu or the shared list.
/// Shows exactly what would leave this Mac, and what is always left out, before anything is sent.
struct ShareFlowView: View {
    @ObservedObject var s: ShareSession
    @ObservedObject private var c = PicklsssController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showLeftOut = false

    var body: some View {
        ScrollView { content }
            .frame(width: 560, height: 640)
            .task {
                // Ask the shelf first: sharing may have been closed since, and a Mac that lost its data learns the handle this key already has.
                if s.mode != .file { await c.refreshMine(); if s.handleText.isEmpty, let h = c.handle { s.handleText = h } }
                if s.isUpdate { await s.loadPrevious() }
            }
    }

    /// Sharing is closed for this key and this is not a file: say so at once, in place of the form.
    private var closedBeforeStart: String? {
        guard s.mode != .file, s.closedReason == nil, let reason = c.sharingClosedReason else { return nil }
        return "Sharing setups is closed for this key. Reason: \(reason). Everything else in Whoprrr keeps working. Write to hello@whoprrr.app if you think this is a mistake."
    }

    /// The sheet's content, apart from its ScrollView so a screenshot can draw it.
    var content: some View {
            VStack(alignment: .leading, spacing: 14) {
                if let closed = closedBeforeStart {
                    SharingClosedCard(message: closed)
                    HStack { Button("OK") { c.sharing = nil }.buttonStyle(.brand); Spacer() }
                } else {
                switch s.step {
                case .goes: goes
                case .describe: describe
                case .sending:
                    VStack(alignment: .leading, spacing: 10) {
                        Text(s.isUpdate ? "Sending the update" : "Sending").font(Brand.display(20, .semibold))
                        HStack { CookinLabel(detail: "The shelf is looking at it"); Spacer() }
                    }
                case .result: result
                }
                }
            }
            .padding(24)
    }

    // MARK: 1. What goes

    private var goes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(s.headline).font(Brand.display(20, .semibold))
            Text(s.recipe.name).font(Brand.subheadline).foregroundStyle(.secondary)
            BrandCard {
                ForEach(Array(s.rows.enumerated()), id: \.element.id) { i, r in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("", isOn: Binding(get: { s.partsOn.contains(r.part) }, set: { s.toggle(r.part, on: $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(r.empty).accessibilityLabel(PicklsssWords.partTitle(r.part))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(PicklsssWords.partTitle(r.part)).font(Brand.headline)
                            Text(r.empty ? "Nothing in this part can be shared from this recipe." : r.detail).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if !r.left.isEmpty { Text("\(r.left.count) \(r.left.count == 1 ? "thing" : "things") left out of this part (listed below)").font(Brand.caption).foregroundStyle(.secondary) }
                            ForEach(Array(r.violations.enumerated()), id: \.offset) { _, v in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(v.message).font(Brand.caption).foregroundStyle(StatusChip.Tone.bad.text).fixedSize(horizontal: false, vertical: true)
                                    Text(v.line).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        Spacer(minLength: 8)
                        if !r.violations.isEmpty { StatusChip(text: "Past the limit", tone: .bad).fixedSize() }
                        else if r.changed == true { StatusChip(text: "Changed", tone: .warn).fixedSize() }
                        else if r.changed == false { Text("No change").font(Brand.caption).foregroundStyle(.secondary) }
                    }
                    if i < s.rows.count - 1 { Divider() }
                }
                if s.rows.isEmpty { Text("This recipe holds nothing that can be shared.").font(Brand.subheadline).foregroundStyle(.secondary) }
            }
            if let sourceID = s.recipe.inputSourceID {
                Toggle("Include typing language · \(s.recipe.inputSourceName ?? sourceID)", isOn: $s.includeTypingLanguage)
                    .toggleStyle(.switch).controlSize(.small).font(Brand.subheadline)
                    .onChange(of: s.includeTypingLanguage) { _, _ in s.rebuild() }
                ForEach(Array(s.typingLanguageProblems.enumerated()), id: \.offset) { _, problem in
                    Text(problem.message).font(Brand.caption).foregroundStyle(StatusChip.Tone.bad.text)
                }
            }
            if !s.blocking.isEmpty {
                Text("A setting past a limit cannot be shared, so nothing can be sent yet. Switch that part off, or change the setting in your recipe. Your own recipe keeps its values; only the shared copy is limited.")
                    .font(Brand.caption).foregroundStyle(Brand.accentText).fixedSize(horizontal: false, vertical: true)
            }
            BrandCard {
                DisclosureGroup(isExpanded: $showLeftOut) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(SharedSetupExport.alwaysLeftOut, id: \.self) { Text("• \($0)").font(Brand.caption).foregroundStyle(.secondary) }
                    }.padding(.top, 4)
                } label: { Text("Always left out").font(Brand.headline) }
                if !s.leftOut.isEmpty {
                    Text("Taken out of this one").font(Brand.headline)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(s.leftOut.enumerated()), id: \.offset) { Text("• \($0.element)").font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Next") { s.next() }.buttonStyle(.brand).disabled(!s.canContinue || (s.isUpdate && !s.changedAnything)).keyboardShortcut(.defaultAction)
                Button("Cancel") { c.sharing = nil }.buttonStyle(.brandPlain).keyboardShortcut(.cancelAction)
            }
            if s.isUpdate && !s.changedAnything && s.canContinue { Text("Nothing has changed since you last shared it.").font(Brand.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: 2. Describe

    private var describe: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(s.isUpdate ? "What changed" : "Describe it").font(Brand.display(20, .semibold))
            Text(s.isUpdate ? "People who took it get an offer with this note. Nobody’s Mac changes by itself." : "This is what people read before they open it.").font(Brand.subheadline).foregroundStyle(.secondary)
            if !s.isUpdate {
                field("Title", text: $s.title, prompt: "Podcast desk", hint: "\(s.title.utf16.count) of \(SharedSetupTable.titleMax)")
                field("One line", text: $s.line, prompt: "Voice chain for a dynamic mic, thirds for notes beside the recording app.", hint: "\(s.line.utf16.count) of \(SharedSetupTable.lineMax)")
                if !s.gearTags.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Made for (from your gear scan)").font(Brand.caption).foregroundStyle(.secondary)
                        WrapLayout(spacing: 5) { ForEach(Array(s.gearTags.enumerated()), id: \.offset) { _, m in GearTag(model: m, fit: .have) } }
                        Text("Model names only: never a serial number, never a name you gave a device.").font(Brand.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                field("What changed, in one line", text: $s.note, prompt: "Gentler presence lift, less harsh on S sounds.", hint: "\(s.note.utf16.count) of 200")
            }
            if s.mode == .share { handleBlock }
            if let m = s.message { Text(m).font(Brand.subheadline).foregroundStyle(Brand.accentText).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            if !s.errors.isEmpty {
                BrandCard {
                    SectionLabel("Fix these and try again")
                    ForEach(Array(s.errors.enumerated()), id: \.offset) { _, v in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(v.message).font(Brand.subheadline).fixedSize(horizontal: false, vertical: true)
                            Text("\(v.line) · \(v.limit)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                if s.mode == .file { Button("Save the file") { s.saveFile() }.buttonStyle(.brand).disabled(ShareFields.titleProblem(s.title) != nil || ShareFields.lineProblem(s.line) != nil) }
                else { Button(s.isUpdate ? "Share update" : "Share") { Task { await s.send() } }.buttonStyle(.brand).disabled(!s.canSend || s.busy).keyboardShortcut(.defaultAction) }
                Button("Back") { s.back() }.buttonStyle(.brandPlain)
            }
            if s.mode == .file { Text("Anyone with Whoprrr can open this file and see how it fits their gear. Nothing is uploaded.").font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    @ViewBuilder private var handleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if s.needsHandle {
                field("Your handle", text: $s.handleText, prompt: "ana.kitchen", hint: "3 to 20 of a–z, 0–9, dot, underscore")
                if let p = s.handleProblem { Text(p).font(Brand.caption).foregroundStyle(Brand.accentText) }
                else if !s.handleText.isEmpty, let p = ShareFields.handleProblem(s.handleText) { Text(p).font(Brand.caption).foregroundStyle(.secondary) }
            } else {
                HStack { Text("Shown as").font(Brand.caption).foregroundStyle(.secondary); Text(c.handle ?? "").font(Brand.headline).lineLimit(1) }
            }
            Text("Sharing makes your handle, your keeps and your kitchen time public. From then on this Mac’s daily check also tells the shelf you were here, under your handle, so kitchen days can be counted. It stops if you take down everything you shared.")
                .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(label).font(Brand.caption).foregroundStyle(.secondary); Spacer(); Text(hint).font(Brand.caption2).foregroundStyle(.secondary) }
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).font(Brand.body).accessibilityLabel(label)
        }
    }

    // MARK: 3. Result

    private var result: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let closed = s.closedReason {
                SharingClosedCard(message: closed)
                Button("OK") { c.sharing = nil }.buttonStyle(.brand)
            } else if s.mode == .file {
                Text("File saved").font(Brand.display(20, .semibold))
                BrandCard {
                    Text(s.savedFile?.lastPathComponent ?? s.fileName).font(Brand.headline).lineLimit(2)
                    Text("\(s.fileSize) · settings only, same exclusions as sharing").font(Brand.caption).foregroundStyle(.secondary)
                    Text("Saved in the Whoprrr folder in your home folder. Move it wherever you like.").font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let copy = s.copiedTo { Text("A copy is in \(copy.deletingLastPathComponent().lastPathComponent).").font(Brand.caption).foregroundStyle(.secondary) }
                    Text("Anyone with Whoprrr can open this file and see how it fits their gear. Nothing was uploaded.").font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack { Button("Show in Finder") { if let u = s.savedFile { NSWorkspace.shared.activateFileViewerSelecting([u]) } }.buttonStyle(.brandQuiet); Button("Save a copy somewhere else…") { s.saveCopyElsewhere() }.buttonStyle(.brandQuiet); Button("Done") { c.sharing = nil }.buttonStyle(.brand) }
            } else if let o = s.outcome {
                resultCard(o)
                HStack(spacing: 8) {
                    if o.state == .held || o.state == .checking { Button("See the private preview") { c.sharing = nil; c.route = .mine; Task { if let card = c.mine?.picklsss.first(where: { $0.id == o.id }) { await c.openOwn(card) } } }.buttonStyle(.brandQuiet) }
                    Button("My shared setups") { c.sharing = nil; c.route = .mine; Shared.nav.page = .picklsss }.buttonStyle(.brandQuiet)
                    Button("Done") { c.sharing = nil }.buttonStyle(.brand)
                }
            }
        }
    }

    @ViewBuilder private func resultCard(_ o: ShareOutcome) -> some View {
        switch o.state {
        case .public:
            Text(s.isUpdate ? "Your update is public" : "\(s.title) is a picklsss now").font(Brand.display(20, .semibold))
            BrandCard {
                Text("Accepted and public").font(Brand.headline)
                Text(s.isUpdate ? "People who took the earlier version are offered this one, with your note. Nobody’s Mac changes by itself." : "Shown as \(o.handle). Nobody has taken it yet.").font(Brand.subheadline).foregroundStyle(.secondary)
                if s.freeExtraNow || c.hasExtra && !s.isUpdate { Text("Picklsss (setups other people shared) is yours at no cost, because a picklsss you shared was accepted. It covers this Mac and your others.").font(Brand.subheadline).fixedSize(horizontal: false, vertical: true) }
            }
        case .held, .checking:
            Text("Sent for a check").font(Brand.display(20, .semibold))
            BrandCard {
                StatusChip(text: "Being checked", tone: .warn)
                Text(o.reason.map { "We’ll look at it soon. Reason: \($0)." } ?? "We’ll look at it soon.").font(Brand.subheadline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text("Only you can see it until then. You can look at the private preview, and you will see its state under My shared setups.").font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .refused:
            Text("It was not accepted").font(Brand.display(20, .semibold))
            BrandCard { Text(o.reason ?? "The shelf did not accept it.").font(Brand.subheadline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
        case .removed:
            Text("It is off the shelf").font(Brand.display(20, .semibold))
        }
    }
}
