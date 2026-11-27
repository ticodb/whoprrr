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

    // What the last check found, for the version line in the menu-bar panel and the About page.
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in UpdateController.shared.found(version) }
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in UpdateController.shared.found(nil) }
    }
}

@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    private let hook = DailyCheckHook()
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: hook, userDriverDelegate: nil)
    @Published private(set) var canCheck = false
    @Published private(set) var isAvailable = false
    /// The newer version the last check found ("0.9.0 beta 7"), or nil when this build is the latest we know of.
    @Published private(set) var newerVersion: String?
    private var lastLook = Date.distantPast
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.lookQuietly() }
    }

    fileprivate func found(_ version: String?) { newerVersion = version }

    /// Asks the feed whether a newer version exists without showing anything, at most once an hour, and only while
    /// automatic checks are on. The answer arrives through the delegate.
    func lookQuietly() {
        guard isAvailable, updater.automaticallyChecksForUpdates, updater.canCheckForUpdates,
              Date().timeIntervalSince(lastLook) > 3600 else { return }
        lastLook = Date()
        updater.checkForUpdateInformation()
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); updater.automaticallyChecksForUpdates = newValue }
    }
}
