import AppKit
import ApplicationServices
import AudioCore
import WindowCore
import WhopperKit

struct SetupPermissionChecker: PermissionChecking {
    func status(_ permission: Permission) -> PermissionStatus {
        if permission == .micDriver {
            // The device list the audio model already keeps (read off the main thread), never a CoreAudio call here.
            let devices = Thread.isMainThread ? MainActor.assumeIsolated { Shared.audio.devices } : CoreAudioSystem.shared.devices()
            return devices.contains { $0.uid == WhopperMic.uid && $0.hasInput } ? .granted : .denied
        }
        return LivePermissionChecker().status(permission)
    }
}

struct OwnPermissionResetter: PermissionResetting {
    func reset(_ permission: Permission) async -> Bool {
        guard let service = permission.resetService, let bundle = Bundle.main.bundleIdentifier,
              Bundle.main.bundleURL.pathExtension == "app",
              ProcessInfo.processInfo.environment["WHOPPER_NO_START"] != "1",
              ProcessInfo.processInfo.environment["WHOPPER_DATA_DIR"] == nil || bundle.hasPrefix("gg.tico.whopper.qa.") else { return false }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundle]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            // Never wait forever: give up after 10 seconds and report that the reset didn't work.
            for _ in 0..<200 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { process.terminate(); return false }
            return process.terminationStatus == 0
        }.value
    }
}

@MainActor
final class SetupChecks: TasteProbing {
    private var chime: Process?
    private var cuedChime: Task<Void, Never>?
    private var verifiedAudio = false

    func prepareAudioPermission() { verifiedAudio = false; Shared.audio.beginEQTest() }

    func startChimeTest() {
        prepareAudioPermission()
        cuedChime?.cancel()
        cuedChime = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            playChime()
        }
    }

    func playChime() {
        guard chime?.isRunning != true else { return }
        // The tap excludes Whoprrr's own process to prevent feedback. Play the chime in a separate process.
        let sound = Process()
        sound.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        sound.arguments = ["-v", "0.2", "/System/Library/Sounds/Glass.aiff"]
        sound.standardOutput = FileHandle.nullDevice
        sound.standardError = FileHandle.nullDevice
        try? sound.run()
        chime = sound
    }

    func stopChimeTest() {
        cuedChime?.cancel()
        cuedChime = nil
        if chime?.isRunning == true { chime?.terminate() }
        chime = nil
        Shared.audio.endEQTest()
    }

    func rememberAudioProof() { if Shared.audio.processedPeak > 0.0003 { verifiedAudio = true } }
    // Keep this proof through Done/Continue so the subsequent Taste test doesn't depend
    // on whether the person clicked before the live meter returned to silence.
    var heardChime: Bool { verifiedAudio || Shared.audio.processedPeak > 0.0003 }

    func tryFeature(_ feature: Feature, mode: TasteMode) async -> TasteFinding {
        switch feature {
        case .windows:
            return await checkWindows(mode)
        case .remap:
            if mode == .afterUpdate {
                // No synthetic keys and no second tap after an update. The running remapper is the proof; it starts
                // alongside this check, so give it a moment. Only a definite denial names a grant.
                for _ in 0..<10 where Shared.input.status == .off && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
                switch Shared.input.status {
                case .running, .paused: return TasteFinding(.works, detail: "The remapper is running.")
                case .needsAccessibility: return TasteFinding(.notWorking, grants: [.accessibility], detail: "Accessibility is off for Whoprrr.")
                case .needsInputMonitoring: return TasteFinding(.notWorking, grants: [.inputMonitoring], detail: "Input Monitoring is off for Whoprrr.")
                case .off, .failed: return TasteFinding(.needsCheck, detail: "Run Test remapping to confirm.")
                }
            }
            let worked = await Shared.input.verifyForSetup()
            let grant: Permission = CGPreflightPostEventAccess() ? .inputMonitoring : .accessibility
            return worked ? TasteFinding(.works, detail: "A test key went through the remapper.")
                : TasteFinding(.notWorking, grants: [grant], detail: "No remapped test key arrived.")
        case .audio:
            if Shared.audio.settings.eq.enabled {
                if mode == .afterUpdate {
                    // macOS can't report this grant. The equalizer's saved proof stands; without it, nothing is parked.
                    return Shared.audio.settings.eq.permissionVerified
                        ? TasteFinding(.works, detail: "The equalizer has heard sound before.")
                        : TasteFinding(.needsCheck, detail: "Play something to confirm the equalizer.")
                }
                // A new recording can trigger TCC, so only the chime the person started counts here.
                return heardChime
                    ? TasteFinding(.works, detail: "A short chime went through the equalizer.")
                    : TasteFinding(.needsCheck, grants: [.systemAudio], detail: "Play a chime to confirm System Audio Recording.")
            }
            let settings = Shared.audio.settings
            let devices = await Self.devices()
            let found = devices.contains { device in
                (device.hasInput && settings.inputPin.enabled && settings.inputPin.preferredUIDs.contains(device.uid))
                    || (device.hasOutput && settings.keepAlive[device.uid]?.enabled == true)
            }
            if !settings.inputPin.enabled, !settings.keepAlive.values.contains(where: \.enabled) {
                return check(devices.contains(where: \.hasOutput), "The current output answered.", "No output device answered.")
            }
            return check(found, "The device selected for audio routing answered.", "The device selected for audio routing did not answer.")
        case .microphone:
            let source = Shared.audio.settings.mic.sourceUID
            let devices = await Self.devices()
            guard devices.contains(where: { $0.uid == source && $0.hasInput }) else {
                return TasteFinding(.notWorking, detail: "The selected microphone did not answer.")
            }
            if mode == .afterUpdate { return TasteFinding(.works, detail: "The microphone grant, source and Whoprrr Mic are available.") }
            Shared.audio.beginMicTest()
            defer { Shared.audio.endMicTest() }
            for _ in 0..<24 {
                if Task.isCancelled { break }
                if Shared.audio.latestMicSignal > 0.0003 { return TasteFinding(.works, detail: "The microphone level moved.") }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return TasteFinding(.notWorking, grants: [.microphone], detail: "No sound reached Whoprrr Mic. Speak into the selected mic and try again.")
        case .clipboard:
            if mode == .afterUpdate {
                // Read-only after an update: nothing is written to any pasteboard and history is untouched.
                return TasteFinding(.works, detail: "Clipboard history is on.")
            }
            // Taste test only: a private, uniquely named pasteboard. The general clipboard and history never see the
            // test word, so there is nothing to restore.
            let read = await Task.detached {
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                board.clearContents()
                let token = "Whoprrr"
                return board.setString(token, forType: .string) && board.string(forType: .string) == token
            }.value
            return check(read, "Whoprrr copied a word and read it back.", "Whoprrr could not read back its test word.", grants: [.paste])
        case .display:
            let model = Shared.model
            let snapshot = model.registry.snapshot
            for display in model.externals where display.hasEndpoint {
                if let target = try? model.controller.target(for: display, in: snapshot),
                   (try? await model.controller.read(.brightness, target: target, logFailures: false)) != nil {
                    return TasteFinding(.works, detail: "The external display answered a brightness read.")
                }
            }
            if mode == .afterUpdate {
                return TasteFinding(.needsCheck, detail: "Could not check the external display after the update.")
            }
            return TasteFinding(.notWorking, detail: "No external display answered a brightness read.")
        }
    }

    private func checkWindows(_ mode: TasteMode) async -> TasteFinding {
        if mode == .afterUpdate {
            // Only "not trusted" is a definite failure. A busy app answering .cannotComplete says nothing about the grant.
            let disabled = await Task.detached {
                guard AXIsProcessTrusted() else { return true }
                var app: CFTypeRef?
                return AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &app) == .apiDisabled
            }.value
            return check(!disabled, "Accessibility is on for Whoprrr.", "Accessibility is off for Whoprrr.", grants: [.accessibility])
        }
        let screens = ScreenMap.current()
        // The target is this app's window. Keep its main thread available to answer AX requests.
        let worked = await Task.detached {
            guard let window = AXWindow.focused(of: .current), let frame = window.frame else { return false }
            let screen = ScreenMap.best(for: frame, in: screens)
            let dx: CGFloat = screen.map { frame.maxX + 16 > $0.visible.maxX ? -16 : 16 } ?? 16
            let moved = frame.offsetBy(dx: dx, dy: 0)
            let changed = window.setFrame(moved) && abs((window.frame?.minX ?? frame.minX) - frame.minX) >= 8
            let restored = window.setFrame(frame)
            return changed && restored
        }.value
        return check(worked, "Whoprrr moved this window and put it back.",
                     "Whoprrr could not move its setup window and put it back.", grants: [.accessibility])
    }

    /// CoreAudio can stall; never ask it on the main thread.
    private static func devices() async -> [AudioDeviceInfo] { await Task.detached { CoreAudioSystem.shared.devices() }.value }

    private func check(_ worked: Bool, _ success: String, _ failure: String, grants: Set<Permission> = []) -> TasteFinding {
        worked ? TasteFinding(.works, detail: success) : TasteFinding(.notWorking, grants: grants, detail: failure)
    }
}
