import SwiftUI
import WindowCore
import WhopperKit

struct WindowPanel: View {
    @EnvironmentObject var m: WindowModel
    @State private var expanded: Set<String> = ["Halves"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader("Windows", symbol: "rectangle.split.2x2", subtitle: "Snap, move, resize") { PresetMenu(surface: PresetSurfaces.windows(m)) }
            if !m.trusted { accessBanner }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Keyboard shortcuts", isOn: bind(\.shortcutsEnabled))
                Toggle("Snap by dragging to screen edges", isOn: bind(\.snapByDrag))
                Toggle("Repeat left/right half to cycle ½ → ⅔ → ⅓", isOn: bind(\.cycleHalves))
                HStack {
                    Text("Gap").frame(width: 40, alignment: .leading)
                    Slider(value: bind(\.gap), in: 0...30, step: 1)
                    Text("\(Int(m.settings.gap)) pt").font(Brand.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                }
            }
            Divider()
            Text("Star the layouts you use most to put them in the menu-bar drawer (up to \(WindowSettings.drawerLimit)).")
                .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(groups, id: \.self) { g in group(g) }
            Text("Defaults match Rectangle. Quit Rectangle first; two apps cannot own the same shortcut.")
                .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { m.refreshTrust() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in m.refreshTrust() }
    }

    private var groups: [String] {
        var seen: [String] = []
        for a in WindowAction.allCases where !seen.contains(a.group) { seen.append(a.group) }
        return seen
    }

    private func bind<T>(_ kp: WritableKeyPath<WindowSettings, T>) -> Binding<T> {
        Binding(get: { m.settings[keyPath: kp] }, set: { m.settings[keyPath: kp] = $0 })
    }

    private var accessBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Whoprrr needs Accessibility to move windows.").font(Brand.caption)
                HStack {
                    Button("Grant") { PermissionRequester.request(.accessibility); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { m.refreshTrust() } }
                        .controlSize(.regular)
                    Button("Open pane") { NSWorkspace.shared.open(Permission.accessibility.settingsURL) }.buttonStyle(.link).font(Brand.caption)
                }
            }
        }
        .padding(8).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func group(_ g: String) -> some View {
        let actions = WindowAction.allCases.filter { $0.group == g }
        return DisclosureGroup(isExpanded: Binding(get: { expanded.contains(g) }, set: { if $0 { expanded.insert(g) } else { expanded.remove(g) } })) {
            VStack(spacing: 4) { ForEach(actions) { row($0) } }.padding(.top, 4)
        } label: { Text(g).font(Brand.subheadline.weight(.medium)) }
    }

    private func row(_ a: WindowAction) -> some View {
        HStack(spacing: 6) {
            let on = m.inDrawer(a)
            Button { m.setInDrawer(a, !on) } label: { Image(systemName: on ? "star.fill" : "star").foregroundStyle(on ? Brand.accentText : Color.secondary) }
                .buttonStyle(.plain).disabled(!on && m.drawerFull).hoverTip(on ? "Remove from the menu-bar drawer" : "Show in the menu-bar drawer")
            Button { m.run(a) } label: { Text(a.title).frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain).help("Run on the front window")
            status(a)
            ShortcutRecorder(shortcut: m.shortcut(a)) { m.setShortcut(a, $0) }.frame(width: 104, height: 22)
            Button { m.reset(a) } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.plain).opacity(m.isCustomised(a) ? 1 : 0.2).disabled(!m.isCustomised(a)).help("Reset to default")
        }
        .font(Brand.callout)
    }

    @ViewBuilder private func status(_ a: WindowAction) -> some View {
        if m.conflicts.contains(a) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Same shortcut as another action")
        } else if m.registrations[a] == .inUse {
            Image(systemName: "lock.fill").foregroundStyle(.orange).help("Another app (Rectangle?) already owns this shortcut")
        }
    }
}
