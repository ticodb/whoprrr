import Foundation

/// "This microphone, always." Pure decision logic plus a runner that applies it.
public struct InputPinPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Device UIDs in priority order; the first one that is connected wins.
    public var preferredUIDs: [String]
    public init(enabled: Bool = false, preferredUIDs: [String] = []) {
        self.enabled = enabled; self.preferredUIDs = preferredUIDs
    }
}

public enum InputPinDecision: Equatable, Sendable {
    case leave
    case set(uid: String)
}

public enum InputPinLogic {
    /// Returns the device to switch to, or `.leave` when nothing should change.
    public static func decide(policy: InputPinPolicy, devices: [AudioDeviceInfo], currentUID: String?) -> InputPinDecision {
        guard policy.enabled else { return .leave }
        let usable = Set(devices.filter(\.hasInput).map(\.uid))
        guard let want = policy.preferredUIDs.first(where: usable.contains) else { return .leave }
        return want == currentUID ? .leave : .set(uid: want)
    }
}

/// Keeps the default input on the preferred device. Re-applies when macOS (or a Bluetooth headset
/// connecting) changes it. If something else keeps stealing the input back, it backs off rather
/// than fight forever, and says so in `status`.
public final class InputPinner: @unchecked Sendable {
    public struct Status: Equatable, Sendable {
        public var activeUID: String?
        public var preferredConnected: Bool
        public var backedOff: Bool
        public var corrections: Int
    }

    private let system: AudioSystem
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var policy = InputPinPolicy()
    private var cancel: (@Sendable () -> Void)?
    private var recent: [Date] = []
    private var backoffUntil: Date?
    private var corrections = 0
    private let work = DispatchQueue(label: "gg.tico.whopper.pinner")
    public var onStatus: (@Sendable (Status) -> Void)?

    /// More than this many corrections inside `window` seconds means another process is fighting us.
    static let maxCorrections = 4
    static let window: TimeInterval = 5
    static let backoff: TimeInterval = 20

    public init(system: AudioSystem, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.system = system; self.clock = clock
    }

    public func start(policy: InputPinPolicy) {
        lock.lock(); self.policy = policy; let running = cancel != nil; lock.unlock()
        if !running {
            let c = system.observe { [weak self] in self?.work.async { self?.reconcile() } }
            lock.lock(); cancel = c; lock.unlock()
        }
        work.async { [weak self] in self?.reconcile() }
    }

    public func update(policy: InputPinPolicy) { start(policy: policy) }

    public func stop() {
        lock.lock(); cancel?(); cancel = nil; lock.unlock()
    }

    /// One pass: read the world, decide, apply. Exposed for tests.
    public func reconcile() {
        lock.lock(); let p = policy; let now = clock(); var until = backoffUntil; lock.unlock()
        let devices = system.devices()
        let current = system.defaultInputUID()
        var backedOff = false
        if let u = until, u > now { backedOff = true } else if until != nil { until = nil }

        if !backedOff, case .set(let uid) = InputPinLogic.decide(policy: p, devices: devices, currentUID: current) {
            lock.lock()
            recent = recent.filter { now.timeIntervalSince($0) < Self.window } + [now]
            let tooMany = recent.count > Self.maxCorrections
            if tooMany { backoffUntil = now.addingTimeInterval(Self.backoff); recent = [] }
            else { corrections += 1 }
            lock.unlock()
            if tooMany { backedOff = true } else { system.setDefaultInput(uid: uid) }
        }
        lock.lock(); let c = corrections; lock.unlock()
        let preferredConnected = p.preferredUIDs.contains { uid in devices.contains { $0.uid == uid && $0.hasInput } }
        onStatus?(Status(activeUID: system.defaultInputUID(), preferredConnected: preferredConnected,
                         backedOff: backedOff, corrections: c))
    }
}
