import SwiftUI
import Combine
import AudioCore
import AVFoundation
import WhopperKit

@MainActor
final class AudioModel: ObservableObject {
    private let system: CoreAudioSystem
    private let store = JSONStore<AudioSettings>(name: "audio")
    private let pinner: InputPinner
    private let keepAlive: KeepAliveEngine
    let eqEngine: OutputEQEngine
    let micEngine: MicEngine
    private var cancelObserve: (@Sendable () -> Void)?
    private var audioActive = false
    private var micActive = false
    private var testingEQ = false
    private var testingMic = false
    private(set) var processedPeak: Float = 0
    private(set) var latestMicSignal: Float = 0

    @Published var settings: AudioSettings { didSet { if settings != oldValue { settingsChanged() } } }
    @Published private(set) var devices: [AudioDeviceInfo] = []
    @Published private(set) var defaultInputUID: String?
    @Published private(set) var pinStatus: InputPinner.Status?
    @Published private(set) var keepAliveStatus: [String: KeepAliveEngine.DeviceStatus] = [:]
    @Published private(set) var eqState: OutputEQEngine.State = .off
    @Published private(set) var eqLevel: Float = 0
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var micState: MicEngine.State = .off
    @Published private(set) var micLevels: (input: Float, output: Float) = (0, 0)
    @Published private(set) var driverInstalled = WhopperMic.isInstalled
    @Published var installMessage: String?
    /// Load state of every effect plugin on the mic and the system output, by slot id.
    @Published private(set) var pluginStatus: [UUID: PluginStatus] = [:]

    init(system: CoreAudioSystem = .shared) {
        self.system = system
        pinner = InputPinner(system: system)
        keepAlive = KeepAliveEngine(system: system)
        eqEngine = OutputEQEngine(system: system)
        micEngine = MicEngine(system: system)
        settings = store.load(default: AudioSettings())
        micEngine.onState = { [weak self] st in Task { @MainActor in self?.micState = st; self?.updatePin() } }
        micEngine.onLevels = { [weak self] i, o in
            Task { @MainActor in
                self?.micLevels = (i, o)
                if let self, self.testingMic { self.latestMicSignal = max(self.latestMicSignal, i) }
            }
        }
        eqEngine.onState = { [weak self] st in Task { @MainActor in self?.eqState = st } }
        eqEngine.onLevel = { [weak self] l in Task { @MainActor in self?.eqLevel = l } }
        eqEngine.onProcessedLevel = { [weak self] level in
            Task { @MainActor in
                if let self, self.testingEQ { self.processedPeak = max(self.processedPeak, level) }
            }
        }
        eqEngine.onPermissionVerified = { [weak self] in
            Task { @MainActor in
                if let self, !self.testingEQ && self.audioActive { self.settings.eq.permissionVerified = true }
            }
        }
        micEngine.rack.onStatus = { [weak self] st in Task { @MainActor in self?.mergePluginStatus(st) } }
        eqEngine.rack.onStatus = { [weak self] st in Task { @MainActor in self?.mergePluginStatus(st) } }
        pinner.onStatus = { [weak self] s in Task { @MainActor in self?.pinStatus = s; self?.defaultInputUID = s.activeUID } }
        keepAlive.onStatus = { [weak self] list in
            Task { @MainActor in self?.keepAliveStatus = Dictionary(uniqueKeysWithValues: list.map { ($0.uid, $0) }) }
        }
    }

    /// Physical inputs only: the virtual mic is the destination, never a source.
    var inputDevices: [AudioDeviceInfo] { devices.filter { $0.hasInput && $0.uid != WhopperMic.uid }.sorted { $0.name < $1.name } }
    var micLoaded: Bool { devices.contains { $0.uid == WhopperMic.uid } }
    /// Real speakers and headsets first; our own and virtual loopbacks are not keep-alive targets.
    var outputDevices: [AudioDeviceInfo] {
        devices.filter { $0.hasOutput && $0.transport != .virtual && $0.transport != .aggregate }
            .sorted { ($0.transport == .bluetooth ? 0 : 1, $0.name) < ($1.transport == .bluetooth ? 0 : 1, $1.name) }
    }

    func startDevices() {
        guard cancelObserve == nil else { return }
        refreshDevices()
        cancelObserve = system.observe { [weak self] in Task { @MainActor in self?.refreshDevices() } }
    }

    func setActive(audio: Bool, mic: Bool) {
        guard audio != audioActive || mic != micActive else { return }
        audioActive = audio
        micActive = mic
        applySettings()
    }

    func refreshDevices() { Task { await readDevices() } }

    func readDevices() async {
        let sys = system
        let (list, din, dout) = await Task.detached { (sys.devices(), sys.defaultInputUID(), sys.defaultOutputUID()) }.value
        devices = list
        defaultInputUID = din
        defaultOutputUID = dout
        var named = settings
        for device in list { named.knownNames[device.uid] = device.name }
        if named != settings { settings = named }
    }

    func beginEQTest() {
        processedPeak = 0
        testingEQ = true
        applySettings()
    }

    func endEQTest() {
        guard testingEQ else { return }
        testingEQ = false
        applySettings()
    }

    func beginMicTest() {
        latestMicSignal = 0
        testingMic = true
        applySettings()
    }

    func endMicTest() {
        guard testingMic else { return }
        testingMic = false
        applySettings()
    }

    private func settingsChanged() {
        store.save(settings)
        applySettings()
    }

    private func applySettings() {
        updatePin()
        if audioActive { keepAlive.apply(settings.keepAlive) } else { keepAlive.stop() }
        if testingEQ {
            var test = settings.eq
            test.enabled = true
            test.permissionVerified = false
            test.plugins = []
            eqEngine.apply(test)
        } else if audioActive { eqEngine.apply(settings.eq) } else { eqEngine.stop() }
        if testingMic {
            var test = settings.mic
            test.enabled = true
            test.plugins = []
            micEngine.apply(test)
        } else if micActive, LivePermissionChecker().status(.microphone) == .granted {
            micEngine.apply(settings.mic)
        } else { micEngine.stop() }
    }

    /// While the mic engine runs, the system input is Whoprrr Mic (falling back to the physical mic if it stops).
    private func updatePin() {
        guard audioActive || micActive else { pinner.stop(); pinStatus = nil; return }
        var policy = audioActive ? settings.inputPin : InputPinPolicy()
        if micActive, settings.mic.enabled, case .running = micState {
            policy.enabled = true
            policy.preferredUIDs = [WhopperMic.uid] + policy.preferredUIDs
        }
        pinner.start(policy: policy)
    }

    private func mergePluginStatus(_ st: [UUID: PluginStatus]) {
        let live = Set(settings.mic.plugins.map(\.id) + settings.eq.plugins.map(\.id))
        var next = pluginStatus.filter { live.contains($0.key) }
        for (k, v) in st { next[k] = v }
        if next != pluginStatus { pluginStatus = next }
    }

    func installDriver() {
        installMessage = DriverInstaller.install()
        driverInstalled = WhopperMic.isInstalled
        refreshDevices()
    }
    func uninstallDriver() {
        installMessage = DriverInstaller.uninstall()
        driverInstalled = WhopperMic.isInstalled
        refreshDevices()
    }

    // MARK: Equalizer

    /// The output device whose EQ is being edited: the chosen target, else the current default output.
    var eqDeviceUID: String? { settings.eq.targetUID ?? defaultOutputUID }
    var eqPerDevice: Bool { eqDeviceUID.map { settings.eq.profiles[$0] != nil } ?? false }

    var eqProfile: EQProfile {
        get { eqDeviceUID.map { settings.eq.profile(for: $0) } ?? settings.eq.defaultProfile }
        set {
            if let uid = eqDeviceUID, settings.eq.profiles[uid] != nil { settings.eq.profiles[uid] = newValue }
            else { settings.eq.defaultProfile = newValue }
        }
    }

    func setEQPerDevice(_ on: Bool) {
        guard let uid = eqDeviceUID else { return }
        if on { settings.eq.profiles[uid] = settings.eq.defaultProfile } else { settings.eq.profiles[uid] = nil }
    }

    // MARK: Intent helpers for the view

    func name(for uid: String) -> String { settings.knownNames[uid] ?? uid }

    var pinnedUID: String? { settings.inputPin.preferredUIDs.first }
    func enableMic(_ on: Bool) {
        if on, settings.mic.sourceUID == nil { settings.mic.sourceUID = pinnedUID ?? inputDevices.first { $0.transport == .usb }?.uid ?? inputDevices.first?.uid }
        settings.mic.enabled = on
        if on && micActive && LivePermissionChecker().status(.microphone) == .notDetermined {
            Task {
                if await AVCaptureDevice.requestAccess(for: .audio) { applySettings() }
            }
        }
    }

    func setPinned(_ uid: String?) {
        settings.inputPin.preferredUIDs = uid.map { [$0] } ?? []
    }

    func keepAliveSettings(_ uid: String) -> KeepAliveSettings { settings.keepAlive[uid] ?? KeepAliveSettings() }
    func setKeepAlive(_ uid: String, _ s: KeepAliveSettings) { settings.keepAlive[uid] = s }
}
