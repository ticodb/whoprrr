import Foundation

public struct LogiDevice: Identifiable, Equatable, Sendable {
    public var id: String                    // "<receiver pid>:<index>"
    public var name: String
    public var protocolVersion: String
    public var controls: [Reprog.Control]
}

/// Talks to every Logitech receiver/device on a dedicated run-loop thread: finds devices, lists their buttons,
/// diverts the ones we are asked to, and reports presses. Changes nothing unless a control is diverted, and
/// diversion is temporary (the device forgets it on power-cycle).
public final class LogitechHub: @unchecked Sendable {
    private struct Live {
        var channel: HIDPPChannel
        var index: UInt8
        var reprogFeature: UInt8
        var info: LogiDevice
        var held: Set<UInt16> = []
        var diverted: Set<UInt16> = []
    }

    public var onDevices: (@Sendable ([LogiDevice]) -> Void)?
    public var onButton: (@Sendable (_ device: String, _ cid: UInt16, _ down: Bool) -> Void)?

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var timer: CFRunLoopTimer?
    private let lock = NSLock()
    private var wanted: Set<UInt16> = []
    private var live: [String: Live] = [:]
    private var channels: [HIDPPChannel] = []
    private var running = false

    public init() {}

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    public func start() {
        lock.lock(); if running { lock.unlock(); return }; running = true; lock.unlock()
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = CFRunLoopGetCurrent()
            var ctx = CFRunLoopTimerContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let tm = CFRunLoopTimerCreate(nil, CFAbsoluteTimeGetCurrent() + 0.1, 5.0, 0, 0, { _, info in
                Unmanaged<LogitechHub>.fromOpaque(info!).takeUnretainedValue().scan()
            }, &ctx)
            self.timer = tm
            CFRunLoopAddTimer(self.runLoop, tm, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "gg.tico.whopper.logi"; t.qualityOfService = .userInitiated
        thread = t; t.start(); ready.wait()
    }

    /// Stops the hub. Releases every control we diverted first, and waits (briefly) for that to happen so a quitting
    /// app cannot leave buttons dead: the device keeps a diversion until it is released or power-cycled.
    public func stop() {
        lock.lock(); running = false; lock.unlock()
        guard let rl = runLoop else { return }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [self] in
            defer { done.signal() }
            for (id, var l) in live { applyDiversion(&l, to: []); live[id] = l }
            for ch in channels { ch.close() }
            channels = []; live = [:]
            if let timer { CFRunLoopTimerInvalidate(timer) }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(rl)
        _ = done.wait(timeout: .now() + 1.5)
        thread = nil; runLoop = nil
    }

    /// The control IDs to take over. Everything else is left to the device.
    public func setDiverted(_ cids: Set<UInt16>) {
        lock.lock(); wanted = cids; lock.unlock()
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [self] in reapply() }
        CFRunLoopWakeUp(rl)
    }

    // MARK: Run-loop thread

    private func scan() {
        if channels.isEmpty {
            channels = LogitechDiscovery.channels().filter { $0.openChannel() }
            for ch in channels { ch.onReport = { [weak self, weak ch] bytes in if let ch { self?.handleEvent(ch, bytes) } } }
        }
        var found: [String: Live] = [:]
        for ch in channels {
            let indices: [UInt8] = ch.info.transport.contains("USB") ? [1, 2, 3, 4, 5, 6] : [0xFF]
            for idx in indices {
                let key = "\(ch.info.productID):\(idx)"
                if let existing = live[key], ping(ch, idx) { found[key] = existing; continue }
                guard let l = probe(ch, idx, key: key) else { continue }
                found[key] = l
            }
        }
        let changed = Set(found.keys) != Set(live.keys)
        live = found
        reapply()
        if changed { let list = live.values.map(\.info).sorted { $0.id < $1.id }; onDevices?(list) }
    }

    private func ping(_ ch: HIDPPChannel, _ idx: UInt8) -> Bool {
        if case .message? = ch.transact(device: idx, feature: 0, function: 1, params: [0, 0, 0x5A], timeout: 0.25) { return true }
        return false
    }

    private func featureIndex(_ ch: HIDPPChannel, _ idx: UInt8, _ id: UInt16) -> UInt8? {
        if case .message(let m)? = ch.transact(device: idx, feature: 0, function: 0, params: [UInt8(id >> 8), UInt8(id & 0xFF)], timeout: 0.4), m.params[0] != 0 { return m.params[0] }
        return nil
    }

    private func probe(_ ch: HIDPPChannel, _ idx: UInt8, key: String) -> Live? {
        guard case .message(let pong)? = ch.transact(device: idx, feature: 0, function: 1, params: [0, 0, 0x5A], timeout: 0.25) else { return nil }
        let version = "\(pong.params[0]).\(pong.params[1])"
        var name = "Logitech device"
        if let ni = featureIndex(ch, idx, HIDPP.FeatureID.deviceName), case .message(let c)? = ch.transact(device: idx, feature: ni, function: 0) {
            var s = "", got = 0; let total = Int(c.params[0])
            while got < total, case .message(let part)? = ch.transact(device: idx, feature: ni, function: 1, params: [UInt8(got)]) {
                let chunk = part.params.prefix { $0 != 0 }; if chunk.isEmpty { break }
                s += String(decoding: chunk, as: UTF8.self); got += chunk.count
            }
            if !s.isEmpty { name = s }
        }
        guard let rf = featureIndex(ch, idx, 0x1B04) ?? featureIndex(ch, idx, 0x1B00),
              case .message(let cnt)? = ch.transact(device: idx, feature: rf, function: 0) else {
            return Live(channel: ch, index: idx, reprogFeature: 0, info: LogiDevice(id: key, name: name, protocolVersion: version, controls: []))
        }
        var controls: [Reprog.Control] = []
        for i in 0..<Int(cnt.params[0]) {
            if case .message(let m)? = ch.transact(device: idx, feature: rf, function: 1, params: [UInt8(i)]), let c = Reprog.parseInfo(index: i, params: m.params) { controls.append(c) }
        }
        // A previous run (or another app) may have left controls diverted; start from a clean state so only wanted ones are.
        for c in controls where c.isDivertable {
            _ = ch.transact(device: idx, feature: rf, function: 3, params: Reprog.divertParams(cid: c.cid, divert: false), timeout: 0.25)
        }
        return Live(channel: ch, index: idx, reprogFeature: rf, info: LogiDevice(id: key, name: name, protocolVersion: version, controls: controls))
    }

    private func reapply() {
        lock.lock(); let w = wanted; lock.unlock()
        for (id, var l) in live { applyDiversion(&l, to: w); live[id] = l }
    }

    private func applyDiversion(_ l: inout Live, to wanted: Set<UInt16>) {
        guard l.reprogFeature != 0 else { return }
        let available = Set(l.info.controls.filter(\.isDivertable).map(\.cid))
        let target = wanted.intersection(available)
        for cid in target.subtracting(l.diverted) {
            _ = l.channel.transact(device: l.index, feature: l.reprogFeature, function: 3, params: Reprog.divertParams(cid: cid, divert: true))
        }
        for cid in l.diverted.subtracting(target) {
            _ = l.channel.transact(device: l.index, feature: l.reprogFeature, function: 3, params: Reprog.divertParams(cid: cid, divert: false))
        }
        l.diverted = target
    }

    private func handleEvent(_ ch: HIDPPChannel, _ bytes: [UInt8]) {
        guard case .message(let m)? = HIDPP.parse(bytes), m.softwareID == 0, m.function == 0 else { return }
        let key = "\(ch.info.productID):\(m.deviceIndex)"
        guard var l = live[key], l.reprogFeature == m.featureIndex else { return }
        let now = Reprog.pressed(from: m.params)
        for cid in now.subtracting(l.held) { onButton?(key, cid, true) }
        for cid in l.held.subtracting(now) { onButton?(key, cid, false) }
        l.held = now
        live[key] = l
    }
}
