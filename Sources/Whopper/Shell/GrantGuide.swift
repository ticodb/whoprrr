import AppKit
import SwiftUI
import WhopperKit
import WindowCore

/// A non-activating panel so the person can work in System Settings with the instructions in sight.
@MainActor
final class GrantGuide {
    private unowned let setup: SetupController
    private var panel: NSPanel?
    private var watch: Task<Void, Never>?

    init(setup: SetupController) { self.setup = setup }

    func show(_ grant: Permission) {
        stop()
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        let start = ContinuousClock.now
        var expanded = false
        render(grant, expanded: false, success: false)
        moveBesideSettings()
        panel.orderFrontRegardless()

        watch = Task { [weak self] in
            while !Task.isCancelled, let self {
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                if self.setup.pollGrant(grant) {
                    self.render(grant, expanded: false, success: true)
                    try? await Task.sleep(for: .milliseconds(550))
                    guard !Task.isCancelled else { return }
                    self.panel?.orderOut(nil)
                    self.panel = nil
                    self.setup.grantArrived(grant)
                    return
                }
                if !expanded, start.duration(to: .now) >= .seconds(40) {
                    expanded = true
                    self.render(grant, expanded: true, success: false)
                }
                self.moveBesideSettings()
            }
        }
    }

    func stop() {
        watch?.cancel()
        watch = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func render(_ grant: Permission, expanded: Bool, success: Bool) {
        guard let panel else { return }
        let ordinal = setup.grants.firstIndex(of: grant).map { "\($0 + 1) of \(setup.grants.count)" }
        let content = NSHostingView(rootView: GrantGuideCard(grant: grant, ordinal: ordinal, expanded: expanded, success: success, setup: setup))
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
    }

    private func moveBesideSettings() {
        guard let panel, let screen = NSScreen.main else { return }
        let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.systempreferences" }
        if let app, let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let window = windows.first(where: { $0[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier && $0[kCGWindowLayer as String] as? Int == 0 }),
           let bounds = window[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds) {
            let settings = ScreenMap.toAppKit(rect)
            let visible = NSScreen.screens.first { $0.frame.contains(CGPoint(x: settings.midX, y: settings.midY)) }?.visibleFrame ?? screen.visibleFrame
            let placement = PanelPlacement.frame(beside: settings, size: panel.frame.size, visible: visible)
            panel.setFrameOrigin(placement.origin)
        } else {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 20, y: screen.visibleFrame.maxY - 55))
        }
    }
}

private struct GrantGuideCard: View {
    let grant: Permission
    let ordinal: String?
    let expanded: Bool
    let success: Bool
    @ObservedObject var setup: SetupController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LogoMark(size: 25)
                Text("Whoprrr setup").font(Brand.display(16, .semibold))
                Spacer()
                if let ordinal { Text(ordinal).font(Brand.caption).foregroundStyle(.secondary) }
            }
            Text(success ? "\(grant.title) is on." : instruction).font(Brand.body).fixedSize(horizontal: false, vertical: true)
            StatusChip(text: success ? "Got it. Bringing Whoprrr back…" : status, tone: success ? .good : .warn)
            if !success {
                if grant == .accessibility || grant == .inputMonitoring {
                    Button("Show this app in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        .buttonStyle(.link)
                    Text("If Whoprrr is missing, add this app with +. For an entry that won’t work, remove it with −, then add this copy again.")
                        .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if expanded {
                    Divider()
                    Text("Can’t find it?").font(Brand.headline)
                    Button("Wrong page? Open \(grant.title)") { setup.openSettings(grant) }.buttonStyle(.link)
                    Button("Whoprrr missing? Show it in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }.buttonStyle(.link)
                    Text("Drag Whoprrr from Finder into the list if there’s an Add button. If the switch won’t move, unlock with Touch ID or your Mac password.")
                        .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if grant == .systemAudio { Button("Play chime again") { setup.playChime() }.buttonStyle(.brandQuiet) }
                    Button("Back to Whoprrr") { setup.stopGuide(); setup.openWindow() }.buttonStyle(.brandPlain)
                }
            }
        }
        .padding(16).frame(width: 330)
        .background(success ? Color.green.opacity(0.13) : Brand.violet.opacity(0.13))
        .tint(Brand.violetBright)
    }

    private var instruction: String {
        switch grant {
        case .inputMonitoring: "Turn on Whoprrr, then press Quit & Reopen. Whoprrr comes back right here."
        case .systemAudio: "Choose Allow when macOS asks. Play the chime again if you didn’t hear it."
        case .microphone, .camera: "Choose Allow when macOS asks, or turn on Whoprrr in System Settings."
        case .paste: "Find Whoprrr and choose Always Allow."
        case .micDriver: "Use your Mac password to install Whoprrr Mic. If it doesn’t appear, restart your Mac."
        case .accessibility: "Turn on Whoprrr in this list. macOS may ask for Touch ID or your Mac password."
        }
    }

    private var status: String {
        if grant == .inputMonitoring { return "Waiting for the restart" }
        if grant == .systemAudio { return "Listening for the chime" }
        if grant == .micDriver { return "Waiting for Whoprrr Mic to appear" }
        return expanded ? "Still watching for the switch" : "Watching for the switch"
    }
}
