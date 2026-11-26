import XCTest
import AudioCore
import WindowCore
import ClipboardCore
import InputCore
@testable import WhopperKit

private func pass(pick: Bool, kid: String = "KID-OWN") -> LicensePass {
    LicensePass(v: 1, kid: kid, dev: "d", kind: "mac", mac: true, tv: false, pick: pick, iat: 0, exp: 9_999_999_999)
}

// MARK: The lock

final class PicklsssLockTests: XCTestCase {
    func testEverythingUpToAndIncludingTheReviewIsFreeWithoutTheExtra() {
        for a: PicklsssLock.Action in [.browse, .open, .matchGear, .review, .openFile, .makeFile, .share, .update, .takedown, .putBack] {
            XCTAssertEqual(PicklsssLock.decision(a, pass: pass(pick: false)), .free, "\(a)")
            XCTAssertEqual(PicklsssLock.decision(a, pass: nil), .free, "\(a)")
        }
    }

    func testTakingIsTheFirstActionThatChangesTheMacAndItNeedsTheExtra() {
        XCTAssertEqual(PicklsssLock.decision(.take, pass: pass(pick: false)), .locked)
        XCTAssertEqual(PicklsssLock.decision(.takePart, pass: pass(pick: false)), .locked)
        XCTAssertEqual(PicklsssLock.decision(.take, pass: nil), .locked)
        XCTAssertEqual(PicklsssLock.decision(.take, pass: pass(pick: true)), .free)
        XCTAssertEqual(PicklsssLock.decision(.takePart, pass: pass(pick: true)), .free)
    }

    func testAFileMadeUnderYourOwnKeyAlwaysOpensFree() {
        XCTAssertEqual(PicklsssLock.decision(.takeFromFile(madeBy: "KID-OWN"), pass: pass(pick: false)), .free)
        XCTAssertTrue(PicklsssLock.isOwnFile(madeBy: "KID-OWN", pass: pass(pick: false)))
    }

    func testAFileMadeUnderSomeoneElsesKeyIsTakingAndNeedsTheExtra() {
        XCTAssertEqual(PicklsssLock.decision(.takeFromFile(madeBy: "KID-OTHER"), pass: pass(pick: false)), .locked)
        XCTAssertEqual(PicklsssLock.decision(.takeFromFile(madeBy: "KID-OTHER"), pass: pass(pick: true)), .free)
        XCTAssertEqual(PicklsssLock.decision(.takeFromFile(madeBy: nil), pass: pass(pick: false)), .locked)
        XCTAssertEqual(PicklsssLock.decision(.takeFromFile(madeBy: ""), pass: pass(pick: false)), .locked)
    }

    func testWithoutAPassNothingIsOwn() {
        XCTAssertFalse(PicklsssLock.isOwnFile(madeBy: "KID-OWN", pass: nil))
        XCTAssertFalse(PicklsssLock.isOwnFile(madeBy: "", pass: pass(pick: true, kid: "")))
        XCTAssertEqual(PicklsssLock.decision(.takeFromFile(madeBy: "KID-OWN"), pass: nil), .locked)
    }

    func testTheFileCarriesTheKeyIdAndOnlyThatKeyOpensItFree() throws {
        let setup = Personal.setup()
        let data = try SharedSetupFile.encode(setup, madeBy: "KID-OWN").get()
        let opened = SharedSetupFile.decode(data)
        XCTAssertNotNil(opened.setup)
        XCTAssertEqual(PicklsssLock.decision(.takeFromFile(madeBy: opened.madeBy), pass: pass(pick: false)), .free)
        XCTAssertEqual(PicklsssLock.decision(.takeFromFile(madeBy: opened.madeBy), pass: pass(pick: false, kid: "KID-SOMEONE-ELSE")), .locked)
    }

    func testTheWordsKeepTheMenuNameBesideItsMeaning() {
        XCTAssertFalse(PicklsssWords.countQuestionBody.contains("Picklsss"), "the question uses the plain word")
        XCTAssertTrue(PicklsssWords.countQuestionBody.hasPrefix("Cooks earn their rank from people who keep their picklsss."))
        XCTAssertEqual(PicklsssWords.countQuestionTitle, "Count what you keep?")
        XCTAssertEqual(PicklsssWords.takedownTitle("Podcast desk"), "Take “Podcast desk” down?")
        XCTAssertTrue(PicklsssWords.takedownBody(keeps: 212).contains("212 people kept it"))
        XCTAssertEqual(PicklsssWords.partTitle("keys"), "Keys and mouse")
        XCTAssertEqual(PicklsssWords.keeps(1), "1 person kept it")
    }
}

// MARK: The day-7 answer

final class KeepTrackerTests: XCTestCase {
    var now = Date(timeIntervalSince1970: 1_800_000_000)       // a fixed, injectable clock
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    func tracker() -> KeepTracker { let n = self; return KeepTracker(clock: { n.now }, calendar: cal) }
    let recipe = UUID()
    let day: TimeInterval = 86_400

    func take(counted: Bool = true, recipeID: UUID? = nil) -> TakeRecord {
        var t = TakeRecord(picklsssId: "p1", title: "Quiet desk", handle: "ana", recipeID: recipeID ?? recipe, takenAt: now, counted: counted,
                           takeToken: counted ? "tok" : nil, askFrom: counted ? now.addingTimeInterval(7 * day) : nil, askUntil: counted ? now.addingTimeInterval(30 * day) : nil)
        t.before = ["audio": Data("x".utf8)]
        return t
    }
    func activeOn(_ days: Int, _ takes: inout [TakeRecord]) {
        for d in 0..<days { now = Date(timeIntervalSince1970: 1_800_000_000 + Double(d) * day); tracker().noteActive(recipeID: recipe, in: &takes) }
    }

    func testActiveDaysAreRememberedOnlyForCountedTakenSetups() {
        var takes = [take(), take(counted: false)]
        takes[1].picklsssId = "p2"; takes[1].recipeID = UUID()
        XCTAssertTrue(tracker().noteActive(recipeID: recipe, in: &takes))
        XCTAssertEqual(takes[0].activeDays.count, 1)
        XCTAssertFalse(tracker().noteActive(recipeID: recipe, in: &takes), "the same day twice is one day")
        XCTAssertFalse(tracker().noteActive(recipeID: UUID(), in: &takes), "a recipe that is not a taken setup is never recorded")
        XCTAssertFalse(tracker().noteActive(recipeID: nil, in: &takes))
        XCTAssertFalse(tracker().noteActive(recipeID: takes[1].recipeID, in: &takes), "a take that is not counted records nothing at all")
        XCTAssertEqual(takes[1].activeDays, [])
    }

    func testThreeDifferentDaysAndStillThereIsKept() {
        var takes = [take()]
        activeOn(3, &takes)
        now = takes[0].askFrom!
        let a = tracker().due(takes: &takes, recipeIDs: [recipe])
        XCTAssertEqual(a, [KeepTracker.Answer(picklsssId: "p1", takeToken: "tok", kept: true)])
    }

    func testTwoDaysIsNotKept() {
        var takes = [take()]
        activeOn(2, &takes)
        now = takes[0].askFrom!
        XCTAssertEqual(tracker().due(takes: &takes, recipeIDs: [recipe]).map(\.kept), [false])
    }

    func testTakingItAndNeverUsingItIsNotKept() {
        var takes = [take()]
        now = takes[0].askFrom!
        XCTAssertEqual(tracker().due(takes: &takes, recipeIDs: [recipe]).map(\.kept), [false])
    }

    func testADeletedRecipeIsNotKeptEvenIfItWasUsed() {
        var takes = [take()]
        activeOn(5, &takes)
        now = takes[0].askFrom!
        XCTAssertEqual(tracker().due(takes: &takes, recipeIDs: [UUID()]).map(\.kept), [false])
    }

    func testAWeekOfTravelWithAnotherSetupOnDoesNotFailIt() {
        var takes = [take()]
        activeOn(3, &takes)                                       // used three days, then another setup for the rest of the week
        now = takes[0].askFrom!.addingTimeInterval(day)
        XCTAssertEqual(tracker().due(takes: &takes, recipeIDs: [recipe]).map(\.kept), [true])
    }

    func testNothingIsAskedBeforeDay7() {
        var takes = [take()]
        activeOn(3, &takes)
        now = takes[0].askFrom!.addingTimeInterval(-1)
        XCTAssertEqual(tracker().due(takes: &takes, recipeIDs: [recipe]), [])
        XCTAssertNil(takes[0].verdict)
    }

    func testTheWindowIsDay7ToDay30AndBothEndsCount() {
        var takes = [take()]
        activeOn(3, &takes)
        now = takes[0].askFrom!
        XCTAssertEqual(tracker().due(takes: &takes, recipeIDs: [recipe]).count, 1)
        now = takes[0].askUntil!
        XCTAssertEqual(tracker().due(takes: &takes, recipeIDs: [recipe]).count, 1)
        now = takes[0].askUntil!.addingTimeInterval(1)
        XCTAssertEqual(tracker().due(takes: &takes, recipeIDs: [recipe]), [])
        XCTAssertNil(takes[0].takeToken, "after day 30 the token is forgotten and nothing is sent")
    }

    func testTheAnswerIsWorkedOutOnceAndCannotFlipLater() {
        var takes = [take()]
        activeOn(3, &takes)
        now = takes[0].askFrom!
        XCTAssertEqual(tracker().due(takes: &takes, recipeIDs: [recipe]).map(\.kept), [true])
        XCTAssertEqual(tracker().due(takes: &takes, recipeIDs: []).map(\.kept), [true], "deleting the recipe afterwards does not change what day 7 said")
    }

    func testAnAnswerThatDidNotGetThroughIsTriedAgainAndOnlyThenForgotten() {
        var takes = [take()]
        activeOn(3, &takes)
        now = takes[0].askFrom!
        _ = tracker().due(takes: &takes, recipeIDs: [recipe])
        tracker().settle("p1", error: .offline, in: &takes)
        XCTAssertNotNil(takes[0].takeToken); XCTAssertFalse(takes[0].answered)
        tracker().settle("p1", error: .rateLimited("later"), in: &takes)
        XCTAssertNotNil(takes[0].takeToken)
        tracker().settle("p1", error: .keptRefused(.tooEarly, "m"), in: &takes)
        XCTAssertNotNil(takes[0].takeToken); XCTAssertNil(takes[0].verdict, "too early: ask again later")
        _ = tracker().due(takes: &takes, recipeIDs: [recipe])
        tracker().settle("p1", error: nil, in: &takes)
        XCTAssertNil(takes[0].takeToken); XCTAssertTrue(takes[0].answered)
        XCTAssertEqual(tracker().due(takes: &takes, recipeIDs: [recipe]), [], "once")
    }

    func testEveryRefusalThatWillNeverChangeForgetsTheToken() {
        for e: ShelfFailure in [.keptRefused(.tooLate, ""), .keptRefused(.alreadyAnswered, ""), .keptRefused(.notCounted, ""), .unknownTake("")] {
            var takes = [take()]
            tracker().settle("p1", error: e, in: &takes)
            XCTAssertNil(takes[0].takeToken, "\(e)"); XCTAssertTrue(takes[0].answered)
        }
    }

    func testATakeThatWasNotCountedIsNeverAnswered() {
        var takes = [take(counted: false)]
        now = now.addingTimeInterval(8 * day)
        XCTAssertEqual(tracker().due(takes: &takes, recipeIDs: [recipe]), [])
    }
}

// MARK: Daily check, notices, shared records, fields

final class PicklsssDailyTests: XCTestCase {
    func testKitchenTimeIsOnlyForSomeoneWithAPublicSetupAndOncePerUTCDay() {
        let d1 = ISO8601DateFormatter().date(from: "2026-12-01T23:30:00Z")!
        let d2 = ISO8601DateFormatter().date(from: "2026-12-02T00:10:00Z")!
        XCTAssertFalse(DailyCheck.shouldCallDay(hasPublicSetup: false, lastCall: nil, now: d1), "nobody else's app makes the call")
        XCTAssertTrue(DailyCheck.shouldCallDay(hasPublicSetup: true, lastCall: nil, now: d1))
        XCTAssertFalse(DailyCheck.shouldCallDay(hasPublicSetup: true, lastCall: DailyCheck.utcDay(d1), now: d1))
        XCTAssertTrue(DailyCheck.shouldCallDay(hasPublicSetup: true, lastCall: DailyCheck.utcDay(d1), now: d2))
        XCTAssertEqual(DailyCheck.utcDay(d2), "2026-12-02")
    }

    func testAStateWithoutAnySharedSetupMakesNoDayCall() {
        var s = PicklsssState()
        XCTAssertFalse(s.hasPublicSetup)
        s.shared = [SharedRecord(picklsssId: "a", recipeID: nil, title: "t", state: "held", version: 1, parts: [], digest: "", sharedAt: Date()),
                    SharedRecord(picklsssId: "b", recipeID: nil, title: "t", state: "removed", version: 1, parts: [], digest: "", sharedAt: Date())]
        XCTAssertFalse(s.hasPublicSetup, "held and taken-down ones do not count")
        s.shared[0].state = "public"
        XCTAssertTrue(s.hasPublicSetup)
    }

    func testTheStateRoundTripsAsJSON() throws {
        var s = PicklsssState()
        s.count = .yes; s.handle = "ana"
        s.takes = [TakeRecord(picklsssId: "p", title: "t", handle: "h", recipeID: UUID(), takenAt: Date(timeIntervalSince1970: 5), counted: true, takeToken: "tok")]
        let back = try JSONDecoder().decode(PicklsssState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}

final class NoticeTests: XCTestCase {
    func update(_ id: String, v: Int, setup: String = "w") -> ShelfNotice { ShelfNotice(id: id, kind: .update, picklsssId: setup, title: "Quiet desk", version: v, note: "n\(v)", message: "m") }
    let removed = ShelfNotice(id: "9", kind: .removed, picklsssId: "gone", title: "Movie night", message: "Taken off the shelf.")

    func testNoticesAreKeptUntilSeenAndNotDuplicated() {
        var s: [StoredNotice] = []
        NoticeBox.merge([update("1", v: 2), removed], into: &s, now: Date())
        NoticeBox.merge([update("1", v: 2)], into: &s, now: Date())
        XCTAssertEqual(s.count, 2)
        NoticeBox.dismiss("1", from: &s)
        XCTAssertEqual(s.map(\.notice.id), ["9"])
    }

    func testANewerUpdateReplacesAnOlderOneForTheSameSetup() {
        var s: [StoredNotice] = []
        NoticeBox.merge([update("1", v: 2)], into: &s, now: Date())
        NoticeBox.merge([update("2", v: 3)], into: &s, now: Date())
        XCTAssertEqual(s.map(\.notice.version), [3])
    }

    func testAnUpdateIsOnlyOfferedForSomethingThePersonStillHas() {
        let r = UUID()
        var s: [StoredNotice] = []
        NoticeBox.merge([update("1", v: 2), update("2", v: 2, setup: "other"), removed], into: &s, now: Date())
        let takes = [TakeRecord(picklsssId: "w", title: "Quiet desk", handle: "ana", recipeID: r, takenAt: Date(), counted: false)]
        XCTAssertEqual(NoticeBox.visible(s, takes: takes, recipeIDs: [r]).map(\.id), ["1", "9"])
        XCTAssertEqual(NoticeBox.visible(s, takes: takes, recipeIDs: []).map(\.id), ["9"], "the recipe was deleted: no offer, but the news stays")
    }

    func testPutBackIsOfferedOnlyWhenTheSettingsFromBeforeAreStillHeld() {
        let r = UUID()
        var t = TakeRecord(picklsssId: "gone", title: "Movie night", handle: "x", recipeID: r, takenAt: Date(), counted: false, before: ["audio": Data("a".utf8)])
        XCTAssertTrue(NoticeBox.canPutBack(removed, takes: [t], recipeIDs: [r]))
        XCTAssertFalse(NoticeBox.canPutBack(removed, takes: [t], recipeIDs: []))
        t.before = [:]
        XCTAssertFalse(NoticeBox.canPutBack(removed, takes: [t], recipeIDs: [r]))
        XCTAssertFalse(NoticeBox.canPutBack(update("1", v: 2), takes: [t], recipeIDs: [r]))
        XCTAssertFalse(NoticeBox.canPutBack(removed, takes: [], recipeIDs: [r]))
    }
}

final class ShareFieldTests: XCTestCase {
    func testHandleRules() {
        XCTAssertNil(ShareFields.handleProblem("ana.kitchen")); XCTAssertNil(ShareFields.handleProblem(" Ana_2 "))
        XCTAssertNotNil(ShareFields.handleProblem("ab")); XCTAssertNotNil(ShareFields.handleProblem(String(repeating: "a", count: 21)))
        XCTAssertNotNil(ShareFields.handleProblem("ana kitchen")); XCTAssertNotNil(ShareFields.handleProblem("ana@home")); XCTAssertNotNil(ShareFields.handleProblem("aña"))
        XCTAssertEqual(ShareFields.normalizedHandle(" Ana.K "), "ana.k")
    }
    func testTitleAndLine() {
        XCTAssertNil(ShareFields.titleProblem("Quiet desk")); XCTAssertNotNil(ShareFields.titleProblem("  ")); XCTAssertNotNil(ShareFields.titleProblem(String(repeating: "x", count: 61)))
        XCTAssertNil(ShareFields.lineProblem("Low volume")); XCTAssertNotNil(ShareFields.lineProblem("")); XCTAssertNotNil(ShareFields.lineProblem(String(repeating: "x", count: 161)))
    }
    func testTheDigestChangesWithTheDocument() {
        let a = Personal.setup().json
        var b = Personal.setup(); b.line = "Another line"
        XCTAssertEqual(ShareDigest.of(a), ShareDigest.of(Personal.setup().json))
        XCTAssertNotEqual(ShareDigest.of(a), ShareDigest.of(b.json))
        XCTAssertEqual(ShareDigest.of(setup: b), ShareDigest.of(setup: Personal.setup()), "a new one-line description is not a change to the setup")
        var c = Personal.setup(); c.settings["windows"] = .object(["gap": .int(99)])
        XCTAssertNotEqual(ShareDigest.of(setup: c), ShareDigest.of(setup: Personal.setup()))
    }
}

// MARK: Fit on the shelf and in the review

final class ShelfFitTests: XCTestCase {
    func card(_ id: String, gear: [(String, String)], keeps: Int = 0) -> ShelfCard {
        ShelfCard(id: id, title: id, line: "", parts: ["audio"], gear: gear.map { SharedGear(role: $0.0, model: $0.1) }, cook: ShelfCook(handle: "h"), keeps: keeps)
    }
    let mine = [Personal.rxSpeaker, Personal.rxMic, Personal.rxMonitor]

    func testSummaryComparesModelsIgnoringCaseAndKindsLoosely() {
        let s = ShelfRanking.summary(card("a", gear: [("speakers", "EDIFIER r1280"), ("microphone", "RØDE PodMic"), ("mouse", "MX Master 3S")]), gear: mine)
        XCTAssertEqual(s.perItem, [.have, .sameKind, .missing])
        XCTAssertEqual(s.label, "Fits 1 of 3"); XCTAssertEqual(s.tone, .good)
        XCTAssertEqual(ShelfRanking.summary(card("b", gear: [("monitor", "S34CG50"), ("speaker", "Edifier R1280")]), gear: mine).label, "Fits all 2")
        XCTAssertEqual(ShelfRanking.summary(card("c", gear: [("speaker", "Bose")]), gear: mine).label, "Same kind of gear")
        XCTAssertEqual(ShelfRanking.summary(card("d", gear: [("mouse", "MX")]), gear: mine).label, "Not for your gear")
        XCTAssertEqual(ShelfRanking.summary(card("e", gear: []), gear: mine).label, "Not tied to gear")
    }

    func testForYourGearPutsTheBestFirstAndGreysWhatFitsNothingAtTheBottomInsteadOfHidingIt() {
        let cards = [card("none", gear: [("mouse", "MX")], keeps: 900), card("one", gear: [("speaker", "Edifier R1280")], keeps: 5),
                     card("two", gear: [("speaker", "Edifier R1280"), ("microphone", "Shure MV7")], keeps: 1), card("kind", gear: [("speaker", "Bose")], keeps: 3),
                     card("free", gear: [], keeps: 2)]
        let r = ShelfRanking.forYourGear(cards, gear: mine)
        XCTAssertEqual(r.fitting.map(\.id), ["two", "one", "kind", "free"])
        XCTAssertEqual(r.others.map(\.id), ["none"], "shown, not hidden")
        XCTAssertTrue(r.others[0].summary.fitsNothing)
    }

    func testPopularAndNewKeepTheShelfsOrder() {
        let cards = [card("b", gear: []), card("a", gear: [("speaker", "Edifier R1280")])]
        XCTAssertEqual(ShelfRanking.inShelfOrder(cards, gear: mine).map(\.id), ["b", "a"])
    }

    func testLinesAreLabelledAgainstYourGearWithTheGearScansWords() {
        let setup = Personal.setup()
        let plan = SharedSetupFit.plan(setup, for: Personal.env())
        let labels = Dictionary(uniqueKeysWithValues: plan.lines.map { ($0.id, TakeFit.fit(of: $0, in: plan)) })
        XCTAssertEqual(labels["windows"], .tested, "an app feature that needs no gear")
        // A speaker that is not the author's: the curve is off, which reads "Not on this setup".
        let bose = DeviceSignature(kind: .audioOutput, key: "RX-BOSE", name: "Bose Mini II")
        let p2 = SharedSetupFit.plan(setup, for: Personal.env(gear: [bose, Personal.rxMic, Personal.rxMonitor, Personal.rxMouse]))
        let curve = p2.line("audio.equalizer")!
        XCTAssertTrue(curve.state.isOff)
        XCTAssertEqual(TakeFit.fit(of: curve, in: p2), .unavailable)
        XCTAssertEqual(Fit.unavailable.label, "Not on this setup")
        // Gear the app was not developed on is "Should work, untested", never "Tested".
        let line = plan.line("microphone.chain")!
        XCTAssertEqual(TakeFit.fit(of: line, in: plan), .untested)
        let podmic = DeviceSignature(kind: .audioInput, key: "RX-POD", name: "RØDE PodMic USB")
        XCTAssertNotEqual(plan.matches.first { $0.author.role == "microphone" }?.receiver?.model, podmic.model)
    }

    func testReviewShowsWhatEachLineWouldChangeBeforeAndAfter() {
        let setup = Personal.setup()
        let env = Personal.env()
        let plan = SharedSetupFit.plan(setup, for: env)
        let changes = SetupDiff.lineChanges(setup: setup, plan: plan, env: env)
        let windows = changes["windows"]!
        XCTAssertFalse(windows.isNoChange, "the receiver's gap is 2 and the setup's is 8")
        XCTAssertTrue(windows.examples.contains { $0.contains("gap") && $0.contains("2 → 8") }, "\(windows.examples)")
        XCTAssertLessThanOrEqual(windows.examples.count, SetupDiff.limit)
        // A line that is switched off has nothing to review.
        var off = plan
        off.lines = plan.lines.map { var l = $0; if l.id == "windows" { l.state = .off("x") }; return l }
        XCTAssertNil(SetupDiff.lineChanges(setup: setup, plan: off, env: env)["windows"])
        XCTAssertEqual(SetupDiff.words("eq.defaultProfile.bands[3].gainDB"), "eq › default profile › bands 4 › gain dB")
    }
}

// MARK: Did it work?

final class TakeReportTests: XCTestCase {
    let scan = GearScan(mac: GearScan.Mac(model: "Mac14,2", appleSilicon: true, os: "27.2"))

    func testTheReportHoldsModelsAndResultsAndNothingPersonal() {
        let setup = Personal.setup()
        let env = Personal.env()
        let plan = SharedSetupFit.plan(setup, for: env)
        let on = Set(plan.lines.filter { !$0.state.isOff }.map(\.id))
        let json = TakeReport.json(app: "0.9.0", scan: scan, plan: plan, switchedOn: on, outcome: .works).text
        for secret in ["SECRET", "/Users/", "Ana", "RX-SPK", "RX-MIC", "EDID", "uid", "serial"] { XCTAssertFalse(json.contains(secret), secret) }
        let p = TakeReport.payload(app: "0.9.0", scan: scan, plan: plan, switchedOn: on, outcome: .works)
        XCTAssertEqual(p["kind"] as? String, "mac")
        XCTAssertEqual(Set(p.keys), ["kind", "app", "mac", "gear", "lines", "off"], "the same shape as the gear scan's report")
        let lines = p["lines"] as! [[String: Any]]
        XCTAssertTrue(lines.allSatisfy { $0["fit"] as? String == "works" || ($0["on"] as? Bool) == false })
        XCTAssertTrue(lines.allSatisfy { ($0["id"] as! String).split(separator: ".").count <= 2 }, "only the rule name leaves the Mac")
    }

    func testSomethingIsOffDoesNotBlameALine() {
        let setup = Personal.setup()
        let plan = SharedSetupFit.plan(setup, for: Personal.env())
        let p = TakeReport.payload(app: "0.9.0", scan: scan, plan: plan, switchedOn: Set(plan.lines.map(\.id)), outcome: .somethingOff)
        let fits = (p["lines"] as! [[String: Any]]).compactMap { $0["fit"] as? String }
        XCTAssertFalse(fits.contains("works")); XCTAssertFalse(fits.contains("no"))
        XCTAssertTrue(TakeReport.text(app: "0.9.0", scan: scan, plan: plan, switchedOn: [], outcome: .works).hasPrefix("Whoprrr 0.9.0 · Mac14,2"))
    }

    func testCookinTakesAboutASecondInAll() {
        XCTAssertEqual(CookinBeats.beats(parts: 4).reduce(0, +), 1.0, accuracy: 0.001)
        XCTAssertEqual(CookinBeats.beats(parts: 1), [1.0]); XCTAssertEqual(CookinBeats.beats(parts: 0), [])
    }
}


final class RequirementsTests: XCTestCase {
    func testRequirementsAreListedBeforeAnythingStarts() {
        let need = SharedRequirements(plugins: ["Pro-Q 3", "TDR Nova"], minMacOS: "14.2", permissions: ["microphone", "accessibility", "camera", "bogus"])
        let env = ReceiverEnvironment(plugins: [Personal.proQ], macOS: "14.1", permissions: [.microphone: .granted, .accessibility: .denied])
        let rows = Requirements.rows(need, env: env)
        XCTAssertEqual(rows.map(\.status), [.ready, .missing, .missing, .ready, .missing, .ask])
        XCTAssertEqual(rows[1].pluginName, "TDR Nova"); XCTAssertTrue(rows[1].detail.contains("never installs plugins"))
        XCTAssertEqual(rows.count, 6, "a permission this version does not know is not listed")
    }
    func testVersionsCompareNumbers() {
        XCTAssertTrue(Requirements.atLeast("27.2", "14")); XCTAssertTrue(Requirements.atLeast("14.2", "14.2")); XCTAssertFalse(Requirements.atLeast("14.1", "14.2"))
        XCTAssertFalse(Requirements.atLeast("9.9", "10")); XCTAssertTrue(Requirements.atLeast("15", "14.9"))
    }
    func testNothingNeededMeansNoRows() { XCTAssertEqual(Requirements.rows(SharedRequirements(), env: ReceiverEnvironment()), []) }
}
