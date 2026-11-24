import Foundation
import CoreAudio

public enum AudioTransport: String, Sendable, Codable {
    case builtIn, usb, bluetooth, virtual, aggregate, displayPort, hdmi, airplay, other

    init(_ raw: UInt32) {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeAirPlay: self = .airplay
        default: self = .other
        }
    }
}

public struct AudioDeviceInfo: Equatable, Identifiable, Sendable {
    public var id: String { uid }
    public let objectID: UInt32
    public let uid: String
    public let name: String
    public let transport: AudioTransport
    public let inputChannels: Int
    public let outputChannels: Int
    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }
    /// Our own aggregate/virtual helpers must never be offered as real devices.
    public var isWhopperInternal: Bool { uid.hasPrefix("gg.tico.whopper.") }

    public init(objectID: UInt32, uid: String, name: String, transport: AudioTransport,
                inputChannels: Int, outputChannels: Int) {
        self.objectID = objectID; self.uid = uid; self.name = name; self.transport = transport
        self.inputChannels = inputChannels; self.outputChannels = outputChannels
    }
}

/// Thin typed wrappers over the Core Audio property API. Every call here can block while
/// coreaudiod reconfigures a device, so callers keep them off the main thread.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
        var a = address(sel, scope)
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        let st = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v)
        return st == noErr ? v : nil
    }

    static func set<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: T) -> OSStatus {
        var a = address(sel, scope)
        var v = value
        return AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var a = address(sel, scope)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }

    static func objectIDs(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = address(sel)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func channelCount(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func info(_ dev: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = string(dev, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = string(dev, kAudioObjectPropertyName) ?? uid
        let t: UInt32 = get(dev, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0
        return AudioDeviceInfo(objectID: dev, uid: uid, name: name, transport: AudioTransport(t),
                               inputChannels: channelCount(dev, scope: kAudioObjectPropertyScopeInput),
                               outputChannels: channelCount(dev, scope: kAudioObjectPropertyScopeOutput))
    }

    static func allDevices() -> [AudioDeviceInfo] {
        objectIDs(system, kAudioHardwarePropertyDevices).compactMap { id in
            if let hidden: UInt32 = get(id, kAudioDevicePropertyIsHidden, UInt32(0)), hidden != 0 { return nil }
            return info(id)
        }
    }

    static func device(uid: String) -> AudioDeviceInfo? { allDevices().first { $0.uid == uid } }

    static func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioObjectID? {
        guard let id: AudioObjectID = get(system, sel, AudioObjectID(0)), id != 0 else { return nil }
        return id
    }
}

/// Everything the pinner and keep-alive need from the audio system, so they can be tested
/// against a fake. The live implementation is `CoreAudioSystem`.
public protocol AudioSystem: AnyObject, Sendable {
    func devices() -> [AudioDeviceInfo]
    func defaultInputUID() -> String?
    func defaultOutputUID() -> String?
    @discardableResult func setDefaultInput(uid: String) -> Bool
    /// Calls `handler` (on an arbitrary queue) when devices or defaults change. Returns a cancel closure.
    func observe(_ handler: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

public final class CoreAudioSystem: AudioSystem, @unchecked Sendable {
    public static let shared = CoreAudioSystem()
    /// All HAL traffic is serialised here; a device being reconfigured can stall a read.
    let queue = DispatchQueue(label: "gg.tico.whopper.audio.hal", qos: .userInitiated)
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable () -> Void] = [:]
    private var installed = false
    private static let selectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
    ]

    public init() {}

    public func devices() -> [AudioDeviceInfo] { queue.sync { HAL.allDevices().filter { !$0.isWhopperInternal } } }

    public func defaultInputUID() -> String? {
        queue.sync { HAL.defaultDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap { HAL.string($0, kAudioDevicePropertyDeviceUID) } }
    }
    public func defaultOutputUID() -> String? {
        queue.sync { HAL.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice).flatMap { HAL.string($0, kAudioDevicePropertyDeviceUID) } }
    }

    @discardableResult
    public func setDefaultInput(uid: String) -> Bool {
        queue.sync {
            guard let d = HAL.device(uid: uid), d.hasInput else { return false }
            return HAL.set(HAL.system, kAudioHardwarePropertyDefaultInputDevice, d.objectID) == noErr
        }
    }

    public func observe(_ handler: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let token = UUID()
        lock.lock(); handlers[token] = handler; let needInstall = !installed; installed = true; lock.unlock()
        if needInstall {
            for sel in Self.selectors {
                var a = HAL.address(sel)
                AudioObjectAddPropertyListenerBlock(HAL.system, &a, DispatchQueue(label: "gg.tico.whopper.audio.listen")) { [weak self] _, _ in
                    self?.fire()
                }
            }
        }
        return { [weak self] in
            self?.lock.lock(); self?.handlers[token] = nil; self?.lock.unlock()
        }
    }

    private func fire() {
        lock.lock(); let hs = Array(handlers.values); lock.unlock()
        hs.forEach { $0() }
    }
}
