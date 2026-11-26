import SwiftUI
import WhopperKit

private let recipeIcons = ["house", "briefcase", "airplane", "laptopcomputer", "headphones", "music.mic", "cup.and.saucer", "building.2", "car", "gamecontroller", "tv", "fork.knife"]

/// All recipes: one click to put the whole Mac into the setup for the gear you have with you.
struct RecipesView: View {
    @EnvironmentObject var recipes: RecipeStore
    @EnvironmentObject var nav: WindowNav
    @State private var connected: [DeviceSignature] = []
    @State private var creating = false
    @State private var renaming: Recipe?
    @State private var deleting: Recipe?
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader("Recipes", symbol: "fork.knife", subtitle: "Switch your whole setup in one click") {
                Button("Scan my gear") { nav.page = .welcome }.buttonStyle(.brandQuiet)
                Button("New recipe") { creating = true }.buttonStyle(.brand)
            }
            if let n = recipes.notice {
                HStack(spacing: 8) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text(n).font(Brand.subheadline); Spacer()
                    Button { recipes.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    .padding(10).background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            gearCard
            if recipes.recipes.isEmpty { emptyState }
            ForEach(recipes.ranked(connected: connected)) { r in card(r) }
            Text("A recipe remembers your settings for one set of gear: audio and effects, windows, clipboard, keys and mouse, installed features and a display preset. Applying it changes all of them at once. Turn on “Switch automatically” and Whoprrr applies it when exactly that gear is connected.")
                .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { connected = Gear.current(); if nav.newRecipeRequested { nav.newRecipeRequested = false; creating = true } }
        .onReceive(timer) { _ in connected = Gear.current() }
        .sheet(isPresented: $creating) { NewRecipeSheet(connected: connected) }
        .sheet(item: $renaming) { r in RenameRecipeSheet(recipe: r) }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { r in
            Button("Delete recipe", role: .destructive) { recipes.delete(r.id) }
        } message: { _ in Text("Your current settings are not changed.") }
    }

    private var gearCard: some View {
        BrandCard {
            SectionLabel("Connected now")
            if connected.isEmpty { Text("No external gear found. Built-in speakers, mic and display are not counted.").font(Brand.caption).foregroundStyle(.secondary) }
            FlowChips(items: connected.map { ($0.symbol, $0.name, true) })
        }
    }

    private var emptyState: some View {
        BrandCard {
            Text("No recipes yet").font(Brand.display(15, .semibold))
            Text("Set things up the way you like them for the gear on your desk, then press “New recipe” to save it. Make another when you travel and switch between them here, or from the menu-bar panel.")
                .font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Save this setup as a recipe") { creating = true }.buttonStyle(.brand)
        }
    }

    private func card(_ r: Recipe) -> some View {
        let g = r.gear(connected: connected)
        let isActive = recipes.activeID == r.id
        let modified = recipes.isModified(r.id)
        return BrandCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: r.symbol).font(.system(size: 17, weight: .medium)).frame(width: 40, height: 40)
                    .foregroundStyle(isActive ? Color.white : Brand.accentText)
                    .background(isActive ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Brand.violet.opacity(0.14)), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(r.name).font(Brand.display(17, .semibold))
                        if isActive { StatusChip(text: "Active", tone: .good) }
                    }
                    Text(summary(r)).font(Brand.caption).foregroundStyle(.secondary)
                    if r.devices.isEmpty { Text("Not tied to any gear").font(Brand.caption).foregroundStyle(.secondary) }
                    FlowChips(items: r.devices.map { d in (d.symbol, d.name, g.present.contains(d)) })
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 6) {
                        Button(isActive && !modified ? "Applied" : isActive ? "Reapply" : "Apply") { recipes.apply(r.id) }
                            .buttonStyle(.brand).disabled(isActive && !modified)
                        Menu {
                            if let prev = r.previous {
                                Button(RecipeWording.goBackTitle(prev, now: Date())) { goBack(r) }
                            } else {
                                Button("Go back to the version before the last save") {}.disabled(true)
                            }
                            Button("Update gear to what is connected") { recipes.setDevices(r.id, connected) }
                            Button("Rename or change icon…") { renaming = r }
                            Divider()
                            Button("Delete…", role: .destructive) { deleting = r }
                        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)) }.menuStyle(.borderlessButton).fixedSize()
                    }
                    Toggle("Switch automatically", isOn: Binding(get: { r.autoApply }, set: { recipes.setAutoApply(r.id, $0) }))
                        .toggleStyle(.switch).controlSize(.small).font(Brand.caption).disabled(r.devices.isEmpty)
                        .help(r.devices.isEmpty ? "Tie the recipe to gear first" : "Apply when all of this gear is connected")
                }
            }
            if !g.missing.isEmpty && !r.devices.isEmpty {
                Text(g.present.isEmpty ? "None of this gear is connected." : "\(g.missing.count) of \(r.devices.count) not connected.")
                    .font(Brand.caption).foregroundStyle(.orange)
            }
        }
    }

    private func goBack(_ r: Recipe) {
        if let failed = recipes.goBack(r.id), !failed.isEmpty { recipes.notice = "Went back, except \(failed.joined(separator: ", "))" }
    }

    private func summary(_ r: Recipe) -> String {
        let names = recipes.surfaceList.filter { r.sections[$0.key] != nil }.map(\.title)
        return names.isEmpty ? "Empty" : names.joined(separator: " · ")
    }
}

/// Chips that wrap onto several lines: (symbol, text, highlighted).
struct FlowChips: View {
    var items: [(String, String, Bool)]
    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 5) {
                    Image(systemName: it.2 ? it.0 : "circle.dashed").font(.system(size: 12))
                    Text(it.1).font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(1)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(it.2 ? Brand.violet.opacity(0.15) : Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(it.2 ? Brand.accentText : Color.secondary)
            }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxW = max(maxW, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

struct NewRecipeSheet: View {
    @EnvironmentObject var recipes: RecipeStore
    @Environment(\.dismiss) private var dismiss
    var connected: [DeviceSignature]
    @State private var name = ""
    @State private var symbol = "house"
    @State private var includes: Set<String> = []
    @State private var gear: Set<String> = []
    @State private var auto = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New recipe").font(Brand.display(20, .semibold))
            TextField("Name, e.g. Home desk or On the road", text: $name).textFieldStyle(.roundedBorder).font(Brand.body)
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Icon")
                HStack(spacing: 6) {
                    ForEach(recipeIcons, id: \.self) { s in
                        Button { symbol = s } label: {
                            Image(systemName: s).font(.system(size: 15)).frame(width: 34, height: 34)
                                .background(symbol == s ? AnyShapeStyle(Brand.violet) : AnyShapeStyle(Color.primary.opacity(0.07)), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .foregroundStyle(symbol == s ? Color.white : Color.primary)
                        }.buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("What to save")
                ForEach(recipes.surfaceList, id: \.key) { s in
                    Toggle(s.title, isOn: Binding(get: { includes.contains(s.key) }, set: { if $0 { includes.insert(s.key) } else { includes.remove(s.key) } })).font(Brand.body)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Gear this recipe is for")
                if connected.isEmpty { Text("Nothing external is connected, so this recipe will not be tied to gear. You can add it later with “Update gear”.").font(Brand.caption).foregroundStyle(.secondary) }
                ForEach(connected) { d in
                    Toggle(isOn: Binding(get: { gear.contains(d.id) }, set: { if $0 { gear.insert(d.id) } else { gear.remove(d.id) } })) {
                        Label(d.name, systemImage: d.symbol).font(Brand.body)
                    }
                }
                Toggle("Switch to it automatically when all of this gear is connected", isOn: $auto).font(Brand.caption).disabled(gear.isEmpty)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.brandQuiet)
                Button("Save recipe") {
                    recipes.create(name: name.trimmingCharacters(in: .whitespaces), symbol: symbol, includes: includes,
                                   devices: connected.filter { gear.contains($0.id) }, autoApply: auto && !gear.isEmpty)
                    dismiss()
                }.buttonStyle(.brand).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || includes.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520)
        .onAppear {
            includes = Set(recipes.surfaceList.map(\.key)).subtracting(["display"])
            if recipes.surfaceList.contains(where: { $0.key == "display" }), Shared.model.lastPresetName != nil { includes.insert("display") }
            gear = Set(connected.map(\.id))
        }
    }
}

struct RenameRecipeSheet: View {
    @EnvironmentObject var recipes: RecipeStore
    @Environment(\.dismiss) private var dismiss
    let recipe: Recipe
    @State private var name = ""
    @State private var symbol = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename recipe").font(Brand.display(20, .semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).font(Brand.body)
            HStack(spacing: 6) {
                ForEach(recipeIcons, id: \.self) { s in
                    Button { symbol = s } label: {
                        Image(systemName: s).font(.system(size: 15)).frame(width: 34, height: 34)
                            .background(symbol == s ? AnyShapeStyle(Brand.violet) : AnyShapeStyle(Color.primary.opacity(0.07)), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .foregroundStyle(symbol == s ? Color.white : Color.primary)
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.brandQuiet)
                Button("Save") { recipes.rename(recipe.id, to: name.trimmingCharacters(in: .whitespaces), symbol: symbol); dismiss() }
                    .buttonStyle(.brand).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 500)
        .onAppear { name = recipe.name; symbol = recipe.symbol }
    }
}
