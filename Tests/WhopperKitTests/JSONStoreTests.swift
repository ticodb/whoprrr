import XCTest
@testable import WhopperKit

final class JSONStoreTests: XCTestCase {
    struct Doc: Codable, Equatable, Sendable { var n: Int }
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("whopper-\(UUID().uuidString)/d.json") }

    func testRoundTripAndDefault() {
        let s = JSONStore<Doc>(url: tmp())
        XCTAssertEqual(s.load(default: Doc(n: 1)), Doc(n: 1))
        XCTAssertTrue(s.save(Doc(n: 7)))
        XCTAssertEqual(s.load(default: Doc(n: 1)), Doc(n: 7))
    }
    func testCorruptFileIsKeptAside() throws {
        let u = tmp(); let s = JSONStore<Doc>(url: u)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: u)
        XCTAssertEqual(s.load(default: Doc(n: 3)), Doc(n: 3))
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.appendingPathExtension("bad").path))
    }
}
