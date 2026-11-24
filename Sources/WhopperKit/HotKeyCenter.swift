import Foundation
import Carbon.HIToolbox

/// Global hotkeys through Carbon's RegisterEventHotKey. Needs no privacy permission, which is why
/// window shortcuts use it. Fails per-shortcut when another app already owns the combination.
public final class HotKeyCenter: @unchecked Sendable {
    public static let shared = HotKeyCenter()

    public enum Registration: Equatable, Sendable { case ok, inUse, failed(Int32) }

    private struct Entry { var ref: EventHotKeyRef?; var handler: @Sendable () -> Void }
    private let lock = NSLock()
    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private static let signature: OSType = 0x57485052   // 'WHPR'

    public init() {}

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData!).takeUnretainedValue()
            center.lock.lock(); let h = center.entries[hk.id]?.handler; center.lock.unlock()
            if let h { DispatchQueue.main.async(execute: h) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Registers a shortcut; returns its token (for `unregister`) and how it went.
    public func register(_ s: Shortcut, handler: @escaping @Sendable () -> Void) -> (token: UInt32?, result: Registration) {
        lock.lock(); installHandlerIfNeeded(); let id = nextID; nextID += 1; lock.unlock()
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(s.keyCode, s.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        if st == noErr {
            lock.lock(); entries[id] = Entry(ref: ref, handler: handler); lock.unlock()
            return (id, .ok)
        }
        return (nil, st == OSStatus(eventHotKeyExistsErr) ? .inUse : .failed(st))
    }

    public func unregister(_ token: UInt32) {
        lock.lock(); let e = entries.removeValue(forKey: token); lock.unlock()
        if let ref = e?.ref { UnregisterEventHotKey(ref) }
    }

    public func unregisterAll() {
        lock.lock(); let all = entries; entries = [:]; lock.unlock()
        for e in all.values { if let r = e.ref { UnregisterEventHotKey(r) } }
    }
}
