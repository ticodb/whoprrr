import SwiftUI
import AppKit
import InputCore
import LogitechCore
import UniformTypeIdentifiers
import WhopperKit

@MainActor
final class InputController: ObservableObject {
    enum Status: Equatable { case off, running, needsAccessibility, needsInputMonitoring, failed, paused }

    private let store = JSONStore<InputSettings>(name: "input")
    private let engine = RemapEngine()
    private let poster = EventPoster()
    private lazy var runner = EventTapRunner(engine: engine, poster: poster)
    private var pollTimer: Timer?
    private(set) var active = false

    @Published var settings: InputSettings { didSet { if settings != oldValue { store.save(settings); if active { applySettings() } } } }
    @Published private(set) var status: Status = .off
    @Published private(set) var logiDevices: [LogiDevice] = []
    private let hub = LogitechHub()
    @Published var selfTestResult: String?
    @Published private(set) var learningLogitech = false
    /// The last Logitech button press that reached Whoprrr, so a button that "does nothing" can be told apart from one that is never seen.
    @Published private(set) var lastLogiPress: (name: String, time: Date)?
    @Published var importReport: ImportReport?
    private var learnHandler: ((Int) -> Void)?
    private var learnGeneration = 0

    struct ImportReport: Equatable {
        var added = 0, hid = 0, skipped = 0
        var warnings: [String] = []
        var error: String?
    }
    var commands: [(id: String, title: String, run: () -> Void)] = []

    init() {
        settings = store.load(default: InputSettings())
        poster.onCommand = { [weak self] id in DispatchQueue.main.async { self?.runCommand(id) } }
        hub.onDevices = { [weak self] d in DispatchQueue.main.async { self?.logiDevices = d } }
        hub.onButton = { [weak self] _, cid, down in DispatchQueue.main.async { self?.feedLogi(cid, down: down) } }
        engine.onPanicChange = { [weak self] p in DispatchQueue.main.async { self?.status = p ? .paused : .running } }
    }

    var isPaused: Bool { status == .paused }
    func setPaused(_ on: Bool) { poster.post(engine.setPaused(on)) }

    func runCommand(_ id: String) { commands.first { $0.id == id }?.run() }

    /// Presses and releases a key combo (used by system actions whose only trigger is a keyboard shortcut).
    func tapChord(_ code: Int, _ mods: Mods) {
        poster.post([.key(code: code, down: true, flags: mods, autorepeat: false), .key(code: code, down: false, flags: mods, autorepeat: false)])
    }

    /// The system actions, in the same shape as `commands`, for menus.
    var systemActions: [SystemActions.Action] { SystemActions.all }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on { applySettings() } else { stopAll() }
    }

    private func applySettings() {
        engine.setRules(settings.rules)
        runner.setInvertWheel(settings.invertMouseWheel)
        guard settings.enabled else { stopAll(keepActive: true); return }
        if settings.hidMappings.isEmpty { HIDUtil.shared.restore() } else { HIDUtil.shared.apply(settings.hidMappings) }
        startTap()
        syncLogitech()
    }

    private func wantedLogiControls() -> Set<UInt16> {
        Set(settings.rules.filter(\.enabled).compactMap { r -> UInt16? in if case .logi(let c) = r.trigger { return UInt16(c) }; return nil })
    }

    /// Logitech buttons are only taken over while a rule uses them (or while learning one); with none, the hub only lists devices.
    private func syncLogitech() {
        if hub.isRunning == false { hub.start() }
        hub.setDiverted(wantedLogiControls())
    }

    /// Press a button on a Logitech mouse to pick it for a rule. Every remappable button is held for the moment, except
    /// left and right click, so the first press is reported instead of acted on.
    func learnLogitech(_ done: @escaping (Int) -> Void) {
        guard !learningLogitech else { return }
        if hub.isRunning == false { hub.start() }
        learningLogitech = true; learnHandler = done; learnGeneration += 1
        let gen = learnGeneration
        let all = Set(logiDevices.flatMap { $0.controls.filter(\.isDivertable).map(\.cid) }).subtracting([0x50, 0x51])
        hub.setDiverted(all.union(wantedLogiControls()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in if self?.learnGeneration == gen { self?.endLearn(nil) } }
    }
    func cancelLearn() { endLearn(nil) }
    private func endLearn(_ cid: Int?) {
        guard learningLogitech else { return }
        learningLogitech = false
        let h = learnHandler; learnHandler = nil
        syncLogitech()
        if let cid { h?(cid) }
    }

    private func feedLogi(_ cid: UInt16, down: Bool) {
        if down { lastLogiPress = (Reprog.name(of: cid), Date()) }
        if learningLogitech { if down { endLearn(Int(cid)) }; return }
        // Logitech buttons come over HID++, not through the event tap, so they work as soon as remapping is on.
        guard active, settings.enabled else { return }
        let mods = Mods(cg: CGEventFlags(rawValue: UInt64(NSEvent.modifierFlags.rawValue)))
        runner.process(InputEvent(down ? .down : .up, .logi(Int(cid)), mods: mods.intersection(.main),
                                  bundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, time: ProcessInfo.processInfo.systemUptime))
    }

    private func startTap() {
        switch runner.start() {
        case .running: status = engine.panicked ? .paused : .running; stopPolling()
        case .needsAccessibility: status = .needsAccessibility; startPolling()
        case .needsInputMonitoring: status = .needsInputMonitoring; startPolling()
        case .failed: status = .failed; startPolling()
        }
    }

    private func stopAll(keepActive: Bool = false) {
        runner.stop(); hub.stop(); HIDUtil.shared.restore(); stopPolling()
        status = .off
    }

    /// Permissions are granted in System Settings, away from our UI: check back until they are.
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.active, self.settings.enabled else { return }; self.startTap() }
        }
    }
    private func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    /// Called as the app quits so Caps Lock and friends are never left remapped.
    func shutdown() { runner.stop(); hub.stop(); HIDUtil.shared.restore() }

    // MARK: Self test

    /// Remaps F13 to F14 (keys no app uses), presses F13 for real and checks what comes out the other side.
    func selfTest() {
        guard runner.isRunning else { selfTestResult = "Remapping is not running yet. Grant the permissions above first."; return }
        selfTestResult = "Testing…"
        let before = settings
        // Temporarily extend the live engine so the real tap handles the test key.
        engine.setRules(before.rules + test_rules())
        let counter = SeenCounter()
        let watch = counter.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 105, keyDown: down)?.post(tap: .cghidEventTap) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            counter.stop(watch)
            self.engine.setRules(before.rules)
            if counter.f14 >= 1 && counter.f13 == 0 { self.selfTestResult = "Working: a test key was remapped by Whoprrr." }
            else if counter.f13 >= 1 { self.selfTestResult = "Not remapping: the test key reached apps unchanged. Check Input Monitoring for Whoprrr." }
            else { self.selfTestResult = "No key events were delivered. Grant Input Monitoring to Whoprrr in System Settings, then try again." }
        }
    }

    private func test_rules() -> [Rule] { [Rule(trigger: .key(105), tap: .chord(Chord(107)))] }

    // MARK: Editing helpers

    /// Raw keyboard types seen on key presses since remapping started: tells two keyboards apart.
    func keyboardsSeen() -> [Int: Int] { runner.keyboardTypesSeen }

    /// Brings Karabiner-Elements rules over. `url` nil asks with a file panel that starts in ~/.config/karabiner.
    func importKarabiner(from url: URL? = nil) {
        var file = url
        if file == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]; panel.showsHiddenFiles = true
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/karabiner")
            panel.message = "Choose karabiner.json, or a rule file exported from Karabiner"
            guard panel.runModal() == .OK else { return }
            file = panel.url
        }
        guard let file else { return }
        do {
            let r = try KarabinerImport.parse(Data(contentsOf: file))
            var s = settings
            var report = ImportReport(skipped: r.skipped, warnings: r.warnings)
            for rule in r.rules where !s.rules.contains(where: { $0.trigger == rule.trigger && $0.requiredMods == rule.requiredMods && $0.layouts == rule.layouts && $0.tap == rule.tap && $0.scope == rule.scope }) {
                s.rules.append(rule); report.added += 1
            }
            for h in r.hidMappings where !s.hidMappings.contains(h) { s.hidMappings.append(h); report.hid += 1 }
            settings = s
            importReport = report
        } catch KarabinerImport.ImportError.nothingFound {
            importReport = ImportReport(error: "No Karabiner rules found in that file.")
        } catch {
            importReport = ImportReport(error: "Could not read that file as Karabiner JSON.")
        }
    }

    func apply(preset: InputPreset) { settings = InputPresets.apply(preset, to: settings) }
    func delete(_ id: UUID) { settings.rules.removeAll { $0.id == id } }
    func save(_ rule: Rule) {
        if let i = settings.rules.firstIndex(where: { $0.id == rule.id }) { settings.rules[i] = rule } else { settings.rules.append(rule) }
    }
}

/// Counts F13/F14 key-downs seen at the end of the event chain.
final class SeenCounter: @unchecked Sendable {
    var f13 = 0, f14 = 0
    func start() -> CFMachPort? {
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue, callback: { _, _, e, info in
            let me = Unmanaged<SeenCounter>.fromOpaque(info!).takeUnretainedValue()
            switch e.getIntegerValueField(.keyboardEventKeycode) { case 105: me.f13 += 1; case 107: me.f14 += 1; default: break }
            return Unmanaged.passUnretained(e)
        }, userInfo: ref) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return t
    }
    func stop(_ t: CFMachPort?) { if let t { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) } }
}
