import AppKit
import CoreAudio
import Darwin

public struct MixApp: Identifiable, Equatable, Sendable {
    public static let systemID = "gg.tico.whopper.system-sounds"
    public let id: String
    public let name: String
    public let bundleURL: URL?
    public let isPlaying: Bool
    /// Remains true after playback pauses, until the app quits or monitoring stops.
    public let hasPlayedAudio: Bool
    public let processIDs: [UInt32]

    public init(id: String, name: String, bundleURL: URL? = nil, isPlaying: Bool, processIDs: [UInt32] = [], hasPlayedAudio: Bool = false) {
        self.id = id
        self.name = name
        self.bundleURL = bundleURL
        self.isPlaying = isPlaying
        self.hasPlayedAudio = hasPlayedAudio || isPlaying
        self.processIDs = processIDs
    }
}

struct MixProcess {
    let objectID: UInt32
    let pid: Int32
    let bundleID: String?
    let ancestors: [Int32]
    let isPlaying: Bool
    var name: String? = nil
    var bundleURL: URL? = nil

    var unownedApp: (id: String, name: String, url: URL?)? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let bundleURL, bundleURL.pathExtension == "app", !bundleURL.path.hasPrefix("/System/Library/") {
            return (bundleID, name ?? bundleURL.deletingPathExtension().lastPathComponent, bundleURL)
        }
        if bundleID.localizedCaseInsensitiveContains("helper") || bundleID.hasPrefix("com.apple.WebKit.") {
            return (bundleID, name ?? bundleID, bundleURL)
        }
        return nil
    }
}

struct MixRunningApp {
    let pid: Int32
    let id: String
    let name: String
    var url: URL? = nil
}

func groupMixProcesses(_ processes: [MixProcess], apps: [MixRunningApp], ownPID: Int32) -> [MixApp] {
    let owners = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    var groups: [String: MixApp] = [:]
    for app in apps.sorted(by: { $0.pid < $1.pid }) where app.pid != ownPID && groups[app.id] == nil {
        groups[app.id] = MixApp(id: app.id, name: app.name, bundleURL: app.url, isPlaying: false)
    }
    for process in processes.sorted(by: { $0.objectID < $1.objectID }) where process.pid != ownPID {
        let matchingBundle = apps.first { $0.id == process.bundleID }
        let owner = owners[process.pid] ?? matchingBundle ?? process.ancestors.lazy.compactMap { owners[$0] }.first
        if owner?.pid == ownPID || process.ancestors.contains(ownPID) { continue }
        let fallback = owner == nil ? process.unownedApp : nil
        let id = owner?.id ?? fallback?.id ?? MixApp.systemID
        let existing = groups[id]
        groups[id] = MixApp(id: id, name: existing?.name ?? owner?.name ?? fallback?.name ?? "System sounds",
                            bundleURL: existing?.bundleURL ?? owner?.url ?? fallback?.url,
                            isPlaying: process.isPlaying || existing?.isPlaying == true,
                            processIDs: (existing?.processIDs ?? []) + [process.objectID])
    }
    return groups.values.sorted { $0.id < $1.id }
}

/// HAL registers dormant audio clients too. Only actual output earns a mixer row. Keep
/// that row (and its tap) through pauses, so adjusting or resetting a fader never reroutes it.
struct MixPlaybackHistory {
    private var heard = Set<String>()

    mutating func update(_ apps: [MixApp]) -> [MixApp] {
        heard.formIntersection(apps.map(\.id))
        heard.formUnion(apps.filter(\.isPlaying).map(\.id))
        return apps.map {
            MixApp(id: $0.id, name: $0.name, bundleURL: $0.bundleURL, isPlaying: $0.isPlaying,
                   processIDs: $0.processIDs, hasPlayedAudio: heard.contains($0.id))
        }
    }
}

struct MixTapPlan: Equatable {
    struct App: Equatable {
        let id: String
        let processes: [UInt32]
    }
    let apps: [App]

    init(mix: MixSettings, live: [MixApp]) {
        apps = live.filter { ($0.hasPlayedAudio || mix.apps[$0.id] != nil) && !$0.processIDs.isEmpty }
            .map { App(id: $0.id, processes: $0.processIDs.sorted()) }
            .sorted { $0.id < $1.id }
    }

    func resolve<T>(own: [UInt32], create: (App) -> T?) -> (taps: [T], ids: [String], failed: Set<String>, exclusions: [UInt32]) {
        var taps: [T] = []
        var ids: [String] = []
        var failed = Set<String>()
        var exclusions = own
        for app in apps {
            guard let tap = create(app) else { failed.insert(app.id); continue }
            taps.append(tap)
            ids.append(app.id)
            exclusions.append(contentsOf: app.processes)
        }
        return (taps, ids, failed, exclusions)
    }
}

/// Owns the HAL listeners on the engine's work queue. No tap or device is opened here.
final class MixProcessMonitor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let changed: ([MixApp]) -> Void
    private var observedIDs = Set<AudioObjectID>()
    private var applications: [NSObjectProtocol] = []
    private var last: [MixApp]?
    private var playback = MixPlaybackHistory()
    private var listening = true
    private var poller: DispatchSourceTimer?
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }

    // Launch services can reparent an XPC helper to launchd. Use its responsible PID when
    // this Darwin symbol is present, then fall back to ordinary parents and the helper's ID.
    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t
    private let responsiblePID: ResponsiblePID? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePID.self)
    }()

    init(queue: DispatchQueue, changed: @escaping ([MixApp]) -> Void) {
        self.queue = queue
        self.changed = changed
        var address = HAL.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(HAL.system, &address, queue, listener)
        let center = NSWorkspace.shared.notificationCenter
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        poller = timer
        applications = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map {
            center.addObserver(forName: $0, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.refresh() }
            }
        }
    }

    func refresh() {
        guard listening, let ids = Self.readProcessIDs() else { return }
        var address = HAL.address(kAudioProcessPropertyIsRunningOutput)
        for id in observedIDs.subtracting(ids) { AudioObjectRemovePropertyListenerBlock(id, &address, queue, listener) }
        observedIDs.formIntersection(ids)
        for id in ids.subtracting(observedIDs) {
            if AudioObjectAddPropertyListenerBlock(id, &address, queue, listener) == noErr { observedIDs.insert(id) }
        }

        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> MixRunningApp? in
            guard !app.isTerminated, app.activationPolicy == .regular, let id = app.bundleIdentifier else { return nil }
            return MixRunningApp(pid: app.processIdentifier, id: id, name: app.localizedName ?? id, url: app.bundleURL)
        }
        let processes = ids.compactMap { id -> MixProcess? in
            guard let pid = HAL.get(id, kAudioProcessPropertyPID, pid_t(0)), pid > 0, pid != getpid() else { return nil }
            let bundleID = HAL.string(id, kAudioProcessPropertyBundleID)
            let playing = HAL.get(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) == 1
            let parents = ancestors(of: pid)
            let app = NSRunningApplication(processIdentifier: pid)
            return MixProcess(objectID: id, pid: pid, bundleID: bundleID ?? app?.bundleIdentifier,
                              ancestors: parents, isPlaying: playing, name: app?.localizedName, bundleURL: app?.bundleURL)
        }
        let current = playback.update(groupMixProcesses(processes, apps: apps, ownPID: getpid()))
        if current != last { last = current; changed(current) }
    }

    func stop() {
        guard listening else { return }
        listening = false
        poller?.cancel()
        poller = nil
        var address = HAL.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(HAL.system, &address, queue, listener)
        address = HAL.address(kAudioProcessPropertyIsRunningOutput)
        for id in observedIDs { AudioObjectRemovePropertyListenerBlock(id, &address, queue, listener) }
        applications.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    private static func readProcessIDs() -> Set<AudioObjectID>? {
        var address = HAL.address(kAudioHardwarePropertyProcessObjectList)
        let stride = MemoryLayout<AudioObjectID>.stride
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(HAL.system, &address, 0, nil, &size) == noErr else { return nil }
        if size == 0 { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        // A list that grew between these calls can fail the read. Keep the old snapshot until
        // the next notification instead of treating every app as if it quit.
        guard AudioObjectGetPropertyData(HAL.system, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return Set(ids.prefix(Int(size) / stride))
    }

    private func ancestors(of pid: pid_t) -> [pid_t] {
        var seen: Set<pid_t> = [pid]
        var result: [pid_t] = []
        // A parent that owns the app is better evidence than a responsible app (which
        // may simply be the terminal or launcher that started it).
        func follow(_ start: pid_t) {
            var next = start
            while next > 1, seen.insert(next).inserted {
                result.append(next)
                next = parent(of: next)
            }
        }
        follow(parent(of: pid))
        follow(responsiblePID?(pid) ?? 0)
        return result
    }

    private func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return 0 }
        return pid_t(info.pbsi_ppid)
    }
}
