import SwiftUI
import WhopperKit

struct BackupReviewSheet: View {
    @ObservedObject var controller: BackupController
    let item: BackupController.Review
    @State private var selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Brand.display(20, .semibold)).accessibilityAddTraits(.isHeader)
            Label(item.fileName, systemImage: "archivebox").font(Brand.subheadline).lineLimit(2)
            Text("Made with Whoprrr \(item.contents.backup.appVersion) · \(item.contents.backup.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(Brand.caption).foregroundStyle(.secondary)
            if item.action == .take {
                Text("This backup was made with a different key. Pick a recipe to fit to your Mac with Picklsss.")
                    .font(Brand.subheadline)
                if !item.contents.recipes.isEmpty {
                    Picker("Recipe", selection: $selected) {
                        ForEach(item.contents.recipes) { recipe in Text(recipe.name).tag(Optional(recipe.id)) }
                    }
                }
                Text("Saved presets and settings for unrelated gear stay out of the shared setup.")
                    .font(Brand.caption).foregroundStyle(.secondary)
            } else {
                summary(item.contents.summary)
                if item.action == .restore {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Replaces current data").font(Brand.subheadline.weight(.semibold))
                        if let current = item.current {
                            Text(current.recipes == 0 && current.presets == 0 && current.devices == 0
                                 ? "This Mac has no recipes, presets or separate device settings. The current app settings will be replaced."
                                 : "Your \(current.description), along with the current app settings.")
                        } else {
                            Text("The current recipes, presets and app settings on this Mac.")
                        }
                        Text("Whoprrr keeps a copy before restoring.")
                    }
                    .font(Brand.caption).foregroundStyle(.secondary)
                } else {
                    Text("Includes all recipes, presets and device settings. Opens on any Mac with your key.")
                        .font(Brand.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { controller.review = nil }.buttonStyle(.brandQuiet).keyboardShortcut(.cancelAction)
                Button(buttonTitle, action: proceed).buttonStyle(.brand).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { selected = item.contents.recipes.first?.id }
    }

    private var title: String {
        switch item.action {
        case .export: "Back up everything"
        case .restore: "Restore this backup?"
        case .take: "This backup is from another key"
        }
    }

    private var buttonTitle: String {
        switch item.action {
        case .export: "Save…"
        case .restore: "Restore"
        case .take: "Open as shared setup"
        }
    }

    private func summary(_ value: BackupSummary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow { Text("Recipes"); Text(value.recipes.formatted()).gridColumnAlignment(.trailing) }
            GridRow { Text("Presets"); Text(value.presets.formatted()) }
            GridRow { Text("Devices with their own settings"); Text(value.devices.formatted()) }
        }
        .font(Brand.subheadline)
    }

    private func proceed() {
        switch item.action {
        case .export: controller.save(item)
        case .restore: controller.restore(item)
        case .take:
            let recipe = item.contents.recipes.first { $0.id == selected }
                ?? Recipe(name: "Current settings", sections: item.contents.liveSections)
            controller.take(item, recipe: recipe)
        }
    }
}
