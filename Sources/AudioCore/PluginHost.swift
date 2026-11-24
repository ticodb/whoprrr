import Foundation
import AVFoundation
import AudioToolbox
import CoreAudioKit
import AppKit

/// One effect plugin in a chain, as saved in settings: which Audio Unit, whether it is on, and its state (the plugin's
/// own settings and preset, so the chain comes back exactly as it was).
public struct PluginSlot: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var manufacturer: String
    public var type: UInt32
    public var subtype: UInt32
    public var manufacturerCode: UInt32
    public var enabled = true
    /// Load inside Whoprrr instead of in a separate process. Faster to open and needed by a few older plugins, but a crash in
    /// the plugin then takes Whoprrr down with it.
    public var inProcess = false
    /// Property list of the plugin's full state.
    public var state: Data?

    private enum CodingKeys: String, CodingKey { case id, name, manufacturer, type, subtype, manufacturerCode, enabled, inProcess, state }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer) ?? ""
        type = try c.decode(UInt32.self, forKey: .type)
        subtype = try c.decode(UInt32.self, forKey: .subtype)
        manufacturerCode = try c.decode(UInt32.self, forKey: .manufacturerCode)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        inProcess = try c.decodeIfPresent(Bool.self, forKey: .inProcess) ?? false
        state = try c.decodeIfPresent(Data.self, forKey: .state)
    }

    public init(name: String, manufacturer: String, type: UInt32, subtype: UInt32, manufacturerCode: UInt32) {
        self.name = name; self.manufacturer = manufacturer; self.type = type; self.subtype = subtype; self.manufacturerCode = manufacturerCode
    }

    var description: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subtype, componentManufacturer: manufacturerCode, componentFlags: 0, componentFlagsMask: 0)
    }

    public func sameComponent(as o: PluginSlot) -> Bool { type == o.type && subtype == o.subtype && manufacturerCode == o.manufacturerCode }
}

/// An effect Audio Unit installed on this Mac.
public struct PluginInfo: Identifiable, Hashable, Sendable {
    public var id: String { "\(type)-\(subtype)-\(manufacturerCode)" }
    public var name: String
    public var manufacturer: String
    public var type: UInt32, subtype: UInt32, manufacturerCode: UInt32
    public var isApple: Bool { manufacturer == "Apple" }

    public func makeSlot() -> PluginSlot { PluginSlot(name: name, manufacturer: manufacturer, type: type, subtype: subtype, manufacturerCode: manufacturerCode) }
}

public enum PluginCatalog {
    /// Every effect Audio Unit (plain effects and music effects), sorted by maker then name. VST/VST3 plugins appear here
    /// only if their maker also installs an Audio Unit version.
    public static func effects() -> [PluginInfo] {
        var out: [PluginInfo] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let desc = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            for c in AVAudioUnitComponentManager.shared().components(matching: desc) {
                let d = c.audioComponentDescription
                out.append(PluginInfo(name: c.name, manufacturer: c.manufacturerName, type: d.componentType, subtype: d.componentSubType, manufacturerCode: d.componentManufacturer))
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }.sorted { ($0.manufacturer.lowercased(), $0.name.lowercased()) < ($1.manufacturer.lowercased(), $1.name.lowercased()) }
    }
}

public enum PluginStatus: Equatable, Sendable {
    case loading, ready, failed(String)
}

/// A live plugin instance: an Audio Unit node, ready to be wired into the rack's engine.
final class HostedPlugin {
    let slot: PluginSlot
    let node: AVAudioUnit
    var enabled: Bool
    var appliedState: Data?
    var au: AUAudioUnit { node.auAudioUnit }
    init(slot: PluginSlot, node: AVAudioUnit) { self.slot = slot; self.node = node; enabled = slot.enabled }
}

/// One running engine wired as input -> plugins -> output, driven by hand from the audio thread.
final class RackSession {
    static let maxFrames = 4096
    let engine = AVAudioEngine()
    let rate: Double
    let order: [UUID]
    private let inL = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames), inR = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let inList: UnsafeMutablePointer<AudioBufferList>
    private let outBuf: AVAudioPCMBuffer
    private let render: AVAudioEngineManualRenderingBlock

    init(plugins: [HostedPlugin], rate: Double) throws {
        self.rate = rate; order = plugins.map(\.slot.id)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        try engine.enableManualRenderingMode(.realtime, format: fmt, maximumFrameCount: AVAudioFrameCount(Self.maxFrames))
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size, alignment: 16)
        inList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Self.maxFrames))!
        let l = inL, r = inR, list = inList
        _ = engine.inputNode.setManualRenderingInputPCMFormat(fmt) { frames in
            let abl = UnsafeMutableAudioBufferListPointer(list); abl.count = 2
            abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(l))
            abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(r))
            return UnsafePointer(list)
        }
        var prev: AVAudioNode = engine.inputNode
        for p in plugins {
            engine.attach(p.node)
            engine.connect(prev, to: p.node, format: fmt)
            prev = p.node
        }
        engine.connect(prev, to: engine.mainMixerNode, format: fmt)
        render = engine.manualRenderingBlock
        try engine.start()
    }

    /// Real-time: runs `frames` of planar stereo through the plugins, in place.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            let n = min(frames - done, Self.maxFrames)
            inL.update(from: left + done, count: n); inR.update(from: right + done, count: n)
            outBuf.frameLength = AVAudioFrameCount(n)
            var err: OSStatus = 0
            let st = render(AVAudioFrameCount(n), outBuf.mutableAudioBufferList, &err)
            if st == .success, let ch = outBuf.floatChannelData {
                (left + done).update(from: ch[0], count: n); (right + done).update(from: ch[1], count: n)
            }
            done += n
        }
    }

    func stop(detaching plugins: [HostedPlugin]) {
        engine.stop()
        for p in plugins where p.node.engine === engine { engine.detach(p.node) }
    }

    deinit { inL.deallocate(); inR.deallocate(); UnsafeMutableRawPointer(inList).deallocate() }
}

/// An ordered chain of effect plugins. Loads them off the audio thread, runs them on it, and keeps their state.
public final class PluginRack: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var session: RackSession?
    private var statuses: [UUID: PluginStatus] = [:]
    private let queue = DispatchQueue(label: "gg.tico.whopper.pluginrack")
    // Owned by `queue`.
    private var hosted: [UUID: HostedPlugin] = [:]
    private var desired: [PluginSlot] = []
    private var rate: Double = 48000
    private var generation = 0
    private var windows: [UUID: NSWindow] = [:]
    public var onStatus: (@Sendable ([UUID: PluginStatus]) -> Void)?

    public init() {}

    public var status: [UUID: PluginStatus] { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return statuses }
    public var isEmpty: Bool { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return session == nil }

    /// Makes the rack match `slots`: loads new plugins, drops removed ones, reorders, and applies on/off and state.
    public func apply(slots: [PluginSlot], sampleRate: Double) {
        queue.async { [self] in
            desired = slots; rate = sampleRate
            generation += 1; let gen = generation

            // Drop plugins that are gone or whose component or loading mode changed.
            for (id, h) in hosted where !slots.contains(where: { $0.id == id && $0.sameComponent(as: h.slot) && $0.inProcess == h.slot.inProcess }) {
                closeEditor(id); hosted[id] = nil; _ = h
            }
            // Apply state and on/off to the ones we keep.
            for s in slots {
                guard let h = hosted[s.id] else { continue }
                h.enabled = s.enabled
                if let st = s.state, st != h.appliedState { restore(st, into: h.au); h.appliedState = st }
            }
            let missing = slots.filter { hosted[$0.id] == nil }
            os_unfair_lock_lock(&lock)
            statuses = statuses.filter { id, _ in slots.contains { $0.id == id } }
            for s in missing { statuses[s.id] = .loading }
            os_unfair_lock_unlock(&lock)
            publish()

            guard !missing.isEmpty else { rebuild(gen); return }
            let group = DispatchGroup()
            for s in missing {
                group.enter()
                instantiate(s) { [self] result in
                    self.queue.async {
                        switch result {
                        case .success(let h): self.hosted[s.id] = h
                        case .failure(let e): self.setStatus(s.id, .failed(Self.explain(e, inProcess: s.inProcess)))
                        }
                        group.leave()
                    }
                }
            }
            group.notify(queue: queue) { [self] in if gen == generation { rebuild(gen) } }
        }
    }

    /// Stops and releases every plugin (used when the chain this rack serves is switched off).
    public func clear() { apply(slots: [], sampleRate: rate) }

    /// Real-time: run the chain on planar stereo audio. If the chain is being changed this instant, audio passes through.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard os_unfair_lock_trylock(&lock) else { return }
        let s = session
        os_unfair_lock_unlock(&lock)
        s?.process(left: left, right: right, frames: frames)
    }

    // MARK: Engine

    /// Builds a fresh engine for the enabled, loaded plugins and swaps it in. Audio passes through while it is built.
    private func rebuild(_ gen: Int) {
        os_unfair_lock_lock(&lock); let old = session; session = nil; os_unfair_lock_unlock(&lock)
        old?.stop(detaching: Array(hosted.values))
        var chain = desired.filter(\.enabled).compactMap { hosted[$0.id] }
        for s in desired { if hosted[s.id] != nil { setStatus(s.id, .ready, publishNow: false) } }
        // AVAudioEngine raises an uncatchable exception when a node cannot take the format, so check first.
        chain = chain.filter { p in
            if let why = Self.incompatibility(p, rate: rate) { setStatus(p.slot.id, .failed(why), publishNow: false); return false }
            return true
        }
        defer { publish() }
        guard !chain.isEmpty else { return }
        do {
            let new = try RackSession(plugins: chain, rate: rate)
            os_unfair_lock_lock(&lock); session = new; os_unfair_lock_unlock(&lock)
        } catch {
            // Find the plugin that will not run, mark it, and build without it.
            var good: [HostedPlugin] = []
            for p in chain {
                if let probe = try? RackSession(plugins: [p], rate: rate) { probe.stop(detaching: [p]); good.append(p) }
                else { setStatus(p.slot.id, .failed("It would not start (\(error.localizedDescription)). Try “Run inside Whoprrr”."), publishNow: false) }
            }
            if !good.isEmpty, let new = try? RackSession(plugins: good, rate: rate) {
                os_unfair_lock_lock(&lock); session = new; os_unfair_lock_unlock(&lock)
            }
        }
    }

    // MARK: State

    /// The current state of every loaded plugin, as saved in slots. Call before saving settings or a recipe.
    public func captureStates() -> [UUID: Data] {
        queue.sync {
            var out: [UUID: Data] = [:]
            for (id, h) in hosted {
                if let full = h.au.fullState, let data = try? PropertyListSerialization.data(fromPropertyList: full, format: .binary, options: 0) {
                    out[id] = data; h.appliedState = data
                }
            }
            return out
        }
    }

    private func restore(_ data: Data, into au: AUAudioUnit) {
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] { au.fullState = plist }
    }

    // MARK: Editor windows

    /// Opens the plugin's own editor in a window (or a plain notice if it has none). Main thread.
    public func openEditor(_ id: UUID, onClose: @escaping @Sendable () -> Void) {
        if let w = windows[id] { w.makeKeyAndOrderFront(nil); return }
        guard let h = queue.sync(execute: { hosted[id] }) else { return }
        h.au.requestViewController { [self] vc in
            DispatchQueue.main.async {
                let controller: NSViewController
                if let vc { controller = vc } else {
                    controller = NSViewController()
                    let label = NSTextField(wrappingLabelWithString: "\(h.slot.name) has no editor window. Its settings are saved with the chain.")
                    label.frame = NSRect(x: 20, y: 20, width: 320, height: 60)
                    let v = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 100)); v.addSubview(label); controller.view = v
                }
                let w = NSWindow(contentViewController: controller)
                w.title = h.slot.name; w.styleMask.insert(.closable); w.isReleasedWhenClosed = false
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                    self?.windows[id] = nil; onClose()
                }
                self.windows[id] = w
                w.center(); w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func closeEditor(_ id: UUID) {
        DispatchQueue.main.async { [self] in windows[id]?.close(); windows[id] = nil }
    }

    // MARK: Loading

    private func publish() {
        os_unfair_lock_lock(&lock); let s = statuses; os_unfair_lock_unlock(&lock)
        onStatus?(s)
    }
    private func setStatus(_ id: UUID, _ st: PluginStatus, publishNow: Bool = true) {
        os_unfair_lock_lock(&lock); statuses[id] = st; os_unfair_lock_unlock(&lock)
        if publishNow { publish() }
    }

    /// nil when the plugin can run as stereo at this rate; otherwise why not.
    private static func incompatibility(_ p: HostedPlugin, rate: Double) -> String? {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false) else { return "No stereo format" }
        let au = p.au
        if let caps = au.channelCapabilities?.map(\.intValue), caps.count >= 2 {
            // Pairs of (inputs, outputs); a negative number means "any".
            var ok = false
            for i in stride(from: 0, to: caps.count - 1, by: 2) {
                let (a, b) = (caps[i], caps[i + 1])
                if (a == 2 || a < 0) && (b == 2 || b < 0) { ok = true }
            }
            if !ok { return "This plugin only works on mono or surround audio, not stereo." }
        }
        do {
            if au.inputBusses.count > 0 { try au.inputBusses[0].setFormat(fmt) }
            if au.outputBusses.count > 0 { try au.outputBusses[0].setFormat(fmt) }
        } catch { return "It does not accept stereo audio at \(Int(rate)) Hz." }
        return nil
    }

    private static func explain(_ e: Error, inProcess: Bool) -> String {
        let code = (e as NSError).code
        let base = "Could not load (\(code))."
        return inProcess ? base : base + " Some older plugins need “Run inside Whoprrr”."
    }

    private func instantiate(_ slot: PluginSlot, completion: @escaping (Result<HostedPlugin, Error>) -> Void) {
        let options: AudioComponentInstantiationOptions = slot.inProcess ? [.loadInProcess] : [.loadOutOfProcess]
        AVAudioUnit.instantiate(with: slot.description, options: options) { [self] node, error in
            guard let node else { completion(.failure(error ?? NSError(domain: "Whoprrr", code: 2))); return }
            let h = HostedPlugin(slot: slot, node: node)
            if let st = slot.state { restore(st, into: node.auAudioUnit); h.appliedState = st }
            completion(.success(h))
        }
    }
}
