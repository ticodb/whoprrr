import SwiftUI
import AudioCore
import InputCore
import WhopperKit

/// Sample data for screenshots and demos. Only active when WHOPPER_DEMO=1 *and* WHOPPER_DATA_DIR points somewhere other
/// than your real settings, so it can never touch them.
@MainActor
enum DemoData {
    static var isOn: Bool {
        let e = ProcessInfo.processInfo.environment
        return e["WHOPPER_DEMO"] == "1" && !(e["WHOPPER_DATA_DIR"] ?? "").isEmpty
    }

    /// Hide devices named after a person ("Alex's iPhone") from anything shown.
    static func isPersonal(_ name: String) -> Bool { name.contains("\u{2019}") || name.contains("'") }

    static func seedAfterGearLoads(delay: TimeInterval = 5) {
        guard isOn else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { seed() }
    }

    private static func seed() {
        let r = Shared.recipes, a = Shared.audio, i = Shared.input
        guard r.recipes.isEmpty else { return }
        let gear = Gear.current()

        // "On the road": different audio, no desk gear.
        a.settings.eq.enabled = false
        a.settings.eq.dynamics = OutputDynamicsSettings()
        r.create(name: "On the road", symbol: "airplane", includes: ["audio", "windows", "input", "clipboard"],
                 devices: [DeviceSignature(kind: .audioOutput, key: "demo-headphones", name: "AirPods Pro")], autoApply: true)

        // "Home desk": the full setup.
        a.settings.eq.enabled = true
        a.eqProfile = EQProfile.presets.first { $0.name == "Vocal" }?.profile ?? .flat
        a.settings.eq.dynamics.compressor.enabled = true
        a.settings.eq.dynamics.limiterEnabled = true
        if let limiter = PluginCatalog.effects().first(where: { $0.isApple && $0.name.contains("Peak Limiter") }) { a.addPlugin(limiter, to: .output) }
        for id in ["numpad-period", "spanish-accents", "mouse-middle-mission"] {
            if let p = InputPresets.all.first(where: { $0.id == id }) { i.apply(preset: p) }
        }
        i.save(Rule(name: "Precision button", trigger: .logi(0x00ED), tap: .command("clipboard.open")))
        let home = r.create(name: "Home desk", symbol: "house", includes: Set(r.surfaceList.map(\.key)).subtracting(["display"]), devices: gear, autoApply: true)
        r.apply(home.id)
        r.notice = nil
    }
}
