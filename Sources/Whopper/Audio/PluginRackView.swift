import SwiftUI
import AudioCore

/// The effect-plugin chain for the mic or the system output: add Audio Unit plugins, reorder, bypass, open their editors.
struct PluginRackView: View {
    @EnvironmentObject var m: AudioModel
    var target: PluginTarget
    @State private var catalog: [PluginInfo] = []
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Effect plugins")
                Spacer()
                addMenu
            }
            let slots = m.plugins(target)
            if slots.isEmpty {
                Text("None yet. Add compressors, de-essers, EQs, reverbs: any Audio Unit effect installed on this Mac, including Apple’s own.")
                    .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(slots.enumerated()), id: \.element.id) { i, slot in row(slot, index: i, count: slots.count) }
            if !slots.isEmpty {
                Text("Plugins run in order, after the built-in processing. Their settings are saved with the chain, presets and recipes.")
                    .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard catalog.isEmpty, !loading else { return }
        loading = true
        catalog = await Task.detached { PluginCatalog.effects() }.value
        loading = false
    }

    private var addMenu: some View {
        Menu {
            if catalog.isEmpty { Text(loading ? "Looking for plugins…" : "No effect plugins found") }
            let makers = Dictionary(grouping: catalog, by: \.manufacturer).sorted { ($0.key == "Apple" ? "" : $0.key.lowercased()) < ($1.key == "Apple" ? "" : $1.key.lowercased()) }
            ForEach(makers, id: \.key) { maker, infos in
                Menu("\(maker) (\(infos.count))") {
                    ForEach(infos) { info in Button(info.name) { m.addPlugin(info, to: target) } }
                }
            }
            Divider()
            Button("Rescan plugins") { catalog = []; Task { await load() } }
        } label: { Label("Add plugin", systemImage: "plus") }
            .menuStyle(.button).buttonStyle(.brand).fixedSize()
    }

    private func row(_ slot: PluginSlot, index: Int, count: Int) -> some View {
        let status = m.pluginStatus[slot.id]
        return BrandCard {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { slot.enabled }, set: { v in m.updatePlugin(slot.id, in: target) { $0.enabled = v } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(slot.name).font(Brand.display(15, .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(slot.manufacturer).font(Brand.caption).foregroundStyle(.secondary).lineLimit(1)
                        switch status {
                        case .loading?: ProgressView().controlSize(.mini)
                        case .ready?: if slot.enabled { StatusChip(text: "Running", tone: .good) }
                        case .failed?: StatusChip(text: "Not running", tone: .bad)
                        case nil: EmptyView()
                        }
                    }
                }
                Spacer(minLength: 4)
                Button { m.openPluginEditor(slot.id, in: target) } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).help("Open the plugin’s window").disabled(status != .ready)
                Button { m.movePlugin(slot.id, in: target, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(index == 0)
                Button { m.movePlugin(slot.id, in: target, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(index == count - 1)
                Menu {
                    Toggle("Run inside Whoprrr", isOn: Binding(get: { slot.inProcess }, set: { v in m.updatePlugin(slot.id, in: target) { $0.inProcess = v } }))
                    Divider()
                    Button("Remove", role: .destructive) { m.removePlugin(slot.id, from: target) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
            if case .failed(let why)? = status {
                Text(why).font(Brand.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Compressor and limiter on the system output.
struct OutputDynamicsView: View {
    @EnvironmentObject var m: AudioModel

    private var d: Binding<OutputDynamicsSettings> { Binding(get: { m.settings.eq.dynamics }, set: { m.settings.eq.dynamics = $0 }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Dynamics")
            Toggle("Compressor: even out loud and quiet parts", isOn: d.compressor.enabled)
            if d.wrappedValue.compressor.enabled {
                row("Threshold", d.compressor.thresholdDB, -50...0, "dB")
                row("Ratio", d.compressor.ratio, 1...12, ": 1")
                row("Attack", d.compressor.attackMs, 1...100, "ms")
                row("Release", d.compressor.releaseMs, 20...1000, "ms")
                row("Make-up gain", d.compressor.makeupDB, 0...18, "dB")
            }
            Toggle("Limiter: never louder than a ceiling", isOn: d.limiterEnabled)
            if d.wrappedValue.limiterEnabled {
                row("Ceiling", d.ceilingDB, -12...0, "dB")
                row("Release", d.limiterReleaseMs, 10...500, "ms")
            }
            Text("Applied to everything you play, after the equalizer and plugins. Stereo-linked, so the picture does not shift.")
                .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, _ unit: String) -> some View {
        HStack {
            Text(label).font(Brand.caption).frame(width: 90, alignment: .leading)
            Slider(value: v, in: range)
            Text(String(format: v.wrappedValue.rounded() == v.wrappedValue ? "%.0f" : "%.1f", v.wrappedValue) + " " + unit)
                .font(Brand.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
        }
    }
}
