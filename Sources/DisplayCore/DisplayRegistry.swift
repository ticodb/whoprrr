import AppKit
import CoreGraphics
import Combine

/// Discovers displays and watches for topology changes. CGDirectDisplayID is only a session handle;
/// every callback invalidates the connection generation synchronously, and the actual rescan runs
/// later, outside the callback.
@MainActor
public final class DisplayRegistry: ObservableObject {
    @Published public private(set) var displays: [DisplayDescriptor] = []
    @Published public private(set) var snapshot = DisplayController.Snapshot(generation: 0, displays: [])
    @Published public private(set) var events: [DiagnosticEvent] = []
    /// Bumped on sleep/wake and topology change so the UI can drop selections that need reselection.
    @Published public private(set) var needsRefresh = false

    public let controller: DisplayController
    private var refreshTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    public init(controller: DisplayController) {
        self.controller = controller
        controller.log.onChange = { [weak self] in
            Task { @MainActor in self?.events = controller.log.events }
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(Self.callback, ctx)

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.invalidate("system will sleep", kind: .sleepWake, delay: 0) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Displays re-enumerate a moment after wake. Refresh only; never replay a preset.
            Task { @MainActor in self?.invalidate("system did wake", kind: .sleepWake, delay: 2.0) }
        })
        controller.log.record(.info, "Registry started (\(controller.transport.kind.rawValue) transport)")
        scheduleRefresh(after: 0)
    }

    nonisolated private static let callback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard let userInfo else { return }
        let registry = Unmanaged<DisplayRegistry>.fromOpaque(userInfo).takeUnretainedValue()
        // Invalidate immediately and cheaply; the rescan happens later on the main actor.
        registry.controller.generation.bump()
        let desc = DisplayRegistry.describe(flags)
        registry.controller.log.record(.topology, "display \(displayID) reconfigured: \(desc)")
        // Only act on the completed phase to avoid refreshing mid-reconfiguration.
        if !flags.contains(.beginConfigurationFlag) {
            Task { @MainActor in registry.scheduleRefresh(after: 0.6) }
        }
    }

    nonisolated static func describe(_ f: CGDisplayChangeSummaryFlags) -> String {
        var parts: [String] = []
        if f.contains(.beginConfigurationFlag) { parts.append("begin") }
        if f.contains(.addFlag) { parts.append("added") }
        if f.contains(.removeFlag) { parts.append("removed") }
        if f.contains(.enabledFlag) { parts.append("enabled") }
        if f.contains(.disabledFlag) { parts.append("disabled") }
        if f.contains(.movedFlag) { parts.append("moved") }
        if f.contains(.setMainFlag) { parts.append("main") }
        if f.contains(.setModeFlag) { parts.append("mode") }
        if f.contains(.mirrorFlag) { parts.append("mirror") }
        if f.contains(.unMirrorFlag) { parts.append("unmirror") }
        return parts.isEmpty ? "other" : parts.joined(separator: ",")
    }

    private func invalidate(_ reason: String, kind: DiagnosticEvent.Kind, delay: TimeInterval) {
        controller.generation.bump()
        controller.log.record(kind, reason)
        needsRefresh = true
        scheduleRefresh(after: delay)
    }

    public func scheduleRefresh(after delay: TimeInterval) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if Task.isCancelled { return }
            await self?.refreshNow()
        }
    }

    public func refreshNow() async {
        let snap = await controller.refresh()
        snapshot = snap
        displays = snap.displays
        needsRefresh = false
        let summary = snap.displays.map { "\($0.identity.productName)\($0.isBuiltIn ? " [built-in]" : "")\($0.hasEndpoint ? "" : " [no DDC endpoint]")" }
        controller.log.record(.topology, "scan gen \(snap.generation): \(summary.joined(separator: ", "))")
    }

    /// True while `snapshot` still reflects the live connection state.
    public var snapshotIsCurrent: Bool { snapshot.generation == controller.generation.current }

    public func markBlackout() {
        controller.log.record(.userMark, "User marked: screen went blank / No Signal")
    }
}
