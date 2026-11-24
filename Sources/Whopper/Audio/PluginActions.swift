import SwiftUI
import AudioCore

enum PluginTarget { case mic, output
    var title: String { self == .mic ? "Microphone" : "System output" }
}

/// Editing the effect-plugin chains on the mic and on the system output.
extension AudioModel {
    func plugins(_ t: PluginTarget) -> [PluginSlot] { t == .mic ? settings.mic.plugins : settings.eq.plugins }
    private func setPlugins(_ t: PluginTarget, _ new: [PluginSlot]) {
        if t == .mic { settings.mic.plugins = new } else { settings.eq.plugins = new }
    }
    private func rack(_ t: PluginTarget) -> PluginRack { t == .mic ? micEngine.rack : eqEngine.rack }

    func addPlugin(_ info: PluginInfo, to t: PluginTarget) { syncPluginStates(); setPlugins(t, plugins(t) + [info.makeSlot()]) }
    func removePlugin(_ id: UUID, from t: PluginTarget) { setPlugins(t, plugins(t).filter { $0.id != id }) }
    func movePlugin(_ id: UUID, in t: PluginTarget, by delta: Int) {
        var list = plugins(t)
        guard let i = list.firstIndex(where: { $0.id == id }), list.indices.contains(i + delta) else { return }
        list.swapAt(i, i + delta); setPlugins(t, list)
    }
    func updatePlugin(_ id: UUID, in t: PluginTarget, _ change: (inout PluginSlot) -> Void) {
        var list = plugins(t)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i]); setPlugins(t, list)
    }
    func openPluginEditor(_ id: UUID, in t: PluginTarget) {
        rack(t).openEditor(id) { [weak self] in Task { @MainActor in self?.syncPluginStates() } }
    }

    /// Copies each loaded plugin's current state into its slot, so saving settings, a preset or a recipe keeps what you tweaked.
    func syncPluginStates() {
        for t in [PluginTarget.mic, .output] {
            let states = rack(t).captureStates()
            var list = plugins(t)
            var changed = false
            for i in list.indices { if let d = states[list[i].id], d != list[i].state { list[i].state = d; changed = true } }
            if changed { setPlugins(t, list) }
        }
    }
}
