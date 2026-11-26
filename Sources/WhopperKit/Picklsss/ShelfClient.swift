import Foundation

// The client for the shelf of shared setups. The transport is a protocol so tests inject a fake and never touch a network;
// every error code the server can answer is a case of ShelfFailure, with the server's own words kept for display.

public struct ShelfRequest: Equatable, Sendable {
    public var method: String
    /// "api/shelf/take": relative to the server's address.
    public var path: String
    public var query: [URLQueryItem]
    public var body: Data?
    public init(method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil) {
        self.method = method; self.path = path; self.query = query; self.body = body
    }
}

public struct ShelfResponse: Equatable, Sendable {
    public var status: Int
    public var data: Data
    public init(status: Int, data: Data = Data()) { self.status = status; self.data = data }
}

/// Sends one request. Throws when no answer came back at all (offline, timeout).
public protocol ShelfTransport: Sendable {
    func send(_ request: ShelfRequest) async throws -> ShelfResponse
}

/// The real transport: URLSession against the server address the licence code uses.
public struct URLSessionShelfTransport: ShelfTransport {
    public var server: URL
    public var timeout: TimeInterval
    public init(server: URL, timeout: TimeInterval = 10) { self.server = server; self.timeout = timeout }

    public func send(_ r: ShelfRequest) async throws -> ShelfResponse {
        var comps = URLComponents(url: server.appendingPathComponent(r.path), resolvingAgainstBaseURL: false)!
        if !r.query.isEmpty { comps.queryItems = r.query }
        var req = URLRequest(url: comps.url!, timeoutInterval: timeout)
        req.httpMethod = r.method
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let body = r.body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return ShelfResponse(status: http.statusCode, data: data)
    }
}

/// Everything that can go wrong with a shelf call. `message` is for the person, in plain words.
public enum ShelfFailure: Error, Equatable, Sendable {
    /// No answer: offline or timed out. Nothing was done.
    case offline
    /// 400 bad_request: a bug in the app.
    case badRequest(String)
    /// 400 invalid_pass: not a pass this server signed. Drop it and activate again.
    case invalidPass(String)
    /// 401 pass_expired: renew the pass, then repeat the call. Nothing was done.
    case passExpired(String)
    /// 403 revoked: the device was removed or the key switched off. The server's message names the reason when it gave one.
    case revoked(String)
    /// 429.
    case rateLimited(String)
    /// 503 or any 5xx. Nothing was done.
    case unavailable(String)
    /// 403 needs_extra.
    case needsExtra(String)
    /// 403 needs_take: flagging a setup this purchase never took.
    case needsTake(String)
    /// 404 not_found.
    case notFound(String)
    /// 410 gone: taken down; share it again as a new one.
    case gone(String)
    /// 409 handle_taken.
    case handleTaken(String)
    /// 422 refused: one or more limits broken. Nothing was stored.
    case refused(String, [SharedSetupViolation])
    /// 403 sharing_closed: the owner closed sharing for this key. Do not retry.
    case sharingClosed(String)
    /// 413.
    case tooBig(String)
    /// 409 on `kept`.
    case keptRefused(KeptRefusal, String)
    /// 404 unknown_take on `kept`.
    case unknownTake(String)
    /// An answer this version does not know. The status and code are kept for the log, never shown.
    case other(status: Int, code: String?, message: String)

    public var message: String {
        switch self {
        case .offline: return "Could not reach whoprrr.app. Check your internet connection and try again."
        case .badRequest(let m), .invalidPass(let m), .passExpired(let m), .revoked(let m), .rateLimited(let m), .unavailable(let m),
             .needsExtra(let m), .needsTake(let m), .notFound(let m), .gone(let m), .handleTaken(let m), .refused(let m, _),
             .sharingClosed(let m), .tooBig(let m), .keptRefused(_, let m), .unknownTake(let m), .other(_, _, let m): return m
        }
    }

    /// Network failures, timeouts and 5xx never mean "this device is not allowed".
    public var isTemporary: Bool {
        switch self { case .offline, .unavailable, .rateLimited: return true; default: return false }
    }

    /// Only these two mean this Mac is not allowed to use its pass.
    public var dropsThePass: Bool {
        switch self { case .revoked, .invalidPass: return true; default: return false }
    }
}

/// Why the server turned a day-7 answer away (409).
public enum KeptRefusal: String, Equatable, Sendable {
    /// Less than 7 days since the take: ask again later.
    case tooEarly = "too_early"
    /// More than 30 days: forget the token.
    case tooLate = "too_late"
    /// Already stored: forget the token.
    case alreadyAnswered = "already_answered"
    /// The take was not counted: forget the token.
    case notCounted = "not_counted"

    public var retryLater: Bool { self == .tooEarly }
}

public struct ShelfClient: Sendable {
    public var transport: ShelfTransport
    public init(transport: ShelfTransport) { self.transport = transport }

    // MARK: Browsing (no pass)

    /// One page of the shelf. Nothing about the person's gear is sent: ranking for their gear is done on the Mac.
    /// `q` is the search the person typed, when they typed one.
    public func list(tab: ShelfTab = .popular, part: String? = nil, search: String? = nil, cursor: String? = nil) async throws -> ShelfPage {
        var q = [URLQueryItem(name: "tab", value: tab.rawValue)]
        if let part { q.append(URLQueryItem(name: "part", value: part)) }
        if let s = search?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { q.append(URLQueryItem(name: "q", value: s)) }
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await call("GET", "api/shelf", query: q, as: ShelfPage.self)
    }

    public func count() async throws -> ShelfCount { try await call("GET", "api/shelf/count", as: ShelfCount.self) }

    // MARK: With a pass

    public func item(pass: String, id: String) async throws -> ShelfItem {
        let r = try await post("api/shelf/item", ["pass": pass, "id": id])
        guard let v = JSONValue.parse(r), let o = v.object, let doc = o["document"], let card = v.decode(ShelfCard.self) else { throw malformed() }
        return ShelfItem(card: card, document: doc, formatVersion: o["formatVersion"]?.integer ?? 1)
    }

    /// `counted` is the person's answer to "Count what you keep?". `part` is informational.
    public func take(pass: String, id: String, counted: Bool, part: String? = nil) async throws -> TakeReceipt {
        var body: [String: Any] = ["pass": pass, "id": id, "counted": counted]
        if let part { body["part"] = part }
        let data = try await post("api/shelf/take", body)
        struct R: Decodable { var again: Bool?; var takeToken: String?; var counted: Bool?; var askFrom: String?; var askUntil: String? }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { throw malformed() }
        return TakeReceipt(again: r.again ?? false, takeToken: r.takeToken, counted: r.counted ?? false,
                           askFrom: r.askFrom.flatMap(ShelfDates.parse), askUntil: r.askUntil.flatMap(ShelfDates.parse))
    }

    /// The day-7 answer. No pass: the take token is the credential. Nothing else is sent.
    public func kept(takeToken: String, kept: Bool) async throws {
        _ = try await post("api/shelf/kept", ["takeToken": takeToken, "kept": kept])
    }

    public func flag(pass: String, id: String) async throws { _ = try await post("api/shelf/flag", ["pass": pass, "id": id]) }

    public func notices(pass: String) async throws -> [ShelfNotice] {
        let data = try await post("api/shelf/notices", ["pass": pass])
        struct R: Decodable { var notices: [ShelfNotice] }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { throw malformed() }
        return r.notices
    }

    public func share(pass: String, _ r: ShareRequest) async throws -> ShareOutcome {
        var body = fields(r)
        body["pass"] = pass
        if let h = r.handle { body["handle"] = h }
        return try await outcome("api/shelf/share", body)
    }

    public func update(pass: String, id: String, note: String?, _ r: ShareRequest) async throws -> ShareOutcome {
        var body = fields(r)
        body["pass"] = pass; body["id"] = id
        if let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { body["note"] = n }
        return try await outcome("api/shelf/update", body)
    }

    public func takedown(pass: String, id: String) async throws { _ = try await post("api/shelf/takedown", ["pass": pass, "id": id]) }

    public func mine(pass: String) async throws -> ShelfMine {
        let data = try await post("api/shelf/mine", ["pass": pass])
        guard let v = JSONValue.parse(data), let o = v.object else { throw malformed() }
        let cook = o["cook"].flatMap { $0.isNull ? nil : $0.decode(ShelfCook.self) }
        let cards = (o["picklsss"]?.array ?? []).compactMap { $0.decode(ShelfCard.self) }
        return ShelfMine(cook: cook, picklsss: cards)
    }

    /// Kitchen time. Only for a person who has a public setup: nobody else's app calls this.
    public func day(pass: String) async throws { _ = try await post("api/shelf/day", ["pass": pass]) }

    // MARK: Plumbing

    private func fields(_ r: ShareRequest) -> [String: Any] {
        [
            "title": r.title, "line": r.line, "parts": r.parts,
            "gear": r.gear.map { ["role": $0.role, "model": $0.model] },
            "requirements": ["plugins": r.requirements.plugins, "minMacOS": r.requirements.minMacOS as Any? ?? NSNull(), "permissions": r.requirements.permissions],
            "document": r.document.foundation, "formatVersion": r.formatVersion,
        ]
    }

    private func outcome(_ path: String, _ body: [String: Any]) async throws -> ShareOutcome {
        let data = try await post(path, body)
        guard let o = try? JSONDecoder().decode(ShareOutcome.self, from: data) else { throw malformed() }
        return o
    }

    private func malformed() -> ShelfFailure { .other(status: 200, code: nil, message: "The shelf answered in a way this version of Whoprrr does not understand.") }

    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { throw ShelfFailure.badRequest("This could not be sent.") }
        return try await send(ShelfRequest(method: "POST", path: path, body: data))
    }

    private func call<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], as: T.Type) async throws -> T {
        let data = try await send(ShelfRequest(method: method, path: path, query: query))
        guard let v = try? JSONDecoder().decode(T.self, from: data) else { throw malformed() }
        return v
    }

    private func send(_ r: ShelfRequest) async throws -> Data {
        let resp: ShelfResponse
        do { resp = try await transport.send(r) } catch { throw ShelfFailure.offline }
        if (200..<300).contains(resp.status) { return resp.data }
        throw ShelfErrors.map(status: resp.status, body: resp.data, path: r.path)
    }
}

/// Turns a refusal into a typed case.
public enum ShelfErrors {
    struct Body: Decodable { var error: String?; var message: String?; var violations: [SharedSetupViolation]? }

    public static func map(status: Int, body: Data, path: String = "") -> ShelfFailure {
        let b = try? JSONDecoder().decode(Body.self, from: body)
        let code = b?.error
        func say(_ fallback: String) -> String { (b?.message).flatMap { $0.isEmpty ? nil : $0 } ?? fallback }
        switch (status, code) {
        case (400, "invalid_pass"): return .invalidPass(say("This Mac is no longer activated on that key. Enter your key to activate it again."))
        case (400, _): return .badRequest(say("This could not be sent. Update Whoprrr and try again."))
        case (401, _): return .passExpired(say("This Mac’s activation needs to be refreshed. Try again in a moment."))
        case (403, "revoked"): return .revoked(say("This Mac is no longer activated on that key. Enter your key to activate it again."))
        case (403, "needs_extra"): return .needsExtra(say("Taking a shared setup needs the shared-setups extra: $4, paid once, and free if a setup you share is accepted."))
        case (403, "needs_take"): return .needsTake(say("Take this shared setup first."))
        case (403, "sharing_closed"): return .sharingClosed(say("Sharing setups is closed for this key. Everything else in Whoprrr keeps working."))
        case (404, "unknown_take"): return .unknownTake(say("That take is not known."))
        case (404, _): return .notFound(say("That shared setup is not there any more."))
        case (409, "handle_taken"): return .handleTaken(say("Someone already has that handle. Pick another."))
        case (409, let c?) where path.hasSuffix("kept"):
            return .keptRefused(KeptRefusal(rawValue: c) ?? .tooLate, say("That answer was not needed."))
        case (410, _): return .gone(say("That shared setup was taken down. Share it again as a new one."))
        case (413, _): return .tooBig(say("That is too big to send."))
        case (422, "refused"): return .refused(say("This setup was not shared. Fix the lines below and try again."), b?.violations ?? [])
        case (429, _): return .rateLimited(say("Too many tries. Wait a while and try again."))
        case (500..., _): return .unavailable(say("Something went wrong on our side. Try again in a little while."))
        default: return .other(status: status, code: code, message: say("The shelf could not do that just now. Try again later."))
        }
    }
}
