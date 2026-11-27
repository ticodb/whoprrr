import SwiftUI
import WhopperKit

struct ManagePresetsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: PresetLibrary
    @EnvironmentObject private var actions: PresetActions
    let surface: PresetSurface
    #if DEBUG
    var previewActionsFor: PresetID? = nil
    var renderAllRows = false
    #endif

    private var preview: PresetID? {
        #if DEBUG
        previewActionsFor
        #else
        nil
        #endif
    }

    @State private var more: PresetID?
    @State private var renaming: PresetEntry?
    @State private var rename = false
    @State private var name = ""
    @State private var deleting: PresetEntry?
    @State private var delete = false

    var body: some View {
        let groups = surface.groups(in: library)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Presets").font(Brand.display(20, .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.brandPlain).keyboardShortcut(.cancelAction)
            }
            #if DEBUG
            if renderAllRows { rows(groups, previewActionsFor: preview) } else { scrollingRows(groups) }
            #else
            scrollingRows(groups)
            #endif
        }
        .padding(22)
        .frame(width: 480)
        .alert("Rename preset", isPresented: $rename, presenting: renaming) { entry in
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { renameTo(cleanName, entry: entry) }
                .disabled(cleanName.isEmpty || cleanName == entry.name || presetNameTaken(cleanName, groups: groups, except: entry.id))
        } message: { entry in
            if presetNameTaken(cleanName, groups: groups, except: entry.id) {
                Text("A preset already has that name. Choose another name.")
            }
        }
        .alert("Delete preset?", isPresented: $delete, presenting: deleting) { entry in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard case .personal(let id) = entry.id else { return }
                if !library.delete(id, for: surface.key) { actions.couldNotSave() }
            }
        } message: { entry in
            Text("Delete “\(entry.name)”?")
        }
    }

    private func scrollingRows(_ groups: PresetGroups) -> some View {
        ViewThatFits(in: .vertical) {
            rows(groups).fixedSize(horizontal: false, vertical: true)
            ScrollView { rows(groups) }
        }
        .frame(maxHeight: 440)
    }

    private func rows(_ groups: PresetGroups, previewActionsFor preview: PresetID? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            group("Yours", entries: groups.yours, groups: groups, preview: preview)
            group("Built in", entries: groups.builtIn, groups: groups, preview: preview)
            if !groups.hidden.isEmpty { group("Hidden", entries: groups.hidden, groups: groups, hidden: true, preview: preview) }
        }
    }

    @ViewBuilder private func group(_ title: String, entries: [PresetEntry], groups: PresetGroups,
                                    hidden: Bool = false, preview: PresetID?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Brand.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            if entries.isEmpty {
                Text("No presets").font(Brand.caption).foregroundStyle(.secondary).padding(.vertical, 5)
            }
            ForEach(entries) { entry in
                row(entry, inUse: groups.inUse?.id == entry.id, edited: groups.edited, hidden: hidden)
                if preview == entry.id {
                    HStack {
                        Spacer()
                        menu(entry).frame(width: 235)
                            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                if entry.id != entries.last?.id { Divider() }
            }
        }
    }

    private func row(_ entry: PresetEntry, inUse: Bool, edited: Bool, hidden: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(Brand.subheadline.weight(.semibold)).lineLimit(2)
                    .onTapGesture(count: 2) { if !hidden { beginRename(entry) } }
                if inUse {
                    Text("In use on \(surface.locationName)" + (edited ? " · edited" : ""))
                        .font(Brand.caption2).foregroundStyle(.secondary)
                }
                if entry.changed { Text("Changed by you").font(Brand.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if hidden, case .factory(let id) = entry.id {
                Button("Show") { setHidden(false, id: id) }.buttonStyle(.brandPlain)
                    .accessibilityLabel("Show \(entry.name)")
            } else {
                if inUse && edited {
                    Button("Update") { update(entry) }.buttonStyle(.brand)
                        .accessibilityLabel("Update \(entry.name)")
                }
                Button { more = entry.id } label: { Image(systemName: "ellipsis").frame(minWidth: 16) }
                    .buttonStyle(.brandPlain)
                    .accessibilityLabel("More actions for \(entry.name)")
                    .popover(isPresented: Binding(get: { more == entry.id }, set: { if !$0 { more = nil } }), arrowEdge: .bottom) {
                        menu(entry).frame(width: 235)
                    }
            }
        }
        .padding(.vertical, 4)
    }

    private func menu(_ entry: PresetEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            PresetMenuItem("Rename…") { more = nil; beginRename(entry) }
            if !entry.isFactory {
                PresetMenuItem("Duplicate") {
                    more = nil
                    let groups = surface.groups(in: library)
                    let names = (groups.yours + groups.builtIn + groups.hidden).map(\.name)
                    let name = StarterRecipes.uniqueName("\(entry.name) Copy", existing: names)
                    if !library.duplicate(entry, name: name, for: surface.key) { actions.couldNotSave() }
                }
            }
            PresetMenuItem("Update with current settings") { more = nil; update(entry) }
            if case .factory(let id) = entry.id {
                if entry.changed { PresetMenuItem("Restore original") { more = nil; restoreOriginal(id) } }
                Divider()
                PresetMenuItem("Hide") { more = nil; setHidden(true, id: id) }
            } else {
                Divider()
                PresetMenuItem("Delete", destructive: true) { more = nil; deleting = entry; delete = true }
            }
        }
        .padding(8)
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func beginRename(_ entry: PresetEntry) {
        renaming = entry
        name = entry.name
        rename = true
    }

    private func renameTo(_ newName: String, entry: PresetEntry) {
        guard !presetNameTaken(newName, groups: surface.groups(in: library), except: entry.id) else {
            Task { @MainActor in rename = true }
            return
        }
        if !library.rename(entry.id, to: newName, for: surface.key) { actions.couldNotSave() }
    }

    private func setHidden(_ hidden: Bool, id: String) {
        if !library.setHidden(hidden, id: id, for: surface.key) { actions.couldNotSave() }
    }

    private func restoreOriginal(_ id: String) {
        let wasInUse = surface.groups(in: library).inUse?.id == .factory(id)
        guard library.restoreFactory(id, for: surface.key) else { actions.couldNotSave(); return }
        if wasInUse, let entry = surface.groups(in: library).inUse { actions.apply(entry, on: surface) }
    }

    private func update(_ entry: PresetEntry) {
        if actions.update(entry, on: surface) { dismiss() }
    }
}
