import Foundation

// Buying an extra from the app. The "Get Picklsss" button trades the Mac's pass for a one-time link (10 minutes, one payment)
// to a small page on whoprrr.app, and opens it in the browser. Contract: `POST /api/pass/link` in docs/licensing.md of the site
// repository. Buying never depends on this call: when it cannot be made, the app falls back to the "find your order by email" page.

public enum PurchaseLinkOutcome: Equatable, Sendable {
    /// Open this in the default browser.
    case ready(URL)
    /// The server will not trust this pass any more (removed device, key switched off, not a pass it signed). Treated exactly like a refused renewal.
    case revoked(message: String)
    /// 401 pass_expired: renew the pass, then ask again once.
    case passExpired
    /// 429: asked too often. `message` is the server's own words.
    case busy(message: String)
    /// No answer, a timeout, a 404 (a server that does not know the call yet), a 5xx, or an answer that is not a usable link.
    case unavailable
}

public enum PurchaseWords {
    /// Shown inline when no link could be made, with the "find my order by email" button beside it.
    public static let couldNotReach = "Could not reach whoprrr.app. Check your connection and try again."
    public static let findByEmail = "Find my order by email instead"
    /// Shown when the person came back from paying and the pass does not have the extra yet.
    public static let notYet = "Not on your key yet. If you just paid, give it a moment."
}

public extension LicenseReplies {
    /// The answer to `POST /api/pass/link`. `server` is the site the app talks to: a link to anywhere else is never opened.
    static func link(status: Int?, body: Data?, server: URL) -> PurchaseLinkOutcome {
        guard let status else { return .unavailable }
        let b = parse(body)
        if status == 200, let text = b?.url, let url = URL(string: text), isOurs(url, server: server) { return .ready(url) }
        if (status == 403 && b?.error == "revoked") || (status == 400 && b?.error == "invalid_pass") {
            return .revoked(message: (b?.message).flatMap { $0.isEmpty ? nil : $0 } ?? "This Mac is no longer activated on that key. Enter your key to activate it again.")
        }
        if status == 401 && b?.error == "pass_expired" { return .passExpired }
        if status == 429 && b?.error == "rate_limited" { return .busy(message: (b?.message).flatMap { $0.isEmpty ? nil : $0 } ?? "Too many tries. Wait a few minutes and try again.") }
        return .unavailable
    }

    /// A purchase link is an https page of the same site (plain http only for a local test server), under /add/.
    static func isOurs(_ url: URL, server: URL) -> Bool {
        guard let host = url.host, host == server.host, url.path.hasPrefix("/add/"), url.path.count > 6 else { return false }
        return url.scheme == "https" || (url.scheme == "http" && server.scheme == "http")
    }
}

/// Asks the server for the link. The transport is the shelf's (a protocol, so tests use a fake and no network).
public struct PurchaseLinkClient: Sendable {
    let transport: ShelfTransport
    let server: URL
    public init(transport: ShelfTransport, server: URL) { self.transport = transport; self.server = server }

    public func request(pass: String) async -> PurchaseLinkOutcome {
        let body = try? JSONSerialization.data(withJSONObject: ["pass": pass])
        do {
            let r = try await transport.send(ShelfRequest(method: "POST", path: "api/pass/link", body: body))
            return LicenseReplies.link(status: r.status, body: r.data, server: server)
        } catch {
            return .unavailable
        }
    }
}

/// When the app may ask for a fresh pass because the Picklsss or Extras page is open and the pass lacks the extra: at most once every
/// 10 minutes, remembered in memory only (a relaunch starts again), and never when the extra is already there.
public struct PassRefreshGate: Sendable {
    public static let interval: TimeInterval = 10 * 60
    private var last: Date?
    public init() {}

    /// True when a refresh may start now; it then counts as started.
    public mutating func allow(now: Date, hasExtra: Bool) -> Bool {
        guard !hasExtra else { return false }
        if let last, now.timeIntervalSince(last) < Self.interval { return false }
        last = now
        return true
    }
}
