import AppKit
import IOKit
import Combine
import WhopperKit

/// Holds this Mac's pass, checks it offline at launch, activates with a key, and renews quietly.
/// The rules live in WhopperKit/License.swift; this file is storage, network and timing.
@MainActor
final class LicenseController: ObservableObject {
    static let shared = LicenseController()

    struct Stored: Codable, Sendable {
        var pass: String?
        var lastRenewAttempt: Date?
        /// "Mac 2 of 3", as the server said at activation.
        var slot: Int?
        var of: Int?
    }

    @Published private(set) var state: LicenseState = .needsKey(message: nil)
    @Published private(set) var busy = false
    /// What to show under the key field after a failed try.
    @Published var notice: String?
    @Published private(set) var stored: Stored

    private let store = JSONStore<Stored>(name: "license")
    private var timer: Timer?
    private var trace: AnyCancellable?
    private var wake: NSObjectProtocol?

    let deviceId: String
    let server: URL
    private let publicKey: Data?
    /// Development only: runs without a pass (screenshots, demo data, trying features from a debug build).
    let skipped: Bool

    var isLicensed: Bool { skipped || state.isLicensed }

    private init() {
        stored = store.load(default: Stored())
        deviceId = DeviceID.derive(platformUUID: Self.platformUUID())
        var server = URL(string: "https://whoprrr.app")!
        var spki = LicenseKeys.productionSPKI
        var skip = false
        #if DEBUG
        // Debug builds can point at a local test server with its own signing key, or skip the check. Release builds cannot.
        let env = ProcessInfo.processInfo.environment
        if let s = env["WHOPRRR_SERVER"], let u = URL(string: s) { server = u }
        if let k = env["WHOPRRR_PASS_KEY"], !k.isEmpty { spki = k }
        skip = env["WHOPPER_LICENSE"] == "skip" || (env["WHOPPER_LICENSE"] == nil && (env["WHOPPER_DEMO"] == "1" || env["WHOPPER_NO_START"] == "1" || env["WHOPPER_RENDER_ICON"] != nil))
        #endif
        self.server = server
        publicKey = LicenseKeys.rawKey(fromSPKI: spki)
        skipped = skip
        state = evaluate()
    }

    /// Call once at launch: refresh an expired pass at once, and check for the weekly renewal now, daily, and after waking.
    func start() {
        guard !skipped else { return }
        #if DEBUG
        // Test aids for debug builds: WHOPRRR_LICENSE_TRACE=1 prints each state; WHOPRRR_TEST_KEY activates with that key at launch.
        let env = ProcessInfo.processInfo.environment
        if env["WHOPRRR_LICENSE_TRACE"] == "1" {
            trace = $state.combineLatest($notice).sink { st, n in
                let name: String
                switch st { case .licensed(let p): name = "licensed iat=\(p.iat) exp=\(p.exp)"; case .expiredOffline: name = "expiredOffline"; case .needsKey(let m): name = "needsKey [\(m ?? "")]" }
                FileHandle.standardError.write(Data("license: \(name) | notice: \(n ?? "")\n".utf8))
            }
        }
        if let k = env["WHOPRRR_TEST_KEY"] { Task { await renewIfDue(); await activate(key: k) }; return }
        #endif
        Task { await renewIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in Task { @MainActor in await self?.renewIfDue() } }
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.renewIfDue() }
        }
    }

    /// The stored pass against the six checks. Never touches the network.
    private func evaluate(now: Date = Date()) -> LicenseState {
        guard let pass = stored.pass, let publicKey else { return .needsKey(message: nil) }
        switch PassVerifier.check(pass, deviceId: deviceId, publicKeyRaw: publicKey, now: now) {
        case .valid(let p): return .licensed(p)
        case .expired(let p, renewable: true): return .expiredOffline(p)
        case .expired(_, renewable: false): return .needsKey(message: "This Mac’s activation ran out. Enter your key to activate it again.")
        case .notValid: return .needsKey(message: nil)
        }
    }

    private func save(_ change: (inout Stored) -> Void) { var s = stored; change(&s); stored = s; store.save(s) }

    // MARK: Activate

    func activate(key: String) async {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !busy else { return }
        busy = true; notice = nil
        defer { busy = false }
        let body: [String: Any] = ["key": typed, "deviceId": deviceId, "kind": "mac", "name": Host.current().localizedName ?? "Mac",
                                   "model": Self.sysctl("hw.model"), "appVersion": AppInfo.version]
        let (status, data) = await post("api/activate", body)
        switch LicenseReplies.activate(status: status, body: data) {
        case .activated(let pass, let slot, let of):
            // Trust nothing the check does not confirm: the pass must verify here before it counts.
            guard let publicKey, case .valid(let p) = PassVerifier.check(pass, deviceId: deviceId, publicKeyRaw: publicKey) else {
                notice = "The server answered, but its pass does not match this Mac. Try again, and write to hello@whoprrr.app if it keeps happening."
                return
            }
            save { $0.pass = pass; $0.slot = slot; $0.of = of; $0.lastRenewAttempt = nil }
            state = .licensed(p)
        case .refused(_, let message):
            notice = message
        case .tryLater:
            notice = status == nil ? "Could not reach whoprrr.app. Check your internet connection and try again."
                                   : "The server could not check the key just now. Nothing is lost; try again in a few minutes."
        }
    }

    // MARK: Renew

    /// Renews when the pass is over 7 days old (at most once a day), or at once when it has expired.
    func renewIfDue(force: Bool = false) async {
        guard !skipped, !busy, let pass = stored.pass else { return }
        let now = Date()
        switch evaluate(now: now) {
        case .licensed(let p):
            state = .licensed(p)
            guard force || PassVerifier.needsRenewal(p, now: now, lastAttempt: stored.lastRenewAttempt) else { return }
        case .expiredOffline(let p):
            state = .expiredOffline(p)
            // Expired: try on every check, but not more than once a minute.
            if !force, let last = stored.lastRenewAttempt, now.timeIntervalSince(last) < 60 { return }
        case .needsKey(let message):
            if stored.pass != nil { save { $0.pass = nil } }
            state = .needsKey(message: message)
            return
        }
        busy = true
        defer { busy = false }
        save { $0.lastRenewAttempt = now }
        let (status, data) = await post("api/pass/renew", ["pass": pass])
        switch LicenseReplies.renew(status: status, body: data) {
        case .renewed(let fresh):
            guard let publicKey, case .valid(let p) = PassVerifier.check(fresh, deviceId: deviceId, publicKeyRaw: publicKey) else { return }   // keep the old one
            save { $0.pass = fresh }
            state = .licensed(p); notice = nil
        case .revoked(let message):
            save { $0.pass = nil; $0.slot = nil; $0.of = nil }
            state = .needsKey(message: message)
        case .tryLater:
            break       // network trouble never costs anyone their pass
        }
    }

    // MARK: Plumbing

    /// (status, body). Status nil when no answer came back.
    private func post(_ path: String, _ body: [String: Any]) async -> (Int?, Data?) {
        var req = URLRequest(url: server.appendingPathComponent(path), timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return (nil, nil) }
        return (http.statusCode, data)
    }

    private static func platformUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if service != 0 { IOObjectRelease(service) } }
        if service != 0, let v = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String { return v }
        // No hardware id (should not happen on a Mac): fall back to an id kept in the data folder.
        let key = "gg.tico.whoprrr.fallbackDeviceID"
        if let s = UserDefaults.standard.string(forKey: key) { return s }
        let s = UUID().uuidString; UserDefaults.standard.set(s, forKey: key); return s
    }

    static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
