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
    @Published private(set) var audioCheckRunning = false

    private let store = JSONStore<SetupProgress>(name: "onboarding")
    private let checks = SetupChecks()
    private lazy var taste = TasteTest(checker: SetupPermissionChecker(), probe: checks, resetter: OwnPermissionResetter())
    private lazy var guide = GrantGuide(setup: self)
    private var inputRestartRequested = false
    private var waitingForSwitchOff: Permission?
    private var audioCheckTimeout: Task<Void, Never>?
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
    var canAutoSwitch: Bool { progress.step == .complete && !auditing && progress.renewal.isEmpty && !hasPermissionAssistant }

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
        if var flow = progress.permissionFlow {
            flow.reopened()
            if let name = flow.returnPage, let page = AppPage(name: name) { Shared.nav.page = page }
            progress.permissionFlow = flow
            if !flow.suspended {
                auditing = false
                showPermissionAssistant()
                return
            }
        }
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

    var permissionFlow: PermissionFlow? { progress.permissionFlow }
    var hasPermissionAssistant: Bool { permissionFlow.map { !$0.suspended } ?? false }
    var needsPermissionRestart: Bool {
        permissionFlow?.permission == .inputMonitoring && inputRestartRequested && states[.inputMonitoring] == .granted
    }
    var nextAssistantGrant: Permission? {
        guard permissionFlow?.tracksSetup == true, permissionFlow?.stage == .ready else { return nil }
        return currentGrant
    }

    func beginCurrentGrant(_ grant: Permission) {
        presentPermission(grant, repair: isStale(grant) && canReset(grant), track: true)
    }

    private func presentPermission(_ grant: Permission, repair: Bool, track: Bool, replace: Bool = false) {
        guard !working, LicenseController.shared.isLicensed,
              ProcessInfo.processInfo.environment["WHOPPER_NO_START"] != "1" else { return }
        stopGuide()
        if !replace, var flow = progress.permissionFlow, flow.stage != .ready {
            flow.suspended = false
            progress.permissionFlow = flow
        } else {
            var flow = PermissionFlow(grant, repair: repair, tracksSetup: track)
            flow.returnPage = Shared.nav.page.storageName
            progress.permissionFlow = flow
            note = nil
        }
        showPermissionAssistant()
    }

    func showPermissionAssistant() { guide.show() }

    /// Continue is the single point that can clear a grant or launch system UI.
    func continuePermissionAssistant() {
        guard !working, var flow = permissionFlow, flow.begin() else { return }
        progress.permissionFlow = flow
        working = true
        let grant = flow.permission
        for feature in users(of: grant) { progress.findings[feature] = nil }
        run = Task {
            var resetOK = true
            if flow.repair {
                if progress.reserveReset(grant) {
                    await Shared.audio.stopForPermissionReset(grant)
                    resetOK = await taste.reset(grant)
                } else { resetOK = false }
                progress.grantedByTest.remove(grant)
            }
            guard !Task.isCancelled else { working = false; return }
            progress.skipped.remove(grant)
            if flow.tracksSetup { progress.askingAgain = grant }
            attemptedGrant = grant
            refreshGrants()
            waitingForSwitchOff = flow.repair && !resetOK && states[grant] == .granted ? grant : nil
            note = waitingForSwitchOff == nil ? nil : "Whoprrr couldn’t clear the old grant. Turn its switch off, then on again."
            if grant == .inputMonitoring { inputRestartRequested = flow.repair || states[grant] != .granted }
            flow.wait()
            progress.permissionFlow = flow
            working = false
            switch grant {
            case .accessibility, .inputMonitoring:
                // Opening the pane alone avoids a TCC alert and a Settings window competing for focus.
                // The guide offers the manual +/Add path if this copy isn't listed.
                openSettings(grant)
            case .systemAudio:
                if states[grant] == .denied { openSettings(grant) }
                else { checks.prepareAudioPermission() }
            case .microphone, .camera:
                if states[grant] == .notDetermined { PermissionRequester.request(grant) }
                else { openSettings(grant) }
            case .micDriver:
                if !Shared.audio.driverInstalled { Shared.audio.installDriver() }
                note = Shared.audio.installMessage
            case .paste:
                if #available(macOS 15.4, *), NSPasteboard.general.accessBehavior == .default {
                    // Only the read that creates the native consent prompt. Settings is a separate user action.
                    _ = NSPasteboard.general.string(forType: .string)
                } else { openSettings(grant) }
            }
        }
    }

    func openSettings(_ grant: Permission) {
        NSWorkspace.shared.open(grant.settingsURL)
        guide.placeBesideSettingsOnce()
    }

    func runAssistantAudioCheck() {
        guard let flow = permissionFlow, flow.permission == .systemAudio,
              flow.stage == .waiting || flow.stage == .checkAudio else { return }
        if audioCheckRunning { checks.playChime(); return }
        audioCheckRunning = true
        note = nil
        checks.startChimeTest()
        audioCheckTimeout?.cancel()
        audioCheckTimeout = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, audioCheckRunning else { return }
            audioCheckRunning = false
            checks.stopChimeTest()
            note = "The chime didn’t get through. Check your current output and the permission switch, then try again."
        }
    }

    func playChime() { runAssistantAudioCheck() }

    func pollPermissionAssistant() {
        guard var flow = permissionFlow, !flow.suspended,
              flow.stage == .waiting || flow.stage == .checkAudio else { return }
        let grant = flow.permission
        refreshGrant(grant)
        if grant == .systemAudio {
            if audioCheckRunning, checks.heardChime {
                checks.rememberAudioProof()
                progress.grantedByTest.insert(grant)
            } else {
                if states[grant] == .granted { flow.needsAudioCheck(); progress.permissionFlow = flow }
                return
            }
        } else {
            if waitingForSwitchOff == grant {
                guard states[grant] != .granted else { return }
                waitingForSwitchOff = nil
            }
            guard isGranted(grant) else { return }
        }
        if progress.askingAgain == grant { progress.askingAgain = nil }
        progress.renewedGrants.insert(grant)
        flow.finish()
        progress.permissionFlow = flow
        audioCheckTimeout?.cancel(); audioCheckTimeout = nil
        audioCheckRunning = false
        checks.stopChimeTest()
        // Success updates this guide in place. Only Done/Continue can bring the app back.
    }

    func finishPermissionAssistant() {
        guard permissionFlow?.stage == .ready else { return }
        let next = nextAssistantGrant
        progress.permissionFlow = nil
        stopGuide()
        if let next { beginCurrentGrant(next) }
        else { Shared.endPermissionGuide(returnToApp: true) }
    }

    func suspendPermissionAssistant(returnToApp: Bool = true) {
        guard !working else { return }
        progress.permissionFlow?.suspended = true
        stopGuide()
        Shared.endPermissionGuide(returnToApp: returnToApp)
    }

    func restartForPermission() {
        guard needsPermissionRestart, !working else { return }
        Shared.saveBar.noteLeaving()
        // Ask Launch Services to reopen this same bundle after the process exits. The app
        // path is a positional argument, never shell source; no permission request is replayed.
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "whoprrr-reopen", Bundle.main.bundleURL.path]
        do { try reopen.run(); NSApp.terminate(nil) }
        catch { note = "Quit and reopen Whoprrr to finish applying this permission." }
    }

    func stopGuide() {
        guide.stop()
        audioCheckTimeout?.cancel(); audioCheckTimeout = nil
        audioCheckRunning = false
        checks.stopChimeTest()
    }

    func skip(_ grant: Permission) {
        progress.permissionFlow = nil
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
        prepareParkedTargets(for: grant)
        presentPermission(grant, repair: reset, track: true, replace: true)
    }

    /// Entry from a feature or Permissions page. It opens the same explanation first.
    func guideGrant(_ grant: Permission) {
        let parked = prepareParkedTargets(for: grant)
        presentPermission(grant, repair: false, track: parked)
    }

    @discardableResult private func prepareParkedTargets(for grant: Permission) -> Bool {
        guard progress.step == .complete else { return false }
        let targets = Set(parkedFeatures.filter { progress.parked[$0]?.grants.contains(grant) == true })
        guard !targets.isEmpty else { return false }
        progress.renewal.formUnion(targets)
        progress.renewalStarted = true
        renewalVisible = true
        tasteStarted = false
        return true
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
