import XCTest
@testable import WhopperKit

final class PurchaseLinkTests: XCTestCase {
    let server = URL(string: "https://whoprrr.app")!
    func j(_ s: String) -> Data { Data(s.utf8) }
    func client(_ fake: FakeShelf) -> PurchaseLinkClient { PurchaseLinkClient(transport: fake, server: server) }

    func testASuccessfulLinkIsAskedForWithThePassAndReturned() async throws {
        let fake = FakeShelf()
        fake.answers = [(200, #"{"url":"https://whoprrr.app/add/Zk3rQ0v2c1m9T5xLw8sNfH4yBd7aPeUj"}"#)]
        let outcome = await client(fake).request(pass: "a.b")
        XCTAssertEqual(outcome, .ready(URL(string: "https://whoprrr.app/add/Zk3rQ0v2c1m9T5xLw8sNfH4yBd7aPeUj")!))
        XCTAssertEqual(fake.sent.count, 1)
        XCTAssertEqual([fake.sent[0].method, fake.sent[0].path], ["POST", "api/pass/link"])
        XCTAssertEqual(fake.body()["pass"] as? String, "a.b")
        XCTAssertEqual(fake.body().count, 1, "nothing but the pass goes")
    }

    func testRefusalsAreTheRenewalRefusals() {
        let revoked = LicenseReplies.link(status: 403, body: j(#"{"error":"revoked","message":"Removed."}"#), server: server)
        XCTAssertEqual(revoked, .revoked(message: "Removed."))
        XCTAssertEqual(LicenseReplies.link(status: 400, body: j(#"{"error":"invalid_pass","message":"Not ours."}"#), server: server), .revoked(message: "Not ours."))
        // Both map to the same outcome renewal gives, so the app drops the pass in the same way.
        XCTAssertEqual(LicenseReplies.renew(status: 403, body: j(#"{"error":"revoked","message":"Removed."}"#)), .revoked(message: "Removed."))
        guard case .revoked(let m) = LicenseReplies.link(status: 403, body: j(#"{"error":"revoked"}"#), server: server) else { return XCTFail() }
        XCTAssertTrue(m.contains("Enter your key"))
        XCTAssertEqual(LicenseReplies.link(status: 401, body: j(#"{"error":"pass_expired","message":"Old."}"#), server: server), .passExpired)
        XCTAssertEqual(LicenseReplies.link(status: 429, body: j(#"{"error":"rate_limited","message":"Slow down."}"#), server: server), .busy(message: "Slow down."))
    }

    func testTroubleNeverCountsAsARefusal() async {
        for (status, body) in [(404, "<html>no such page</html>"), (500, ""), (502, "bad gateway"), (503, #"{"error":"unavailable","message":"Later."}"#), (400, #"{"error":"bad_request"}"#), (403, "<html>blocked</html>"), (200, "{}"), (200, "<html>"), (200, #"{"url":""}"#)] {
            XCTAssertEqual(LicenseReplies.link(status: status, body: j(body), server: server), .unavailable, "\(status) \(body)")
        }
        XCTAssertEqual(LicenseReplies.link(status: nil, body: nil, server: server), .unavailable)
        let offline = FakeShelf(); offline.offline = true
        let a = await client(offline).request(pass: "a.b")
        XCTAssertEqual(a, .unavailable, "no connection")
        let slow = FakeShelf(); slow.cancelled = true
        let b = await client(slow).request(pass: "a.b")
        XCTAssertEqual(b, .unavailable, "cancelled or timed out")
        let notThere = FakeShelf(); notThere.answers = [(404, "<html>Not Found</html>")]
        let c = await client(notThere).request(pass: "a.b")
        XCTAssertEqual(c, .unavailable, "a server that does not have the endpoint yet")
    }

    func testOnlyALinkOnOurOwnSiteIsEverOpened() {
        for url in ["https://evil.example/add/Zk3rQ0v2c1m9T5xLw8sNfH4yBd7aPeUj", "https://whoprrr.app.evil.example/add/Zk3rQ0v2c1m9T5xLw8sNfH4yBd7aPeUj",
                    "http://whoprrr.app/add/Zk3rQ0v2c1m9T5xLw8sNfH4yBd7aPeUj", "https://whoprrr.app/get", "https://whoprrr.app/add/", "file:///etc/passwd", "javascript:alert(1)"] {
            XCTAssertEqual(LicenseReplies.link(status: 200, body: j(#"{"url":"\#(url)"}"#), server: server), .unavailable, url)
        }
        // A local test server (debug builds) may be plain http, as long as it is the same server.
        let local = URL(string: "http://localhost:3000")!
        XCTAssertEqual(LicenseReplies.link(status: 200, body: j(#"{"url":"http://localhost:3000/add/Zk3rQ0v2c1m9T5xLw8sNfH4yBd7aPeUj"}"#), server: local), .ready(URL(string: "http://localhost:3000/add/Zk3rQ0v2c1m9T5xLw8sNfH4yBd7aPeUj")!))
    }

    func testTheRefreshGateAllowsOnceEveryTenMinutesAndNeverWithTheExtra() {
        var gate = PassRefreshGate()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(gate.allow(now: t0, hasExtra: false), "the first look goes")
        XCTAssertFalse(gate.allow(now: t0.addingTimeInterval(1), hasExtra: false))
        XCTAssertFalse(gate.allow(now: t0.addingTimeInterval(9 * 60 + 59), hasExtra: false))
        XCTAssertTrue(gate.allow(now: t0.addingTimeInterval(10 * 60), hasExtra: false), "exactly ten minutes later")
        XCTAssertFalse(gate.allow(now: t0.addingTimeInterval(10 * 60 + 5), hasExtra: false), "and that one counted")
        var owner = PassRefreshGate()
        XCTAssertFalse(owner.allow(now: t0, hasExtra: true), "nothing to look for")
        XCTAssertTrue(owner.allow(now: t0, hasExtra: false), "having the extra did not use up the allowance")
        XCTAssertEqual(PassRefreshGate.interval, 600)
    }

    func testTheWordsArePlain() {
        let all = [PurchaseWords.couldNotReach, PurchaseWords.findByEmail, PurchaseWords.notYet]
        XCTAssertEqual(PurchaseWords.couldNotReach, "Could not reach whoprrr.app. Check your connection and try again.")
        XCTAssertEqual(PurchaseWords.notYet, "Not on your key yet. If you just paid, give it a moment.")
        for w in all { XCTAssertFalse(w.contains("!") || w.contains("—") || w.contains("–"), w) }
    }
}
