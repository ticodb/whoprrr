import AppKit
import CoreGraphics
import AudioCore
import WindowCore
import InputCore
import WhopperKit

/// Reads the gear connected right now into a `GearScan`. Read-only: display reach comes from the brightness read the display
/// module already makes; nothing is written to any device.
@MainActor
enum GearScanner {
    static func current() -> GearScan {
        var arm = false
        #if arch(arm64)
        arm = true
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let mac = GearScan.Mac(model: sysctl("hw.model"), appleSilicon: arm, os: "\(v.majorVersion).\(v.minorVersion)")
        let screens = Shared.model.displays.map { d -> GearScan.Screen in
            let answers: Bool? = d.isBuiltIn ? nil : {
                switch Shared.model.reach[d.uuid] {
                case .responds?: true
                case .silent?: false
                default: d.hasEndpoint ? nil : false
                }
            }()
            return GearScan.Screen(name: d.shortName, width: CGDisplayPixelsWide(d.displayID), height: CGDisplayPixelsHigh(d.displayID), builtIn: d.isBuiltIn, answers: answers)
        }
        let audio = Shared.audio.devices.filter { !$0.isWhopperInternal && $0.transport != .virtual && $0.transport != .aggregate }
            .map { GearScan.Audio(uid: $0.uid, name: $0.name, transport: $0.transport.rawValue, hasInput: $0.hasInput, hasOutput: $0.hasOutput) }
        let logi = Shared.input.logiDevices.map { $0.name.trimmingCharacters(in: .whitespaces) }
        return GearScan(mac: mac, screens: screens, audio: audio, logitech: logi)
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

/// Turns the accepted lines of a starter plan into real settings and saves them as a recipe. Keeps what the Mac looked like
/// before, so one click puts everything back.
@MainActor
enum Starter {
    struct Applied { var recipeID: UUID; var name: String; fileprivate var backup: [String: Data] }

    static func apply(_ plan: StarterPlan, accepted: Set<String>) -> Applied {
        let recipes = Shared.recipes
        let backup = recipes.snapshot(recipes.surfaceKeys)
        let lines = plan.lines.filter { accepted.contains($0.id) }

        for o in plan.off { Shared.features.setEnabled(o.feature, false) }
        for f in Set(lines.map(\.feature)) { Shared.features.setEnabled(f, true) }

        var windows = Shared.windows.settings
        var audio = Shared.audio.settings
        var input = Shared.input.settings
        var pinned: [String] = []
        for l in lines {
            switch l.action {
            case .windowLayouts(let names):
                let valid = names.filter { WindowAction(rawValue: $0) != nil }
                windows.drawerActions = Set(valid.prefix(WindowSettings.drawerLimit))
            case .displayControl, .clipboard:
                break       // switching the feature on is the whole change
            case .keepAwake(let uid):
                var k = audio.keepAlive[uid] ?? KeepAliveSettings()
                k.enabled = true
                audio.keepAlive[uid] = k
            case .pinInput(let uid):
                pinned.append(uid)
            case .micSource(let uid):
                audio.mic.sourceUID = uid
            case .inputPreset(let id):
                if let p = InputPresets.all.first(where: { $0.id == id }) { input = InputPresets.apply(p, to: input) }
            }
        }
        if !pinned.isEmpty {
            audio.inputPin = InputPinPolicy(enabled: true, preferredUIDs: pinned + audio.inputPin.preferredUIDs.filter { !pinned.contains($0) })
        }
        Shared.windows.settings = windows
        Shared.audio.settings = audio
        Shared.input.settings = input

        let gear = Gear.current()
        let name = StarterRecipes.uniqueName(plan.name, existing: recipes.recipes.map(\.name))
        let wanted: Set<String> = ["features", "windows", "audio", "input", "clipboard"]
        let r = recipes.create(name: name, symbol: plan.symbol, includes: wanted.intersection(recipes.surfaceKeys), devices: gear, autoApply: !gear.isEmpty)
        recipes.notice = nil
        return Applied(recipeID: r.id, name: name, backup: backup)
    }

    /// Removes the starter recipe and restores every setting it changed.
    static func undo(_ a: Applied) {
        Shared.recipes.delete(a.recipeID)
        Shared.recipes.restore(a.backup)
    }
}

/// Sends a fit report, and only when the user presses Send. One request, no retries, no identifiers.
enum FitSender {
    static let endpoint = URL(string: "https://whoprrr.app/api/fit")!

    static func send(_ body: Data) async -> Bool {
        var req = URLRequest(url: endpoint, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
