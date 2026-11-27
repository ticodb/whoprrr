import AppKit
import Combine
import WhopperKit

@MainActor
final class SetupController: ObservableObject {
    static let shared = SetupController()

    @Published private(set) var progress: SetupProgress { didSet { store.save(progress) } }
    @Published private(set) var states: [Permission: PermissionStatus] = [:]
    @Published private(set) var working = false
    @Published private(set) var trying: Feature?
    @Published private(set) var auditing = true
    @Published private(set) var renewalVisible = false
    @Published private(set) var attemptedGrant: Permission?
    @Published private(set) var note: String?
    @Published private(set) var checking = false
    @Published private(set) var tasteStarted = false

    private let store = JSONStore<SetupProgress>(name: "onboarding")
    private let checks = SetupChecks()
    private lazy var taste = TasteTest(checker: SetupPermissionChecker(), probe: checks, resetter: OwnPermissionResetter())
    private lazy var guide = GrantGuide(setup: self)
    private var inputRestartRequested = false
    private var waitingForSwitchOff: Permission?
    private var beganLicensedLaunch = false
    private var run: Task<Void, Never>?
    private static let legacyKey = "gg.tico.whoprrr.welcomed"

    init() {
        let env = ProcessInfo.processInfo.environment
        let debugApp = env["SDC_DEBUG_WINDOW"] == "1" && env["WHOPPER_PAGE"] != "setup"
        let legacy = env["WHOPPER_DATA_DIR"] == nil && UserDefaults.standard.bool(forKey: Self.legacyKey)
        progress = store.load(default: SetupProgress(step: debugApp || legacy ? .complete : .gear))
    }

    var step: SetupStep { LicenseController.shared.isLicensed ? progress.step : .key }
    var showsSetup: Bool { step != .complete || renewalVisible }
    var canAutoSwitch: Bool { progress.step == .complete && !auditing && progress.renewal.isEmpty }

    var plan: StarterPlan? { progress.scan.map { StarterRecipes.plan(for: $0, firstSetup: true) } }
    var proposed: [Feature: Set<Permission>] {
        let lines = plan?.lines.filter { progress.accepted.contains($0.id) } ?? []
        return requirements(for: Set(lines.map(\.feature)), eq: lines.contains { $0.action == .outputEQ }, mic: lines.contains { $0.feature == .microphone })
    }

    private func requirements(for features: Set<Feature>, eq: Bool, mic: Bool) -> [Feature: Set<Permission>] {
        var paste = false
        if #available(macOS 15.4, *) { paste = true }
        return Dictionary(uniqueKeysWithValues: features.map { ($0, TasteTest.requirements(for: $0, audioCapture: eq, mic: mic, clipboardPrivacy: paste)) })
    }

    func requirements(for features: Set<Feature>) -> [Feature: Set<Permission>] {
        requirements(for: features, eq: Shared.audio.settings.eq.enabled, mic: Shared.audio.settings.mic.enabled)
    }

    var activeTargets: Set<Feature> { progress.step == .complete ? progress.renewal : progress.selected }
    var grants: [Permission] {
        if progress.step == .complete {
            let needed = activeTargets.flatMap { progress.parked[$0]?.grants ?? [] }
            return ordered(Set(needed))
        }
        return ordered(Set(requirements(for: activeTargets).values.flatMap { $0 }))
    }

    func ordered(_ grants: Set<Permission>) -> [Permission] { Permission.setupOrder.filter(grants.contains) }

    func users(of grant: Permission) -> [Feature] {
        let affected = TasteTest.affected(by: grant, in: requirements(for: activeTargets))
        return Feature.allCases.filter(affected.contains)
    }

    var currentGrant: Permission? {
        progress.currentGrant(order: grants, requirements: requirements(for: activeTargets), targets: activeTargets, isGranted: isGranted)
    }

    func isStale(_ grant: Permission) -> Bool { progress.isStale(grant, targets: activeTargets) }

    func isGranted(_ grant: Permission) -> Bool {
        if grant == .inputMonitoring && inputRestartRequested { return false }
        return states[grant] == .granted || (states[grant] == .unknown && progress.grantedByTest.contains(grant))
    }

    var parkedFeatures: [Feature] {
        let enabled = Shared.features.enabled
        return Feature.allCases.filter { enabled.contains($0) && progress.parked[$0] != nil }
    }
    var parkedGrants: Set<Permission> { Set(parkedFeatures.flatMap { progress.parked[$0]?.grants ?? [] }) }
    var updateOK: Bool { progress.updateOKUntil.map { $0 > Date() } ?? false }
    var updateCheckIncomplete: Bool { progress.updateCheckIncomplete && progress.build == AppInfo.build }

    static func allowed(_ enabled: Set<Feature>, progress: SetupProgress) -> Set<Feature> { progress.allowed(enabled) }

    func beginLicensedLaunch() {
        guard !beganLicensedLaunch else { return }
        beganLicensedLaunch = true
        refreshGrants()
        if progress.step != .complete {
            // A recording from a prior process can't prove a fresh tap still has access.
            progress.grantedByTest = []
            reconcileSetupGrants()
            auditing = false
            return
        }
        let env = ProcessInfo.processInfo.environment
        guard env["WHOPPER_NO_START"] != "1", env["SDC_DEBUG_WINDOW"] != "1" else {
            auditing = false
            return
        }
        if progress.build != AppInfo.build && AppInfo.build != "0" {
            run = Task { await auditUpdate() }
        } else {
            auditing = false
            if !progress.renewal.isEmpty {
                if progress.grantedByTest.contains(.systemAudio) {
                    progress.grantedByTest.remove(.systemAudio)
                    progress.renewedGrants.remove(.systemAudio)
                    progress.findings[.audio] = nil
                }
                renewalVisible = progress.renewalStarted
            }
        }
    }

    func refreshGrants() {
        guard LicenseController.shared.isLicensed else { return }
        let previous = states
        let next = taste.readGrants()
        if previous != next { states = next }
        afterGrantRead()
    }

    /// Reads only the one grant the guide card is waiting for.
    private func refreshGrant(_ grant: Permission) {
        guard LicenseController.shared.isLicensed else { return }
        let next = taste.checker.status(grant)
        if states[grant] != next { states[grant] = next }
        afterGrantRead()
    }

    private func afterGrantRead() {
        if !inputRestartRequested, progress.askingAgain == .inputMonitoring, states[.inputMonitoring] == .granted, attemptedGrant == nil {
            progress.askingAgain = nil
            progress.renewedGrants.insert(.inputMonitoring)
        }
    }

    func reconcileSetupGrants() {
        guard progress.step == .taste || progress.step == .orderUp else { return }
        let needs = requirements(for: progress.selected)
        let affected = progress.selected.filter { feature in
            progress.parked[feature] == nil && (needs[feature] ?? []).contains { !isGranted($0) }
        }
        guard !affected.isEmpty else { return }
        for feature in affected { progress.findings[feature] = nil }
        progress.step = .permissions
    }

    func scanGear() async {
        guard LicenseController.shared.isLicensed, progress.step == .gear, !working else { return }
        working = true
        defer { working = false }
        await Shared.audio.readDevices()
        await Shared.model.registry.refreshNow()
        let scan = GearScanner.current()
        progress.scan = scan
        progress.accepted = Set((plan?.lines ?? []).filter(\.on).map(\.id))
    }

    func showRecipe() { progress.step = .recipe }

    func choose(_ id: String, on: Bool) {
        if on { progress.accepted.insert(id) } else { progress.accepted.remove(id) }
    }

    func applyRecipe() {
        guard progress.step == .recipe, let plan else { return }
        progress.selected = Set(proposed.keys)
        if progress.recipeName == nil {
            progress.recipeName = StarterRecipes.uniqueName(plan.name, existing: Shared.recipes.recipes.map(\.name))
        }
        if !Shared.recipes.recipes.contains(where: { $0.name == progress.recipeName }) {
            _ = Starter.apply(plan, accepted: progress.accepted, firstSetup: true, name: progress.recipeName)
        }
        progress.step = .permissions
        refreshGrants()
    }

    func setUpByHand() {
        Shared.features.setEnabled([])
        finishSetup(page: .features)
    }

    func finishSetup(page: AppPage = .recipes) {
        progress.step = .complete
        progress.build = AppInfo.build
        progress.grantedByTest = []
        Shared.nav.page = page
    }

    func openWindow(activate: Bool = true) {
        refreshGrants()
        Shared.showWindow(activate: activate)
    }

    /// When the after-update renewal window appeared. Renew counts only after it has been readable for a moment.
    private var renewalShownAt: Date?

    func windowClosed() {
        stopGuide()
        if !auditing { run?.cancel() }
    }

    /// Renew clears a grant whose previous feature test failed before asking macOS again.
    func beginCurrentGrant(_ grant: Permission) {
        if isStale(grant), canReset(grant) {
            retry(grant, reset: true)
        } else {
            startGrant(grant, requireToggle: isGranted(grant) && isStale(grant))
        }
    }

    private func startGrant(_ grant: Permission, requireToggle: Bool = false, track: Bool = true) {
        guard !working, LicenseController.shared.isLicensed,
              ProcessInfo.processInfo.environment["WHOPPER_NO_START"] != "1" else { return }
        note = requireToggle ? "Turn this switch off, then on again." : nil
        waitingForSwitchOff = requireToggle ? grant : nil
        attemptedGrant = grant
        if track { progress.askingAgain = grant }
        if track, grant == .inputMonitoring, requireToggle || states[grant] != .granted { inputRestartRequested = true }
        guide.show(grant)
        switch grant {
        case .systemAudio:
            checks.startChimeTest()
        case .microphone, .camera:
            if states[grant] == .notDetermined { PermissionRequester.request(grant) }
            else { openSettings(grant) }
        case .micDriver:
            if !Shared.audio.driverInstalled { Shared.audio.installDriver() }
            note = Shared.audio.installMessage
        case .inputMonitoring:
            PermissionRequester.request(grant)
            openSettings(grant)
        case .accessibility:
            if states[grant] != .granted { PermissionRequester.request(grant) }
            openSettings(grant)
        case .paste:
            // The System Settings row appears after the first programmatic read.
            if #available(macOS 15.4, *), NSPasteboard.general.accessBehavior == .default {
                // Give the explicit user action time to finish before a background-style read.
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard attemptedGrant == grant, !track || progress.askingAgain == grant else { return }
                    _ = NSPasteboard.general.string(forType: .string)
                    openSettings(grant)
                }
            } else { openSettings(grant) }
        }
    }

    func openSettings(_ grant: Permission) { NSWorkspace.shared.open(grant.settingsURL) }
    func playChime() { checks.playChime() }

    func pollGrant(_ grant: Permission) -> Bool {
        refreshGrant(grant)
        if waitingForSwitchOff == grant {
            guard states[grant] != .granted else { return false }
            waitingForSwitchOff = nil
        }
        if grant == .systemAudio && checks.heardChime {
            progress.grantedByTest.insert(grant)
            return true
        }
        return isGranted(grant)
    }

    func grantArrived(_ grant: Permission) {
        if grant == .systemAudio { checks.stopChimeTest() }
        if progress.askingAgain == grant { progress.askingAgain = nil }
        progress.renewedGrants.insert(grant)
        openWindow()
    }

    func stopGuide() {
        guide.stop()
        checks.stopChimeTest()
    }

    func skip(_ grant: Permission) {
        stopGuide()
        progress.skipped.insert(grant)
        if progress.askingAgain == grant { progress.askingAgain = nil }
        for feature in users(of: grant) {
            let needed = (progress.parked[feature]?.grants ?? []).union([grant])
            progress.parked[feature] = TasteFinding(.parked, grants: needed, detail: "Waiting for " + TasteTest.names(needed) + ". Your settings are kept.")
        }
    }

    func showTaste() {
        if progress.step != .complete { progress.step = .taste }
        runTaste()
    }

    func runTaste(force: Bool = false) {
        guard !checking, LicenseController.shared.isLicensed,
              ProcessInfo.processInfo.environment["WHOPPER_NO_START"] != "1" else { return }
        stopGuide()
        checking = true
        tasteStarted = true
        run = Task {
            let targets = activeTargets
            let needs = requirements(for: targets)
            for feature in Feature.allCases where targets.contains(feature) {
                if Task.isCancelled { break }
                if !force, progress.findings[feature]?.result == .works, progress.parked[feature] == nil { continue }
                trying = feature
                let result = await taste.tryFeature(feature, grants: needs[feature] ?? [], skipped: progress.skipped, mode: .setup)
                guard !Task.isCancelled else { break }
                progress.findings[feature] = result
                if result.result == .works { progress.parked[feature] = nil }
                else if result.result == .parked || progress.step == .complete { progress.parked[feature] = result }
            }
            trying = nil
            checking = false
        }
    }

    var canFinishTaste: Bool {
        !checking && activeTargets.allSatisfy { f in
            if progress.parked[f]?.result == .parked { return true }
            return progress.findings[f]?.result == .works
        }
    }

    func park(_ feature: Feature) {
        guard let finding = progress.findings[feature] else { return }
        progress.parked[feature] = TasteFinding(.parked, grants: finding.grants, detail: finding.detail + " Your settings are kept.")
    }

    func retry(_ grant: Permission, reset: Bool) {
        guard !working else { return }
        if reset, !progress.reserveReset(grant) { return }
        working = true
        for feature in users(of: grant) { progress.findings[feature] = nil }
        run = Task {
            if reset {
                if grant == .systemAudio { checks.stopChimeTest() }
                if grant == .microphone { Shared.audio.endMicTest() }
                await Shared.audio.stopForPermissionReset(grant)
            }
            let resetOK = !reset ? true : await taste.reset(grant)
            // Preserve the retry step before opening a pane that can relaunch the app.
            progress.grantedByTest.remove(grant)
            progress.skipped.remove(grant)
            progress.askingAgain = grant
            if grant == .inputMonitoring && reset { inputRestartRequested = true }
            if progress.step != .complete { progress.step = .permissions }
            working = false
            refreshGrants()
            guard !Task.isCancelled else { return }
            startGrant(grant, requireToggle: !resetOK && states[grant] == .granted)
            if reset, grant == .accessibility || grant == .inputMonitoring {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                note = resetOK
                    ? "The old grant was cleared. Add this copy of Whoprrr in System Settings and turn it on."
                    : "Remove the existing Whoprrr entry with −, then add this copy with + and turn it on."
            } else if !resetOK {
                note = "Whoprrr couldn’t clear this switch. Turn it off and on in System Settings."
            }
        }
    }

    /// A grant asked for from Permissions or a feature page. Only guides; it never parks or pauses anything,
    /// so backing out leaves every feature as it was.
    func guideGrant(_ grant: Permission) {
        startGrant(grant, track: false)
    }

    func continueParked(_ features: Set<Feature>? = nil) {
        guard !checking else { return }
        let targets = features ?? Set(parkedFeatures)
        if progress.renewal != targets {
            progress.renewal = targets
            progress.renewalStarted = false
            progress.skipped = []
            progress.renewedGrants = []
            progress.askingAgain = nil
        }
        tasteStarted = false
        renewalVisible = true
        openWindow()
    }

    /// The only way from the renewal window to System Settings, the guide card or a macOS prompt: a press on Renew.
    func renew() {
        guard RenewalStart.allowed(shownAt: renewalShownAt, now: Date(), windowIsKey: Shared.windowIsKey) else { return }
        renewalShownAt = nil
        tasteStarted = false
        progress.renewalStarted = true
        progress.skipped = []
        refreshGrants()
        if let grant = currentGrant { beginCurrentGrant(grant) }
        else { showTaste() }
    }

    func canReset(_ permission: Permission) -> Bool { permission.resetService != nil && progress.resetAttempts[permission, default: 0] < 2 }

    func leaveRenewal() {
        stopGuide()
        renewalVisible = false
        Shared.nav.page = .permissions
    }

    func finishTaste() {
        if progress.step == .complete {
            progress.renewal = []
            progress.renewalStarted = false
            progress.skipped = []
            progress.renewedGrants = []
            leaveRenewal()
        } else { progress.step = .orderUp }
    }

    private func auditUpdate() async {
        var features = Shared.features.enabled
        if !Shared.input.settings.enabled { features.remove(.remap) }
        if !Shared.clipboard.settings.enabled { features.remove(.clipboard) }
        if !Shared.audio.settings.mic.enabled { features.remove(.microphone) }
        let needs = requirements(for: features)
        let targets = Feature.allCases.filter { features.contains($0) && progress.parked[$0] == nil }
        // Features already run during the check; the deadline only bounds how long the result can take.
        let audit = await taste.auditAfterUpdate(targets, needs: needs, deadline: .seconds(6))
        progress = progress.applyingAudit(audit, build: AppInfo.build, now: Date())
        auditing = false
        if !audit.park.isEmpty {
            // Show the window with its Renew button, without focus. Nothing else starts until Renew is pressed.
            renewalShownAt = Date()
            renewalVisible = true
            openWindow(activate: false)
        }
    }
}
