import SwiftUI
import AudioCore
import WhopperKit

struct AudioPanel: View {
    @EnvironmentObject var m: AudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader("Audio", symbol: "slider.vertical.3", subtitle: "Equalizer, effects, routing")
            eqSection
            if m.settings.eq.enabled {
                Divider()
                HStack { SectionLabel("System effects"); Spacer(); PresetMenu(surface: PresetSurfaces.outputFX(m)) }
                OutputDynamicsView()
                PluginRackView(target: .output)
            }
            Divider()
            micSection
            Divider()
            keepAliveSection
        }
    }

    // MARK: Equalizer

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("System sound")
                Spacer()
                PresetMenu(surface: PresetSurfaces.eq(m))
                Toggle("", isOn: Binding(get: { m.settings.eq.enabled }, set: { m.settings.eq.enabled = $0 })).toggleStyle(.switch).labelsHidden().controlSize(.regular)
            }
            eqStatus
            if m.settings.eq.enabled || m.eqProfile != .flat {
                HStack {
                    Picker("Output", selection: Binding(get: { m.settings.eq.targetUID ?? "" }, set: { m.settings.eq.targetUID = $0.isEmpty ? nil : $0 })) {
                        Text("Follow default output").tag("")
                        ForEach(m.outputDevices.filter { $0.transport != .virtual }) { Text($0.name).tag($0.uid) }
                    }.labelsHidden()
                }
                if let uid = m.eqDeviceUID {
                    Toggle("Separate settings for \(m.name(for: uid))", isOn: Binding(get: { m.eqPerDevice }, set: { m.setEQPerDevice($0) }))
                        .font(Brand.caption)
                }
                EQBandsView(profile: Binding(get: { m.eqProfile }, set: { m.eqProfile = $0 }))
            }
        }
    }

    @ViewBuilder private var eqStatus: some View {
        switch m.eqState {
        case .off: if m.settings.eq.enabled { Text("Starting…").font(Brand.caption).foregroundStyle(.secondary) }
        case .running(let d, let muted):
            Text(muted ? "Equalizing \(d)" : "Waiting for the first sound to confirm audio capture on \(d)…")
                .font(Brand.caption).foregroundStyle(muted ? .green : .orange)
        case .unavailable(let why): Text(why).font(Brand.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .failed(let why):
            Text(why).font(Brand.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            Button("Open System Audio Recording settings") { NSWorkspace.shared.open(Permission.systemAudio.settingsURL) }.buttonStyle(.link).font(Brand.caption)
        }
    }

    // MARK: Microphone

    private var micSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { SectionLabel("Microphone input"); Spacer(); PresetMenu(surface: PresetSurfaces.routing(m)) }
            Toggle("Always use this input", isOn: Binding(
                get: { m.settings.inputPin.enabled },
                set: { m.settings.inputPin.enabled = $0 }))
            Picker("Input", selection: Binding(get: { m.pinnedUID ?? "" }, set: { m.setPinned($0.isEmpty ? nil : $0) })) {
                Text("Choose…").tag("")
                if let p = m.pinnedUID, !m.inputDevices.contains(where: { $0.uid == p }) {
                    Text("\(m.name(for: p)) (not connected)").tag(p)
                }
                ForEach(m.inputDevices) { Text($0.name).tag($0.uid) }
            }
            Text(micStatus).font(Brand.caption).foregroundStyle(micStatusColor).fixedSize(horizontal: false, vertical: true)
            Text("Stops Bluetooth headsets and other devices from taking over the input, which also keeps Bluetooth audio at full quality. Apps that pick their own device ignore the system input; the Microphone tab adds a virtual mic that covers those.")
                .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var micStatus: String {
        guard m.settings.inputPin.enabled else { return "Off. Current input: \(m.defaultInputUID.map(m.name(for:)) ?? "none")." }
        guard let s = m.pinStatus else { return "Starting…" }
        if m.pinnedUID == nil { return "Pick an input to keep." }
        if !s.preferredConnected { return "\(m.name(for: m.pinnedUID!)) is not connected. Using \(s.activeUID.map(m.name(for:)) ?? "none") until it is." }
        if s.backedOff { return "Another app keeps changing the input, so Whoprrr paused for a moment." }
        return "Holding \(s.activeUID.map(m.name(for:)) ?? "?")\(s.corrections > 0 ? " (restored \(s.corrections)×)" : "")."
    }
    private var micStatusColor: Color {
        guard m.settings.inputPin.enabled, let s = m.pinStatus else { return .secondary }
        return s.backedOff || !s.preferredConnected ? .orange : .green
    }

    // MARK: Keep-alive

    private var keepAliveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KEEP SPEAKERS AWAKE").font(Brand.caption).foregroundStyle(.secondary)
            Text("Plays an inaudible tone so a Bluetooth speaker never sees silence and powers off.")
                .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(m.outputDevices) { d in KeepAliveRow(uid: d.uid, name: d.name, connected: true, bluetooth: d.transport == .bluetooth) }
            // Enabled devices that are currently disconnected stay visible so they can be turned off.
            ForEach(offlineKeepAlive, id: \.self) { uid in KeepAliveRow(uid: uid, name: m.name(for: uid), connected: false, bluetooth: true) }
        }
    }

    private var offlineKeepAlive: [String] {
        let live = Set(m.outputDevices.map(\.uid))
        return m.settings.keepAlive.filter { $0.value.enabled && !live.contains($0.key) }.keys.sorted()
    }
}

struct KeepAliveRow: View {
    @EnvironmentObject var m: AudioModel
    let uid: String, name: String, connected: Bool, bluetooth: Bool
    @State private var open = false

    var body: some View {
        let s = m.keepAliveSettings(uid)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: bluetooth ? "dot.radiowaves.left.and.right" : "speaker.wave.2").frame(width: 18).foregroundStyle(.secondary)
                Text(name).lineLimit(1)
                Spacer()
                if s.enabled { statusDot }
                Button { open.toggle() } label: { Image(systemName: open ? "chevron.up" : "chevron.down") }.buttonStyle(.plain)
                Toggle("", isOn: Binding(get: { s.enabled }, set: { var n = s; n.enabled = $0; m.setKeepAlive(uid, n) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.regular)
            }
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    tuner("Level", value: Binding(get: { s.levelDB }, set: { var n = s; n.levelDB = $0; m.setKeepAlive(uid, n) }),
                          range: -90...(-30), step: 1, unit: "dBFS")
                    tuner("Tone", value: Binding(get: { s.frequencyHz }, set: { var n = s; n.frequencyHz = $0; m.setKeepAlive(uid, n) }),
                          range: 20...1000, step: 5, unit: "Hz")
                    tuner("Pulse every", value: Binding(get: { s.pulseEverySeconds }, set: { var n = s; n.pulseEverySeconds = $0; m.setKeepAlive(uid, n) }),
                          range: 0...120, step: 5, unit: s.pulseEverySeconds == 0 ? "continuous" : "s")
                    Text("If the speaker still sleeps, raise the level a few dB. Every speaker's auto-off is different.")
                        .font(Brand.caption2).foregroundStyle(.secondary)
                }.padding(.leading, 24)
            }
        }
    }

    private var statusDot: some View {
        let st = m.keepAliveStatus[uid]
        let ok = st?.running == true
        return Text(ok ? "running" : (connected ? (st?.error ?? "starting") : "waiting for device"))
            .font(Brand.caption2).foregroundStyle(ok ? .green : .orange)
    }

    private func tuner(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        HStack {
            Text(label).font(Brand.caption).frame(width: 78, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(unit == "continuous" ? unit : "\(Int(value.wrappedValue)) \(unit)").font(Brand.caption.monospacedDigit()).frame(width: 82, alignment: .trailing)
        }
    }
}


struct EQBandsView: View {
    @Binding var profile: EQProfile
    private func label(_ f: Double) -> String { f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(profile.bands.indices, id: \.self) { i in
                    VStack(spacing: 2) {
                        Text(String(format: "%+.0f", profile.bands[i].gainDB)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                        VSlider(value: Binding(get: { profile.bands[i].gainDB }, set: { profile.bands[i].gainDB = $0 }), range: -12...12)
                        Text(label(profile.bands[i].freq)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
            }
            HStack {
                Text("Preamp").font(Brand.caption)
                Slider(value: $profile.preampDB, in: -12...6, step: 0.5)
                Text(String(format: "%+.1f dB", profile.preampDB)).font(Brand.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
                Button("Auto") { profile.preampDB = profile.autoPreampDB }.controlSize(.regular).help("Lower the preamp by the largest boost so nothing clips")
            }
        }
    }
}

/// Vertical slider with a centre detent at 0.
struct VSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    private let height: CGFloat = 110

    var body: some View {
        GeometryReader { g in
            let span = range.upperBound - range.lowerBound
            let y = CGFloat(1 - (value - range.lowerBound) / span) * g.size.height
            ZStack(alignment: .top) {
                Capsule().fill(.quaternary).frame(width: 4).frame(maxWidth: .infinity)
                Rectangle().fill(.secondary.opacity(0.4)).frame(width: 12, height: 1).position(x: g.size.width / 2, y: g.size.height / 2)
                Circle().fill(Color.accentColor).frame(width: 12, height: 12).position(x: g.size.width / 2, y: y)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let t = 1 - min(max(d.location.y / g.size.height, 0), 1)
                var v = range.lowerBound + Double(t) * span
                if abs(v) < 0.6 { v = 0 }
                value = (v * 2).rounded() / 2
            })
            .onTapGesture(count: 2) { value = 0 }
        }.frame(width: 22, height: height)
    }
}
