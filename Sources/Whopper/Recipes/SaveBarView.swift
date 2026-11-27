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

// MARK: Recipe save mark and messages

private struct RecipeSaveMarkKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var showsRecipeSaveMark: Bool {
        get { self[RecipeSaveMarkKey.self] }
        set { self[RecipeSaveMarkKey.self] = newValue }
    }
}

struct RecipeSaveMark: View {
    @EnvironmentObject private var bar: SaveBarController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var library: PresetLibrary
    @EnvironmentObject private var presets: PresetActions
    @EnvironmentObject private var nav: WindowNav
    @EnvironmentObject private var audio: AudioModel
    @EnvironmentObject private var windows: WindowModel
    @EnvironmentObject private var clipboard: ClipboardController
    @EnvironmentObject private var input: InputController
    @State private var naming = false
    @State private var filled = false

    var body: some View {
        Group {
            switch bar.phase {
            case .changing(let recipe):
                Menu {
                    Button("Save to \(recipe)") { bar.save() }.keyboardShortcut("s", modifiers: .command)
                    if let (surface, entry) = presets.editedPreset(on: nav.page, in: library, includeOtherPanels: true) {
                        Button("Update preset “\(entry.name)” too") { presets.update(entry, on: surface) }
                    }
                    Button("Save as new recipe…") { naming = true }
                    Divider()
                    Button("Put back") { bar.putBack() }
                } label: {
                    Text("Cookin’ · \(recipe)")
                        .lineLimit(1).truncationMode(.middle)
                        .font(Brand.caption.weight(.semibold))
                        .foregroundStyle(Brand.accentText)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Brand.violet.opacity(0.14), in: Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: 220)
                .accessibilityLabel("Cookin’ · \(recipe)")
            case .saving:
                HStack(spacing: 6) {
                    Text("Cookin’…")
                    Capsule().fill(Brand.violet.opacity(0.23)).frame(width: 24, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Brand.violetBright).frame(width: filled ? 24 : 1)
                        }
                }
                .font(Brand.caption.weight(.semibold)).foregroundStyle(Brand.accentText)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Brand.violet.opacity(0.14), in: Capsule())
                .accessibilityLabel("Saving recipe")
                .onAppear {
                    if reduceMotion { filled = true }
                    else { withAnimation(.linear(duration: SaveBarController.savingDuration)) { filled = true } }
                }
                .onDisappear { filled = false }
            case .saved where bar.served:
                Label("Served", systemImage: "checkmark")
                    .font(Brand.caption.weight(.semibold)).foregroundStyle(StatusChip.Tone.good.text)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(StatusChip.Tone.good.color.opacity(0.12), in: Capsule())
            default:
                EmptyView()
            }
        }
        .sheet(isPresented: $naming) { SaveAsNewSheet() }
    }
}

struct SaveBarArea: View {
    @EnvironmentObject private var bar: SaveBarController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let confirmation = bar.confirmation {
                saved(confirmation)
            } else if let recipe = bar.reminderRecipe {
                reminder(recipe)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: bar.confirmation)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: bar.reminderRecipe)
    }

    private func reminder(_ recipe: String) -> some View {
        let headline = Text(SaveBarController.reminder)
            .font(Brand.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        let buttons = HStack(spacing: 8) {
            Button("Save to \(recipe)") { bar.save() }.buttonStyle(.brand)
            Button("Not yet") { bar.dismissReminder() }.buttonStyle(.brandPlain)
        }.fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { headline; Spacer(minLength: 4); buttons }
            VStack(alignment: .leading, spacing: 10) { headline; buttons }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.violet.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.violetBright.opacity(0.4)))
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(SaveBarController.reminder).post() }
        .transition(.opacity)
    }

    private func saved(_ confirmation: SaveBarController.Confirmation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(StatusChip.Tone.good.text)
                .accessibilityHidden(true)
            Text(confirmation.message).font(Brand.subheadline).lineLimit(2)
            Spacer(minLength: 8)
            if confirmation.undoRecipeID != nil || confirmation.canUndoPreset { Button("Undo") { bar.undoSave() }.buttonStyle(.brandPlain) }
            Button { bar.dismissConfirmation() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss saved message").help("Dismiss")
        }
        .padding(12)
        .background(StatusChip.Tone.good.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .onHover { bar.hoverConfirmation($0) }
        .onAppear { AccessibilityNotification.Announcement(confirmation.message).post() }
        .transition(.opacity)
    }
}

// MARK: Left on the stove

/// At the top of a page: something was changed and never saved, and the window was closed (or the app quit) in the meantime.
struct StoveReminder: View {
    @EnvironmentObject var recipes: RecipeStore

    var body: some View {
        if let s = recipes.stove, let r = recipes.recipe(s.recipeID) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "flame.fill").font(.system(size: 16)).foregroundStyle(StatusChip.Tone.warn.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(RecipeWording.stoveTitle).font(Brand.subheadline.weight(.semibold))
                    Text(RecipeWording.stoveDetail(parts: s.parts.map(recipes.title(forPart:)), recipe: r.name, changedAt: s.changedAt, now: Date()))
                        .font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(StatusChip.Tone.warn.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StatusChip.Tone.warn.color.opacity(0.4)))
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: Sheets

struct SaveAsNewSheet: View {
    @EnvironmentObject var bar: SaveBarController
    @EnvironmentObject var recipes: RecipeStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save as new recipe").font(Brand.display(20, .semibold))
            Text("Your changes go into a new recipe, and it becomes the one that is on. \(recipes.active?.name ?? "The current recipe") stays as it was saved.")
                .font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).font(Brand.body)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.brandQuiet).keyboardShortcut(.cancelAction)
                Button("Save") { bar.saveAsNew(name: name.trimmingCharacters(in: .whitespaces)); dismiss() }
                    .buttonStyle(.brand).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 440)
        .onAppear { if let a = recipes.active { name = recipes.suggestedCopyName(of: a.id) } }
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
