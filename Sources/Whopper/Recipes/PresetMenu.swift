import SwiftUI
import WhopperKit

@MainActor
final class PresetActions: ObservableObject {
    @Published var problem: String?
    var preferredControl: String?

    func editedPreset(on page: AppPage, in library: PresetLibrary) -> (PresetSurface, PresetEntry)? {
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
                if groups.edited, let entry = groups.inUse, !entry.isFactory { return (surface, entry) }
            }
            return nil
        }
        return edited(panel)
    }

    func apply(_ entry: PresetEntry, on surface: PresetSurface) {
        guard surface.apply(entry.data) else { problem = "Could not apply that preset."; return }
        if !Shared.presets.select(entry.id, at: surface.location) { couldNotSave() }
        Shared.saveBar.didChoosePreset(in: surface.key, copy: savePart(of: surface))
    }

    @discardableResult
    func update(_ entry: PresetEntry, on surface: PresetSurface) -> Bool {
        guard !entry.isFactory else { return false }
        let inUse = surface.groups(in: Shared.presets).inUse?.id == entry.id
        let merge = savePart(of: surface)
        let saved = Shared.saveBar.savePreset(entry.name, in: inUse ? surface.key : nil, copy: merge) {
            surface.sync()
            guard let data = surface.capture(),
                  let update = Shared.presets.update(entry, with: data, at: surface.location,
                                                     recipePart: surface.recipePart, recipes: Shared.recipes,
                                                     mergeRecipePart: merge) else {
                return nil
            }
            return { Shared.presets.undo(update, recipes: Shared.recipes, applyRecipe: false) }
        }
        if !saved { couldNotSave() }
        return saved
    }

    @discardableResult
    func create(_ name: String, on surface: PresetSurface) -> Bool {
        let merge = savePart(of: surface)
        let saved = Shared.saveBar.savePreset(name, in: surface.key, copy: merge) {
            surface.sync()
            guard let data = surface.capture(),
                  let creation = Shared.presets.create(name, data: data, at: surface.location,
                                                       recipePart: surface.recipePart, recipes: Shared.recipes,
                                                       mergeRecipePart: merge) else {
                return nil
            }
            return { Shared.presets.undoCreation(creation, recipes: Shared.recipes) }
        }
        if !saved { couldNotSave() }
        return saved
    }

    private func savePart(of surface: PresetSurface) -> (Data, Data) -> Data? {
        { SaveBarSurfaces.mergePreset(surface, from: $0, into: $1) }
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
        let title = groups.inUse.map { "Presets · " + $0.name + (groups.edited ? " · edited" : "") } ?? "Presets"
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
        actions.create(cleanName, on: surface)
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
            heading("Built-in")
            if groups.builtIn.isEmpty { empty("No built-in presets") }
            ForEach(groups.builtIn) { choice($0, inUse: $0.id == groups.inUse?.id) }
            heading("Yours")
            if groups.yours.isEmpty { empty("None yet") }
            ForEach(groups.yours) { choice($0, inUse: $0.id == groups.inUse?.id) }
            Divider().padding(.vertical, 4)
            if let entry = groups.inUse, groups.edited, !entry.isFactory {
                PresetMenuItem("Update “\(entry.name)”", detail: "⌘U", emphasized: true) {
                    close()
                    actions.update(entry, on: surface)
                }
                .keyboardShortcut("u", modifiers: .command)
            }
            PresetMenuItem("Save as new…") { close(); saveNew() }
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
        PresetMenuItem(entry.name + (inUse && groups.edited ? " · edited" : ""), checked: inUse) {
            close()
            actions.apply(entry, on: surface)
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
