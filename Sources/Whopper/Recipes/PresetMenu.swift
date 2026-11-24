import SwiftUI
import WhopperKit

/// "Presets" menu for one settings surface: apply a saved preset, save the current settings, delete one.
struct PresetMenu: View {
    @EnvironmentObject var library: PresetLibrary
    var surface: PresetSurface
    @State private var asking = false
    @State private var name = ""
    @State private var failed = false

    var body: some View {
        Menu {
            let saved = library.presets(for: surface.key)
            if saved.isEmpty { Text("No saved presets yet") }
            ForEach(saved) { p in Button(p.name) { if !surface.apply(p.data) { failed = true } } }
            Divider()
            Button("Save current as…") { name = ""; asking = true }
            if !saved.isEmpty {
                Menu("Delete") { ForEach(saved) { p in Button(p.name, role: .destructive) { library.delete(p.id, for: surface.key) } } }
            }
        } label: { Label("Presets", systemImage: "bookmark") }
            .menuStyle(.button).buttonStyle(.brandQuiet).fixedSize()
            .help("Save and restore \(surface.title.lowercased()) settings")
            .alert("Save \(surface.title.lowercased()) preset", isPresented: $asking) {
                TextField("Name", text: $name)
                Button("Save") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty, let d = surface.capture() { library.save(n, data: d, for: surface.key) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Saving a name that exists replaces it.") }
            .alert("Could not apply that preset", isPresented: $failed) { Button("OK", role: .cancel) {} }
    }
}
