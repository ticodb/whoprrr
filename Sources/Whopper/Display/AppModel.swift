import SwiftUI
import AppKit
import Combine
import DisplayCore

enum ControlState: Equatable {
    case unknown
    case value(ControlValue)
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    let registry: DisplayRegistry
    let controller: DisplayController
    let store: PresetStore
    let learnedStore: LearnedStore
    let patterns = PatternWindows()
    private var bag = Set<AnyCancellable>()

    /// Explicit user choice. nil until the user picks an external display; nothing is written without it.
    @Published var selectedUUID: String?
    @Published private(set) var target: DisplayTarget?
    @Published private(set) var states: [Control: ControlState] = [:]
    @Published var drafts: [Control: Double] = [:]
    @Published var lastOutcomes: [Control: WriteOutcome] = [:]
    @Published var status: String = "Pick the Samsung to begin."
    @Published var busy = false
    @Published private(set) var presets: [Preset] = []
    @Published var presetError: String?
    /// Name of the last preset applied this session, so a recipe can reapply it.
    @Published private(set) var lastPresetName: String?
    @Published var lastReport: ApplyReport?
    @Published var lastRestore: [FieldResult]?
    @Published private(set) var learned: [LearnedSetting] = []

    // Auto match
    let camera = CameraSource()
    @Published var matching = false
    @Published var matchLog: [String] = []
    @Published var previewing = false
    private var matchTask: Task<Void, Never>?
    private var escMonitor: Any?

    // Learn
    @Published var scanProgress: Int?
    @Published var fullScan: ScanResult?
    @Published var beforeScan: ScanResult?
    @Published var diff: [ScanDiffItem]?

    init(useFake: Bool = ProcessInfo.processInfo.environment["SDC_FAKE"] == "1") {
        let transport: DDCTransport = useFake ? AppModel.fakeTransport() : HardwareTransport()
        controller = DisplayController(transport: transport)
        registry = DisplayRegistry(controller: controller)
        store = PresetStore(url: PresetStore.defaultURL())
        learnedStore = LearnedStore(url: LearnedStore.defaultURL())
        loadPresets()
        registry.$snapshot.sink { [weak self] snap in
            Task { @MainActor in self?.snapshotChanged(snap) }
        }.store(in: &bag)
        registry.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        registry.start()
    }

    var transportKind: TransportKind { controller.transport.kind }
    var displays: [DisplayDescriptor] { registry.displays }
    var selected: DisplayDescriptor? { displays.first { $0.uuid == selectedUUID } }
    var controlsEnabled: Bool {
        guard let t = target, registry.snapshotIsCurrent, t.generation == controller.generation.current else { return false }
        if case .value = states[.brightness] { return true }
        return false
    }

    func value(_ c: Control) -> ControlValue? { if case .value(let v)? = states[c] { return v }; return nil }

    // MARK: Selection and reads

    func select(_ uuid: String?) {
        selectedUUID = uuid
        target = nil
        states = [:]
        lastOutcomes = [:]
        guard let uuid, let d = displays.first(where: { $0.uuid == uuid }) else { return }
        if d.isBuiltIn { status = "Built-in display is the comparison reference. It is never written."; return }
        bind(to: d)
    }

    private func bind(to d: DisplayDescriptor) {
        do {
            target = try controller.target(for: d, in: registry.snapshot)
            learned = learnedStore.settings(for: d.identity)
            controller.writableControls = Control.defaultWritable.union(learned.map(\.control))
            fullScan = nil; beforeScan = nil; diff = nil
            status = "Reading \(d.identity.productName)…"
            Task { await readAll() }
        } catch {
            status = "\(error)"
        }
    }

    /// The registry rescanned after a topology change, sleep or wake. Never replays anything: controls stay
    /// disabled until the same display is found again and a fresh read succeeds.
    private func snapshotChanged(_ snap: DisplayController.Snapshot) {
        guard let uuid = selectedUUID else { return }
        let old = target
        target = nil
        states = [:]
        lastOutcomes = [:]
        if let d = snap.displays.first(where: { $0.uuid == uuid }), !d.isBuiltIn, old == nil || old?.identity == d.identity {
            bind(to: d)
        } else if let old, let t = try? controller.resolve(identity: old.identity, in: snap) {
            selectedUUID = t.uuid
            if let d = snap.displays.first(where: { $0.uuid == t.uuid }) { bind(to: d) }
        } else if old != nil {
            status = "Display changed or went away. Reselect the Samsung."
        }
    }

    var readList: [Control] { Control.allCases + learned.map(\.control) }

    func readAll() async {
        guard let t = target else { return }
        busy = true; defer { busy = false }
        for c in readList {
            do {
                let v = try await controller.read(c, target: t)
                states[c] = .value(v)
                drafts[c] = Double(v.current)
            } catch let f as DDCFailure {
                states[c] = .failed(f.description)
                if f == .stale { status = "Connection changed. Refreshing…"; return }
            } catch {}
        }
        if case .value = states[.brightness] { status = "Ready. These are hardware (DDC) settings, not software dimming." }
        else { status = "Brightness could not be read. Controls stay disabled." }
    }

    // MARK: Writing any setting (commit on release / explicit choice)

    func commit(_ c: Control, value requested: Int) {
        guard controlsEnabled, let t = target, !busy else { return }
        if c == .colorPreset, requested == Catalog.customTone {
            status = "Custom is entered by moving any RGB gain. Presets 1–4 are selectable."
            drafts[c] = Double(value(c)?.current ?? requested)
            return
        }
        if Catalog.spec(for: c)?.needsConfirm == true, !confirmRisky(c, requested) {
            drafts[c] = Double(value(c)?.current ?? requested)
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let o = try await controller.write(c, value: requested, target: t)
                lastOutcomes[c] = o
                if let r = o.readback { states[c] = .value(ControlValue(current: r, maximum: value(c)?.maximum ?? o.maximum)); drafts[c] = Double(r) }
                status = o.verified ? "\(c.label): wrote \(o.applied), readback \(o.readback!) — verified."
                    : o.adjusted ? "\(c.label): display settled on \(o.readback!) (steps)."
                    : "\(c.label): wrote \(o.applied) but readback was \(o.readback.map(String.init) ?? "missing") — UNVERIFIED."
                // Tone and RGB drive each other: refresh the group so the UI shows the truth.
                if [.colorPreset, .red, .green, .blue].contains(c) {
                    for dep in [Control.colorPreset, .red, .green, .blue] where dep != c {
                        if let v = try? await controller.read(dep, target: t) { states[dep] = .value(v); drafts[dep] = Double(v.current) }
                    }
                }
            } catch let f as DDCFailure {
                status = "\(c.label) not written: \(f)"
                if let v = value(c) { drafts[c] = Double(v.current) }
            } catch {}
        }
    }

    private func confirmRisky(_ c: Control, _ v: Int) -> Bool {
        let name = (Catalog.spec(for: c)?.kind).flatMap { kind -> String? in
            if case .choice(let cs) = kind { return cs.first { $0.value == v }?.label }; return nil } ?? "\(v)"
        let alert = NSAlert()
        alert.messageText = "Switch \(c.label) to \(name)?"
        alert.informativeText = Catalog.spec(for: c)?.note ?? "This can blank the screen."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Presets

    func loadPresets() {
        do { presets = try store.load(); presetError = nil } catch { presetError = "Presets file: \(error)"; presets = [] }
    }

    func presetsForSelected() -> [Preset] {
        guard let id = target?.identity ?? selected?.identity else { return [] }
        return presets.filter { $0.identity.matches(id) }
    }

    func savePreset(name: String, notes: String) {
        guard let t = target, controlsEnabled else { return }
        busy = true
        Task {
            defer { busy = false }
            let snap = await controller.snapshot(target: t, extra: learned.map(\.control))
            let p = Preset(name: name, identity: t.identity, values: snap.values, maximums: snap.maximums, notes: notes)
            do { try store.save(p); loadPresets(); status = "Saved “\(name)” (\(snap.values.count) values)." }
            catch { presetError = "Could not save: \(error)" }
        }
    }

    func deletePreset(_ p: Preset) { try? store.delete(id: p.id); loadPresets() }

    func apply(_ p: Preset) {
        guard controlsEnabled, let t = target else { return }
        busy = true; lastRestore = nil; lastPresetName = p.name
        Task {
            defer { busy = false }
            do {
                let r = try await controller.apply(p, to: t)
                lastReport = r
                status = "Applied “\(p.name)”: see per-field results."
            } catch { status = "Preset not applied: \(error)" }
            await refreshStates()
        }
    }

    func restoreLast() {
        guard let r = lastReport else { return }
        busy = true
        Task {
            defer { busy = false }
            lastRestore = await controller.restore(r)
            await refreshStates()
        }
    }

    private func refreshStates() async {
        guard let t = target else { return }
        for c in readList { if let v = try? await controller.read(c, target: t) { states[c] = .value(v); drafts[c] = Double(v.current) } }
    }

    // MARK: Learn (discover Samsung-specific settings by diffing scans while the user changes the OSD)

    func runFullScan() {
        guard let t = target, !busy else { return }
        busy = true; scanProgress = 0; diff = nil; beforeScan = nil
        status = "Scanning all 256 DDC codes (about 25 s)…"
        Task {
            let r = await controller.scanAll(target: t) { n in Task { @MainActor in self.scanProgress = n } }
            fullScan = r; scanProgress = nil; busy = false
            status = "Scan found \(r.count) codes. Now take a “before” snapshot, change one OSD item, then compare."
        }
    }

    func takeBefore() {
        guard let t = target, let full = fullScan, !busy else { return }
        busy = true; diff = nil
        Task {
            beforeScan = await controller.rescan(codes: Array(full.keys), target: t)
            busy = false
            status = "Snapshot taken. Change ONE setting in the monitor OSD, then press Compare."
        }
    }

    func compare() {
        guard let t = target, let before = beforeScan, !busy else { return }
        busy = true
        Task {
            let after = await controller.rescan(codes: Array(before.keys), target: t)
            diff = ScanDiff.changes(before: before, after: after)
            busy = false
            status = diff!.isEmpty ? "No code changed. That OSD item may not be exposed over DDC." : "\(diff!.count) code(s) changed."
        }
    }

    func saveLearned(_ item: ScanDiffItem, name: String) {
        guard let t = target else { return }
        let s = LearnedSetting(identity: t.identity, code: item.code, name: name.isEmpty ? String(format: "VCP 0x%02X", item.code) : name,
                               observed: [item.before, item.after], maximum: max(item.maximum, item.before, item.after))
        do {
            try learnedStore.save(s)
            learned = learnedStore.settings(for: t.identity)
            controller.writableControls = Control.defaultWritable.union(learned.map(\.control))
            status = "Learned “\(s.name)”. It now appears under Control."
            Task { await refreshStates() }
        } catch { status = "Could not save: \(error)" }
    }

    func forget(_ s: LearnedSetting) {
        try? learnedStore.delete(id: s.id)
        if let t = target {
            learned = learnedStore.settings(for: t.identity)
            controller.writableControls = Control.defaultWritable.union(learned.map(\.control))
        }
    }

    // MARK: Auto match (camera closes the loop; replaces eyeballing and OSD fiddling)

    var canAutoMatch: Bool { controlsEnabled && !matching && !busy && displays.contains(where: \.isBuiltIn) }

    func togglePreview() {
        if previewing { previewing = false; camera.setPreview(false); if !matching { camera.stop() }; return }
        Task {
            do { try await camera.start(preview: true); previewing = true }
            catch { status = "\(error)" }
        }
    }

    func startMatch() {
        guard canAutoMatch, let t = target, let sam = selected, let mac = displays.first(where: \.isBuiltIn) else { return }
        matching = true; busy = true; matchLog = ["Starting. Screens will flash gray full-screen. Press Esc to cancel."]
        lastRestore = nil
        let presenter = FullScreenPatches(samsungDisplayID: sam.displayID, macDisplayID: mac.displayID)
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.cancelMatch(); return nil }
            return e
        }
        matchTask = Task {
            defer {
                matching = false; busy = false
                if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
                if !previewing { camera.stop() }
            }
            do {
                try await camera.start(preview: previewing)
                let matcher = AutoMatcher(controller: controller, target: t, presenter: presenter, camera: camera)
                let report = try await matcher.run { line in Task { @MainActor in self.matchLog.append(line) } }
                lastReport = report.apply
                let done = report.converged ? "Matched in \(report.iterations.count) rounds." : (report.limit?.rawValue ?? "Stopped without a full match.")
                matchLog.append(done); status = done
            } catch is CancellationError {
                matchLog.append("Cancelled."); status = "Auto match cancelled. Use Undo to return to the earlier values."
                await presenter.finish()
            } catch {
                matchLog.append("Stopped: \(error)"); status = "Auto match stopped: \(error)"
                await presenter.finish()
            }
            await refreshStates()
        }
    }

    func cancelMatch() { matchTask?.cancel() }

    // MARK: Patterns and export

    func openPatterns() {
        let ids = displays.filter { $0.isBuiltIn || $0.uuid == selectedUUID }.map(\.displayID)
        let n = patterns.open(on: ids)
        status = n >= 2 ? "Pattern open on both displays. Drag the windows side by side." : "Pattern opened on \(n) display(s). Select the Samsung to open on both."
    }

    func exportDiagnostics(redacted: Bool = true) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = redacted ? "display-diagnostics-redacted.json" : "display-diagnostics.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try DiagnosticsExporter.export(displays: displays, events: controller.log.events, redact: redacted)
            try data.write(to: url, options: .atomic)
            status = "Diagnostics exported (\(redacted ? "redacted" : "UNREDACTED"))."
        } catch { status = "Export failed: \(error)" }
    }

    static func fakeTransport() -> FakeTransport {
        let id = DisplayIdentity(vendor: 19501, model: 29455, serial: 1, alphaSerial: "FAKE0001", productName: "S34CG50 (fake)", manufacturer: "SAM")
        let ext = DisplayDescriptor(uuid: "FAKE-EXT", edidUUID: nil, displayID: 2, identity: id, isBuiltIn: false, hasEndpoint: true)
        let bi = DisplayDescriptor(uuid: "FAKE-BI", edidUUID: nil, displayID: 1,
                                   identity: DisplayIdentity(vendor: 1552, model: 1, serial: 2, alphaSerial: nil, productName: "Color LCD", manufacturer: nil),
                                   isBuiltIn: true, hasEndpoint: false)
        let f = FakeTransport(displays: [bi, ext])
        for c in Control.allCases { f.setValue(ControlValue(current: 60, maximum: 100), c, uuid: ext.uuid) }
        f.setValue(ControlValue(current: 5, maximum: 4), .colorPreset, uuid: ext.uuid)
        f.setValue(ControlValue(current: 15, maximum: 18), .input, uuid: ext.uuid)
        f.setValue(ControlValue(current: 1, maximum: 255), Control(0xE0), uuid: ext.uuid)
        return f
    }
}
