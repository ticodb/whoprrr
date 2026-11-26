import XCTest
@testable import WhopperKit

/// The format document and the code say the same thing.
final class SharedSetupDocsTests: XCTestCase {
    var doc: String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("docs/shared-setup-format.md"), encoding: .utf8)) ?? ""
    }

    func testTheDocumentIsThere() { XCTAssertGreaterThan(doc.count, 5000) }

    func testTheCompleteExampleIsTheFullExampleVector() throws {
        let tail = try XCTUnwrap(doc.range(of: "## 12. A complete example").map { String(doc[$0.upperBound...]) })
        let start = try XCTUnwrap(tail.range(of: "```json\n")), end = try XCTUnwrap(tail.range(of: "\n```", range: start.upperBound..<tail.endIndex))
        let block = String(tail[start.upperBound..<end.lowerBound])
        XCTAssertEqual(JSONValue.parse(Data(block.utf8)), SharedVectors.document("full-example"))
        XCTAssertTrue(SharedSetupLimits.check(value: JSONValue.parse(Data(block.utf8))!).ok)
    }

    func testEveryRuleNameIsExplained() {
        for r in SharedSetupTable.ruleNames { XCTAssertTrue(doc.contains("`\(r)`"), "the format document does not explain `\(r)`") }
    }

    func testTheOwnersNumbersAreInTheDocument() {
        for n in ["+6 dB", "-50 dBFS", "15 to 2000 Hz", "-1 dB", "64 KB", "65536", "1 to 60", "1 to 160", "more than 40", "5.4 dB", "-54 dBFS"] {
            XCTAssertTrue(doc.contains(n), "missing “\(n)”")
        }
    }

    func testTheTableAndTheDocumentAgreeOnTheNumbers() {
        XCTAssertEqual(SharedSetupTable.maxBoostDB, 6); XCTAssertEqual(SharedSetupTable.keepAwakeLevelMaxDB, -50)
        XCTAssertEqual(SharedSetupTable.keepAwakeHz.lo, 15); XCTAssertEqual(SharedSetupTable.keepAwakeHz.hi, 2000)
        XCTAssertEqual(SharedSetupTable.limiterCeilingMaxDB, -1); XCTAssertEqual(SharedSetupTable.maxBytes, 65536)
        XCTAssertEqual(SharedSetupTable.titleMax, 60); XCTAssertEqual(SharedSetupTable.lineMax, 160); XCTAssertEqual(SharedSetupTable.unusualKeyRules, 40)
        XCTAssertEqual(SharedSetupTable.maxBoostDB - SharedSetupTable.unusualFraction * SharedSetupTable.maxBoostDB, 5.4, accuracy: 1e-9)
    }

    func testEveryCommandAndEveryDefaultIgnoredAppIsNamed() {
        for c in SharedSetupTable.commands where !c.hasPrefix("window.") { XCTAssertTrue(doc.contains(c), c) }
        for a in SharedSetupTable.clipboardDefaultIgnored { XCTAssertTrue(doc.contains(a), a) }
        for a in SharedSetupTable.windowActions { XCTAssertTrue(doc.contains(a), a) }
    }

    func testEveryVectorNamedInTheDocumentExists() throws {
        let names = Set(SharedVectors.load().map(\.name))
        let section = try XCTUnwrap(doc.range(of: "## 11. Test vectors").map { String(doc[$0.upperBound...]) })
        var checked = 0
        for line in section.split(separator: "\n") where line.hasPrefix("| `") {
            let cell = line.dropFirst(2).prefix(while: { $0 != "|" })
            for part in cell.split(separator: "`", omittingEmptySubsequences: false).enumerated() where part.offset % 2 == 1 {
                XCTAssertTrue(names.contains(String(part.element)), "the document names a vector that does not exist: \(part.element)"); checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 20)
    }

    func testTheVectorCountIsStatedRight() {
        XCTAssertTrue(doc.contains("The file has \(SharedVectors.load().count) vectors"))
    }
}
