import SwiftUI
import DisplayCore

/// The external displays module panel. The shell supplies padding, width and Quit.
struct DisplayPanel: View {
    @EnvironmentObject var m: AppModel
    @State private var tab = Tab(rawValue: ProcessInfo.processInfo.environment["SDC_TAB"] ?? "") ?? Tab.control
    enum Tab: String, CaseIterable { case control = "Control", pattern = "Match", presets = "Presets", learn = "Learn", diagnostics = "Log" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            Group {
                switch tab {
                case .control: ControlTab()
                case .pattern: PatternTab()
                case .presets: PresetsTab()
                case .learn: LearnTab()
                case .diagnostics: DiagnosticsTab()
                }
            }
            Divider()
            HStack(alignment: .top) {
                Text(m.status).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }

    var header: some View {
        HStack {
            Image(systemName: "display").font(Brand.title3)
            Text("External displays").font(Brand.headline)
            Spacer()
            if m.transportKind == .fake {
                Text("FAKE TRANSPORT").font(Brand.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.25), in: Capsule())
            }
        }
    }
}

// MARK: Control

struct ControlTab: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisplayList()
            if m.registry.needsRefresh || !m.registry.snapshotIsCurrent {
                Label("Display connection changed. Refreshing; controls stay off until re-read.", systemImage: "arrow.triangle.2.circlepath")
                    .font(Brand.caption).foregroundStyle(.orange)
            }

            if let d = m.selected, !d.isBuiltIn {
                Scroller {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(["Picture", "Color", "Audio", "System"], id: \.self) { group in
                            let specs = Catalog.known.filter { $0.group == group }
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.uppercased()).font(Brand.caption2.bold()).foregroundStyle(.secondary)
                                ForEach(specs, id: \.key) { SettingRow(spec: $0) }
                            }
                        }
                        if !m.learned.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("LEARNED FROM OSD").font(Brand.caption2.bold()).foregroundStyle(.secondary)
                                ForEach(m.learned) { LearnedRow(setting: $0) }
                            }
                        }
                    }.padding(.trailing, 6)
                }
                Button("Read from display") { Task { await m.readAll() } }.disabled(m.busy || m.target == nil)
            } else if m.selected?.isBuiltIn == true {
                Text("The MacBook display is the comparison reference. No hardware writes are ever sent to it.")
                    .font(Brand.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Fixed-height scroller. (Snapshot mode, used only for development renders, skips scrolling because
/// ImageRenderer cannot draw AppKit-backed scroll views.)
struct Scroller<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder _ content: @escaping () -> Content) { self.content = content }
    var body: some View {
        if ProcessInfo.processInfo.environment["SDC_SNAPSHOT"] != nil { content() }
        else { ScrollView { content() }.frame(height: 420) }
    }
}

struct SettingRow: View {
    @EnvironmentObject var m: AppModel
    let spec: SettingSpec

    var body: some View {
        let state = m.states[spec.control] ?? .unknown
        let editable = m.controlsEnabled && !m.busy && Control.defaultWritable.contains(spec.control)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(spec.label).font(Brand.callout)
                Spacer()
                switch state {
                case .value(let v) where spec.kind == .slider: Text("\(v.current) / \(v.maximum)").font(Brand.caption.monospacedDigit()).foregroundStyle(.secondary)
                case .failed(let why): Text(why).font(Brand.caption).foregroundStyle(.red)
                case .unknown: Text("—").font(Brand.caption).foregroundStyle(.secondary)
                default: EmptyView()
                }
            }
            if case .value(let v) = state {
                switch spec.kind {
                case .slider:
                    HStack {
                        Slider(value: Binding(get: { m.drafts[spec.control] ?? Double(v.current) }, set: { m.drafts[spec.control] = $0 }),
                               in: 0...Double(max(v.maximum, 1)), step: 1) { editing in
                            if !editing { m.commit(spec.control, value: Int((m.drafts[spec.control] ?? Double(v.current)).rounded())) }
                        }.disabled(!editable)
                        Text("\(Int((m.drafts[spec.control] ?? Double(v.current)).rounded()))")
                            .font(Brand.callout.monospacedDigit()).frame(width: 30, alignment: .trailing)
                    }
                case .choice(let choices):
                    let extra = (spec.control == .colorPreset && v.current == Catalog.customTone) ? [Choice(Catalog.customTone, "Custom (from RGB)")] : []
                    Picker("", selection: Binding(get: { v.current }, set: { m.commit(spec.control, value: $0) })) {
                        ForEach(extra + choices, id: \.value) { Text($0.label).tag($0.value) }
                        if !(extra + choices).contains(where: { $0.value == v.current }) { Text("Value \(v.current)").tag(v.current) }
                    }.labelsHidden().disabled(!editable)
                }
            }
            if let o = m.lastOutcomes[spec.control] {
                Text(o.verified ? "verified by readback" : o.adjusted ? "display settled on \(o.readback!)" : "UNVERIFIED (readback \(o.readback.map(String.init) ?? "missing"))")
                    .font(Brand.caption2).foregroundStyle(o.accepted ? Color.green : Color.orange)
            }
            if let n = spec.note { Text(n).font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct LearnedRow: View {
    @EnvironmentObject var m: AppModel
    let setting: LearnedSetting
    var body: some View {
        let state = m.states[setting.control] ?? .unknown
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(setting.name).font(Brand.callout)
                Text(String(format: "0x%02X", setting.code)).font(Brand.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if case .value(let v) = state { Text("now \(v.current)").font(Brand.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Button("Forget") { m.forget(setting) }.buttonStyle(.link).font(Brand.caption)
            }
            HStack(spacing: 6) {
                ForEach(setting.observed, id: \.self) { v in
                    Button("\(v)") { m.commit(setting.control, value: v) }.buttonStyle(.bordered).controlSize(.regular)
                        .disabled(!m.controlsEnabled || m.busy)
                }
                if case .value(let cur) = state {
                    Stepper("", onIncrement: { m.commit(setting.control, value: min(cur.current + 1, max(setting.maximum, cur.current))) },
                            onDecrement: { m.commit(setting.control, value: max(cur.current - 1, 0)) })
                        .labelsHidden().disabled(!m.controlsEnabled || m.busy)
                }
            }
            if let o = m.lastOutcomes[setting.control] {
                Text(o.verified ? "verified by readback" : "readback \(o.readback.map(String.init) ?? "missing")")
                    .font(Brand.caption2).foregroundStyle(o.accepted ? Color.green : Color.orange)
            }
        }
    }
}

// MARK: Learn

struct LearnTab: View {
    @EnvironmentObject var m: AppModel
    @State private var names: [UInt8: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find monitor settings the app doesn’t know yet. Steps:").font(Brand.subheadline.bold())
            Text("1 Scan  →  2 Take “before”  →  3 change ONE item in the monitor’s OSD  →  4 Compare  →  name what changed. It then appears under Control with one-tap values.")
                .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("1 · Scan display") { m.runFullScan() }.disabled(m.target == nil || m.busy)
                Button("2 · Take “before”") { m.takeBefore() }.disabled(m.fullScan == nil || m.busy)
                Button("4 · Compare") { m.compare() }.disabled(m.beforeScan == nil || m.busy)
            }
            if let p = m.scanProgress { ProgressView(value: Double(p), total: 255) }
            if let full = m.fullScan { Text("\(full.count) DDC codes answer on this display.").font(Brand.caption).foregroundStyle(.secondary) }

            if let d = m.diff {
                if d.isEmpty { Text("Nothing changed. That OSD item may not be reachable over DDC.").font(Brand.callout) }
                ForEach(d, id: \.code) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "VCP 0x%02X changed %d → %d (max %d)", item.code, item.before, item.after, item.maximum))
                            .font(Brand.callout.monospacedDigit())
                        HStack {
                            TextField("Name it (e.g. Game mode)", text: Binding(get: { names[item.code] ?? "" }, set: { names[item.code] = $0 }))
                                .textFieldStyle(.roundedBorder)
                            Button("Save") { m.saveLearned(item, name: names[item.code] ?? "") }
                        }
                    }
                    Divider()
                }
                Text("Learn each OSD item a few times at different values to collect its one-tap values. Factory-reset, power and settings-save codes are never offered.")
                    .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Visual match

struct PatternTab: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 12) {
                AutoMatchBox()
                Divider()
                Text("Manual match (by eye)").font(Brand.subheadline.bold())
                Button("Open test pattern on both displays") { m.openPatterns() }
                    .disabled(m.selectedUUID == nil || m.selected?.isBuiltIn == true)
                Text("Drag the windows side by side and compare white, gray and the 40–60 % steps. Use the Control tab sliders. You judge the match.")
                    .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Close patterns") { m.patterns.close() }
            }.padding(.trailing, 6)
        }
    }
}

struct AutoMatchBox: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject var camera: CameraSource
    init() { _camera = ObservedObject(wrappedValue: Shared.model.camera) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Auto match (camera)").font(Brand.subheadline.bold())
            Text("Put a camera where it sees BOTH screens at once and keep it still: an iPhone on a stand (Continuity Camera) or a webcam. The app lights each screen, measures, and adjusts the Samsung’s brightness and RGB gains until it matches the MacBook. No OSD needed.")
                .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("", selection: Binding(get: { camera.selectedID ?? "" }, set: { camera.selectedID = $0 })) {
                    if camera.devices.isEmpty { Text("No camera found").tag("") }
                    ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }.labelsHidden().disabled(m.previewing || m.matching)
                Button { camera.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }.help("Rescan cameras")
            }
            Button(m.previewing ? "Stop preview" : "Preview camera (aim it)") { m.togglePreview() }.disabled(m.matching || camera.devices.isEmpty)
            if let img = camera.preview {
                Image(decorative: img, scale: 1).resizable().scaledToFit().frame(maxHeight: 150).cornerRadius(6)
            }
            Text("Tips: keep the room light steady, turn off Studio Light / Center Stage / tracking, and disable True Tone on the MacBook while matching.")
                .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(m.matching ? "Matching… (Esc cancels)" : "Match display to MacBook") { m.startMatch() }
                    .disabled(!m.canAutoMatch).buttonStyle(.borderedProminent)
                if m.matching { Button("Cancel") { m.cancelMatch() } }
            }
            if m.selectedUUID == nil || m.selected?.isBuiltIn == true {
                Text("Pick a display on the Control tab first.").font(Brand.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(m.matchLog.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            if m.lastReport != nil, !m.matching, !m.matchLog.isEmpty {
                HStack {
                    Button("Undo (restore earlier values)") { m.restoreLast() }.disabled(m.busy)
                    Text("Then save the result from the Presets tab.").font(Brand.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Presets

struct PresetsTab: View {
    @EnvironmentObject var m: AppModel
    @State private var name = ""
    @State private var notes = ""
    @State private var preview: Preset?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let e = m.presetError { Text(e).font(Brand.caption).foregroundStyle(.red) }
            if m.target == nil { Text("Select a display to save or apply presets.").font(Brand.callout).foregroundStyle(.secondary) }

            GroupBox("Save current settings") {
                VStack(alignment: .leading) {
                    TextField("Preset name", text: $name).textFieldStyle(.roundedBorder)
                    TextField("Notes (e.g. OSD color tone, gamma)", text: $notes).textFieldStyle(.roundedBorder)
                    Button("Save snapshot") { m.savePreset(name: name.isEmpty ? "Untitled" : name, notes: notes); name = ""; notes = "" }
                        .disabled(!m.controlsEnabled || m.busy)
                }
            }

            ForEach(m.presetsForSelected()) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(p.name).font(Brand.callout.bold())
                        Spacer()
                        Button("Preview") { preview = (preview?.id == p.id) ? nil : p }.buttonStyle(.link)
                        Button("Delete") { m.deletePreset(p) }.buttonStyle(.link)
                    }
                    if !p.notes.isEmpty { Text(p.notes).font(Brand.caption).foregroundStyle(.secondary) }
                    if preview?.id == p.id {
                        ForEach(m.controller.plan(p), id: \.control) { item in
                            HStack {
                                Text(item.control.label).font(Brand.caption)
                                Spacer()
                                Text("\(item.saved)").font(Brand.caption.monospacedDigit())
                                Text(item.status == .willApply ? "will apply" : { if case .skipped(let w) = item.status { return "skipped: \(w)" }; return "" }())
                                    .font(Brand.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Button("Apply to display") { m.apply(p) }.disabled(!m.controlsEnabled || m.busy)
                    }
                }
                Divider()
            }

            if let r = m.lastReport {
                Text("Last apply").font(Brand.subheadline.bold())
                ForEach(r.fields, id: \.control) { f in
                    HStack {
                        Text(f.control.label).font(Brand.caption)
                        Spacer()
                        Text(summary(f.status)).font(Brand.caption).foregroundStyle(f.isVerifiedSuccess ? .green : .secondary)
                    }
                }
                Button("Restore values from before apply") { m.restoreLast() }
                    .disabled(!m.controlsEnabled || m.busy)
                if let rr = m.lastRestore {
                    ForEach(rr, id: \.control) { f in
                        Text("restore \(f.control.label): \(summary(f.status))").font(Brand.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    func summary(_ s: FieldResult.Status) -> String {
        switch s {
        case .applied(let o): return o.verified ? "\(o.before.map(String.init) ?? "?") → \(o.applied) verified" : "wrote \(o.applied), UNVERIFIED (read \(o.readback.map(String.init) ?? "none"))"
        case .failed(let f): return "failed: \(f)"
        case .skipped(let w): return "skipped (\(w))"
        case .notRun: return "not run"
        }
    }
}

// MARK: Diagnostics

struct DiagnosticsTab: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(m.displays) { d in
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.displayName).font(Brand.callout.bold())
                    Text("vendor \(d.identity.vendor) · model \(d.identity.model) · DDC endpoint: \(d.hasEndpoint ? "yes (IOAVService)" : "none")")
                        .font(Brand.caption).foregroundStyle(.secondary)
                }
            }
            if let e = m.controller.log.lastDDCEvent {
                Text("Last DDC: [\(e.transport?.rawValue ?? "?")] \(e.ok == true ? "ok" : "ERROR") — \(Redaction.scrub(e.message, displays: m.displays))")
                    .font(Brand.caption).foregroundStyle(e.ok == true ? Color.secondary : Color.red)
            }
            HStack {
                Button("Mark blackout") { m.registry.markBlackout() }
                Button("Export redacted…") { m.exportDiagnostics() }
                Button("Rescan") { m.registry.scheduleRefresh(after: 0) }
            }
            Text("Timeline (latest first, last \(DiagnosticsLog.capacity))").font(Brand.caption.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(m.registry.events.reversed()) { e in
                        Text("\(e.timestamp.formatted(date: .omitted, time: .standard)) \(e.kind.rawValue)\(e.transport.map { "/\($0.rawValue)" } ?? ""): \(Redaction.scrub(e.message, displays: m.displays))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(e.ok == false ? Color.red : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(height: 150)
            Text("A blank screen that macOS still recognises leaves no event. Use “Mark blackout” when it happens.")
                .font(Brand.caption2).foregroundStyle(.secondary)
        }
    }
}


/// The external displays macOS reports, with which of them can actually be controlled. One that answers is picked for you.
struct DisplayList: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(m.externals.count > 1 ? "Displays" : "Display")
                Spacer()
                Button("Rescan") { Task { await m.registry.refreshNow() } }.buttonStyle(.brandQuiet)
            }
            if m.externals.isEmpty {
                BrandCard {
                    Label("No external display found", systemImage: "display.trianglebadge.exclamationmark").font(Brand.display(14.5, .semibold))
                    Text("Connect a monitor and Whoprrr finds it by itself. The MacBook’s own screen is never changed; it is only used as the reference for matching.")
                        .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(m.externals) { d in row(d) }
        }
    }

    private func row(_ d: DisplayDescriptor) -> some View {
        let reach = m.reach[d.uuid]
        let selected = m.selectedUUID == d.uuid
        let canPick = d.hasEndpoint && reach == .responds
        return BrandCard {
            HStack(spacing: 10) {
                Image(systemName: "display").font(.system(size: 18)).frame(width: 30).foregroundStyle(canPick ? Brand.accentText : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.identity.productName).font(Brand.display(15, .semibold))
                    Text(detail(d, reach)).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if !d.hasEndpoint { StatusChip(text: "Can’t be controlled", tone: .neutral) }
                else if reach == .checking || reach == nil { ProgressView().controlSize(.small) }
                else if reach == .silent { StatusChip(text: "Not answering", tone: .warn) }
                else if selected { StatusChip(text: "Selected", tone: .good) }
                else { Button("Use") { m.select(d.uuid) }.buttonStyle(.brandQuiet) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Brand.violetBright.opacity(0.6) : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { if canPick && !selected { m.select(d.uuid) } }
    }

    private func detail(_ d: DisplayDescriptor, _ reach: AppModel.Reach?) -> String {
        if !d.hasEndpoint { return "macOS sees it, but no DDC/CI link was found. Try another cable or port, or turn on DDC/CI in the monitor’s own menu." }
        switch reach {
        case .responds: return "Answers DDC/CI. Brightness, contrast and color can be controlled."
        case .silent: return "Detected, but it did not answer a brightness read. Try another cable or port."
        default: return "Checking whether it answers…"
        }
    }
}
