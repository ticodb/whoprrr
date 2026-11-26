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

// MARK: Save bar

/// Sits at the bottom of the main window on every page: "Cookin'" while settings are being changed, the save bar once they have
/// been left alone, and the confirmation after saving.
struct SaveBarArea: View {
    @EnvironmentObject var bar: SaveBarController
    @State private var naming = false

    var body: some View {
        Group {
            switch bar.phase {
            case .idle: EmptyView()
            case .changing, .saving: cookin
            case .unsaved(let recipe, let parts): unsaved(recipe, parts)
            case .saved(let c): saved(c)
            }
        }
        .animation(.easeOut(duration: 0.15), value: bar.phase)
        .sheet(isPresented: $naming) { SaveAsNewSheet() }
    }

    private var cookin: some View {
        HStack { CookinLabel(detail: nil); Text(bar.cookinLabel ?? "").font(Brand.caption).foregroundStyle(.secondary); Spacer() }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Brand.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .transition(.opacity)
    }

    private func unsaved(_ recipe: String, _ parts: [String]) -> some View {
        let summary = Text(recipe).fontWeight(.semibold) + Text(" has changes you have not saved: \(parts.joined(separator: ", "))")
        let buttons = HStack(spacing: 8) {
            Button("Save to \(clipped(recipe))") { bar.save() }.buttonStyle(.brand).keyboardShortcut("s", modifiers: .command)
            Button("Save as new recipe…") { naming = true }.buttonStyle(.brandQuiet)
            Button("Put back") { bar.putBack() }.buttonStyle(.brandQuiet)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { summary.font(Brand.subheadline).lineLimit(1); Spacer(minLength: 8); buttons }
            VStack(alignment: .leading, spacing: 10) { summary.font(Brand.subheadline).fixedSize(horizontal: false, vertical: true); buttons }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.violet.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.violetBright.opacity(0.4)))
        .accessibilityElement(children: .contain)
        .transition(.opacity)
    }

    private func saved(_ c: SaveBarController.Confirmation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(c.message).font(Brand.subheadline).lineLimit(2)
            Spacer(minLength: 8)
            if c.undoRecipeID != nil { Button("Undo") { bar.undoSave() }.buttonStyle(.brandQuiet) }
            Button { bar.dismissConfirmation() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(12)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.opacity)
    }

    private func clipped(_ name: String) -> String { name.count > 20 ? String(name.prefix(19)) + "…" : name }
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
