import SwiftUI
import WhopperKit

// MARK: Cookin'

/// The one label and indicator for every deliberate wait in the main window: while settings are still being changed, and the
/// moment of saving. Not used in the menu-bar panel.
struct CookinLabel: View {
    var detail: String?
    var body: some View {
        HStack(spacing: 8) {
            CookinIndicator()
            Text("Cookin'…").font(Brand.display(14, .semibold)).foregroundStyle(Brand.accentText)
            if let detail { Text(detail).font(Brand.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "Cookin'. \($0)" } ?? "Cookin'")
    }
}

/// A small pulse (still, when the Mac is set to reduce motion).
struct CookinIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var body: some View {
        Circle().fill(Brand.violetBright).frame(width: 9, height: 9)
            .opacity(on ? 1 : 0.4).scaleEffect(on ? 1 : 0.75)
            .onAppear {
                if reduceMotion { on = true } else { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { on = true } }
            }
    }
}

/// An automatic switch that would leave unsaved changes behind asks first. Escape, or closing the sheet, stays where you are.
struct AutoSwitchSheet: View {
    let pending: PendingSwitch
    @EnvironmentObject var recipes: RecipeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(RecipeWording.switchQuestionTitle).font(Brand.display(20, .semibold))
            Text(RecipeWording.switchQuestionDetail(candidate: pending.candidateName, current: pending.currentName, parts: pending.parts))
                .font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { choices }
                VStack(alignment: .leading, spacing: 8) { choices }
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled()
    }

    @ViewBuilder private var choices: some View {
        Button(RecipeWording.saveThenSwitch(current: pending.currentName)) { recipes.resolveSwitch(.saveThenSwitch) }
            .buttonStyle(.brand).keyboardShortcut(.defaultAction)
        Button(RecipeWording.switchWithoutSaving) { recipes.resolveSwitch(.switchWithoutSaving) }.buttonStyle(.brandQuiet)
        Button(RecipeWording.stay(current: pending.currentName)) { recipes.resolveSwitch(.stay) }.buttonStyle(.brandQuiet).keyboardShortcut(.cancelAction)
    }
}

struct SaveBarArea: View {
    @EnvironmentObject private var bar: SaveBarController
    @EnvironmentObject private var recipes: RecipeStore
    @EnvironmentObject private var library: PresetLibrary
    @EnvironmentObject private var presets: PresetActions
    @State private var creating = false

    private var surfaces: [PresetSurface] {
        bar.changedSections.compactMap { PresetSurfaces.surface($0) }
    }

    var body: some View {
        if !bar.changedSections.isEmpty || bar.confirmation != nil {
            VStack(alignment: .leading, spacing: 8) {
                if !bar.changedSections.isEmpty {
                    Label("Changed: \(bar.changedTitles.joined(separator: ", "))", systemImage: "circle.fill")
                        .font(Brand.subheadline.weight(.semibold)).foregroundStyle(Brand.accentText)
                        .accessibilityAddTraits(.isHeader)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { actions }.fixedSize()
                        VStack(alignment: .leading, spacing: 6) { actions }
                    }
                }
                if let confirmation = bar.confirmation {
                    HStack(spacing: 10) {
                        Label(confirmation.message, systemImage: "checkmark.circle.fill")
                            .font(Brand.subheadline).foregroundStyle(StatusChip.Tone.good.text)
                        Spacer()
                        if confirmation.canUndo { Button("Undo") { bar.undoSave() }.buttonStyle(.brandPlain) }
                    }
                    .onAppear { AccessibilityNotification.Announcement(confirmation.message).post() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.violet.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.violetBright.opacity(0.32)))
            .sheet(isPresented: $creating) { CreateFromChangesSheet(surfaces: surfaces) }
        }
    }

    @ViewBuilder private var actions: some View {
        ForEach(surfaces, id: \.key) { surface in
            let groups = surface.groups(in: library)
            if groups.edited, let entry = groups.inUse, !entry.isFactory {
                Button("Update preset \(entry.name)") { presets.update(entry, on: surface) }
                    .buttonStyle(.brandQuiet)
            }
        }
        if let recipe = recipes.active {
            Button("Update recipe \(recipe.name)") { bar.save() }.buttonStyle(.brand)
        }
        Button("Create new…") { creating = true }.buttonStyle(.brandQuiet)
        Button("Put back") { bar.putBack() }.buttonStyle(.link).font(Brand.caption)
    }
}

private struct CreateFromChangesSheet: View {
    private enum Choice { case recipe, preset(PresetSurface) }

    let surfaces: [PresetSurface]
    @EnvironmentObject private var bar: SaveBarController
    @EnvironmentObject private var recipes: RecipeStore
    @EnvironmentObject private var library: PresetLibrary
    @EnvironmentObject private var presets: PresetActions
    @Environment(\.dismiss) private var dismiss
    @State private var choice: Choice?
    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(heading).font(Brand.display(20, .semibold)).accessibilityAddTraits(.isHeader)
            if let choice {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                if let problem { Text(problem).font(Brand.caption).foregroundStyle(StatusChip.Tone.bad.text) }
                HStack {
                    Spacer()
                    cancel
                    Button("Save") { save(choice) }
                        .buttonStyle(.brand).keyboardShortcut(.defaultAction).disabled(cleanName.isEmpty)
                }
            } else {
                ForEach(surfaces, id: \.key) { surface in
                    Button("Preset · \(surface.title)") { choice = .preset(surface) }.buttonStyle(.brandQuiet)
                }
                Button("Recipe · all settings for your gear") {
                    name = recipes.active.map { recipes.suggestedCopyName(of: $0.id) } ?? ""
                    choice = .recipe
                }.buttonStyle(.brandQuiet)
                HStack { Spacer(); cancel }
            }
        }
        .padding(24).frame(width: 440)
    }

    private var heading: String {
        switch choice {
        case nil: "Create new"
        case .preset: "Name your preset"
        case .recipe: "Name your recipe"
        }
    }

    private var cancel: some View { Button("Cancel") { dismiss() }.buttonStyle(.brandQuiet).keyboardShortcut(.cancelAction) }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save(_ choice: Choice) {
        switch choice {
        case .recipe:
            guard bar.saveAsNew(name: cleanName, devices: Gear.current()) else { problem = bar.problem; bar.problem = nil; return }
        case .preset(let surface):
            guard !presetNameTaken(cleanName, groups: surface.groups(in: library)) else {
                problem = "A preset already has that name."
                return
            }
            guard presets.create(cleanName, on: surface) else { problem = presets.problem; presets.problem = nil; return }
        }
        dismiss()
    }
}
