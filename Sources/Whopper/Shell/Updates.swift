import Foundation
import Sparkle

/// Automatic updates through Sparkle 2. The feed URL, public EdDSA key and schedule live in Info.plist
/// (written by scripts/build-app.sh). Sparkle only runs inside a packaged .app that carries those keys, so
/// `swift run`, tests and the screenshot/demo modes never contact the network.
/// Tells the shelf code that the daily update check ran, so what the shelf needs once a day (notices, the day-7 answer, kitchen
/// time for people who share) usually rides on that check. The shelf code keeps a timer of its own too, for people who switched
/// automatic update checks off; whichever comes first does the day's round.
final class DailyCheckHook: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Task { @MainActor in await PicklsssController.shared.runDailyIfDue(fromUpdateCheck: true) }
    }
    // What the last look at the update feed found, for the menu-bar panel's update line.
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in UpdateController.shared.found(.available(version)) }
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in UpdateController.shared.found(.upToDate) }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // "No update" also arrives as an abort; only a real failure (no network, a broken feed) is shown as one.
        let noUpdate = (error as NSError).domain == SUSparkleErrorDomain && (error as NSError).code == 1001
        Task { @MainActor in if !noUpdate { UpdateController.shared.found(.failed) } }
    }
}

/// What the panel's update line says.
enum UpdateStatus: Equatable {
    case unknown, checking, upToDate, available(String), failed
}

@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    private let hook = DailyCheckHook()
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: hook, userDriverDelegate: nil)
    @Published private(set) var canCheck = false
    @Published private(set) var isAvailable = false
    @Published private(set) var status: UpdateStatus = .unknown
    private var lastLook: Date?
    private var observation: NSKeyValueObservation?

    private var updater: SPUUpdater { controller.updater }

    /// Starts the updater unless this is a development/demo launch. Call once at launch.
    func start() {
        let info = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        guard Bundle.main.bundlePath.hasSuffix(".app"),
              info["SUFeedURL"] != nil, info["SUPublicEDKey"] != nil,
              env["WHOPPER_FORCE_UPDATER"] == "1" || (env["WHOPPER_NO_START"] != "1" && env["SDC_DEBUG_WINDOW"] != "1" && env["WHOPPER_RENDER_ICON"] == nil)
        else { return }
        controller.startUpdater()
        isAvailable = true
        canCheck = updater.canCheckForUpdates
        observation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] u, _ in
            let value = u.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// Looks at the update feed quietly (no window) so the panel can say "Up to date" or name the new version. Asked for each
    /// time the panel opens; it really looks at most once every 10 minutes, and at once when `force` is set (a click).
    func look(force: Bool = false) {
        guard isAvailable, status != .checking else { return }
        if !force, let lastLook, Date().timeIntervalSince(lastLook) < 600, status != .unknown, status != .failed { return }
        guard updater.canCheckForUpdates else { return }
        lastLook = Date()
        status = .checking
        updater.checkForUpdateInformation()
        // A look that never answers (no network at all) must not leave "Checking…" on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in if self?.status == .checking { self?.status = .failed } }
    }
    func found(_ s: UpdateStatus) { status = s }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); updater.automaticallyChecksForUpdates = newValue }
    }
}
