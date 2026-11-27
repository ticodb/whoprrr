import XCTest
@testable import WhopperKit

/// A transport that answers from a script and remembers what it was asked. No network.
final class FakeShelf: ShelfTransport, @unchecked Sendable {
    var sent: [ShelfRequest] = []
    var answers: [(Int, String)] = []
    var offline = false
    var cancelled = false
    func send(_ r: ShelfRequest) async throws -> ShelfResponse {
        sent.append(r)
        if cancelled { throw URLError(.cancelled) }
        if offline { throw URLError(.notConnectedToInternet) }
        let (s, b) = answers.isEmpty ? (200, "{}") : answers.removeFirst()
        return ShelfResponse(status: s, data: Data(b.utf8))
    }
    func body(_ i: Int = 0) -> [String: Any] { (try? JSONSerialization.jsonObject(with: sent[i].body ?? Data())) as? [String: Any] ?? [:] }
}

let cardJSON = #"{"id":"wK3n9xQ2pLs","title":"Quiet desk","line":"Low volume.","parts":["audio","microphone"],"gear":[{"role":"speakers","model":"Edifier R1280"}],"requirements":{"plugins":[],"minMacOS":"13","permissions":["microphone"]},"cook":{"handle":"ana.kitchen","rank":"line cook","keeps":23,"kitchenDays":41},"keeps":14,"match":2,"version":3,"createdAt":"2026-12-01T10:00:00.000Z","updatedAt":"2026-12-20T18:30:00.000Z"}"#

final class ShelfClientTests: XCTestCase {
    func make(_ answers: (Int, String)...) -> (ShelfClient, FakeShelf) {
        let t = FakeShelf(); t.answers = answers
        return (ShelfClient(transport: t), t)
    }

    // MARK: Browsing

    func testListAsksForATabAndNeverSendsGear() async throws {
        let (c, t) = make((200, #"{"items":[\#(cardJSON)],"next":"MjA"}"#))
        let page = try await c.list(tab: .new, part: "audio", search: "  quiet desk ", cursor: "ab")
        XCTAssertEqual(page.items.map(\.title), ["Quiet desk"])
        XCTAssertEqual(page.next, "MjA")
        XCTAssertEqual(page.items[0].cook.rank, "line cook")
        XCTAssertEqual(t.sent[0].method, "GET"); XCTAssertEqual(t.sent[0].path, "api/shelf")
        let names = t.sent[0].query.map(\.name)
        XCTAssertEqual(names, ["tab", "part", "q", "cursor"])
        XCTAssertFalse(names.contains("gear"), "ranking for your gear is done on the Mac, so the shelf is never told")
        XCTAssertEqual(t.sent[0].query.first { $0.name == "q" }?.value, "quiet desk")
        XCTAssertNil(t.sent[0].body)
    }

    func testListWithNothingToSearchSendsOnlyTheTab() async throws {
        let (c, t) = make((200, #"{"items":[],"next":null}"#))
        let page = try await c.list(search: "   ")
        XCTAssertEqual(page.items, []); XCTAssertNil(page.next)
        XCTAssertEqual(t.sent[0].query.map(\.name), ["tab"])
    }

    func testCount() async throws {
        let (c, t) = make((200, #"{"count":12,"gearTypes":31}"#))
        let n = try await c.count()
        XCTAssertEqual(n, ShelfCount(count: 12, gearTypes: 31)); XCTAssertEqual(t.sent[0].path, "api/shelf/count")
    }

    // MARK: Opening and taking

    func testItemCarriesTheCardAndTheDocument() async throws {
        let (c, t) = make((200, #"{"id":"wK3n9xQ2pLs","title":"Quiet desk","line":"x","parts":["audio"],"gear":[],"requirements":{"plugins":[],"minMacOS":null,"permissions":[]},"cook":{"handle":"ana.kitchen","rank":"dishwasher","keeps":0,"kitchenDays":1},"keeps":0,"version":1,"createdAt":"","updatedAt":"","state":"public","document":{"a":1},"formatVersion":1}"#))
        let item = try await c.item(pass: "P", id: "wK3n9xQ2pLs")
        XCTAssertEqual(item.document, .object(["a": .int(1)])); XCTAssertEqual(item.formatVersion, 1); XCTAssertEqual(item.card.shelfState, .public)
        XCTAssertEqual(t.body()["pass"] as? String, "P"); XCTAssertEqual(t.body()["id"] as? String, "wK3n9xQ2pLs")
    }

    func testTakeSendsTheAnswerAndReturnsTheToken() async throws {
        let (c, t) = make((200, #"{"ok":true,"again":false,"takeToken":"q7Zk","counted":true,"askFrom":"2026-12-08T10:00:00.000Z","askUntil":"2026-12-31T10:00:00.000Z"}"#))
        let r = try await c.take(pass: "P", id: "x", counted: true, part: "audio")
        XCTAssertEqual(r.takeToken, "q7Zk"); XCTAssertTrue(r.counted); XCTAssertFalse(r.again)
        XCTAssertEqual(r.askFrom, ShelfDates.parse("2026-12-08T10:00:00Z")); XCTAssertNotNil(r.askUntil)
        XCTAssertEqual(t.body()["counted"] as? Bool, true); XCTAssertEqual(t.body()["part"] as? String, "audio")
    }

    func testTakeAgainHasNoToken() async throws {
        let (c, _) = make((200, #"{"ok":true,"again":true}"#))
        let r = try await c.take(pass: "P", id: "x", counted: false)
        XCTAssertTrue(r.again); XCTAssertNil(r.takeToken); XCTAssertNil(r.askFrom)
    }

    func testKeptSendsOnlyTheTokenAndTheAnswer() async throws {
        let (c, t) = make((204, ""))
        try await c.kept(takeToken: "tok", kept: false)
        XCTAssertEqual(Set(t.body().keys), ["takeToken", "kept"], "nothing else is sent: no pass, no setup, no device")
        XCTAssertEqual(t.body()["kept"] as? Bool, false)
    }

    func testFlagNoticesDayTakedownAndMine() async throws {
        let (c, t) = make((200, #"{"ok":true}"#),
                          (200, #"{"notices":[{"id":"41","kind":"update","picklsssId":"w","title":"Quiet desk","version":4,"note":"Quieter","at":"x","message":"New version."},{"id":"42","kind":"removed","picklsssId":"a","title":"Movie night","version":1,"note":"","at":"x","message":"Taken off."}]}"#),
                          (204, ""), (200, #"{"ok":true}"#),
                          (200, #"{"cook":{"handle":"ana.kitchen","rank":"dishwasher","keeps":3,"kitchenDays":9,"sharingClosed":{"reason":"too loud"}},"picklsss":[\#(cardJSON.dropLast()),"state":"held","reason":"the title has a web address"}]}"#),
                          (200, #"{"cook":null,"picklsss":[]}"#))
        try await c.flag(pass: "P", id: "w")
        let n = try await c.notices(pass: "P")
        XCTAssertEqual(n.map(\.kind), [.update, .removed]); XCTAssertEqual(n[0].note, "Quieter")
        try await c.day(pass: "P")
        try await c.takedown(pass: "P", id: "w")
        let mine = try await c.mine(pass: "P")
        XCTAssertEqual(mine.cook?.sharingClosed?.reason, "too loud"); XCTAssertEqual(mine.picklsss[0].shelfState, .held); XCTAssertEqual(mine.picklsss[0].reason, "the title has a web address")
        let none = try await c.mine(pass: "P")
        XCTAssertNil(none.cook); XCTAssertEqual(none.picklsss, [])
        XCTAssertEqual(t.sent.map(\.path), ["api/shelf/flag", "api/shelf/notices", "api/shelf/day", "api/shelf/takedown", "api/shelf/mine", "api/shelf/mine"])
        XCTAssertTrue(t.sent.allSatisfy { $0.method == "POST" })
    }

    // MARK: Sharing

    func shareRequest(handle: String? = "ana.kitchen") -> ShareRequest {
        ShareRequest(handle: handle, title: "Quiet desk", line: "Low volume", parts: ["audio"], gear: [SharedGear(role: "speaker", model: "Edifier R1280")],
                     requirements: SharedRequirements(plugins: ["Pro-Q 3"], minMacOS: nil, permissions: ["microphone"]), document: .object(["formatVersion": .int(1)]))
    }

    func testShareSendsTheFieldsBesideTheDocument() async throws {
        let (c, t) = make((200, #"{"id":"i","state":"public","version":1,"handle":"ana.kitchen"}"#))
        let o = try await c.share(pass: "P", shareRequest())
        XCTAssertEqual(o.state, .public); XCTAssertEqual(o.handle, "ana.kitchen")
        let b = t.body()
        XCTAssertEqual(Set(b.keys), ["pass", "handle", "title", "line", "parts", "gear", "requirements", "document", "formatVersion"])
        let req = b["requirements"] as? [String: Any]
        XCTAssertTrue(req?["minMacOS"] is NSNull, "minMacOS is always written, null when there is none")
        XCTAssertEqual((b["gear"] as? [[String: String]])?.first, ["role": "speaker", "model": "Edifier R1280"])
    }

    func testShareAfterTheFirstTimeSendsNoHandle() async throws {
        let (c, t) = make((200, #"{"id":"i","state":"held","version":1,"reason":"waiting for the format check","handle":"ana.kitchen"}"#))
        let o = try await c.share(pass: "P", shareRequest(handle: nil))
        XCTAssertEqual(o.state, .held); XCTAssertEqual(o.reason, "waiting for the format check")
        XCTAssertNil(t.body()["handle"])
    }

    func testUpdateCarriesTheIdAndTheNote() async throws {
        let (c, t) = make((200, #"{"id":"i","state":"public","version":2,"handle":"ana.kitchen"}"#))
        let o = try await c.update(pass: "P", id: "i", note: "  Quieter by default ", shareRequest(handle: nil))
        XCTAssertEqual(o.version, 2)
        XCTAssertEqual(t.body()["id"] as? String, "i"); XCTAssertEqual(t.body()["note"] as? String, "Quieter by default")
        XCTAssertEqual(t.sent[0].path, "api/shelf/update")
    }

    func testShelfV1ShareAndUpdateOmitPrivateFileTypingLanguage() async throws {
        let reply = #"{"id":"i","state":"public","version":1,"handle":"ana.kitchen"}"#
        let (c, t) = make((200, reply), (200, reply))
        var request = shareRequest()
        request.document = .object([
            "formatVersion": .int(1),
            "typingLanguage": .object(["id": .string("com.apple.keylayout.Spanish-ISO"), "name": .string("Spanish – ISO")]),
        ])

        _ = try await c.share(pass: "P", request)
        _ = try await c.update(pass: "P", id: "i", note: nil, request)

        XCTAssertEqual(t.sent.map(\.path), ["api/shelf/share", "api/shelf/update"])
        for index in t.sent.indices {
            let document = try XCTUnwrap(t.body(index)["document"] as? [String: Any])
            XCTAssertEqual(Set(document.keys), ["formatVersion"])
            XCTAssertEqual(document["formatVersion"] as? Int, 1)
        }
        XCTAssertNotNil(request.document["typingLanguage"])
    }

    // MARK: Every error is a typed case, and the server's words are kept

    func fail(_ status: Int, _ body: String, path: String = "api/shelf/take") async -> ShelfFailure? {
        let (c, _) = make((status, body))
        do {
            if path.hasSuffix("kept") { try await c.kept(takeToken: "t", kept: true) } else { _ = try await c.take(pass: "P", id: "x", counted: false) }
            return nil
        } catch { return error as? ShelfFailure }
    }

    func testPassErrors() async {
        let a = await fail(400, #"{"error":"invalid_pass","message":"Not ours."}"#)
        XCTAssertEqual(a, .invalidPass("Not ours.")); XCTAssertTrue(a!.dropsThePass)
        let b = await fail(401, #"{"error":"pass_expired","message":"Renew."}"#)
        XCTAssertEqual(b, .passExpired("Renew.")); XCTAssertFalse(b!.dropsThePass)
        let c = await fail(403, #"{"error":"revoked","message":"This key has been switched off. Reason: nope."}"#)
        XCTAssertEqual(c, .revoked("This key has been switched off. Reason: nope.")); XCTAssertTrue(c!.dropsThePass)
        let d = await fail(400, #"{"error":"bad_request","message":"x"}"#)
        XCTAssertEqual(d, .badRequest("x")); XCTAssertFalse(d!.dropsThePass)
    }

    func testTakeErrors() async {
        let a = await fail(403, #"{"error":"needs_extra","message":"Shared setups are an extra."}"#)
        XCTAssertEqual(a, .needsExtra("Shared setups are an extra."))
        let b = await fail(404, #"{"error":"not_found","message":"That shared setup is not there any more."}"#)
        XCTAssertEqual(b, .notFound("That shared setup is not there any more."))
        let c = await fail(403, #"{"error":"needs_take","message":"Take this shared setup first."}"#)
        XCTAssertEqual(c, .needsTake("Take this shared setup first."))
        let d = await fail(429, #"{"error":"rate_limited","message":"Slow down."}"#)
        XCTAssertEqual(d, .rateLimited("Slow down.")); XCTAssertTrue(d!.isTemporary)
        let e = await fail(503, #"{"error":"unavailable","message":"Later."}"#)
        XCTAssertEqual(e, .unavailable("Later.")); XCTAssertTrue(e!.isTemporary); XCTAssertFalse(e!.dropsThePass, "5xx never means not allowed")
        let f = await fail(410, #"{"error":"gone","message":"Share it again."}"#)
        XCTAssertEqual(f, .gone("Share it again."))
        let g = await fail(413, "")
        if case .tooBig = g! {} else { XCTFail("\(String(describing: g))") }
    }

    func testShareErrors() async {
        let (c, _) = make((422, #"{"error":"refused","message":"This setup was not shared.","violations":[{"line":"title","limit":"1 to 60 characters","message":"The title must be 1 to 60 characters (it has 71)."},{"line":"audio.output.volume","limit":"at most 100%","message":"The volume goes past 100%."}]}"#),
                           (409, #"{"error":"handle_taken","message":"Someone has that handle."}"#),
                           (403, #"{"error":"sharing_closed","message":"Sharing setups is closed for this key. Reason: loud."}"#))
        do { _ = try await c.share(pass: "P", shareRequest()); XCTFail() } catch let e as ShelfFailure {
            guard case .refused(let m, let v) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(m, "This setup was not shared.")
            XCTAssertEqual(v.map(\.line), ["title", "audio.output.volume"]); XCTAssertEqual(v[1].limit, "at most 100%")
        } catch { XCTFail("\(error)") }
        do { _ = try await c.share(pass: "P", shareRequest()); XCTFail() } catch { XCTAssertEqual(error as? ShelfFailure, .handleTaken("Someone has that handle.")) }
        do { _ = try await c.share(pass: "P", shareRequest()); XCTFail() } catch {
            XCTAssertEqual(error as? ShelfFailure, .sharingClosed("Sharing setups is closed for this key. Reason: loud."))
        }
    }

    func testKeptRefusalsEachHaveTheirOwnCase() async {
        for (code, want) in [("too_early", KeptRefusal.tooEarly), ("too_late", .tooLate), ("already_answered", .alreadyAnswered), ("not_counted", .notCounted)] {
            let f = await fail(409, #"{"error":"\#(code)","message":"m"}"#, path: "api/shelf/kept")
            XCTAssertEqual(f, .keptRefused(want, "m"), code)
        }
        let u = await fail(404, #"{"error":"unknown_take","message":"m"}"#, path: "api/shelf/kept")
        XCTAssertEqual(u, .unknownTake("m"))
        XCTAssertTrue(KeptRefusal.tooEarly.retryLater); XCTAssertFalse(KeptRefusal.tooLate.retryLater)
    }

    func testAnAbandonedCallIsNotReportedAsOffline() async {
        let t = FakeShelf(); t.cancelled = true
        let c = ShelfClient(transport: t)
        do { _ = try await c.notices(pass: "P"); XCTFail() } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertNil(error as? ShelfFailure)
        }
    }

    func testNoAnswerIsOfflineAndNeverBlamesThePass() async {
        let t = FakeShelf(); t.offline = true
        let c = ShelfClient(transport: t)
        do { _ = try await c.notices(pass: "P"); XCTFail() } catch {
            let f = error as? ShelfFailure
            XCTAssertEqual(f, .offline); XCTAssertTrue(f!.isTemporary); XCTAssertFalse(f!.dropsThePass)
            XCTAssertTrue(f!.message.contains("Could not reach"))
        }
    }

    func testAnUnknownCodeKeepsTheServersWords() async {
        let f = await fail(418, #"{"error":"teapot","message":"Short and stout."}"#)
        XCTAssertEqual(f, .other(status: 418, code: "teapot", message: "Short and stout."))
        let g = await fail(500, "not json")
        if case .unavailable(let m) = g! { XCTAssertFalse(m.isEmpty) } else { XCTFail() }
    }

    func testAnAnswerThatIsNotWhatWasPromisedIsNotACrash() async {
        let (c, _) = make((200, "<html>"))
        do { _ = try await c.count(); XCTFail() } catch { if case .other = error as! ShelfFailure {} else { XCTFail() } }
    }
}
