import AppKit
import Combine
import SwiftUI
import WhopperKit
import WindowCore

/// The one Whoprrr window during a grant. It never floats over other apps, follows
/// their windows, reveals Finder, or takes focus when a permission arrives.
@MainActor
final class GrantGuide: NSObject, NSWindowDelegate {
    private unowned let setup: SetupController
    private var window: NSWindow?
    private var watch: Task<Void, Never>?
    private var changes: AnyCancellable?
    private var placement: DispatchWorkItem?

    init(setup: SetupController) { self.setup = setup }

    func show() {
        guard setup.hasPermissionAssistant else { return }
        if let window { window.makeKeyAndOrderFront(nil); return }
        let previousFrame = Shared.beginPermissionGuide()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Whoprrr"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentView = NSHostingView(rootView: GrantGuideView(setup: setup))
        self.window = window
        resize()
        if let frame = previousFrame {
            window.setFrameTopLeftPoint(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY + window.frame.height / 2))
        } else { window.center() }
        changes = setup.$progress.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resize() }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled, let self else { return }
                self.setup.pollPermissionAssistant()
            }
        }
    }

    func stop() {
        watch?.cancel(); watch = nil
        placement?.cancel(); placement = nil
        changes = nil
        window?.orderOut(nil); window = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        setup.suspendPermissionAssistant(returnToApp: false)
        return false
    }

    private func resize() {
        guard let window, let content = window.contentView else { return }
        let size = content.fittingSize
        guard size.width > 0, size.height > 0, window.contentLayoutRect.size != size else { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
    }

    /// One placement after the explicit handoff, never a polling loop that chases Settings.
    func placeBesideSettingsOnce() {
        placement?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window, let screen = NSScreen.main,
                  let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.systempreferences" }),
                  let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
                  let target = windows.first(where: { $0[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier && $0[kCGWindowLayer as String] as? Int == 0 }),
                  let bounds = target[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds) else { return }
            let settings = ScreenMap.toAppKit(rect)
            let visible = NSScreen.screens.first { $0.frame.contains(CGPoint(x: settings.midX, y: settings.midY)) }?.visibleFrame ?? screen.visibleFrame
            window.setFrame(PanelPlacement.frame(beside: settings, size: window.frame.size, visible: visible), display: true)
        }
        placement = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }
}

private struct GrantGuideView: View {
    @ObservedObject var setup: SetupController

    var body: some View {
        if let flow = setup.permissionFlow {
            PermissionAssistantCard(flow: flow, state: setup.states[flow.permission] ?? .unknown, note: setup.note,
                needsRestart: setup.needsPermissionRestart, nextGrant: setup.nextAssistantGrant,
                audioCheckRunning: setup.audioCheckRunning, canRepair: setup.canReset(flow.permission),
                proceed: setup.continuePermissionAssistant, openSettings: { setup.openSettings(flow.permission) },
                showFinder: { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) },
                playChime: setup.runAssistantAudioCheck, finish: setup.finishPermissionAssistant,
                later: { setup.suspendPermissionAssistant() },
                repair: { setup.retry(flow.permission, reset: true) }, restart: setup.restartForPermission)
        }
    }
}

/// Pure view data keeps every permission state renderable without asking macOS for access.
struct PermissionAssistantCard: View {
    let flow: PermissionFlow
    let state: PermissionStatus
    var note: String? = nil
    var needsRestart = false
    var nextGrant: Permission? = nil
    var audioCheckRunning = false
    var canRepair = false
    var proceed: () -> Void = {}
    var openSettings: () -> Void = {}
    var showFinder: () -> Void = {}
    var playChime: () -> Void = {}
    var finish: () -> Void = {}
    var later: () -> Void = {}
    var repair: () -> Void = {}
    var restart: () -> Void = {}
    @State private var help = false

    private var grant: Permission { flow.permission }
    private var ready: Bool { flow.stage == .ready }
    private var isAudio: Bool { grant == .systemAudio }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: ready ? "checkmark" : symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(ready ? StatusChip.Tone.good.text : Brand.accentText)
                    .frame(width: 44, height: 44)
                    .background((ready ? Color.green : Brand.violet).opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                Text(title).font(Brand.display(24, .bold)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(Brand.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note { Text(note).font(Brand.caption).foregroundStyle(StatusChip.Tone.warn.text).fixedSize(horizontal: false, vertical: true) }
                content
            }
            .padding(24).padding(.top, 12)
            Divider()
            HStack {
                Text("Permission assistant").font(Brand.caption2).foregroundStyle(.secondary)
                Spacer()
                if flow.stage == .waiting || flow.stage == .checkAudio {
                    Button("Finish later", action: later).buttonStyle(.brandPlain)
                } else { Text("Your settings are kept").font(Brand.caption2).foregroundStyle(.secondary) }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 400).fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Brand.violetBright)
    }

    @ViewBuilder private var content: some View {
        switch flow.stage {
        case .prepare:
            VStack(alignment: .leading, spacing: 16) {
                instruction(1, flow.repair ? "Clear the old permission" : isAudio ? "Ask macOS for access" : "Open the right Settings page",
                            flow.repair ? "Only this Whoprrr permission is reset." : "You stay in control of the next step.")
                instruction(2, isAudio ? "Check that audio gets through" : "Enable this copy of Whoprrr",
                            grant == .inputMonitoring ? "macOS may ask you to quit and reopen." : isAudio ? "A short chime checks the audio path." : "We’ll watch for the change quietly.")
            }.padding(.vertical, 8)
            Label("Your recipes, rules, and settings are kept.", systemImage: "lock").font(Brand.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: later).buttonStyle(.brandPlain)
                Button(flow.repair ? "Continue" : isAudio || ((grant == .microphone || grant == .camera) && state == .notDetermined) ? "Ask for access" : grant == .micDriver ? "Continue" : "Open System Settings", action: proceed).buttonStyle(.brand)
            }.padding(.top, 10)
        case .working:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparing this copy of Whoprrr").font(Brand.caption).foregroundStyle(.secondary) }
        case .waiting, .checkAudio:
            if audioCheckRunning {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Listening for the test chime").font(Brand.caption).foregroundStyle(.secondary) }
                Button("Play chime again", action: playChime).buttonStyle(.brandQuiet)
            } else if isAudio, flow.stage == .checkAudio || state == .unknown {
                StatusChip(text: state == .granted ? "Permission allowed" : "Ready to check audio", tone: state == .granted ? .good : .neutral)
                Button("Play test chime", action: playChime).buttonStyle(.brand)
            } else {
                StatusChip(text: needsRestart ? "Waiting for the restart" : "Waiting for your choice", tone: .warn)
            }
            if needsRestart {
                Button("Restart Whoprrr", action: restart).buttonStyle(.brand)
            } else if grant != .micDriver {
                Button("Open \(grant.title) in System Settings", action: openSettings).buttonStyle(AssistantLinkStyle()).font(Brand.caption)
            }
            if grant == .accessibility || grant == .inputMonitoring {
                DisclosureGroup("Whoprrr isn’t listed?", isExpanded: $help) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Click + below the list in System Settings, choose this copy of Whoprrr, then click Add. If an old entry won’t work, remove it with − first.")
                        Button("Show app in Finder", action: showFinder).buttonStyle(AssistantLinkStyle())
                        if canRepair { Button("Try repairing this permission…", action: repair).buttonStyle(AssistantLinkStyle()) }
                    }.font(Brand.caption).foregroundStyle(.secondary).padding(.top, 8)
                }.font(Brand.caption).padding(.top, 10)
            } else if canRepair {
                DisclosureGroup("Access still isn’t working?", isExpanded: $help) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Check Whoprrr’s switch in System Settings. If access still won’t work, repair this permission and try again.")
                        Button("Repair \(grant.title)…", action: repair).buttonStyle(AssistantLinkStyle())
                    }.font(Brand.caption).foregroundStyle(.secondary).padding(.top, 8)
                }.font(Brand.caption).padding(.top, 10)
            }
        case .ready:
            StatusChip(text: "Access checked", tone: .good).accessibilityAddTraits(.updatesFrequently)
            HStack { Spacer(); Button(nextGrant.map { "Continue to \($0.title)" } ?? "Done", action: finish).buttonStyle(.brand) }.padding(.top, 12)
        }
    }

    private func instruction(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(Brand.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).background(Color.primary.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Brand.headline)
                Text(detail).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var symbol: String {
        switch grant {
        case .inputMonitoring: "keyboard"
        case .systemAudio: "speaker.wave.2"
        case .microphone, .micDriver: "mic"
        case .camera: "camera"
        default: "lock.shield"
        }
    }

    private var title: String {
        switch flow.stage {
        case .prepare: "\(flow.repair ? "Repair" : "Set up") \(grant.title)"
        case .working: flow.repair ? "Clearing the old permission…" : "Preparing \(grant.title)…"
        case .checkAudio: audioCheckRunning ? "Checking the audio path…" : "Now check the audio path."
        case .ready: "\(grant.title) is ready."
        case .waiting:
            needsRestart ? "Access is on. One restart to finish." : isAudio && state == .denied ? "Audio access is still off." : "Enable \(grant.title)"
        }
    }

    private var detail: String {
        switch flow.stage {
        case .prepare: return flow.repair ? "We’ll clear this copy’s old permission, then help you enable it again." : grant.why
        case .working: return "Your recipes, rules, and settings are kept."
        case .checkAudio: return "Play a short chime so Whoprrr can check that audio gets through. Audio is not saved."
        case .ready: return isAudio ? "The equalizer and mixer can hear your apps." : "Whoprrr can use this permission. Continue when you’re ready."
        case .waiting:
            if needsRestart { return "Choose Quit & Reopen if macOS asks, or restart here. Whoprrr will come back to this guide." }
            switch grant {
            case .accessibility: return "Turn on this copy of Whoprrr in Accessibility. macOS may ask for Touch ID or your Mac password."
            case .inputMonitoring: return "Turn on this copy of Whoprrr in Input Monitoring. If macOS asks, choose Quit & Reopen. We’ll pick up right here."
            case .systemAudio: return state == .denied ? "The equalizer and mixer need access to process audio from other apps. Your settings are kept." : "Choose Allow when macOS asks. Then we’ll check the audio path with a short chime."
            case .paste: return "Choose Always Allow for Whoprrr. If the prompt didn’t appear, open the switch in System Settings."
            case .micDriver: return "Use your Mac password to install Whoprrr Mic. If it doesn’t appear, restart your Mac and resume here."
            default: return "Choose Allow when macOS asks, or turn on Whoprrr in System Settings."
            }
        }
    }
}

private struct AssistantLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Brand.caption).foregroundStyle(Brand.accentText)
            .padding(.vertical, 3).contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
