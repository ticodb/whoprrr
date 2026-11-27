import Foundation
import CoreAudio
import AudioToolbox
import CMixerDSP

public struct OutputEQSettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// Output device UID the engine follows; nil = whatever the system default output is.
    public var targetUID: String?
    public var defaultProfile = EQProfile.flat
    /// Per-device profiles, keyed by output device UID. A device without one uses `defaultProfile`.
    public var profiles: [String: EQProfile] = [:]
    /// Set once the system-audio permission has been seen to deliver real signal. Until then the tap does not mute.
    public var permissionVerified = false
    /// Compressor and limiter applied after the EQ and plugins.
    public var dynamics = OutputDynamicsSettings()
    /// Effect plugins (Audio Units) run between the EQ and the dynamics.
    public var plugins: [PluginSlot] = []
    public init() {}

    public func profile(for uid: String) -> EQProfile { profiles[uid] ?? defaultProfile }

    private enum CodingKeys: String, CodingKey { case enabled, targetUID, defaultProfile, profiles, permissionVerified, dynamics, plugins }
    /// Tolerant: settings saved before dynamics and plugins existed keep loading.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        targetUID = try c.decodeIfPresent(String.self, forKey: .targetUID)
        defaultProfile = try c.decodeIfPresent(EQProfile.self, forKey: .defaultProfile) ?? .flat
        profiles = try c.decodeIfPresent([String: EQProfile].self, forKey: .profiles) ?? [:]
        permissionVerified = try c.decodeIfPresent(Bool.self, forKey: .permissionVerified) ?? false
        dynamics = try c.decodeIfPresent(OutputDynamicsSettings.self, forKey: .dynamics) ?? OutputDynamicsSettings()
        plugins = try c.decodeIfPresent([PluginSlot].self, forKey: .plugins) ?? []
    }
}

/// Everything about one running tap -> EQ -> device chain. Created and destroyed as a unit.
final class TapChain {
    private let routing: TapRouting
    private let mixer: OpaquePointer
    private let hasAppStreams: Bool
    var failedApps: Set<String> { routing.failedApps }
    var layoutFailed: Bool { whoprrr_mixer_layout_failed(mixer) }
    private var aggregateID: AudioObjectID { routing.aggregateID }
    private var procID: AudioDeviceIOProcID?
    let processor: EQProcessor
    let dynamics: StereoDynamics
    let rack: PluginRack
    let sampleRate: Double
    let deviceUID: String
    let muted: Bool
    let renders: Bool
    private var scratchL: UnsafeMutablePointer<Float>, scratchR: UnsafeMutablePointer<Float>
    private let capacity = 32768

    enum BuildError: Error, CustomStringConvertible {
        case unsupportedOS, tap(OSStatus), aggregate(OSStatus), start(OSStatus), noDevice, mixLayout, mixerMemory
        var description: String {
            switch self {
            case .unsupportedOS: "Needs macOS 14.2 or newer"
            case .tap(let s): "Could not tap system audio (OSStatus \(s)). Allow System Audio Recording for Whoprrr in System Settings."
            case .aggregate(let s): "Could not create the routing device (OSStatus \(s))"
            case .start(let s): "Could not start audio (OSStatus \(s))"
            case .noDevice: "Output device not found"
            case .mixLayout: "Could not read the separate app audio streams"
            case .mixerMemory: "Could not prepare audio buffers"
            }
        }
    }

    init(deviceUID: String, sampleRate: Double, muted: Bool, renders: Bool, profile: EQProfile,
         dynamics: OutputDynamicsSettings = OutputDynamicsSettings(), rack: PluginRack = PluginRack(),
         mix: MixSettings = MixSettings(), plan: MixTapPlan = MixTapPlan(mix: MixSettings(), live: []),
         fadeIn: Bool = false) throws {
        guard #available(macOS 14.2, *) else { throw BuildError.unsupportedOS }
        self.deviceUID = deviceUID; self.muted = muted; self.renders = renders; self.sampleRate = sampleRate; self.rack = rack
        processor = EQProcessor(sampleRate: sampleRate)
        processor.update(profile)
        self.dynamics = StereoDynamics(sampleRate: sampleRate); self.dynamics.update(dynamics)

        routing = try TapRouting(deviceUID: deviceUID, muted: muted, plan: plan, mix: mix)
        let rampFrames = UInt32(max(1, sampleRate * 0.020))
        let streams = routing.streams
        guard let mixer = whoprrr_mixer_create(streams, UInt32(streams.count), routing.inputBufferCount, rampFrames, fadeIn) else {
            throw BuildError.mixerMemory
        }
        self.mixer = mixer
        hasAppStreams = !streams.isEmpty
        scratchL = .allocate(capacity: capacity); scratchR = .allocate(capacity: capacity)

        let aggID = routing.aggregateID
        var st: OSStatus
        var pidProc: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&pidProc, aggID, nil) { [unowned self] _, inData, _, outData, _ in self.io(inData, outData) }
        guard st == noErr, let pidProc else { throw BuildError.start(st) }
        procID = pidProc
        st = AudioDeviceStart(aggID, pidProc)
        guard st == noErr else { throw BuildError.start(st) }
    }

    /// Real-time callback: tap stream in, EQ, device stream out.
    private func io(_ inData: UnsafePointer<AudioBufferList>, _ outData: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        var frames = 0

        if hasAppStreams {
            frames = Int(whoprrr_mixer_sum(mixer, inData, scratchL, scratchR, UInt32(capacity)))
        } else {
            frames = readGlobalInput(inData)
        }
        let hasInput = whoprrr_mixer_measure(mixer, scratchL, scratchR, UInt32(frames))

        guard renders, frames > 0 else {
            for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        processor.process(left: scratchL, right: scratchR, frames: frames)
        rack.process(left: scratchL, right: scratchR, frames: frames)
        dynamics.process(left: scratchL, right: scratchR, frames: frames)
        whoprrr_mixer_finish(mixer, scratchL, scratchR, UInt32(frames))
        if hasInput { whoprrr_mixer_measure_output(mixer, scratchL, scratchR, UInt32(frames)) }

        // Write L/R into the first two output channels; silence everywhere else.
        for (bi, b) in outs.enumerated() {
            guard let d = b.mData else { continue }
            let p = d.assumingMemoryBound(to: Float.self), ch = Int(b.mNumberChannels)
            let n = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * max(ch, 1))
            memset(d, 0, Int(b.mDataByteSize))
            let m = min(n, frames)
            if ch >= 2, bi == 0 { for i in 0..<m { p[i * ch] = scratchL[i]; p[i * ch + 1] = scratchR[i] } }
            else if ch == 1, bi < 2 { let src = bi == 0 ? scratchL : scratchR; for i in 0..<m { p[i] = src[i] } }
        }
    }

    private func readGlobalInput(_ input: UnsafePointer<AudioBufferList>) -> Int {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var frames = 0
        // The tap stream is the last input stream (device inputs, if any, come first).
        if let last = ins.last, last.mNumberChannels >= 2, let d = last.mData {
            frames = min(Int(last.mDataByteSize) / (MemoryLayout<Float>.size * Int(last.mNumberChannels)), capacity)
            let p = d.assumingMemoryBound(to: Float.self), ch = Int(last.mNumberChannels)
            for i in 0..<frames { scratchL[i] = p[i * ch]; scratchR[i] = p[i * ch + 1] }
        } else if ins.count >= 2, let dl = ins[ins.count - 2].mData, let dr = ins[ins.count - 1].mData {
            let bytes = min(ins[ins.count - 2].mDataByteSize, ins[ins.count - 1].mDataByteSize)
            frames = min(Int(bytes) / MemoryLayout<Float>.size, capacity)
            scratchL.update(from: dl.assumingMemoryBound(to: Float.self), count: frames)
            scratchR.update(from: dr.assumingMemoryBound(to: Float.self), count: frames)
        } else if let last = ins.last, last.mNumberChannels == 1, let d = last.mData {
            frames = min(Int(last.mDataByteSize) / MemoryLayout<Float>.size, capacity)
            scratchL.update(from: d.assumingMemoryBound(to: Float.self), count: frames)
            scratchR.update(from: d.assumingMemoryBound(to: Float.self), count: frames)
        }
        return frames
    }

    func takeInputPeak() -> Float { whoprrr_mixer_take_peak(mixer) }
    func takeOutputPeak() -> Float { whoprrr_mixer_take_output_peak(mixer) }

    func updateGains(_ mix: MixSettings) {
        for (i, id) in routing.appIDs.enumerated() {
            whoprrr_mixer_set_gain(mixer, UInt32(i + 1), mix.apps[id]?.gain ?? 1)
        }
    }

    func fadeOut() { whoprrr_mixer_fade_out(mixer) }
    var fadedOut: Bool { whoprrr_mixer_is_faded_out(mixer) }

    func stop() {
        if let p = procID {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
            procID = nil
        }
        routing.close()
    }

    deinit {
        stop()
        whoprrr_mixer_destroy(mixer)
        scratchL.deallocate()
        scratchR.deallocate()
    }
}

/// System-wide EQ without a virtual driver: taps everything apps play, runs it through the EQ, renders it to the
/// real output device. Follows the default output and switches per-device profiles when it changes.
public final class OutputEQEngine: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case off
        case running(device: String, muted: Bool)
        /// Not an error: nothing to do right now (virtual output, no device...).
        case unavailable(String)
        case failed(String)
    }

    private let system: AudioSystem
    private let lock = NSLock()
    private var settings = OutputEQSettings()
    private var chain: TapChain?
    /// The effect plugins on the system output.
    public let rack = PluginRack()
    private var cancel: (@Sendable () -> Void)?
    private var meter: DispatchSourceTimer?
    private let work = DispatchQueue(label: "gg.tico.whopper.eq")
    private var mix = MixSettings()
    private var processMonitor: MixProcessMonitor?
    private var liveApps: [MixApp] = []
    private var appliedPlan: MixTapPlan?
    private var appliedSettings: OutputEQSettings?
    private var failedApps = Set<String>()
    private var failedWhilePlaying = Set<String>()
    private var fadeDeadline: DispatchTime?
    private var fadeCheck: DispatchWorkItem?
    public var onState: (@Sendable (State) -> Void)?
    /// Called once real signal has been seen through the tap, proving the permission works.
    public var onPermissionVerified: (@Sendable () -> Void)?
    public var onLevel: (@Sendable (Float) -> Void)?
    public var onProcessedLevel: (@Sendable (Float) -> Void)?
    public var onMixApps: (@Sendable ([MixApp]) -> Void)?
    public var onMixFailures: (@Sendable (Set<String>) -> Void)?

    public init(system: AudioSystem) { self.system = system }

    public func apply(_ s: OutputEQSettings, mix: MixSettings = MixSettings()) {
        lock.lock(); settings = s; self.mix = mix; lock.unlock()
        if s.enabled { observeIfNeeded() }
        work.async { [weak self] in self?.reconcile() }
    }

    public func stop() {
        lock.lock(); cancel?(); cancel = nil; settings.enabled = false; lock.unlock()
        work.sync { self.stopMonitoring(); self.teardown(); self.reportFailures([]); self.onState?(.off) }
    }

    private func observeIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard cancel == nil else { return }
        cancel = system.observe { [weak self] in self?.work.async { self?.reconcile() } }
    }

    private func observeProcessesIfNeeded() {
        guard processMonitor == nil, #available(macOS 14.2, *) else { return }
        let monitor = MixProcessMonitor(queue: work) { [weak self] apps in
            guard let self else { return }
            self.liveApps = apps
            self.onMixApps?(apps)
            self.work.async { [weak self] in self?.reconcile() }
        }
        processMonitor = monitor
        monitor.refresh()
    }

    private func stopMonitoring() {
        processMonitor?.stop()
        processMonitor = nil
        liveApps = []
        onMixApps?([])
    }

    private func reportFailures(_ ids: Set<String>) {
        if ids != failedApps { failedApps = ids; onMixFailures?(ids) }
        failedWhilePlaying = Set(liveApps.filter { ids.contains($0.id) && $0.isPlaying }.map(\.id))
    }

    private func teardown(keepRack: Bool = false) {
        fadeCheck?.cancel(); fadeCheck = nil; fadeDeadline = nil
        meter?.cancel(); meter = nil
        chain?.stop(); chain = nil
        appliedPlan = nil
        appliedSettings = nil
        if !keepRack { rack.clear() }
    }

    private func fadeBeforeRebuild(_ chain: TapChain) -> Bool {
        if let deadline = fadeDeadline { return !chain.fadedOut && DispatchTime.now() < deadline }
        // HAL can edit a tap description and the aggregate's list separately. Updating a
        // live mix that way leaves a window with overlapping mutes or stale buffer indices.
        // Swap the whole routing together, with a short fade either side and native playback
        // in the gap. The deadline releases a stopped or disconnected device without waiting for IO.
        chain.fadeOut()
        fadeDeadline = .now() + .milliseconds(150)
        scheduleFadeCheck()
        return true
    }

    private func scheduleFadeCheck() {
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.fadeDeadline != nil else { return }
            self.reconcile()
            if self.fadeDeadline != nil { self.scheduleFadeCheck() }
        }
        fadeCheck = check
        work.asyncAfter(deadline: .now() + .milliseconds(8), execute: check)
    }

    private func reconcile() {
        lock.lock(); let (s, mix) = (settings, mix); lock.unlock()
        guard s.enabled else {
            stopMonitoring(); teardown(); reportFailures([]); onState?(.off)
            return
        }
        observeProcessesIfNeeded()

        let devices = system.devices()
        let targetUID = s.targetUID ?? system.defaultOutputUID()
        guard let uid = targetUID, let dev = devices.first(where: { $0.uid == uid && $0.hasOutput }) else {
            teardown(); reportFailures([]); onState?(.unavailable("No output device")); return
        }
        if dev.transport == .virtual || dev.transport == .aggregate {
            teardown(); reportFailures([]); onState?(.unavailable("\(dev.name) is a virtual device (eqMac?). Pick a real output, or quit eqMac.")); return
        }

        // App taps never mute anything until a global tap has proved that capture works.
        let plan = MixTapPlan(mix: mix, live: s.permissionVerified ? liveApps : [])
        let sameOutput = chain.map { $0.deviceUID == uid && $0.muted == s.permissionVerified } ?? false
        let oldHasMix = appliedPlan?.apps.isEmpty == false
        let newHasMix = !plan.apps.isEmpty
        let retry = liveApps.contains { $0.isPlaying && failedApps.contains($0.id) && !failedWhilePlaying.contains($0.id) }
        let layoutFailed = sameOutput && chain?.layoutFailed == true

        if let c = chain, sameOutput, appliedPlan == plan, !retry, !layoutFailed, fadeDeadline == nil {
            c.updateGains(mix)
            if let old = appliedSettings {
                if old.profile(for: uid) != s.profile(for: uid) { c.processor.update(s.profile(for: uid)) }
                if old.dynamics != s.dynamics { c.dynamics.update(s.dynamics) }
                if old.plugins != s.plugins { rack.apply(slots: s.plugins, sampleRate: c.sampleRate) }
            }
            appliedSettings = s
            failedWhilePlaying.formIntersection(liveApps.filter(\.isPlaying).map(\.id))
            return
        }

        if let c = chain, !layoutFailed, (oldHasMix || newHasMix || fadeDeadline != nil), fadeBeforeRebuild(c) {
            c.updateGains(mix)
            return
        }
        let fadeIn = fadeDeadline != nil || newHasMix || layoutFailed
        let nominal = HAL.get(dev.objectID, kAudioDevicePropertyNominalSampleRate, Double(0)) ?? 0
        let rate = nominal.isFinite && nominal > 0 ? nominal : 48000
        let keepRack = (oldHasMix || newHasMix) && chain?.sampleRate == rate && appliedSettings?.plugins == s.plugins
        teardown(keepRack: keepRack)
        do {
            if !keepRack { rack.apply(slots: s.plugins, sampleRate: rate) }
            func start(_ plan: MixTapPlan) throws -> TapChain {
                try TapChain(deviceUID: uid, sampleRate: rate, muted: s.permissionVerified, renders: true,
                             profile: s.profile(for: uid), dynamics: s.dynamics, rack: rack,
                             mix: mix, plan: plan, fadeIn: fadeIn)
            }
            let c: TapChain
            let failures: Set<String>
            if newHasMix {
                do {
                    if layoutFailed { throw TapChain.BuildError.mixLayout }
                    c = try start(plan)
                    failures = c.failedApps
                } catch {
                    // Return to the original single tap if the aggregate cannot run with app taps.
                    c = try start(MixTapPlan(mix: MixSettings(), live: []))
                    failures = Set(plan.apps.map(\.id))
                }
            } else {
                c = try start(plan)
                failures = []
            }
            chain = c
            appliedPlan = plan
            appliedSettings = s
            reportFailures(failures)
            onState?(.running(device: dev.name, muted: s.permissionVerified))
            startMeter()
        } catch {
            rack.clear()
            reportFailures(Set(plan.apps.map(\.id)))
            onState?(.failed("\(error)"))
        }
    }

    /// Watches the tap for signal. The first time real audio arrives the permission is proven and we switch to muting
    /// the original (rebuilding the chain), so a missing permission can never silence the system.
    private func startMeter() {
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        var ticks = 0
        t.setEventHandler { [weak self] in
            guard let self, let c = self.chain else { return }
            if c.layoutFailed { self.reconcile(); return }
            ticks += 1
            guard ticks % 4 == 0 else { return }
            let p = c.takeInputPeak()
            self.onLevel?(p)
            self.onProcessedLevel?(c.takeOutputPeak())
            self.lock.lock(); let verified = self.settings.permissionVerified; self.lock.unlock()
            if !verified, p > 0.0003 {
                self.lock.lock(); self.settings.permissionVerified = true; self.lock.unlock()
                self.onPermissionVerified?()
                self.reconcile()
            }
        }
        t.resume(); meter = t
    }
}

/// Read-only: taps system audio without muting or playing anything and reports the peak level.
/// Used to prove the System Audio Recording permission works.
public enum TapProbe {
    public static func peak(onDeviceUID uid: String, seconds: Double) -> (peak: Float, error: String?) {
        guard let dev = HAL.device(uid: uid) else { return (0, "device not found") }
        let rate: Double = HAL.get(dev.objectID, kAudioDevicePropertyNominalSampleRate, Double(0)) ?? 48000
        do {
            let c = try TapChain(deviceUID: uid, sampleRate: rate, muted: false, renders: false, profile: .flat)
            var best: Float = 0
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { Thread.sleep(forTimeInterval: 0.1); best = max(best, c.takeInputPeak()) }
            c.stop()
            return (best, nil)
        } catch { return (0, "\(error)") }
    }
}
