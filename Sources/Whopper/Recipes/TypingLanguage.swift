import Carbon
import SwiftUI
import WhopperKit

@MainActor
final class TypingLanguageController: ObservableObject {
    struct Source: Identifiable, Equatable {
        let id: String
        let name: String
        let enabled: Bool
        let canEnable: Bool
        let selectable: Bool
    }

    @Published private(set) var sources: [Source] = []
    @Published private(set) var note: String?
    @Published private(set) var skippedNote: String?
    private(set) var lastAppliedRecipeID: UUID?
    private let store = JSONStore<TypingLanguageRule>(name: "typing-language")
    private var rule = TypingLanguageRule()
    private var observers: [NSObjectProtocol] = []

    var enabled: [Source] { sources.filter { $0.enabled && $0.selectable } }
    var enabledIDs: Set<String> { Set(enabled.map(\.id)) }
    var installedIDs: Set<String> { Set(sources.map(\.id)) }
    var currentID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.string(source, kTISPropertyInputSourceID)
    }

    func start() {
        guard observers.isEmpty else { return }
        rule = store.load(default: TypingLanguageRule())
        refresh()
        observeSelection()
        observe(kTISNotifySelectedKeyboardInputSourceChanged) { [weak self] in self?.observeSelection() }
        observe(kTISNotifyEnabledKeyboardInputSourcesChanged) { [weak self] in self?.refresh() }
    }

    private func observe(_ name: CFString, _ action: @escaping @MainActor () -> Void) {
        let token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name as String), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in action() }
        }
        observers.append(token)
    }

    private func observeSelection() {
        let before = rule
        rule.observe(currentID, recipeActive: Shared.recipes.activeID != nil)
        if before != rule { store.save(rule) }
        if rule.manualOverride { note = nil; skippedNote = nil }
    }

    func refresh() {
        sources = Self.keyboardSources().map(\.info)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func enable(_ id: String) -> Bool {
        guard let source = Self.keyboardSources().first(where: { $0.info.id == id }),
              source.info.canEnable, TISEnableInputSource(source.ref) == noErr else { return false }
        refresh()
        return true
    }

    func apply(_ recipe: Recipe, automatic: Bool, hadActiveRecipe: Bool) {
        lastAppliedRecipeID = recipe.id
        note = nil
        skippedNote = nil
        let current = currentID
        let before = rule
        rule.observe(current, recipeActive: hadActiveRecipe)
        defer { if before != rule { store.save(rule) } }
        guard rule.permitsSwitch(automatic: automatic), let current, let wanted = recipe.inputSourceID, current != wanted else { return }
        guard let source = Self.keyboardSources().first(where: { $0.info.id == wanted }) else { return }
        guard source.info.enabled, source.info.selectable else {
            skippedNote = "\(source.info.name) is off. Typing language stayed the same."
            return
        }
        guard TISSelectInputSource(source.ref) == noErr, currentID == wanted else { return }
        rule.selectedByRecipe(wanted)
        note = "\(recipe.name) applied · typing in \(source.info.name)"
    }

    func undoTake(before: String, after: String) {
        guard currentID == after,
              let source = Self.keyboardSources().first(where: { $0.info.id == before && $0.info.enabled && $0.info.selectable }),
              TISSelectInputSource(source.ref) == noErr, currentID == before else { return }
        rule.selectedByRecipe(before)
        store.save(rule)
        note = nil
    }

    private static func keyboardSources() -> [(ref: TISInputSource, info: Source)] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource]
        let found = TISCreateInputSourceList(filter as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource] ?? []
        return found.compactMap { source in
            guard let id = string(source, kTISPropertyInputSourceID),
                  let name = string(source, kTISPropertyLocalizedName) else { return nil }
            let selectable = flag(source, kTISPropertyInputSourceIsSelectCapable)
            let canEnable = flag(source, kTISPropertyInputSourceIsEnableCapable)
            guard selectable || canEnable else { return nil }
            return (source, Source(id: id, name: name, enabled: flag(source, kTISPropertyInputSourceIsEnabled),
                                   canEnable: canEnable, selectable: selectable))
        }
    }

    private static func string(_ source: TISInputSource, _ property: CFString) -> String? {
        TISGetInputSourceProperty(source, property).map {
            Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
        }
    }

    private static func flag(_ source: TISInputSource, _ property: CFString) -> Bool {
        guard let value = TISGetInputSourceProperty(source, property) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }
}

struct RecipeTypingLanguageRow: View {
    @EnvironmentObject private var recipes: RecipeStore
    @ObservedObject private var language = Shared.typingLanguage
    let recipe: Recipe
    @State private var problem = false

    var body: some View {
        let source = language.sources.first { $0.id == recipe.inputSourceID }
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Typing language").font(Brand.subheadline.weight(.semibold))
                if let source, !source.enabled {
                    Text("\(source.name) is installed on this Mac but turned off.").foregroundStyle(StatusChip.Tone.warn.text)
                } else if let id = recipe.inputSourceID, source == nil {
                    Text("\(recipe.inputSourceName ?? id) is not on this Mac.").foregroundStyle(StatusChip.Tone.warn.text)
                } else {
                    Text("Switches when this recipe is applied.").foregroundStyle(.secondary)
                }
            }.font(Brand.caption)
            Spacer()
            if let source, !source.enabled, source.canEnable {
                Button("Turn it on") { problem = !language.enable(source.id) }.buttonStyle(.brandQuiet)
            }
            Picker("Typing language for \(recipe.name)", selection: Binding(get: { recipe.inputSourceID }, set: select)) {
                Text("Don’t change").tag(String?.none)
                if let id = recipe.inputSourceID, !language.enabledIDs.contains(id) {
                    Text(source?.name ?? recipe.inputSourceName ?? id).tag(Optional(id))
                }
                ForEach(language.enabled) { item in Text(item.name).tag(Optional(item.id)) }
            }
            .labelsHidden().fixedSize()
        }
        .alert("Could not turn on this input source", isPresented: $problem) {
            Button("OK", role: .cancel) {}
        }
    }

    private func select(_ id: String?) {
        recipes.setInputSource(recipe.id, sourceID: id, name: language.sources.first { $0.id == id }?.name)
    }
}
