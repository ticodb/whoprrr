import SwiftUI
import AppKit
import InputCore
import LogitechCore
import WhopperKit

struct InputPanel: View {
    @EnvironmentObject var c: InputController
    @State private var editing: Rule?
    @State private var showReport = false

    var body: some View {
        if let r = editing {
            RuleEditor(rule: r, onSave: { c.save($0); editing = nil }, onCancel: { editing = nil })
        } else { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader("Keys and mouse", symbol: "keyboard", subtitle: "Remap, transform, layer") {
                PresetMenu(surface: PresetSurfaces.input(c))
                Toggle("", isOn: Binding(get: { c.settings.enabled }, set: { c.settings.enabled = $0 })).toggleStyle(.switch).labelsHidden().controlSize(.regular)
            }
            statusBanner
            if let report = c.importReport { importCard(report) }

            HStack {
                SectionLabel("Rules")
                Spacer()
                Menu {
                    ForEach(InputPresets.all) { p in Button(p.title) { c.apply(preset: p) } }
                    Divider()
                    Button("Import from Karabiner…") { c.importKarabiner() }
                } label: { Text("Presets & import") }
                    .menuStyle(.button).buttonStyle(.brandQuiet).fixedSize()
                Button("Add rule") { editing = Rule(trigger: .key(0), tap: .chord(Chord(0))) }.buttonStyle(.brand)
            }
            if c.settings.rules.isEmpty {
                BrandCard {
                    Text("No rules yet.").font(Brand.display(15, .semibold))
                    Text("Start from a preset (numpad period, Spanish accents, Caps Lock as Esc/Ctrl…), bring your Karabiner rules over, or add your own.")
                        .font(Brand.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(c.settings.rules) { r in row(r) }

            if !c.settings.hidMappings.isEmpty { hidSection }
            mouseSection

            BrandCard {
                HStack {
                    Button("Test remapping") { c.selfTest() }.buttonStyle(.brandQuiet)
                    if let t = c.selfTestResult { Text(t).font(Brand.caption).foregroundStyle(t.hasPrefix("Working") ? Color.green : .orange).fixedSize(horizontal: false, vertical: true) }
                }
                KeyboardsSeen()
                Text("Emergency off: press ⌃⌥⇧⌘⎋ to pause every rule; press it again to resume. Secure fields (passwords) bypass all remapping, by macOS design.")
                    .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Status

    @ViewBuilder private var statusBanner: some View {
        switch c.status {
        case .needsAccessibility: banner("Needs Accessibility to remap keys.", .accessibility)
        case .needsInputMonitoring: banner("Needs Input Monitoring to see keys and mouse buttons.", .inputMonitoring)
        case .failed: StatusChip(text: "Could not start the input tap", tone: .bad)
        case .paused: StatusChip(text: "Paused by ⌃⌥⇧⌘⎋ (press again to resume)", tone: .warn)
        case .running: StatusChip(text: "Running", tone: .good)
        case .off: StatusChip(text: "Off", tone: .neutral)
        }
    }

    private func banner(_ text: String, _ p: Permission) -> some View {
        BrandCard {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(text).font(Brand.caption)
                    HStack {
                        Button("Grant") { PermissionRequester.request(p) }.buttonStyle(.brand)
                        Button("Open pane") { NSWorkspace.shared.open(p.settingsURL) }.buttonStyle(.link).font(Brand.caption)
                    }
                }
            }
        }
    }

    private func importCard(_ r: InputController.ImportReport) -> some View {
        BrandCard {
            HStack {
                Image(systemName: r.error == nil ? "arrow.down.doc.fill" : "exclamationmark.triangle.fill").foregroundStyle(r.error == nil ? Brand.accentText : .orange)
                Text(r.error ?? "Imported \(r.added) rule\(r.added == 1 ? "" : "s")\(r.hid > 0 ? ", \(r.hid) key replacement\(r.hid == 1 ? "" : "s")" : "")\(r.skipped > 0 ? "; \(r.skipped) skipped" : "").")
                    .font(Brand.display(14, .semibold))
                Spacer()
                Button { c.importReport = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            if r.error == nil {
                Text("Quit Karabiner-Elements so the same rule does not run twice.").font(Brand.caption2).foregroundStyle(.secondary)
                if !r.warnings.isEmpty {
                    DisclosureGroup("\(r.warnings.count) note\(r.warnings.count == 1 ? "" : "s")", isExpanded: $showReport) {
                        ForEach(r.warnings, id: \.self) { Text("• \($0)").font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }.font(Brand.caption)
                }
            }
        }
    }

    // MARK: Rules

    /// "Middle button (wheel click) → Mission Control": Logitech buttons by name, commands by title.
    private func triggerName(_ t: Trigger) -> String {
        if case .logi(let cid) = t { return Reprog.name(of: UInt16(cid)) }
        return t.label
    }
    private func outputName(_ o: Output) -> String {
        if case .command(let id) = o {
            let title = c.commands.first { $0.id == id }?.title ?? CommonActions.all.first { $0.id == id }?.title ?? SystemActions.all.first { $0.id == id }?.title
            return title?.replacingOccurrences(of: "Window: ", with: "") ?? (id == "clipboard.open" ? "Open clipboard history" : o.summary)
        }
        return o.summary
    }
    private func describe(_ r: Rule) -> String {
        let t = r.requiredMods.symbols + triggerName(r.trigger)
        if let h = r.hold { return "\(t): tap → \(outputName(r.tap)), hold → \(outputName(h))" }
        return "\(t) → \(outputName(r.tap))"
    }

    private func row(_ r: Rule) -> some View {
        BrandCard {
            HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: Binding(get: { r.enabled }, set: { var n = r; n.enabled = $0; c.save(n) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    if !r.name.isEmpty { Text(r.name).font(Brand.display(14.5, .semibold)) }
                    Text(describe(r)).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        if !r.layouts.isEmpty { chip(r.layouts.map { $0.rawValue.uppercased() }.joined(separator: "/") + " keyboards") }
                        if !r.keyboardTypes.isEmpty { chip("keyboard " + r.keyboardTypes.map(String.init).joined(separator: ", ")) }
                        if r.scope.mode != .everywhere { chip("\(r.scope.mode == .only ? "only in" : "except in") \(r.scope.bundleIDs.count) app\(r.scope.bundleIDs.count == 1 ? "" : "s")") }
                        if let l = r.layer { chip("layer “\(l)”") }
                    }
                }
                Spacer(minLength: 4)
                Button { editing = r } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                Button { c.delete(r.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
            }
        }
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .medium, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Brand.violet.opacity(0.14), in: Capsule()).foregroundStyle(Brand.accentText)
    }

    private var hidSection: some View {
        BrandCard {
            SectionLabel("Key replacements active")
            ForEach(c.settings.hidMappings, id: \.self) { m in
                HStack { Text("\(Self.name(m.src)) → \(Self.name(m.dst))").font(Brand.caption); Spacer()
                    Button { c.settings.hidMappings.removeAll { $0 == m } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain) }
            }
            Text("Applied by macOS itself so Caps Lock and modifier keys can be remapped. Removed when Whoprrr quits.").font(Brand.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Mouse

    private var mouseSection: some View {
        BrandCard {
            HStack {
                SectionLabel("Mouse and Logitech buttons")
                Spacer()
                Button(c.learningLogitech ? "Press a button on the mouse…" : "Learn a button") {
                    if c.learningLogitech { c.cancelLearn() } else {
                        c.learnLogitech { cid in editing = Rule(name: Reprog.name(of: UInt16(cid)), trigger: .logi(cid), tap: .command("clipboard.open")) }
                    }
                }.buttonStyle(.brandQuiet)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Any mouse: middle, back, forward").font(Brand.display(14.5, .semibold))
                buttonRow(title: "Middle click", trigger: .mouse(2))
                buttonRow(title: "Back button", trigger: .mouse(3))
                buttonRow(title: "Forward button", trigger: .mouse(4))
            }
            if c.logiDevices.isEmpty {
                Text("No Logitech device found. Move the mouse to wake it. Quit Logi Options+ first: two apps cannot both own the buttons.")
                    .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(c.logiDevices) { d in
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.name).font(Brand.display(14.5, .semibold))
                    ForEach(listed(d)) { ctl in logiRow(ctl) }
                    if listed(d).isEmpty { Text("No remappable buttons reported.").font(Brand.caption2).foregroundStyle(.secondary) }
                }
            }
            if !c.logiDevices.isEmpty { LogiLastPress() }
            Text("Whoprrr only takes over buttons that have a rule. Left and right click can’t be remapped. For a button that does one thing in one app, use “Add rule” and pick “Only in…”.")
                .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Middle, back and forward are listed once, under "Any mouse", whichever way their rule is stored.
    private func listed(_ d: LogiDevice) -> [Reprog.Control] {
        let standard: Set<UInt16> = [0x0052, 0x0053, 0x0056]
        return d.controls.filter { $0.isDivertable && !standard.contains($0.cid) }
    }

    private func logiRow(_ ctl: Reprog.Control) -> some View {
        buttonRow(title: ctl.name, trigger: .logi(Int(ctl.cid)))
    }

    /// The Logitech control that carries the same button, for devices whose standard buttons are diverted.
    private func logiAlias(_ t: Trigger) -> Trigger? {
        guard case .mouse(let b) = t else { return nil }
        switch b { case 2: return .logi(0x52); case 3: return .logi(0x53); case 4: return .logi(0x56); default: return nil }
    }

    /// One button: its name, what it does now, and a menu to give it something to do.
    private func buttonRow(title: String, trigger: Trigger) -> some View {
        let alias = logiAlias(trigger)
        let rule = c.settings.rules.first { ($0.trigger == trigger || (alias != nil && $0.trigger == alias!)) && $0.requiredMods.isEmpty && $0.layer == nil }
        return HStack(spacing: 6) {
            Text(title).font(Brand.caption)
            Spacer()
            if let rule {
                Text(outputName(rule.tap)).font(Brand.caption).foregroundStyle(Brand.accentText).lineLimit(1)
                Button { editing = rule } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                Button { c.delete(rule.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
            } else {
                if case .mouse(let b) = trigger {
                    Text(b == 3 ? "Default: Back in browsers and Finder" : b == 4 ? "Default: Forward in browsers and Finder" : "Default: middle click")
                        .font(Brand.caption2).foregroundStyle(.secondary)
                }
                assignMenu(title: title, trigger: trigger)
            }
        }
    }

    private func assignMenu(title: String, trigger: Trigger) -> some View {
        func give(_ o: Output) { c.save(Rule(name: title, trigger: trigger, tap: o)) }
        return Menu("Assign") {
            ForEach(CommonActions.categories, id: \.self) { cat in
                Menu(cat) {
                    ForEach(CommonActions.all.filter { $0.category == cat }) { a in
                        Button { give(.command(a.id)) } label: { Label(a.title, systemImage: a.symbol) }
                    }
                }
            }
            Menu("Media") { ForEach(MediaKey.allCases, id: \.self) { k in Button(k.title) { give(.media(k)) } } }
            Menu("System") {
                ForEach(c.systemActions, id: \.id) { a in Button { give(.command(a.id)) } label: { Label(a.title, systemImage: a.symbol) } }
            }
            Menu("Whoprrr") {
                Button { give(.command("clipboard.open")) } label: { Label("Clipboard history", systemImage: "doc.on.clipboard") }
                Menu("Window") {
                    ForEach(c.commands.filter { $0.id.hasPrefix("window.") }, id: \.id) { cmd in
                        Button(cmd.title.replacingOccurrences(of: "Window: ", with: "")) { give(.command(cmd.id)) }
                    }
                }
            }
            Divider()
            Button("Open an app…") { if let b = OutputEditor.chooseApp() { give(.openApp(b)) } }
            Button("Key combo or something else…") { editing = Rule(name: title, trigger: trigger, tap: .chord(Chord(0))) }
        }.menuStyle(.button).buttonStyle(.brandQuiet).fixedSize()
    }

    static func name(_ usage: UInt64) -> String {
        switch usage {
        case HIDMapping.capsLock: "Caps Lock"; case HIDMapping.f18: "F18"; case HIDMapping.f19: "F19"
        case HIDMapping.rightCommand: "Right ⌘"; case HIDMapping.rightOption: "Right ⌥"
        case 0x700000029: "Escape"
        case 0x7000000E0: "Left ⌃"; case 0x7000000E1: "Left ⇧"; case 0x7000000E2: "Left ⌥"; case 0x7000000E3: "Left ⌘"
        case 0x7000000E4: "Right ⌃"; case 0x7000000E5: "Right ⇧"
        default: String(format: "0x%llX", usage)
        }
    }
}

/// Shows the last Logitech press Whoprrr received: proof a button is really being taken over.
struct LogiLastPress: View {
    @EnvironmentObject var c: InputController
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let p = c.lastLogiPress {
                let secs = max(0, Int(ctx.date.timeIntervalSince(p.time)))
                Label("Last press seen: \(p.name), \(secs < 2 ? "just now" : "\(secs) s ago")", systemImage: "checkmark.circle.fill")
                    .font(Brand.caption).foregroundStyle(Color.green)
            } else {
                Label("Press a button you assigned. Nothing seen yet.", systemImage: "circle.dashed").font(Brand.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// "Keyboards seen: 40 (ANSI) ×120 …": the raw keyboard types behind recent key presses.
struct KeyboardsSeen: View {
    @EnvironmentObject var c: InputController
    @State private var seen: [Int: Int] = [:]
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    var body: some View {
        Group {
            if seen.isEmpty {
                Text("Type on each keyboard once to see how macOS tells them apart.").font(Brand.caption2).foregroundStyle(.secondary)
            } else {
                Text("Keyboards seen: " + seen.sorted { $0.key < $1.key }.map { "type \($0.key) (\(KeyboardLayout(keyboardType: $0.key)?.rawValue.uppercased() ?? "?")) ×\($0.value)" }.joined(separator: ", "))
                    .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { seen = c.keyboardsSeen() }
        .onReceive(timer) { _ in seen = c.keyboardsSeen() }
    }
}

struct RuleEditor: View {
    @State var rule: Rule
    var onSave: (Rule) -> Void
    var onCancel: () -> Void
    @State private var dual: Bool
    @State private var holdOut: Output
    @State private var learningKeyboard = false
    @State private var kbMonitor: Any?

    init(rule: Rule, onSave: @escaping (Rule) -> Void, onCancel: @escaping () -> Void) {
        _rule = State(initialValue: rule); self.onSave = onSave; self.onCancel = onCancel
        _dual = State(initialValue: rule.hold != nil); _holdOut = State(initialValue: rule.hold ?? .modifiers(.control))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(rule.name.isEmpty ? "Rule" : rule.name, symbol: "slider.horizontal.3")
                .environment(\.showsRecipeSaveMark, false)
            TextField("Name (optional)", text: $rule.name).textFieldStyle(.roundedBorder)

            BrandCard {
                SectionLabel("When I press")
                TriggerRecorder(trigger: $rule.trigger, mods: $rule.requiredMods, onKeyboard: noteKeyboard)
                if case .mouse(let b) = rule.trigger, b < 2 { Text("Left and right click cannot be remapped.").font(Brand.caption2).foregroundStyle(.red) }
                if case .logi = rule.trigger { Text("A Logitech button: Whoprrr takes it over only while this rule is on.").font(Brand.caption2).foregroundStyle(.secondary) }
                Toggle("Also when extra modifiers are held", isOn: $rule.allowExtraModifiers).font(Brand.caption)
            }

            BrandCard {
                SectionLabel(dual ? "Tap does" : "Do")
                OutputEditor(output: $rule.tap)
                Toggle("Different action when held (dual role)", isOn: $dual).font(Brand.caption)
                if dual {
                    SectionLabel("Hold does")
                    OutputEditor(output: $holdOut)
                    HStack { Text("Hold after").font(Brand.caption); Slider(value: Binding(get: { Double(rule.holdMs) }, set: { rule.holdMs = Int($0) }), in: 100...600, step: 10)
                        Text("\(rule.holdMs) ms").font(Brand.caption.monospacedDigit()).frame(width: 56, alignment: .trailing) }
                }
            }

            BrandCard {
                SectionLabel("Which keyboard")
                HStack(spacing: 6) {
                    ForEach(KeyboardLayout.allCases, id: \.self) { l in
                        let on = rule.layouts.contains(l)
                        Button(l.rawValue.uppercased()) { if on { rule.layouts.removeAll { $0 == l } } else { rule.layouts.append(l) } }
                            .buttonStyle(.plain).font(.system(size: 13, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(on ? AnyShapeStyle(Brand.violet) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
                            .foregroundStyle(on ? Color.white : Color.primary)
                    }
                    Text(rule.layouts.isEmpty && rule.keyboardTypes.isEmpty ? "any keyboard" : "").font(Brand.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Button(learningKeyboard ? "Type a key on that keyboard…" : "Learn a specific keyboard") { learningKeyboard ? stopLearning() : startLearning() }.buttonStyle(.brandQuiet)
                    ForEach(rule.keyboardTypes, id: \.self) { t in
                        HStack(spacing: 2) { Text("type \(t)").font(Brand.caption2); Button { rule.keyboardTypes.removeAll { $0 == t } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Brand.violet.opacity(0.14), in: Capsule())
                    }
                }
                Text("ANSI is a US-style keyboard, ISO a European one (Spanish included). Two keyboards of the same layout can still be told apart by learning one.")
                    .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            BrandCard {
                SectionLabel("Where")
                Picker("", selection: $rule.scope.mode) {
                    Text("Everywhere").tag(Scope.Mode.everywhere); Text("Only in…").tag(Scope.Mode.only); Text("Everywhere except…").tag(Scope.Mode.except)
                }.pickerStyle(.segmented).labelsHidden()
                if rule.scope.mode != .everywhere {
                    ForEach(rule.scope.bundleIDs, id: \.self) { b in
                        HStack { Text(b).font(Brand.caption); Spacer(); Button { rule.scope.bundleIDs.removeAll { $0 == b } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain) }
                    }
                    Button("Add app…") { if let b = OutputEditor.chooseApp(), !rule.scope.bundleIDs.contains(b) { rule.scope.bundleIDs.append(b) } }.buttonStyle(.brandQuiet)
                }
                DisclosureGroup("Layer") {
                    TextField("Only while this layer is on (optional)", text: Binding(get: { rule.layer ?? "" }, set: { rule.layer = $0.isEmpty ? nil : $0 })).textFieldStyle(.roundedBorder)
                }.font(Brand.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { stopLearning(); onCancel() }.buttonStyle(.brandQuiet)
                Button("Save") { stopLearning(); var r = rule; r.hold = dual ? holdOut : nil; onSave(r) }.keyboardShortcut(.defaultAction).buttonStyle(.brand).disabled(saveDisabled)
            }
        }
        .onDisappear(perform: stopLearning)
    }

    private func noteKeyboard(_ type: Int) { /* offered through "Learn a specific keyboard" so a plain key press never changes the filter */ }

    private func startLearning() {
        learningKeyboard = true
        kbMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            if let t = e.cgEvent?.getIntegerValueField(.keyboardEventKeyboardType), !rule.keyboardTypes.contains(Int(t)) { rule.keyboardTypes.append(Int(t)) }
            stopLearning(); return nil
        }
    }
    private func stopLearning() {
        learningKeyboard = false
        if let m = kbMonitor { NSEvent.removeMonitor(m); kbMonitor = nil }
    }

    private var saveDisabled: Bool { if case .mouse(let b) = rule.trigger { return b < 2 }; return false }
}
