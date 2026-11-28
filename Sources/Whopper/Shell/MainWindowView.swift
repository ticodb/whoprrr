import SwiftUI
import AppKit
import WhopperKit

/// The app proper: a sidebar of features and a roomy page for each. Setup, rule editing and every setting live here;
/// the menu-bar panel (QuickView) is only for glancing and quick actions.
struct MainWindowView: View {
    var inDrawer = false

    private var presentsSheets: Bool {
        inDrawer ? nav.drawerOpen : nav.windowOpen && !nav.drawerOpen
    }
    @EnvironmentObject var features: FeatureStore
    @EnvironmentObject var input: InputController
    @EnvironmentObject var nav: WindowNav
    @EnvironmentObject var recipes: RecipeStore
    @EnvironmentObject private var saveBar: SaveBarController
    @ObservedObject private var setup = SetupController.shared
    @EnvironmentObject private var presetActions: PresetActions
    @ObservedObject private var license = LicenseController.shared
    @ObservedObject private var backups = Shared.backups
    @ObservedObject private var picklsss = PicklsssController.shared

    var body: some View {
        if license.isLicensed && !setup.showsSetup { app } else { SetupView() }
    }

    private var app: some View {
        HStack(spacing: 0) {
            if !inDrawer {
                sidebar.frame(width: 232)
                Divider()
            }
            VStack(spacing: 0) {
                if !saveBar.changedSections.isEmpty || saveBar.confirmation != nil {
                    SaveBarArea()
                        .padding(.horizontal, 28)
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.top, 14)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HandoverNotice()
                        NoticesBar()
                        if case .feature(let feature) = nav.page, let finding = setup.progress.parked[feature] {
                            BrandCard {
                                Text(finding.detail).font(Brand.body)
                                Button(setup.ordered(finding.grants).first.map { "Grant \($0.title)" } ?? "Continue setup") {
                                    setup.continueParked([feature])
                                }.buttonStyle(.brand)
                            }
                            PageContent(page: nav.page).disabled(true)
                        } else { PageContent(page: nav.page) }
                    }
                    .padding(28)
                    .frame(maxWidth: 680, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .overlay(alignment: .top) {
                    if let milestone = picklsss.milestone {
                        PicklsssMilestoneView(milestone: milestone)
                            .id(milestone.id)
                            .padding(.top, 76)
                    }
                }
            }
        }
        .frame(minWidth: inDrawer ? nil : 860, minHeight: inDrawer ? nil : 620)
        .tint(Brand.violetBright)
        .sheet(item: Binding(get: { presentsSheets ? recipes.pendingSwitch : nil },
                             set: { if presentsSheets, $0 == nil, recipes.pendingSwitch != nil { recipes.resolveSwitch(.stay) } })) { AutoSwitchSheet(pending: $0) }
        .sheet(item: Binding(get: { presentsSheets ? picklsss.sharing : nil },
                             set: { if presentsSheets { picklsss.sharing = $0 } })) { ShareFlowView(s: $0) }
        .sheet(item: Binding(get: { presentsSheets ? backups.review : nil },
                             set: { if presentsSheets { backups.review = $0 } })) { BackupReviewSheet(controller: backups, item: $0) }
        .alert(backups.problemTitle,
               isPresented: Binding(get: { presentsSheets && backups.problem != nil }, set: { if presentsSheets, !$0 { backups.problem = nil } })) {
            if backups.problem == .newer {
                Button("Check for Updates") { UpdateController.shared.checkForUpdates() }
                    .disabled(!UpdateController.shared.canCheck)
                Button("Cancel", role: .cancel) {}
            } else if backups.problem == .picklsssNeeded {
                Button("Get Picklsss") { backups.getPicklsss() }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            if case .message(let text) = backups.problem { Text(text) }
            if backups.problem == .picklsssNeeded { Text("Taking a setup from a backup made with another key needs Picklsss.") }
        }
        .alert("Presets", isPresented: Binding(get: { presentsSheets && presetActions.problem != nil },
                                              set: { if presentsSheets, !$0 { presetActions.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presetActions.problem ?? "")
        }
        .alert("Could not finish", isPresented: Binding(get: { presentsSheets && saveBar.problem != nil },
                                                      set: { if presentsSheets, !$0 { saveBar.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveBar.problem ?? "")
        }
        .onChange(of: features.enabled) { _, _ in
            if case .feature(let f) = nav.page, !features.isEnabled(f) { nav.page = .features }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                LogoMark(size: 40).shadow(color: Brand.violetDeep.opacity(0.35), radius: 4, y: 2)
                Wordmark(size: 24)
                if AppInfo.isBeta { Text("BETA").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(0.8).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Brand.violet.opacity(0.2), in: Capsule()).foregroundStyle(Brand.accentText) }
            }
            .padding(.bottom, 14)
            row(.recipes, symbol: "fork.knife", title: "Recipes")
            row(.picklsss, symbol: "books.vertical", title: "Picklsss", caption: "shared setups").padding(.bottom, 8)
            SectionLabel("Features").padding(.leading, 10).padding(.bottom, 2)
            ForEach(features.enabledInOrder) { f in row(.feature(f), symbol: f.symbol, title: f.shortTitle) }
            Spacer(minLength: 12)
            SectionLabel("Whoprrr").padding(.leading, 10).padding(.bottom, 2)
            row(.extras, symbol: "plus.rectangle.on.rectangle", title: "Extras")
            row(.features, symbol: "square.grid.2x2", title: "Features")
            row(.permissions, symbol: "lock.shield", title: "Permissions")
            row(.about, symbol: "info.circle", title: "About")
            HStack { overallStatus; Spacer() }.padding(.top, 10).padding(.horizontal, 6)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035))
    }

    @ViewBuilder private var overallStatus: some View {
        switch input.status {
        case .needsAccessibility, .needsInputMonitoring: StatusChip(text: "Needs permission", tone: .warn)
        case .paused: StatusChip(text: "Remap paused", tone: .warn)
        case .failed: StatusChip(text: "Remap failed", tone: .bad)
        default: StatusChip(text: "\(features.enabledInOrder.count) features on", tone: .good)
        }
    }

    private func row(_ p: AppPage, symbol: String, title: String, caption: String? = nil) -> some View {
        let on = nav.page == p
        return Button { nav.page = p } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 24)
                // A menu name never stands without its plain meaning beside it.
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 15, weight: on ? .semibold : .regular, design: .rounded)).lineLimit(1)
                    if let caption { Text(caption).font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundStyle(on ? Brand.accentText : Color.primary)
            .background(on ? AnyShapeStyle(Brand.violet.opacity(0.16)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
