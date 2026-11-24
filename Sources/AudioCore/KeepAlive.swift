import Foundation
import CoreAudio

/// Settings for the signal that stops a Bluetooth speaker deciding "no audio, time to sleep".
/// Every speaker's auto-off logic differs, so these are tunable per device.
public struct KeepAliveSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Level of the tone in dBFS. -60 is far below audibility on small speakers but above the
    /// quantisation floor of AAC/SBC. Raise it if the speaker still sleeps.
    public var levelDB: Double
    /// A low tone is inaudible on small drivers. Raise it if the speaker ignores very low frequencies.
    public var frequencyHz: Double
    /// 0 = continuous. Otherwise one short burst every N seconds (quieter, but some speakers miss it).
    public var pulseEverySeconds: Double
    public var burstSeconds: Double

    public init(enabled: Bool = false, levelDB: Double = -60, frequencyHz: Double = 40,
                pulseEverySeconds: Double = 0, burstSeconds: Double = 0.5) {
        self.enabled = enabled; self.levelDB = levelDB; self.frequencyHz = frequencyHz
        self.pulseEverySeconds = pulseEverySeconds; self.burstSeconds = burstSeconds
    }

    public var clamped: KeepAliveSettings {
        var s = self
        s.levelDB = min(max(levelDB, -90), -20)       // never loud enough to hurt
        s.frequencyHz = min(max(frequencyHz, 15), 2000)
        s.pulseEverySeconds = min(max(pulseEverySeconds, 0), 600)
        s.burstSeconds = min(max(burstSeconds, 0.05), 10)
        return s
    }
}

/// Real-time-safe sine generator: no allocation, no locks, phase-continuous across callbacks.
public final class ToneGenerator: @unchecked Sendable {
    private let amplitude: Float
    private let phaseStep: Double
    private var phase = 0.0
    private let pulseFrames: Int       // period in frames; 0 = continuous
    private let burstFrames: Int
    private var frameInPeriod = 0

    public init(settings: KeepAliveSettings, sampleRate: Double) {
        let s = settings.clamped
        amplitude = Float(pow(10.0, s.levelDB / 20.0))
        phaseStep = 2.0 * .pi * s.frequencyHz / sampleRate
        pulseFrames = Int(s.pulseEverySeconds * sampleRate)
        burstFrames = Int(s.burstSeconds * sampleRate)
    }

    /// Writes `frames` interleaved frames of `channels` channels.
    public func fill(_ out: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        for f in 0..<frames {
            var on = true
            if pulseFrames > 0 {
                on = frameInPeriod < burstFrames
                frameInPeriod += 1
                if frameInPeriod >= pulseFrames { frameInPeriod = 0 }
            }
            let v = on ? amplitude * Float(sin(phase)) : 0
            phase += phaseStep
            if phase > 2.0 * .pi { phase -= 2.0 * .pi }
            for c in 0..<channels { out[f * channels + c] = v }
        }
    }
}

public enum KeepAliveError: Error, CustomStringConvertible {
    case deviceMissing, unsupportedFormat(String), coreAudio(OSStatus, String)
    public var description: String {
        switch self {
        case .deviceMissing: "device not connected"
        case .unsupportedFormat(let s): "unsupported stream format: \(s)"
        case .coreAudio(let st, let what): "\(what) failed (OSStatus \(st))"
        }
    }
}

/// One IOProc writing the tone to one output device.
final class ToneStream {
    let uid: String
    let deviceID: AudioObjectID
    private var procID: AudioDeviceIOProcID?
    private(set) var callbacks = 0
    private let settings: KeepAliveSettings

    init(uid: String, deviceID: AudioObjectID, settings: KeepAliveSettings) {
        self.uid = uid; self.deviceID = deviceID; self.settings = settings
    }

    func start() throws {
        let rate: Double = HAL.get(deviceID, kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal, Double(0)) ?? 48000
        let streams = HAL.objectIDs(deviceID, kAudioDevicePropertyStreams)
        // Only the output streams matter; check the first output stream's format is float32 PCM.
        var checked = false
        for s in streams {
            guard let dir: UInt32 = HAL.get(s, kAudioStreamPropertyDirection, UInt32(1)), dir == 0 else { continue }
            guard let f: AudioStreamBasicDescription = HAL.get(s, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()) else { continue }
            let isFloat = f.mFormatID == kAudioFormatLinearPCM && (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && f.mBitsPerChannel == 32
            if !isFloat { throw KeepAliveError.unsupportedFormat("format \(f.mFormatID) bits \(f.mBitsPerChannel)") }
            checked = true; break
        }
        if !checked { throw KeepAliveError.unsupportedFormat("no output stream") }

        let gen = ToneGenerator(settings: settings, sampleRate: rate)
        var pid: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&pid, deviceID, nil) { [weak self] _, _, _, outData, _ in
            self?.callbacks &+= 1
            let list = UnsafeMutableAudioBufferListPointer(outData)
            for buf in list {
                guard let data = buf.mData else { continue }
                let ch = Int(buf.mNumberChannels)
                guard ch > 0 else { continue }
                let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
                gen.fill(data.assumingMemoryBound(to: Float.self), frames: frames, channels: ch)
            }
        }
        guard st == noErr, let pid else { throw KeepAliveError.coreAudio(st, "create IOProc") }
        procID = pid
        let ss = AudioDeviceStart(deviceID, pid)
        if ss != noErr { AudioDeviceDestroyIOProcID(deviceID, pid); procID = nil; throw KeepAliveError.coreAudio(ss, "start device") }
    }

    func stop() {
        guard let pid = procID else { return }
        AudioDeviceStop(deviceID, pid)
        AudioDeviceDestroyIOProcID(deviceID, pid)
        procID = nil
    }

    deinit { stop() }
}

/// Runs a tone stream on each enabled device while it is connected, and restarts it when a
/// Bluetooth speaker reconnects.
public final class KeepAliveEngine: @unchecked Sendable {
    public struct DeviceStatus: Equatable, Sendable {
        public var uid: String
        public var running: Bool
        public var error: String?
    }

    private let system: AudioSystem
    private let lock = NSLock()
    private var settings: [String: KeepAliveSettings] = [:]
    private var streams: [String: ToneStream] = [:]
    private var applied: [String: KeepAliveSettings] = [:]
    private var errors: [String: String] = [:]
    private var cancel: (@Sendable () -> Void)?
    private let work = DispatchQueue(label: "gg.tico.whopper.keepalive")
    public var onStatus: (@Sendable ([DeviceStatus]) -> Void)?

    public init(system: AudioSystem) { self.system = system }

    public func apply(_ settings: [String: KeepAliveSettings]) {
        lock.lock(); self.settings = settings.mapValues(\.clamped); let needObserve = cancel == nil; lock.unlock()
        if needObserve {
            let c = system.observe { [weak self] in self?.work.async { self?.reconcile() } }
            lock.lock(); cancel = c; lock.unlock()
        }
        work.async { [weak self] in self?.reconcile() }
    }

    public func stop() {
        lock.lock(); cancel?(); cancel = nil; let all = streams; streams = [:]; applied = [:]; lock.unlock()
        all.values.forEach { $0.stop() }
    }

    public func reconcile() {
        lock.lock(); let wanted = settings.filter { $0.value.enabled }; lock.unlock()
        let live = Dictionary(uniqueKeysWithValues: system.devices().filter(\.hasOutput).map { ($0.uid, $0) })

        // Stop streams that are no longer wanted, whose device vanished, or whose settings changed.
        lock.lock()
        let stale = streams.filter { uid, _ in wanted[uid] == nil || live[uid] == nil || applied[uid] != wanted[uid] }
        for uid in stale.keys { streams[uid] = nil; applied[uid] = nil }
        lock.unlock()
        stale.values.forEach { $0.stop() }

        for (uid, s) in wanted {
            lock.lock(); let running = streams[uid] != nil; lock.unlock()
            guard !running, let dev = live[uid] else {
                if live[uid] == nil { lock.lock(); errors[uid] = nil; lock.unlock() }
                continue
            }
            let stream = ToneStream(uid: uid, deviceID: dev.objectID, settings: s)
            do {
                try stream.start()
                lock.lock(); streams[uid] = stream; applied[uid] = s; errors[uid] = nil; lock.unlock()
            } catch {
                lock.lock(); errors[uid] = "\(error)"; lock.unlock()
            }
        }
        lock.lock()
        let status = wanted.keys.sorted().map { DeviceStatus(uid: $0, running: streams[$0] != nil, error: errors[$0]) }
        lock.unlock()
        onStatus?(status)
    }

    /// Callback count of a running stream (the probe uses this to prove the device is being fed).
    public func callbackCount(uid: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return streams[uid]?.callbacks ?? 0
    }
}
