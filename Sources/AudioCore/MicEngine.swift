import Foundation
import CoreAudio
import AudioToolbox

public enum WhopperMic {
    /// UID of the virtual microphone the bundled driver publishes.
    public static let uid = "WhopperMicDevice_UID"
    public static let driverPath = "/Library/Audio/Plug-Ins/HAL/WhopperMic.driver"
    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: driverPath) }
    /// Whether coreaudiod currently exposes the device (installed *and* loaded).
    public static func isLoaded(_ system: AudioSystem = CoreAudioSystem.shared) -> Bool { system.devices().contains { $0.uid == uid } }
}

public struct MicSettings: Codable, Equatable, Sendable {
    /// Run the processing engine and feed the virtual mic.
    public var enabled = false
    /// The physical microphone to process (e.g. the RØDE PodMic).
    public var sourceUID: String?
    public var gainDB = 0.0
    public var highPassEnabled = true
    public var highPassHz = 80.0
    public var eq = EQProfile.flat
    public var gate = GateSettings()
    public var compressor = CompressorSettings()
    /// Effect plugins (Audio Units) run after the built-in processing.
    public var plugins: [PluginSlot] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, sourceUID, gainDB, highPassEnabled, highPassHz, eq, gate, compressor, plugins }
    /// Tolerant: settings saved before plugins existed keep loading.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        sourceUID = try c.decodeIfPresent(String.self, forKey: .sourceUID)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        highPassEnabled = try c.decodeIfPresent(Bool.self, forKey: .highPassEnabled) ?? true
        highPassHz = try c.decodeIfPresent(Double.self, forKey: .highPassHz) ?? 80
        eq = try c.decodeIfPresent(EQProfile.self, forKey: .eq) ?? .flat
        gate = try c.decodeIfPresent(GateSettings.self, forKey: .gate) ?? GateSettings()
        compressor = try c.decodeIfPresent(CompressorSettings.self, forKey: .compressor) ?? CompressorSettings()
        plugins = try c.decodeIfPresent([PluginSlot].self, forKey: .plugins) ?? []
    }

    /// High-pass + EQ bands as one profile for the processor.
    public var chainProfile: EQProfile {
        var bands: [EQBand] = []
        if highPassEnabled { bands.append(EQBand(freq: highPassHz, gainDB: 0, q: 0.707, kind: .highPass)) }
        bands += eq.bands
        return EQProfile(enabled: true, preampDB: gainDB + (eq.enabled ? eq.preampDB : 0),
                         bands: eq.enabled ? bands : bands.filter { $0.kind == .highPass })
    }
}

/// Physical mic -> effects -> Whoprrr Mic. Uses a private aggregate device (source + virtual mic) so Core Audio
/// corrects clock drift between the two for us.
final class MicChain {
    let processor: EQProcessor
    let dynamics: DynamicsProcessor
    let rack: PluginRack
    let sampleRate: Double
    private let aggregateID: AudioObjectID
    private var procID: AudioDeviceIOProcID?
    private let scratch: UnsafeMutablePointer<Float>, scratchR: UnsafeMutablePointer<Float>
    private let capacity = 32768
    private let sourceOutChannels: Int
    private(set) var inputPeak: Float = 0, outputPeak: Float = 0

    enum BuildError: Error, CustomStringConvertible {
        case aggregate(OSStatus), start(OSStatus)
        var description: String {
            switch self {
            case .aggregate(let s): "Could not create the routing device (OSStatus \(s))"
            case .start(let s): "Could not start the microphone (OSStatus \(s)). Allow Microphone access for Whoprrr."
            }
        }
    }

    init(source: AudioDeviceInfo, sampleRate: Double, settings: MicSettings, rack: PluginRack) throws {
        self.rack = rack; self.sampleRate = sampleRate
        processor = EQProcessor(sampleRate: sampleRate); processor.update(settings.chainProfile)
        dynamics = DynamicsProcessor(sampleRate: sampleRate); dynamics.update(gate: settings.gate, compressor: settings.compressor)
        scratch = .allocate(capacity: capacity); scratchR = .allocate(capacity: capacity)
        scratch.initialize(repeating: 0, count: capacity); scratchR.initialize(repeating: 0, count: capacity)
        sourceOutChannels = source.outputChannels

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Whoprrr Mic Engine",
            kAudioAggregateDeviceUIDKey: "gg.tico.whopper.micengine.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: source.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: source.uid],
                [kAudioSubDeviceUIDKey: WhopperMic.uid, kAudioSubDeviceDriftCompensationKey: true],
            ],
        ]
        var aggID = AudioObjectID(0)
        var st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard st == noErr, aggID != 0 else { throw BuildError.aggregate(st) }
        aggregateID = aggID

        var pid: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, nil) { [unowned self] _, inData, _, outData, _ in self.io(inData, outData) }
        guard st == noErr, let pid else { AudioHardwareDestroyAggregateDevice(aggID); throw BuildError.start(st) }
        procID = pid
        st = AudioDeviceStart(aggID, pid)
        guard st == noErr else { AudioDeviceDestroyIOProcID(aggID, pid); AudioHardwareDestroyAggregateDevice(aggID); procID = nil; throw BuildError.start(st) }
    }

    private func io(_ inData: UnsafePointer<AudioBufferList>, _ outData: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        var frames = 0

        // The source's input is the first input buffer; fold it to mono.
        if let first = ins.first, let d = first.mData, first.mNumberChannels > 0 {
            let ch = Int(first.mNumberChannels)
            frames = min(Int(first.mDataByteSize) / (MemoryLayout<Float>.size * ch), capacity)
            let p = d.assumingMemoryBound(to: Float.self)
            if ch == 1 { scratch.update(from: p, count: frames) }
            else { for i in 0..<frames { scratch[i] = (p[i * ch] + p[i * ch + 1]) * 0.5 } }
        }
        var pk: Float = 0
        for i in 0..<frames { pk = max(pk, abs(scratch[i])) }
        if pk > inputPeak { inputPeak = pk }

        scratchR.update(from: scratch, count: frames)
        processor.process(left: scratch, right: scratchR, frames: frames)
        dynamics.process(scratch, frames: frames)
        if !rack.isEmpty {
            // Plugins are stereo: feed the mono mic as dual mono and fold the result back.
            scratchR.update(from: scratch, count: frames)
            rack.process(left: scratch, right: scratchR, frames: frames)
            for i in 0..<frames { scratch[i] = (scratch[i] + scratchR[i]) * 0.5 }
        }
        var op: Float = 0
        for i in 0..<frames { op = max(op, abs(scratch[i])) }
        if op > outputPeak { outputPeak = op }

        // Silence the source's own outputs, then write the virtual mic's (the buffers after them).
        var skipped = 0
        for b in outs {
            guard let d = b.mData else { continue }
            let ch = Int(b.mNumberChannels)
            if skipped < sourceOutChannels { memset(d, 0, Int(b.mDataByteSize)); skipped += ch; continue }
            let p = d.assumingMemoryBound(to: Float.self)
            let n = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * max(ch, 1))
            memset(d, 0, Int(b.mDataByteSize))
            let m = min(n, frames)
            for i in 0..<m { for c in 0..<max(ch, 1) { p[i * ch + c] = scratch[i] } }
            break
        }
    }

    func takePeaks() -> (input: Float, output: Float) { let r = (inputPeak, outputPeak); inputPeak = 0; outputPeak = 0; return r }

    func stop() {
        if let p = procID { AudioDeviceStop(aggregateID, p); AudioDeviceDestroyIOProcID(aggregateID, p); procID = nil }
        AudioHardwareDestroyAggregateDevice(aggregateID)
    }

    deinit { stop(); scratch.deallocate(); scratchR.deallocate() }
}

public final class MicEngine: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case off
        case driverMissing
        case sourceMissing
        case running(source: String)
        case failed(String)
    }

    private let system: AudioSystem
    private let lock = NSLock()
    private var settings = MicSettings()
    /// The effect plugins on the microphone.
    public let rack = PluginRack()
    private var chain: MicChain?
    private var chainSource: String?
    private var cancel: (@Sendable () -> Void)?
    private var meter: DispatchSourceTimer?
    private let work = DispatchQueue(label: "gg.tico.whopper.mic")
    public var onState: (@Sendable (State) -> Void)?
    public var onLevels: (@Sendable (_ input: Float, _ output: Float) -> Void)?

    public init(system: AudioSystem) { self.system = system }

    public func apply(_ s: MicSettings) {
        lock.lock(); settings = s; let needObserve = cancel == nil && s.enabled; lock.unlock()
        if needObserve {
            let c = system.observe { [weak self] in self?.work.async { self?.reconcile() } }
            lock.lock(); cancel = c; lock.unlock()
        }
        work.async { [weak self] in self?.reconcile() }
    }

    public func stop() {
        lock.lock(); cancel?(); cancel = nil; settings.enabled = false; lock.unlock()
        work.sync { self.teardown(); self.onState?(.off) }
    }

    private func teardown() { meter?.cancel(); meter = nil; chain?.stop(); chain = nil; chainSource = nil; rack.clear() }

    private func reconcile() {
        lock.lock(); let s = settings; lock.unlock()
        guard s.enabled else { teardown(); onState?(.off); return }
        let devices = system.devices()
        guard devices.contains(where: { $0.uid == WhopperMic.uid }) else { teardown(); onState?(.driverMissing); return }
        guard let src = s.sourceUID.flatMap({ u in devices.first { $0.uid == u && $0.hasInput } }) else { teardown(); onState?(.sourceMissing); return }

        if let c = chain, chainSource == src.uid {
            c.processor.update(s.chainProfile); c.dynamics.update(gate: s.gate, compressor: s.compressor)
            rack.apply(slots: s.plugins, sampleRate: c.sampleRate)
            return
        }
        teardown()
        let rate: Double = HAL.get(src.objectID, kAudioDevicePropertyNominalSampleRate, Double(0)) ?? 48000
        do {
            rack.apply(slots: s.plugins, sampleRate: rate)
            let c = try MicChain(source: src, sampleRate: rate, settings: s, rack: rack)
            chain = c; chainSource = src.uid
            onState?(.running(source: src.name))
            let t = DispatchSource.makeTimerSource(queue: work)
            t.schedule(deadline: .now() + 0.1, repeating: 0.1)
            t.setEventHandler { [weak self] in if let p = self?.chain?.takePeaks() { self?.onLevels?(p.input, p.output) } }
            t.resume(); meter = t
        } catch { onState?(.failed("\(error)")) }
    }
}
