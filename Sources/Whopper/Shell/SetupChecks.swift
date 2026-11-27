import AppKit
import ApplicationServices
import AudioCore
import WindowCore
import WhopperKit

struct SetupPermissionChecker: PermissionChecking {
    func status(_ permission: Permission) -> PermissionStatus {
        if permission == .micDriver {
            return CoreAudioSystem.shared.devices().contains { $0.uid == WhopperMic.uid && $0.hasInput } ? .granted : .denied
        }
        return LivePermissionChecker().status(permission)
    }
}

struct OwnPermissionResetter: PermissionResetting {
    func reset(_ permission: Permission) async -> Bool {
        guard let service = permission.resetService, let bundle = Bundle.main.bundleIdentifier,
              Bundle.main.bundleURL.pathExtension == "app",
              ProcessInfo.processInfo.environment["WHOPPER_NO_START"] != "1",
              ProcessInfo.processInfo.environment["WHOPPER_DATA_DIR"] == nil else { return false }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundle]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }
}

@MainActor
final class SetupChecks: TasteProbing {
    private var chime: Process?
    private var cuedChime: Task<Void, Never>?

    func startChimeTest() {
        Shared.audio.beginEQTest()
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

    var heardChime: Bool { Shared.audio.processedPeak > 0.0003 }

    func tryFeature(_ feature: Feature, mode: TasteMode) async -> TasteFinding {
        switch feature {
        case .windows:
            return await checkWindows(mode)
        case .remap:
            if mode == .afterUpdate {
                // No synthetic keys after an update: something else may be bound to them. Only open and close a test tap.
                let open = Shared.input.tapOpensForSetup()
                let grant: Permission = CGPreflightPostEventAccess() ? .inputMonitoring : .accessibility
                return open ? TasteFinding(.works, detail: "Whoprrr can watch the keyboard.")
                    : TasteFinding(.notWorking, grants: [grant], detail: "Whoprrr could not watch the keyboard.")
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
            let devices = CoreAudioSystem.shared.devices()
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
            let devices = CoreAudioSystem.shared.devices()
            guard devices.contains(where: { $0.uid == source && $0.hasInput }) else {
                return TasteFinding(.notWorking, detail: "The selected microphone did not answer.")
            }
            if mode == .afterUpdate { return TasteFinding(.works, detail: "The microphone grant, source and Whoprrr Mic are available.") }
            Shared.audio.beginMicTest()
            defer { Shared.audio.endMicTest() }
            for _ in 0..<40 {
                if Task.isCancelled { break }
                if Shared.audio.latestMicSignal > 0.0003 { return TasteFinding(.works, detail: "The microphone level moved.") }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return TasteFinding(.notWorking, grants: [.microphone], detail: "No sound reached Whoprrr Mic. Speak into the selected mic and try again.")
        case .clipboard:
            // Test a private pasteboard so the user's copied items stay in place. The public preflight
            // in TasteTest separately proves that background reads of the general pasteboard are allowed.
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.clearContents()
            let token = "Whoprrr"
            let read = board.setString(token, forType: .string) && board.string(forType: .string) == token
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
            return TasteFinding(.notWorking, detail: "No external display answered a brightness read.")
        }
    }

    private func checkWindows(_ mode: TasteMode) async -> TasteFinding {
        if mode == .afterUpdate {
            let answered = await Task.detached {
                var app: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &app)
                return result == .success || result == .noValue
            }.value
            return check(answered, "The Accessibility window service answered.",
                         "The Accessibility window service did not answer.", grants: [.accessibility])
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

    private func check(_ worked: Bool, _ success: String, _ failure: String, grants: Set<Permission> = []) -> TasteFinding {
        worked ? TasteFinding(.works, detail: success) : TasteFinding(.notWorking, grants: grants, detail: failure)
    }
}
