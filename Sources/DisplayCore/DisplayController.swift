import Foundation

/// Monotonic counter of "the display topology may have changed". Bumped synchronously from CG
/// callbacks and sleep/wake notifications, read on the worker. Any target stamped with an older
/// value is stale.
public final class ConnectionGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1
    public init() {}
    public var current: UInt64 { lock.withLock { value } }
    @discardableResult public func bump() -> UInt64 { lock.withLock { value += 1; return value } }
}

/// Serializes every DDC transaction on one worker queue, off the UI thread.
/// UI -> controller -> transport -> monitor.
public final class DisplayController: @unchecked Sendable {
    public let transport: DDCTransport
    public let generation: ConnectionGeneration
    public let log: DiagnosticsLog
    /// Controls allowed to be written. Brightness only until others are proven on hardware.
    public var writableControls: Set<Control> = Control.defaultWritable

    private let queue = DispatchQueue(label: "display.ddc.worker", qos: .userInitiated)
    // Worker-confined state:
    private var displays: [DisplayDescriptor] = []
    private var ranges: [RangeKey: Int] = [:]

    private struct RangeKey: Hashable { var uuid: String; var control: Control; var generation: UInt64 }

    public init(transport: DDCTransport, generation: ConnectionGeneration = ConnectionGeneration(),
                log: DiagnosticsLog = DiagnosticsLog()) {
        self.transport = transport
        self.generation = generation
        self.log = log
    }

    // MARK: Discovery

    public struct Snapshot: Sendable {
        public var generation: UInt64
        public var displays: [DisplayDescriptor]
    }

    /// Rescans on the worker. The snapshot is stamped with the generation read *before* scanning,
    /// so a topology change that lands mid-scan makes the snapshot stale immediately.
    public func refresh() async -> Snapshot {
        await onWorkerNonThrowing {
            let gen = self.generation.current
            let found = self.transport.scan()
            self.displays = found
            self.ranges = self.ranges.filter { $0.key.generation == gen }
            return Snapshot(generation: gen, displays: found)
        }
    }

    /// Resolves a live display to a write target. External, endpoint-capable displays only.
    public func target(for descriptor: DisplayDescriptor, in snapshot: Snapshot) throws -> DisplayTarget {
        if descriptor.isBuiltIn { throw DDCFailure.builtInRefused }
        guard descriptor.hasEndpoint else { throw DDCFailure.disconnected }
        return DisplayTarget(uuid: descriptor.uuid, identity: descriptor.identity, generation: snapshot.generation)
    }

    /// Finds the single live display matching a saved identity. Weak or duplicate identity needs reselection.
    public func resolve(identity: DisplayIdentity, in snapshot: Snapshot) throws -> DisplayTarget {
        let hits = snapshot.displays.filter { !$0.isBuiltIn && $0.identity.matches(identity) }
        guard identity.isStrong else { throw DDCFailure.ambiguousTarget }
        guard hits.count <= 1 else { throw DDCFailure.ambiguousTarget }
        guard let one = hits.first else { throw DDCFailure.disconnected }
        return try target(for: one, in: snapshot)
    }

    // MARK: Reads and writes

    public func read(_ control: Control, target: DisplayTarget, logFailures: Bool = true) async throws -> ControlValue {
        try await onWorker { try self.readLocked(control, target, quiet: !logFailures) }
    }

    /// Clamp to the verified range, write, read back. A missing readback leaves `verified == false`.
    @discardableResult
    public func write(_ control: Control, value: Int, target: DisplayTarget) async throws -> WriteOutcome {
        try await onWorker { try self.writeLocked(control, value, target) }
    }

    // MARK: Worker internals

    private func validate(_ target: DisplayTarget) throws -> DisplayDescriptor {
        guard target.generation == generation.current else { throw DDCFailure.stale }
        guard let d = displays.first(where: { $0.uuid == target.uuid }), d.identity == target.identity else {
            throw DDCFailure.stale
        }
        guard d.hasEndpoint else { throw DDCFailure.disconnected }
        return d
    }

    private func logDDC(_ message: String, ok: Bool) {
        log.record(.ddc, message, transport: transport.kind, ok: ok)
    }

    private func readLocked(_ control: Control, _ target: DisplayTarget, quiet: Bool = false) throws -> ControlValue {
        let d = try validate(target)
        let started = Date()
        do {
            let v = try transport.read(control, uuid: d.uuid)
            ranges[RangeKey(uuid: d.uuid, control: control, generation: target.generation)] = v.maximum
            if !quiet { logDDC("read \(control.label) = \(v.current)/\(v.maximum) on \(d.uuid) in \(ms(since: started)) ms", ok: true) }
            return v
        } catch let f as DDCFailure {
            if !quiet { logDDC("read \(control.label) failed on \(d.uuid): \(f) after \(ms(since: started)) ms", ok: false) }
            throw f
        }
    }

    private func writeLocked(_ control: Control, _ requested: Int, _ target: DisplayTarget) throws -> WriteOutcome {
        let d = try validate(target)                       // stale target never reaches the transport
        if d.isBuiltIn { throw DDCFailure.builtInRefused }
        if Catalog.denied.contains(control.rawValue) { throw DDCFailure.refused }
        guard writableControls.contains(control) else { throw DDCFailure.notWritable(control) }

        // The range must be verified by a read in this generation before any write.
        let key = RangeKey(uuid: d.uuid, control: control, generation: target.generation)
        let before = try readLocked(control, target)
        var maximum = ranges[key] ?? before.maximum
        // Discrete (choice) controls report an unreliable "max" (the Samsung says 4 while using 5).
        // Their bound is the catalogue's highest choice or the current value, never the reported max.
        if case .choice(let choices)? = Catalog.spec(for: control)?.kind {
            maximum = max(maximum, before.current, choices.map(\.value).max() ?? 0)
        }
        guard requested >= 0 else { throw DDCFailure.outOfRange(requested: requested, maximum: maximum) }
        let applied = min(requested, maximum)

        // Re-check immediately before the write: an unplug during the read must not reach a new display.
        guard target.generation == generation.current else { throw DDCFailure.stale }
        do {
            try transport.write(control, value: applied, uuid: d.uuid)
            logDDC("write \(control.label) \(before.current) -> \(applied) on \(d.uuid)", ok: true)
        } catch let f as DDCFailure {
            logDDC("write \(control.label) \(applied) failed on \(d.uuid): \(f)", ok: false)
            throw f
        }

        var readback: Int?
        if target.generation == generation.current {
            readback = try? transport.read(control, uuid: d.uuid).current
        }
        let outcome = WriteOutcome(control: control, requested: requested, applied: applied,
                                   before: before.current, readback: readback, maximum: maximum)
        logDDC("verify \(control.label): wrote \(applied), readback \(readback.map(String.init) ?? "none") -> \(outcome.verified ? "verified" : outcome.adjusted ? "adjusted by display" : "UNVERIFIED")",
               ok: outcome.accepted)
        return outcome
    }

    private func ms(since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

    func onWorker<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            queue.async {
                do { c.resume(returning: try body()) } catch { c.resume(throwing: error) }
            }
        }
    }

    func onWorkerNonThrowing<T>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            queue.async { c.resume(returning: body()) }
        }
    }
}
