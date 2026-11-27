import SwiftUI
import WhopperKit

@MainActor
final class PresetActions: ObservableObject {
    @Published var problem: String?
    var preferredControl: String?

    func editedPreset(on page: AppPage, in library: PresetLibrary, includeOtherPanels: Bool = false) -> (PresetSurface, PresetEntry)? {
        let audio = Shared.audio.settings.eq.enabled ? ["audio.eq", "audio.outputfx", "audio.routing"] : ["audio.eq", "audio.routing"]
        let panel: [String]
        switch page {
        case .feature(.audio): panel = audio
        case .feature(.microphone): panel = ["audio.mic"]
        case .feature(.windows): panel = ["windows"]
        case .feature(.clipboard): panel = ["clipboard"]
        case .feature(.remap): panel = ["input"]
        default: panel = []
        }
        func edited(_ controls: [String]) -> (PresetSurface, PresetEntry)? {
            let ordered = controls.filter { $0 == preferredControl } + controls.filter { $0 != preferredControl }
            for control in ordered {
                guard let surface = PresetSurfaces.surface(control) else { continue }
                let groups = surface.groups(in: library)
                if groups.edited, let entry = groups.inUse { return (surface, entry) }
            }
            return nil
        }
        if let choice = edited(panel) { return choice }
        guard includeOtherPanels else { return nil }
        let all = audio + ["audio.mic", "windows", "clipboard", "input"]
        return edited(all.filter { !panel.contains($0) })
    }

    func apply(_ entry: PresetEntry, on surface: PresetSurface) {
        guard surface.apply(entry.data) else { problem = "Could not apply that preset."; return }
        if !Shared.presets.select(entry.id, at: surface.location) { couldNotSave() }
    }

    @discardableResult
    func update(_ entry: PresetEntry, on surface: PresetSurface) -> Bool {
        guard let data = surface.captureUpdate(for: entry),
              let update = Shared.presets.update(entry, with: data, at: surface.location,
                                                 recipePart: surface.recipePart, recipes: Shared.recipes) else {
            couldNotSave()
            return false
        }
        Shared.saveBar.showPresetUpdate(update, in: Shared.presets)
        return true
    }

    func couldNotSave() {
        problem = Shared.presets.preservesUnreadableFile
            ? "Whoprrr couldn’t read your presets file. It was kept in place and preset changes can’t be saved."
            : "Could not save the preset changes."
    }
}

struct PresetMenu: View {
    @EnvironmentObject private var library: PresetLibrary
    @EnvironmentObject private var actions: PresetActions
    var surface: PresetSurface
    @State private var picking = false
    @State private var managing = false
    @State private var asking = false
    @State private var name = ""

    var body: some View {
        let groups = surface.groups(in: library)
        let title = groups.inUse.map { $0.name + (groups.edited ? " · edited" : "") } ?? "Presets"
        Button {
            actions.preferredControl = surface.key
            picking.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bookmark")
                Text(title).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(Brand.caption2)
            }
        }
        .buttonStyle(.brandQuiet)
        .accessibilityLabel(title)
        .accessibilityHint("Choose a preset for \(surface.locationName)")
        .help("Presets for \(surface.locationName)")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            PresetPickerContents(surface: surface, groups: surface.groups(in: library),
                                 close: { picking = false }, saveNew: { name = ""; asking = true },
                                 manage: { managing = true })
                .frame(width: 268)
        }
        .sheet(isPresented: $managing) { ManagePresetsView(surface: surface) }
        .alert("Save as new preset", isPresented: $asking) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") { save() }.disabled(cleanName.isEmpty || nameTaken)
        } message: {
            if nameTaken { Text("A preset already has that name. Choose another name.") }
        }
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameTaken: Bool { presetNameTaken(cleanName, groups: surface.groups(in: library)) }

    private func save() {
        guard !nameTaken else {
            Task { @MainActor in asking = true }
            return
        }
        surface.sync()
        guard let data = surface.capture(), library.saveNew(cleanName, data: data, at: surface.location) else {
            actions.couldNotSave()
            return
        }
    }
}

struct PresetPickerContents: View {
    @EnvironmentObject private var actions: PresetActions
    let surface: PresetSurface
    let groups: PresetGroups
    let close: () -> Void
    let saveNew: () -> Void
    let manage: () -> Void
    #if DEBUG
    var renderAllRows = false
    #endif

    var body: some View {
        Group {
            #if DEBUG
            if renderAllRows { list } else { scrollingList }
            #else
            scrollingList
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Presets for \(surface.locationName)")
    }

    private var scrollingList: some View {
        ViewThatFits(in: .vertical) {
            list
            ScrollView { list }
        }
        .frame(maxHeight: 460)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let entry = groups.inUse, groups.edited {
                PresetMenuItem("Update “\(entry.name)”", detail: "⌘U", emphasized: true) {
                    close()
                    actions.update(entry, on: surface)
                }
                .keyboardShortcut("u", modifiers: .command)
                PresetMenuItem("Put “\(entry.name)” back") { close(); actions.apply(entry, on: surface) }
                Divider().padding(.vertical, 4)
            }
            if let entry = groups.inUse {
                heading("In use on \(surface.locationName)")
                choice(entry, inUse: true)
            }
            heading("Yours")
            if groups.selectableYours.isEmpty { empty("No other presets") }
            ForEach(groups.selectableYours) { choice($0) }
            heading("Built in")
            if groups.selectableBuiltIn.isEmpty { empty("No other built-in presets") }
            ForEach(groups.selectableBuiltIn) { choice($0) }
            Divider().padding(.vertical, 4)
            PresetMenuItem("Save as new preset…") { close(); saveNew() }
            PresetMenuItem("Manage presets…") { close(); manage() }
        }
        .padding(10)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(Brand.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.leading, 8).padding(.top, 4).accessibilityAddTraits(.isHeader)
    }

    private func empty(_ title: String) -> some View {
        Text(title).font(Brand.caption).foregroundStyle(.secondary).padding(.leading, 8).padding(.vertical, 4)
    }

    private func choice(_ entry: PresetEntry, inUse: Bool = false) -> some View {
        PresetMenuItem(entry.name, detail: entry.changed ? "Changed by you" : nil, checked: inUse) {
            close()
            if !inUse || !groups.edited { actions.apply(entry, on: surface) }
        }
    }
}

struct PresetMenuItem: View {
    let title: String
    let detail: String?
    let checked: Bool
    let emphasized: Bool
    let destructive: Bool
    let action: () -> Void

    init(_ title: String, detail: String? = nil, checked: Bool = false,
         emphasized: Bool = false, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.checked = checked
        self.emphasized = emphasized
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: 6) {
                if checked { Image(systemName: "checkmark").accessibilityHidden(true) }
                Text(title).font(Brand.subheadline.weight(emphasized ? .semibold : .regular))
                Spacer(minLength: 4)
                if let detail { Text(detail).font(Brand.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(destructive ? StatusChip.Tone.bad.text : (emphasized ? Brand.accentText : Color.primary))
            .background(emphasized ? Brand.violet.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(PresetItemStyle())
        .accessibilityAddTraits(checked ? [.isSelected] : [])
    }
}

private struct PresetItemStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovered || configuration.isPressed ? Brand.violet.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}

func presetNameTaken(_ name: String, groups: PresetGroups, except: PresetID? = nil) -> Bool {
    (groups.yours + groups.builtIn + groups.hidden).contains {
        $0.id != except && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
    }
}
