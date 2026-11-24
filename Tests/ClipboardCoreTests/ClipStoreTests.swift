import XCTest
@testable import ClipboardCore

final class ClipStoreTests: XCTestCase {
    func makeStore() throws -> ClipStore {
        try ClipStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("whopper-clip-\(UUID().uuidString)"))
    }
    func text(_ s: String, app: String? = "Safari") -> ClipCapture { ClipCapture(kind: .text, text: s, sourceApp: app, sourceBundle: "com.apple.Safari") }

    func testAddListNewestFirstAndDedupMovesToTop() throws {
        let s = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1000)
        s.add(text("one"), now: t0); s.add(text("two"), now: t0 + 1); s.add(text("three"), now: t0 + 2)
        XCTAssertEqual(s.list().map(\.preview), ["three", "two", "one"])
        s.add(text("one"), now: t0 + 3)                       // copied again
        XCTAssertEqual(s.list().map(\.preview), ["one", "three", "two"])
        XCTAssertEqual(s.count(), 3)
        XCTAssertEqual(s.list().first?.useCount, 2)
    }

    func testSearchIsCaseAccentAndSubstringInsensitiveAndMultiTerm() throws {
        let s = try makeStore()
        s.add(text("Café Müller invoice 42")); s.add(text("shopping list")); s.add(text("Invoice 43 from ACME", app: "Mail"))
        XCTAssertEqual(s.list(query: "cafe").count, 1)
        XCTAssertEqual(s.list(query: "NVOICE").count, 2)
        XCTAssertEqual(s.list(query: "invoice acme").count, 1)
        XCTAssertEqual(s.list(query: "mail").count, 1)           // matches the source app
        XCTAssertEqual(s.list(query: "100%").count, 0)           // wildcard characters are literal
    }

    func testPinnedSortFirstAndFilters() throws {
        let s = try makeStore()
        let a = s.add(text("old pinned"), now: Date(timeIntervalSince1970: 1))!
        s.add(text("new"), now: Date(timeIntervalSince1970: 100))
        s.add(ClipCapture(kind: .files, text: nil, files: ["/tmp/a.txt"]), now: Date(timeIntervalSince1970: 101))
        s.setPinned(a, true)
        XCTAssertEqual(s.list().first?.id, a)
        XCTAssertEqual(s.list(filter: .pinned).count, 1)
        XCTAssertEqual(s.list(filter: .files).first?.files, ["/tmp/a.txt"])
        XCTAssertEqual(s.list(filter: .text).count, 2)
    }

    func testImageStoredAsFileAndRemovedOnDelete() throws {
        let s = try makeStore()
        let id = s.add(ClipCapture(kind: .image, imageData: Data([1, 2, 3, 4])))!
        let file = s.list().first!.imageFile!
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.imagesDir.appendingPathComponent(file).path))
        s.delete(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.imagesDir.appendingPathComponent(file).path))
        XCTAssertEqual(s.count(), 0)
    }

    func testPrunePreservesPinnedAndDropsOldAndExcess() throws {
        let s = try makeStore()
        let now = Date(timeIntervalSince1970: 10_000_000)
        let pinned = s.add(text("keep me"), now: now - 90 * 86_400)!; s.setPinned(pinned, true)
        s.add(text("ancient"), now: now - 60 * 86_400)
        for i in 0..<5 { s.add(text("recent \(i)"), now: now - Double(i)) }
        s.prune(maxItems: 3, maxAgeDays: 30, now: now)
        let left = s.list().map(\.preview)
        XCTAssertEqual(left.count, 4)
        XCTAssertTrue(left.contains("keep me")); XCTAssertFalse(left.contains("ancient"))
    }

    func testSnippetsArePinnedWithTitleAndSearchable() throws {
        let s = try makeStore()
        let id = s.addSnippet(title: "Email sig", text: "Best,\nAlex")!
        let item = s.list(filter: .pinned).first!
        XCTAssertEqual(item.id, id); XCTAssertTrue(item.isSnippet); XCTAssertEqual(item.title, "Email sig")
        XCTAssertEqual(s.list(query: "sig").count, 1)
        XCTAssertEqual(s.payload(id)?.text, "Best,\nAlex")
    }

    func testRichPayloadRoundTrip() throws {
        let s = try makeStore()
        let id = s.add(ClipCapture(kind: .text, text: "bold", rtf: Data("rtf".utf8), html: Data("<b>bold</b>".utf8)))!
        let p = s.payload(id)!
        XCTAssertEqual(p.rtf, Data("rtf".utf8)); XCTAssertEqual(p.html, Data("<b>bold</b>".utf8))
        XCTAssertTrue(s.list().first!.hasRich)
    }

    func testClearUnpinnedKeepsPinned() throws {
        let s = try makeStore()
        let a = s.add(text("a"))!; s.add(text("b")); s.setPinned(a, true)
        s.clearUnpinned()
        XCTAssertEqual(s.list().map(\.preview), ["a"])
    }

    func testCaptureRulesSkipPasswordManagersAndIgnoredApps() {
        let st = ClipboardSettings()
        XCTAssertTrue(CaptureRules.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], frontBundle: nil, settings: st))
        XCTAssertTrue(CaptureRules.shouldSkip(types: ["public.utf8-plain-text"], frontBundle: "com.bitwarden.desktop", settings: st))
        XCTAssertFalse(CaptureRules.shouldSkip(types: ["public.utf8-plain-text"], frontBundle: "com.apple.Safari", settings: st))
    }
}
