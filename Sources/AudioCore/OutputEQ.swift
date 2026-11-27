import Foundation
import CoreAudio
import AudioToolbox

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
    let tapID: AudioObjectID, aggregateID: AudioObjectID
    private var procID: AudioDeviceIOProcID?
    let processor: EQProcessor
    let dynamics: StereoDynamics
    let rack: PluginRack
    let sampleRate: Double
    let deviceUID: String
    let muted: Bool
    let renders: Bool
    private(set) var inputPeak: Float = 0
    private var outputPeak: Float = 0
    private(set) var callbacks = 0
    private var scratchL: UnsafeMutablePointer<Float>, scratchR: UnsafeMutablePointer<Float>
    private let capacity = 32768

    enum BuildError: Error, CustomStringConvertible {
        case unsupportedOS, tap(OSStatus), aggregate(OSStatus), start(OSStatus), noDevice
        var description: String {
            switch self {
            case .unsupportedOS: "Needs macOS 14.2 or newer"
            case .tap(let s): "Could not tap system audio (OSStatus \(s)). Allow System Audio Recording for Whoprrr in System Settings."
            case .aggregate(let s): "Could not create the routing device (OSStatus \(s))"
            case .start(let s): "Could not start audio (OSStatus \(s))"
            case .noDevice: "Output device not found"
            }
        }
    }

    init(deviceUID: String, sampleRate: Double, muted: Bool, renders: Bool, profile: EQProfile,
         dynamics: OutputDynamicsSettings = OutputDynamicsSettings(), rack: PluginRack = PluginRack()) throws {
        guard #available(macOS 14.2, *) else { throw BuildError.unsupportedOS }
        self.deviceUID = deviceUID; self.muted = muted; self.renders = renders; self.sampleRate = sampleRate; self.rack = rack
        processor = EQProcessor(sampleRate: sampleRate)
        processor.update(profile)
        self.dynamics = StereoDynamics(sampleRate: sampleRate); self.dynamics.update(dynamics)
        scratchL = .allocate(capacity: capacity); scratchR = .allocate(capacity: capacity)
        scratchL.initialize(repeating: 0, count: capacity); scratchR.initialize(repeating: 0, count: capacity)

        // Our own process is excluded so nothing we play ever loops back into the tap.
        var pid = getpid(), own = AudioObjectID(0)
        var a = HAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(HAL.system, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &own)
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: own == 0 ? [] : [own])
        desc.name = "Whoprrr EQ tap"; desc.isPrivate = true
        desc.muteBehavior = muted ? CATapMuteBehavior.mutedWhenTapped : CATapMuteBehavior.unmuted
        var tap = AudioObjectID(0)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr, tap != 0 else { throw BuildError.tap(st) }
        tapID = tap

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Whoprrr EQ",
            kAudioAggregateDeviceUIDKey: "gg.tico.whopper.eq.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var aggID = AudioObjectID(0)
        st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard st == noErr, aggID != 0 else { AudioHardwareDestroyProcessTap(tap); throw BuildError.aggregate(st) }
        aggregateID = aggID

        var pidProc: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&pidProc, aggID, nil) { [unowned self] _, inData, _, outData, _ in self.io(inData, outData) }
        guard st == noErr, let pidProc else { destroyDevices(); throw BuildError.start(st) }
        procID = pidProc
        st = AudioDeviceStart(aggID, pidProc)
        guard st == noErr else { AudioDeviceDestroyIOProcID(aggID, pidProc); procID = nil; destroyDevices(); throw BuildError.start(st) }
    }

    /// Real-time callback: tap stream in, EQ, device stream out.
    private func io(_ inData: UnsafePointer<AudioBufferList>, _ outData: UnsafeMutablePointer<AudioBufferList>) {
        callbacks &+= 1
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        var frames = 0

        // The tap stream is the last input stream (device inputs, if any, come first).
        if let last = ins.last, last.mNumberChannels >= 2, let d = last.mData {
            frames = min(Int(last.mDataByteSize) / (MemoryLayout<Float>.size * Int(last.mNumberChannels)), capacity)
            let p = d.assumingMemoryBound(to: Float.self), ch = Int(last.mNumberChannels)
            for i in 0..<frames { scratchL[i] = p[i * ch]; scratchR[i] = p[i * ch + 1] }
        } else if ins.count >= 2, let dl = ins[ins.count - 2].mData, let dr = ins[ins.count - 1].mData {
            frames = min(Int(ins[ins.count - 1].mDataByteSize) / MemoryLayout<Float>.size, capacity)
            scratchL.update(from: dl.assumingMemoryBound(to: Float.self), count: frames)
            scratchR.update(from: dr.assumingMemoryBound(to: Float.self), count: frames)
        } else if let last = ins.last, last.mNumberChannels == 1, let d = last.mData {
            frames = min(Int(last.mDataByteSize) / MemoryLayout<Float>.size, capacity)
            scratchL.update(from: d.assumingMemoryBound(to: Float.self), count: frames)
            scratchR.update(from: d.assumingMemoryBound(to: Float.self), count: frames)
        }

        var pk: Float = 0
        for i in 0..<frames { pk = max(pk, abs(scratchL[i]), abs(scratchR[i])) }
        if pk > inputPeak { inputPeak = pk }

        guard renders else {
            for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        processor.process(left: scratchL, right: scratchR, frames: frames)
        rack.process(left: scratchL, right: scratchR, frames: frames)
        dynamics.process(left: scratchL, right: scratchR, frames: frames)
        if pk > 0 {
            var processed: Float = 0
            for i in 0..<frames { processed = max(processed, abs(scratchL[i]), abs(scratchR[i])) }
            if processed > outputPeak { outputPeak = processed }
        }

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

    func takeInputPeak() -> Float { let p = inputPeak; inputPeak = 0; return p }

    func takeOutputPeak() -> Float { let p = outputPeak; outputPeak = 0; return p }

    private func destroyDevices() {
        AudioHardwareDestroyAggregateDevice(aggregateID)
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
    }

    func stop() {
        if let p = procID { AudioDeviceStop(aggregateID, p); AudioDeviceDestroyIOProcID(aggregateID, p); procID = nil }
        destroyDevices()
    }

    deinit { stop(); scratchL.deallocate(); scratchR.deallocate() }
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
    private var failures = 0
    public var onState: (@Sendable (State) -> Void)?
    /// Called once real signal has been seen through the tap, proving the permission works.
    public var onPermissionVerified: (@Sendable () -> Void)?
    public var onLevel: (@Sendable (Float) -> Void)?
    public var onProcessedLevel: (@Sendable (Float) -> Void)?

    public init(system: AudioSystem) { self.system = system }

    public func apply(_ s: OutputEQSettings) {
        lock.lock(); settings = s; lock.unlock()
        if s.enabled { observeIfNeeded() }
        work.async { [weak self] in self?.reconcile() }
    }

    public func stop() {
        lock.lock(); cancel?(); cancel = nil; settings.enabled = false; lock.unlock()
        work.sync { self.teardown(); self.onState?(.off) }
    }

    private func observeIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard cancel == nil else { return }
        cancel = system.observe { [weak self] in self?.work.async { self?.reconcile() } }
    }

    private func teardown() {
        meter?.cancel(); meter = nil
        chain?.stop(); chain = nil
        rack.clear()
    }

    private func reconcile() {
        lock.lock(); let s = settings; lock.unlock()
        guard s.enabled else { teardown(); onState?(.off); return }

        let devices = system.devices()
        let targetUID = s.targetUID ?? system.defaultOutputUID()
        guard let uid = targetUID, let dev = devices.first(where: { $0.uid == uid && $0.hasOutput }) else {
            teardown(); onState?(.unavailable("No output device")); return
        }
        if dev.transport == .virtual || dev.transport == .aggregate {
            teardown(); onState?(.unavailable("\(dev.name) is a virtual device (eqMac?). Pick a real output, or quit eqMac.")); return
        }

        // Same device and mute mode: just refresh the profile.
        if let c = chain, c.deviceUID == uid, c.muted == s.permissionVerified {
            c.processor.update(s.profile(for: uid)); c.dynamics.update(s.dynamics)
            rack.apply(slots: s.plugins, sampleRate: c.sampleRate); return
        }
        teardown()
        let rate: Double = HAL.get(dev.objectID, kAudioDevicePropertyNominalSampleRate, Double(0)) ?? 48000
        do {
            rack.apply(slots: s.plugins, sampleRate: rate)
            let c = try TapChain(deviceUID: uid, sampleRate: rate, muted: s.permissionVerified, renders: true, profile: s.profile(for: uid),
                                 dynamics: s.dynamics, rack: rack)
            chain = c; failures = 0
            onState?(.running(device: dev.name, muted: s.permissionVerified))
            startMeter()
        } catch {
            failures += 1
            onState?(.failed("\(error)"))
        }
    }

    /// Watches the tap for signal. The first time real audio arrives the permission is proven and we switch to muting
    /// the original (rebuilding the chain), so a missing permission can never silence the system.
    private func startMeter() {
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + 0.4, repeating: 0.4)
        t.setEventHandler { [weak self] in
            guard let self, let c = self.chain else { return }
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
