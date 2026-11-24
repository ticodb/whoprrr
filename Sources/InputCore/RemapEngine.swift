import Foundation

public struct InputEvent: Sendable {
    public enum Kind: Sendable { case down, up }
    public var kind: Kind
    public var trigger: Trigger
    /// Modifiers physically down, excluding the trigger key itself when it is a modifier.
    public var mods: Mods
    public var bundle: String?
    public var time: TimeInterval
    public var isRepeat: Bool
    /// Raw keyboard type of the keyboard that produced a key event (nil for mouse and Logitech events).
    public var keyboardType: Int?
    public var layout: KeyboardLayout? { keyboardType.flatMap(KeyboardLayout.init(keyboardType:)) }
    public init(_ kind: Kind, _ trigger: Trigger, mods: Mods = [], bundle: String? = nil, time: TimeInterval = 0, isRepeat: Bool = false, keyboardType: Int? = nil) {
        self.kind = kind; self.trigger = trigger; self.mods = mods; self.bundle = bundle; self.time = time; self.isRepeat = isRepeat
        self.keyboardType = keyboardType
    }
}

public enum Emit: Equatable, Sendable {
    case key(code: Int, down: Bool, flags: Mods, autorepeat: Bool)
    case modifier(Mods, down: Bool)
    case mouse(button: Int, down: Bool)
    case media(MediaKey, down: Bool)
    case command(String)
    case openApp(String)
    case openURL(String)
    case shell(String)
    case text(String)
}

/// What to do with the original event. `emits` are posted first, in order.
public struct Decision: Equatable, Sendable {
    public var emits: [Emit] = []
    public var swallow = false
    /// For events passed through: modifiers to add to their flags (virtual modifiers from a hold).
    public var addMods: Mods = []
    public static let pass = Decision()
    public var isPlainPass: Bool { emits.isEmpty && !swallow && addMods.isEmpty }
}

/// The remapping brain: pure state machine, no OS calls. Feed it events, post what it says.
/// Handles plain remaps, tap-vs-hold, hold-as-modifier, layers, per-app scopes and an emergency off switch.
public final class RemapEngine: @unchecked Sendable {
    private enum Held {
        case key(code: Int, flags: Mods)
        case modifiers(Mods)
        case layer(String)
        case mouse(Int)
        case media(MediaKey)
        case text(String)
        case swallowOnly
    }
    private struct Pending { var rule: Rule; var downAt: TimeInterval; var mods: Mods }

    private let lock = NSLock()
    private var rules: [Rule] = []
    private var held: [Trigger: Held] = [:]
    private var pending: [Trigger: Pending] = [:]
    private var activeLayers: Set<String> = []
    public private(set) var panicked = false
    public var onPanicChange: (@Sendable (Bool) -> Void)?

    public init(rules: [Rule] = []) { setRules(rules) }

    public func setRules(_ r: [Rule]) {
        lock.lock(); defer { lock.unlock() }
        // More specific rules first: layer rules, then app-scoped ones, then global, each keeping the user's order.
        func rank(_ x: Rule) -> Int { (x.layer != nil ? 0 : 2) + (x.scope.mode == .everywhere ? 1 : 0) }
        rules = r.filter(\.enabled).enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        // A layer whose rules vanished must not stay "on".
    }

    public var layers: Set<String> { lock.lock(); defer { lock.unlock() }; return activeLayers }

    private var virtualMods: Mods {
        var m: Mods = []
        for h in held.values { if case .modifiers(let x) = h { m.formUnion(x) } }
        return m
    }

    /// Earliest time a pending tap/hold needs a `tick`, so the runner can schedule a timer.
    public var nextDeadline: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return pending.values.map { $0.downAt + Double($0.rule.holdMs) / 1000 }.min()
    }

    // MARK: Events

    public func handle(_ e: InputEvent) -> Decision {
        lock.lock(); defer { lock.unlock() }
        if let d = panicCheck(e) { return d }
        if panicked { return .pass }
        return e.kind == .down ? down(e) : up(e)
    }

    /// Resolves tap/hold timeouts. Call when `nextDeadline` passes.
    public func tick(now: TimeInterval) -> [Emit] {
        lock.lock(); defer { lock.unlock() }
        var out: [Emit] = []
        for (t, p) in pending where now - p.downAt >= Double(p.rule.holdMs) / 1000 {
            out += resolveHold(t, p)
        }
        return out
    }

    /// Pauses or resumes every rule (the same as the emergency shortcut). Returns key-ups to post when pausing.
    public func setPaused(_ on: Bool) -> [Emit] {
        lock.lock(); defer { lock.unlock() }
        guard on != panicked else { return [] }
        panicked = on
        let out = on ? releaseAllLocked() : []
        onPanicChange?(on)
        return out
    }

    /// Releases everything held or pending (used when remapping stops) so no key or modifier stays stuck down.
    public func releaseAll() -> [Emit] {
        lock.lock(); defer { lock.unlock() }
        return releaseAllLocked()
    }

    private func panicCheck(_ e: InputEvent) -> Decision? {
        guard e.kind == .down, e.trigger == .key(53), e.mods.isSuperset(of: .main) else { return nil }
        panicked.toggle()
        var d = Decision.pass
        if panicked { d.emits = releaseAllLocked() }
        onPanicChange?(panicked)
        return d
    }

    private func releaseAllLocked() -> [Emit] {
        var out: [Emit] = []
        for (_, h) in held { out += release(h) }
        held = [:]; pending = [:]; activeLayers = []
        return out
    }

    private func down(_ e: InputEvent) -> Decision {
        let virt = virtualMods
        if e.isRepeat {
            if pending[e.trigger] != nil { return Decision(swallow: true) }
            if case .key(let code, let flags)? = held[e.trigger] {
                return Decision(emits: [.key(code: code, down: true, flags: flags, autorepeat: true)], swallow: true)
            }
            if case .text(let t)? = held[e.trigger] { return Decision(emits: [.text(t)], swallow: true) }
            if held[e.trigger] != nil { return Decision(swallow: true) }
            return Decision(addMods: virt)
        }
        // Any other key going down while a dual-role key is pending means that key was held.
        var pre: [Emit] = []
        for (t, p) in pending where t != e.trigger { pre += resolveHold(t, p) }
        let virt2 = virtualMods
        let eff = e.mods.union(virt2)

        guard let rule = match(e, eff) else {
            return Decision(emits: pre, swallow: false, addMods: virt2)
        }
        if let hold = rule.hold {
            _ = hold
            pending[e.trigger] = Pending(rule: rule, downAt: e.time, mods: e.mods)
            return Decision(emits: pre, swallow: true)
        }
        var d = perform(rule.tap, for: e, rule: rule, mods: eff)
        d.emits = pre + d.emits
        d.swallow = true
        return d
    }

    private func up(_ e: InputEvent) -> Decision {
        if let p = pending.removeValue(forKey: e.trigger) {
            // Released before the hold threshold and with nothing in between: a tap.
            var out = perform(p.rule.tap, for: InputEvent(.down, e.trigger, mods: p.mods, bundle: e.bundle, time: e.time), rule: p.rule, mods: p.mods.union(virtualMods)).emits
            if let h = held.removeValue(forKey: e.trigger) { out += release(h) }
            return Decision(emits: out, swallow: true)
        }
        if let h = held.removeValue(forKey: e.trigger) {
            return Decision(emits: release(h), swallow: true)
        }
        return Decision(addMods: virtualMods)
    }

    // MARK: Matching

    private func match(_ e: InputEvent, _ eff: Mods) -> Rule? {
        rules.first { r in
            guard r.trigger == e.trigger, r.scope.allows(e.bundle) else { return false }
            if let l = r.layer, !activeLayers.contains(l) { return false }
            if !r.layouts.isEmpty { guard let l = e.layout, r.layouts.contains(l) else { return false } }
            if !r.keyboardTypes.isEmpty { guard let k = e.keyboardType, r.keyboardTypes.contains(k) else { return false } }
            let have = eff.intersection(.main)
            return r.allowExtraModifiers ? have.isSuperset(of: r.requiredMods) : have == r.requiredMods
        }
    }

    // MARK: Performing outputs

    /// Starts `out` for a pressed trigger. Held outputs are recorded so the release undoes them.
    private func perform(_ out: Output, for e: InputEvent, rule: Rule, mods: Mods) -> Decision {
        var d = Decision(swallow: true)
        switch out {
        case .chord(let c):
            // Keep physical modifiers the rule did not consume, add the chord's own.
            let flags = mods.subtracting(rule.requiredMods).union(c.mods)
            held[e.trigger] = .key(code: c.key, flags: flags)
            d.emits = [.key(code: c.key, down: true, flags: flags, autorepeat: false)]
        case .modifiers(let m):
            held[e.trigger] = .modifiers(m)
            d.emits = [.modifier(m, down: true)]
        case .layer(let n):
            held[e.trigger] = .layer(n); activeLayers.insert(n)
        case .media(let k):
            held[e.trigger] = .media(k); d.emits = [.media(k, down: true)]
        case .mouseButton(let b):
            held[e.trigger] = .mouse(b); d.emits = [.mouse(button: b, down: true)]
        case .command(let c): held[e.trigger] = .swallowOnly; d.emits = [.command(c)]
        case .openApp(let a): held[e.trigger] = .swallowOnly; d.emits = [.openApp(a)]
        case .openURL(let u): held[e.trigger] = .swallowOnly; d.emits = [.openURL(u)]
        case .shell(let s): held[e.trigger] = .swallowOnly; d.emits = [.shell(s)]
        case .text(let t): held[e.trigger] = .text(t); d.emits = [.text(t)]
        case .sequence(let chords):
            held[e.trigger] = .swallowOnly
            let base = mods.subtracting(rule.requiredMods)
            d.emits = chords.flatMap { c -> [Emit] in
                let f = base.union(c.mods)
                return [.key(code: c.key, down: true, flags: f, autorepeat: false), .key(code: c.key, down: false, flags: f, autorepeat: false)]
            }
        case .nothing: held[e.trigger] = .swallowOnly
        }
        return d
    }

    private func release(_ h: Held) -> [Emit] {
        switch h {
        case .key(let code, let flags): return [.key(code: code, down: false, flags: flags, autorepeat: false)]
        case .modifiers(let m): return [.modifier(m, down: false)]
        case .layer(let n): activeLayers.remove(n); return []
        case .mouse(let b): return [.mouse(button: b, down: false)]
        case .media(let k): return [.media(k, down: false)]
        case .text, .swallowOnly: return []
        }
    }

    private func resolveHold(_ t: Trigger, _ p: Pending) -> [Emit] {
        pending[t] = nil
        guard let hold = p.rule.hold else { return [] }
        let e = InputEvent(.down, t, mods: p.mods, bundle: nil, time: p.downAt)
        return perform(hold, for: e, rule: p.rule, mods: p.mods.union(virtualMods)).emits
    }
}
