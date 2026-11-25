import Foundation
import Sparkle

/// Automatic updates through Sparkle 2. The feed URL, public EdDSA key and schedule live in Info.plist
/// (written by scripts/build-app.sh). Sparkle only runs inside a packaged .app that carries those keys, so
/// `swift run`, tests and the screenshot/demo modes never contact the network.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    @Published private(set) var canCheck = false
    @Published private(set) var isAvailable = false
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

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); updater.automaticallyChecksForUpdates = newValue }
    }
}
