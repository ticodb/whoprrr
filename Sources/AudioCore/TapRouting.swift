import CoreAudio
import Foundation
import CMixerDSP

/// Owns the private taps and their single aggregate device. All HAL calls belong on the control thread.
final class TapRouting {
    private struct Tap {
        let objectID: AudioObjectID
        let uid: String

        @available(macOS 14.2, *)
        init(_ description: CATapDescription, name: String, muted: Bool) throws {
            description.name = name
            description.isPrivate = true
            description.muteBehavior = muted ? .mutedWhenTapped : .unmuted
            var id = AudioObjectID(0)
            let status = AudioHardwareCreateProcessTap(description, &id)
            guard status == noErr, id != 0 else { throw TapChain.BuildError.tap(status) }
            objectID = id
            uid = HAL.string(id, kAudioTapPropertyUID) ?? description.uuid.uuidString
        }

        @available(macOS 14.2, *)
        var planar: Bool? {
            guard let format = HAL.get(objectID, kAudioTapPropertyFormat, AudioStreamBasicDescription()),
                  format.mFormatID == kAudioFormatLinearPCM, format.mChannelsPerFrame == 2,
                  format.mBitsPerChannel == 32, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return nil }
            let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            return format.mBytesPerFrame == (planar ? 4 : 8) ? planar : nil
        }
    }

    private var taps: [Tap] = []
    private(set) var aggregateID: AudioObjectID = 0
    private(set) var appIDs: [String] = []
    private(set) var failedApps: Set<String> = []
    private(set) var streams: [WhoprrrTapStream] = []
    private(set) var inputBufferCount: UInt32 = 0

    @available(macOS 14.2, *)
    init(deviceUID: String, muted: Bool, plan: MixTapPlan, mix: MixSettings) throws {
        // Do not exclude a process from the global tap until its own tap is known to exist.
        let resolved = plan.resolve(own: Self.ownProcess()) { app -> (Tap, Bool)? in
            let description = CATapDescription(stereoMixdownOfProcesses: app.processes)
            guard let tap = try? Tap(description, name: "Whoprrr app tap", muted: muted) else { return nil }
            guard let planar = tap.planar else {
                AudioHardwareDestroyProcessTap(tap.objectID)
                return nil
            }
            return (tap, planar)
        }
        taps = resolved.taps.map { $0.0 }
        appIDs = resolved.ids
        failedApps = resolved.failed

        do {
            let global = try Tap(CATapDescription(stereoGlobalTapButExcludeProcesses: resolved.exclusions),
                                 name: "Whoprrr EQ tap", muted: muted)
            taps.insert(global, at: 0)
            let uids = taps.map(\.uid)
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Whoprrr EQ",
                kAudioAggregateDeviceUIDKey: "gg.tico.whopper.eq.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
                kAudioAggregateDeviceTapListKey: uids.map { [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: true] },
                kAudioAggregateDeviceTapAutoStartKey: true,
            ]
            var id = AudioObjectID(0)
            let status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &id)
            guard status == noErr, id != 0 else { throw TapChain.BuildError.aggregate(status) }
            aggregateID = id

            if !appIDs.isEmpty {
                guard let planar = global.planar,
                      HAL.aggregateTapUIDs(id) == uids,
                      let physical = HAL.device(uid: deviceUID),
                      let aggregateBuffers = HAL.inputBufferChannels(id) else { throw TapChain.BuildError.mixLayout }
                let gains = [Float(1)] + appIDs.map { mix.apps[$0]?.gain ?? 1 }
                var expected = HAL.inputBufferChannels(physical.objectID) ?? []
                // The tap buffers follow the hardware inputs in aggregate tap-list order. Check the
                // layout before starting IO and again in the callback before reading or mixing it.
                for (planar, gain) in zip([planar] + resolved.taps.map { $0.1 }, gains) {
                    streams.append(WhoprrrTapStream(firstBuffer: UInt32(expected.count), planar: planar, gain: gain))
                    expected.append(contentsOf: planar ? [1, 1] : [2])
                }
                guard expected == aggregateBuffers else { throw TapChain.BuildError.mixLayout }
                inputBufferCount = UInt32(expected.count)
            }
        } catch {
            close()
            throw error
        }
    }

    private static func ownProcess() -> [AudioObjectID] {
        // Our output must never loop back into our own tap.
        var pid = getpid(), own = AudioObjectID(0)
        var address = HAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(HAL.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &own)
        return own == 0 ? [] : [own]
    }

    func close() {
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if #available(macOS 14.2, *) {
            for tap in taps { AudioHardwareDestroyProcessTap(tap.objectID) }
        }
        taps.removeAll()
    }

    deinit { close() }
}

extension HAL {
    fileprivate static func aggregateTapUIDs(_ id: AudioObjectID) -> [String]? {
        var address = address(kAudioAggregateDevicePropertyTapList)
        var list: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout.size(ofValue: list))
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &list) == noErr else { return nil }
        return list?.takeRetainedValue() as? [String]
    }

    fileprivate static func inputBufferChannels(_ id: AudioObjectID) -> [UInt32]? {
        var address = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return nil }
        if size == 0 { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return nil }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map(\.mNumberChannels)
    }
}
