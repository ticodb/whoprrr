import AppKit
import CoreGraphics

/// Runs the remap engine on live input through a session event tap on its own thread.
public final class EventTapRunner: @unchecked Sendable {
    public enum StartResult: Equatable, Sendable { case running, needsAccessibility, needsInputMonitoring, failed }

    private let engine: RemapEngine
    private let poster: EventPoster
    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let lock = NSLock()
    private var frontBundle: String?
    private var observer: NSObjectProtocol?
    private var invertWheel = false
    private var timerGen = 0
    private let timerQueue = DispatchQueue(label: "gg.tico.whopper.input.timer")
    public private(set) var eventsSeen = 0
    private var seenKeyboards: [Int: Int] = [:]

    /// Raw keyboard types seen on key events since start, with counts (shown in the UI so a keyboard can be told apart).
    public var keyboardTypesSeen: [Int: Int] { lock.lock(); defer { lock.unlock() }; return seenKeyboards }
    private func noteKeyboard(_ t: Int) { lock.lock(); seenKeyboards[t, default: 0] += 1; lock.unlock() }

    public init(engine: RemapEngine, poster: EventPoster) { self.engine = engine; self.poster = poster }

    public func setInvertWheel(_ on: Bool) { lock.lock(); invertWheel = on; lock.unlock() }

    public func start() -> StartResult {
        guard tap == nil else { return .running }
        guard AXIsProcessTrusted() else { return .needsAccessibility }
        guard CGPreflightListenEventAccess() else { return .needsInputMonitoring }

        frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.lock.lock(); self?.frontBundle = app?.bundleIdentifier; self?.lock.unlock()
        }

        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, info in
            let me = Unmanaged<EventTapRunner>.fromOpaque(info!).takeUnretainedValue()
            return me.handle(type, event)
        }, userInfo: ref) else { return .failed }
        tap = t

        let ready = DispatchSemaphore(value: 0)
        let th = Thread { [weak self] in
            guard let self else { return }
            let src = CFMachPortCreateRunLoopSource(nil, t, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(self.runLoop, src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        th.name = "gg.tico.whopper.input.tap"; th.qualityOfService = .userInteractive
        th.start(); thread = th
        ready.wait()
        return .running
    }

    public func stop() {
        if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o); observer = nil }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let rl = runLoop { CFRunLoopStop(rl) }
        tap = nil; thread = nil; runLoop = nil
        // Anything still held down must come up, or a key could stay stuck.
        poster.post(engine.releaseAll())
    }

    public var isRunning: Bool { tap != nil }

    // MARK: Callback

    private static let deviceMask: [Int: UInt64] = [59: 0x1, 56: 0x2, 60: 0x4, 55: 0x8, 54: 0x10, 58: 0x20, 61: 0x40, 62: 0x2000]

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == EventPoster.marker { return pass }
        lock.lock(); eventsSeen += 1; let bundle = frontBundle; let invert = invertWheel; lock.unlock()

        var input: InputEvent?
        let now = ProcessInfo.processInfo.systemUptime
        let flags = event.flags
        switch type {
        case .keyDown, .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let kbType = Int(event.getIntegerValueField(.keyboardEventKeyboardType))
            noteKeyboard(kbType)
            input = InputEvent(type == .keyDown ? .down : .up, .key(code), mods: Mods(cg: flags), bundle: bundle, time: now,
                               isRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0, keyboardType: kbType)
        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard let m = ModifierKey.mods(for: code) else { return pass }       // Caps Lock: handled by hidutil
            let isDown: Bool
            if let dm = Self.deviceMask[code] { isDown = flags.rawValue & dm != 0 } else { isDown = flags.contains(.maskSecondaryFn) }
            let kbType = Int(event.getIntegerValueField(.keyboardEventKeyboardType))
            noteKeyboard(kbType)
            input = InputEvent(isDown ? .down : .up, .key(code), mods: Mods(cg: flags).subtracting(m), bundle: bundle, time: now, keyboardType: kbType)
        case .otherMouseDown, .otherMouseUp:
            let b = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            input = InputEvent(type == .otherMouseDown ? .down : .up, .mouse(b), mods: Mods(cg: flags), bundle: bundle, time: now)
        case .scrollWheel:
            if invert, event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
                for f in [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
                    event.setIntegerValueField(f, value: -event.getIntegerValueField(f))
                }
            }
            return pass
        default: return pass
        }
        guard let input else { return pass }

        let d = engine.handle(input)
        if d.isPlainPass { return pass }
        if !d.emits.isEmpty { poster.post(d.emits) }
        scheduleTick()
        if d.swallow { return nil }
        if !d.addMods.isEmpty { event.flags = flags.union(d.addMods.cgFlags); }
        return pass
    }

    /// Runs an input that did not come through the tap (Logitech buttons over HID++) through the same engine.
    public func process(_ input: InputEvent) {
        let d = engine.handle(input)
        if !d.emits.isEmpty { poster.post(d.emits) }
        scheduleTick()
    }

    /// A pending tap/hold needs resolving even if no further key arrives.
    private func scheduleTick() {
        guard let deadline = engine.nextDeadline else { return }
        lock.lock(); timerGen += 1; let gen = timerGen; lock.unlock()
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        timerQueue.asyncAfter(deadline: .now() + delay + 0.002) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.timerGen; self.lock.unlock()
            guard gen == current else { return }
            self.poster.post(self.engine.tick(now: ProcessInfo.processInfo.systemUptime))
            self.scheduleTick()
        }
    }
}
