import SwiftUI
import AudioCore

struct MicPanel: View {
    @EnvironmentObject var m: AudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader("Microphone", symbol: "mic", subtitle: "Effects for every app") { PresetMenu(surface: PresetSurfaces.mic(m)) }
            driverSection
            Divider()
            Toggle("Process my mic and send it to Whoprrr Mic", isOn: Binding(get: { m.settings.mic.enabled }, set: { m.enableMic($0) }))
                .disabled(!m.micLoaded)
            engineStatus
            if m.settings.mic.enabled {
                Picker("Source", selection: Binding(get: { m.settings.mic.sourceUID ?? "" }, set: { m.settings.mic.sourceUID = $0.isEmpty ? nil : $0 })) {
                    Text("Choose…").tag("")
                    ForEach(m.inputDevices) { Text($0.name).tag($0.uid) }
                }
                meter
                slider("Gain", Binding(get: { m.settings.mic.gainDB }, set: { m.settings.mic.gainDB = $0 }), -12...24, "dB")
                HStack {
                    Toggle("Cut rumble below", isOn: Binding(get: { m.settings.mic.highPassEnabled }, set: { m.settings.mic.highPassEnabled = $0 }))
                    Slider(value: Binding(get: { m.settings.mic.highPassHz }, set: { m.settings.mic.highPassHz = $0 }), in: 40...200, step: 5)
                    Text("\(Int(m.settings.mic.highPassHz)) Hz").font(Brand.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
                }
                gate; compressor
                Divider()
                PluginRackView(target: .mic)
                Divider()
                DisclosureGroup("Equalizer") {
                    VStack(alignment: .leading) {
                        Toggle("Enabled", isOn: Binding(get: { m.settings.mic.eq.enabled }, set: { m.settings.mic.eq.enabled = $0 }))
                        EQBandsView(profile: Binding(get: { m.settings.mic.eq }, set: { var n = $0; n.enabled = m.settings.mic.eq.enabled; m.settings.mic.eq = n }))
                    }
                }
                Text("While this is on, Whoprrr keeps “Whoprrr Mic” as the system input, so every app gets the processed sound. Apps that ask which mic to use: pick Whoprrr Mic. If the engine stops, the input falls back to the real mic.")
                    .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Driver

    private var driverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: m.micLoaded ? "checkmark.circle.fill" : (m.driverInstalled ? "arrow.triangle.2.circlepath" : "circle.dashed"))
                    .foregroundStyle(m.micLoaded ? .green : .secondary)
                Text(m.micLoaded ? "Whoprrr Mic is installed and loaded" : m.driverInstalled ? "Installed; waiting for macOS to load it" : "Whoprrr Mic is not installed").font(Brand.callout)
                Spacer()
                if m.driverInstalled { Button("Remove…") { m.uninstallDriver() }.controlSize(.regular) }
                else { Button("Install…") { m.installDriver() }.controlSize(.regular).buttonStyle(.borderedProminent) }
            }
            if let msg = m.installMessage { Text(msg).font(Brand.caption).foregroundStyle(.orange) }
            if !m.driverInstalled {
                Text("Adds a virtual microphone so effects reach every app. Needs your administrator password once, and audio restarts for a second or two.")
                    .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var engineStatus: some View {
        switch m.micState {
        case .off: EmptyView()
        case .driverMissing: Text("Whoprrr Mic is not loaded.").font(Brand.caption).foregroundStyle(.orange)
        case .sourceMissing: Text("Choose a microphone to process.").font(Brand.caption).foregroundStyle(.orange)
        case .running(let s): Text("Processing \(s) → Whoprrr Mic").font(Brand.caption).foregroundStyle(.green)
        case .failed(let w): Text(w).font(Brand.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Controls

    private var meter: some View {
        VStack(spacing: 3) {
            bar("In", m.micLevels.input); bar("Out", m.micLevels.output)
        }
    }

    private func bar(_ label: String, _ peak: Float) -> some View {
        let db = peak > 0.00001 ? 20 * log10(Double(peak)) : -90
        let f = min(max((db + 60) / 60, 0), 1)
        return HStack(spacing: 6) {
            Text(label).font(Brand.caption2).frame(width: 22, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(db > -3 ? Color.red : db > -12 ? Color.orange : Color.green).frame(width: g.size.width * f)
                }
            }.frame(height: 6)
            Text(db <= -89 ? "–∞" : String(format: "%.0f", db)).font(Brand.caption2.monospacedDigit()).frame(width: 28, alignment: .trailing)
        }
    }

    private func slider(_ label: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ unit: String) -> some View {
        HStack {
            Text(label).font(Brand.callout).frame(width: 90, alignment: .leading)
            Slider(value: v, in: r, step: 0.5)
            Text(String(format: "%+.1f %@", v.wrappedValue, unit)).font(Brand.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
        }
    }

    private var gate: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Noise gate", isOn: Binding(get: { m.settings.mic.gate.enabled }, set: { m.settings.mic.gate.enabled = $0 }))
            if m.settings.mic.gate.enabled {
                slider("Threshold", Binding(get: { m.settings.mic.gate.thresholdDB }, set: { m.settings.mic.gate.thresholdDB = $0 }), -80...(-20), "dB")
            }
        }
    }

    private var compressor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Compressor", isOn: Binding(get: { m.settings.mic.compressor.enabled }, set: { m.settings.mic.compressor.enabled = $0 }))
            if m.settings.mic.compressor.enabled {
                slider("Threshold", Binding(get: { m.settings.mic.compressor.thresholdDB }, set: { m.settings.mic.compressor.thresholdDB = $0 }), -50...0, "dB")
                slider("Ratio", Binding(get: { m.settings.mic.compressor.ratio }, set: { m.settings.mic.compressor.ratio = $0 }), 1...10, ":1")
                slider("Make-up", Binding(get: { m.settings.mic.compressor.makeupDB }, set: { m.settings.mic.compressor.makeupDB = $0 }), 0...18, "dB")
            }
        }
    }
}
