import SwiftUI
import AudioCore

struct MixerSection: View {
    @EnvironmentObject private var model: AudioModel

    private struct Row: Identifiable {
        let id: String
        let name: String
        let app: MixApp?

        var status: String {
            guard let app else { return "Not running" }
            return app.isPlaying ? "Playing" : "Running"
        }
    }

    private var rows: [Row] {
        let apps = Dictionary(model.mixApps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let adjusted = model.settings.mix.apps
        let ids = Set(adjusted.keys).union(model.mixApps.filter {
            $0.isPlaying || (!$0.processIDs.isEmpty && $0.id != MixApp.systemID)
        }.map(\.id))
        return ids.map { id in
            Row(id: id, name: apps[id]?.name ?? adjusted[id]?.name ?? id, app: apps[id])
        }.sorted {
            if ($0.app == nil) != ($1.app == nil) { return $0.app != nil }
            if ($0.id == MixApp.systemID) != ($1.id == MixApp.systemID) { return $1.id == MixApp.systemID }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Mixer")
                Spacer(minLength: 8)
                Text("Apps you adjust are saved with the recipe")
                    .font(Brand.caption).foregroundStyle(.secondary)
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        if !model.settings.eq.enabled {
            message("The mixer needs the equalizer switched on.")
        } else if case .running(_, true) = model.eqState {
            let rows = self.rows
            if rows.isEmpty {
                message("Nothing is making sound. Apps appear here when they play.")
            } else {
                BrandCard {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            if row.id != rows.first?.id { Divider() }
                            channel(row)
                        }
                    }
                }
            }
        } else if case .running = model.eqState {
            message("The mixer is waiting for the equalizer to hear sound.")
        } else {
            message("The mixer needs the equalizer to be running.")
        }
    }

    private func message(_ text: String) -> some View {
        BrandCard { Text(text).font(Brand.caption).foregroundStyle(.secondary) }
    }

    private func channel(_ row: Row) -> some View {
        let adjusted = model.settings.mix.apps[row.id]
        let muted = adjusted?.muted ?? false
        let volume = Binding<Double>(
            get: { model.settings.mix.apps[row.id]?.volume ?? 1 },
            set: { value in
                model.settings.mix.set(row.id, volume: value, muted: model.settings.mix.apps[row.id]?.muted ?? false, name: row.name)
            })
        let percent = "\(Int((volume.wrappedValue * 100).rounded()))%"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                icon(row).opacity(row.app == nil ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(Brand.caption.weight(.semibold))
                        .foregroundStyle(row.app == nil || muted ? .secondary : .primary).lineLimit(1)
                        .help(row.name)
                    Text(row.status).font(Brand.caption2).foregroundStyle(.secondary)
                }.frame(minWidth: 104, idealWidth: 144, maxWidth: 144, alignment: .leading)

                Slider(value: volume, in: 0...1, step: 0.01)
                    .tint(muted || row.app == nil ? Color.secondary : Brand.violetBright)
                    .accessibilityLabel("\(row.name) volume")
                    .accessibilityValue(muted ? "\(percent), muted" : percent)
                Text(muted ? "Muted" : percent)
                    .font(Brand.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 43, alignment: .trailing)
                    .accessibilityHidden(true)
                Button {
                    model.settings.mix.set(row.id, volume: volume.wrappedValue,
                                           muted: !(model.settings.mix.apps[row.id]?.muted ?? false), name: row.name)
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                        .frame(width: 26, height: 26)
                        .background(muted ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(muted ? "Unmute \(row.name)" : "Mute \(row.name)")
                .help(muted ? "Unmute \(row.name)" : "Mute \(row.name)")
                ZStack {
                    Color.clear.frame(width: 22, height: 26).accessibilityHidden(true)
                    if adjusted != nil {
                        Menu {
                            Button("Reset") { model.settings.mix.reset(row.id) }
                                .accessibilityLabel("Reset \(row.name) volume")
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 22)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .accessibilityLabel("\(row.name) options")
                        .help("\(row.name) options")
                    }
                }.frame(width: 22)
            }
            if model.mixFailures.contains(row.id), adjusted != nil {
                Text("Could not take control of this app’s sound.")
                    .font(Brand.caption2).foregroundStyle(.secondary).padding(.leading, 36)
            }
        }.padding(.vertical, 5)
    }

    private func icon(_ row: Row) -> some View {
        let url = row.app?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: row.id)
        return Group {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
            } else {
                Image(systemName: row.id == MixApp.systemID ? "speaker.wave.2" : "app")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }.frame(width: 26, height: 26).accessibilityHidden(true)
    }
}
