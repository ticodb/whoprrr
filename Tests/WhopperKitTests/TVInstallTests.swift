import CryptoKit
import XCTest
@testable import WhopperKit

@MainActor
final class TVInstallTests: XCTestCase {
    private let site = URL(string: "https://whoprrr.app")!
    private let adb = URL(fileURLWithPath: "/fixture/adb")
    private let address = TVAddress("192.168.1.50")!
    private let fixture = Data("example APK".utf8)

    func testSetupLinksAcceptCaseAndDashAndRejectAmbiguity() {
        XCTAssertEqual(SetupCode.fromActivationURL(URL(string: "whoprrr://activate?code=7qk-m2xd")!), "7QK-M2XD")
        XCTAssertEqual(SetupCode.fromActivationURL(URL(string: "WHOPRRR://ACTIVATE?code=7QKM2XD")!), "7QK-M2XD")
        XCTAssertNil(SetupCode.fromActivationURL(URL(string: "https://activate?code=7QK-M2XD")!))
        XCTAssertNil(SetupCode.fromActivationURL(URL(string: "whoprrr://activate?code=7QK-M2XD&code=7QK-M2XD")!))
        XCTAssertNil(SetupCode.fromActivationURL(URL(string: "whoprrr://other?code=7QK-M2XD")!))
        XCTAssertNil(SetupCode.normalize("7QK-M2XO"))
        XCTAssertNil(SetupCode.normalize("7-QKM2XD"))
    }

    func testExpiredCodeShowsServiceMessageAndHasAFallback() {
        let body = Data(#"{"error":"code_expired","message":"Open your order for another link."}"#.utf8)
        XCTAssertEqual(LicenseReplies.activate(status: 410, body: body),
                       .refused(code: "code_expired", message: "Open your order for another link."))
        XCTAssertEqual(LicenseReplies.activate(status: 410, body: nil),
                       .refused(code: "code_expired", message: LicenseReplies.fallback("code_expired")))
    }

    func testAddressesAreValidatedAndSerialUsesFixedPort() {
        XCTAssertEqual(TVAddress(" Living-Room.local. ")?.serial, "living-room.local.:5555")
        XCTAssertEqual(TVAddress("[fe80::1%en0]:5555")?.serial, "[fe80::1%en0]:5555")
        XCTAssertEqual(TVAddress("192.168.1.50:5555")?.serial, address.serial)
        for invalid in ["--help", "https://tv.local", "192.168.1.400", "tv.local:5556", "tv.local;id", "[fe80::1]:22", ""] {
            XCTAssertNil(TVAddress(invalid))
        }
    }

    func testDiscoveryReportsReadyAndKeepsClosedOrUnresolvedTVs() async {
        let closed = TVAddress("192.168.1.51")!
        let announcements = [
            TVAnnouncement(id: "c", name: "Kitchen", addresses: []),
            TVAnnouncement(id: "b", name: "Bedroom", addresses: [closed]),
            TVAnnouncement(id: "a", name: "Den", addresses: [closed, address]),
        ]
        let results = await TVDiscovery.check(announcements, using: PortProbe(open: [address]))
        XCTAssertEqual(results.map(\.name), ["Bedroom", "Den", "Kitchen"])
        XCTAssertEqual(results.map(\.isReady), [false, true, false])
        XCTAssertEqual(results.map(\.address), [closed, address, nil])
    }

    func testADBOutputDistinguishesAuthorizationAndFailures() {
        XCTAssertEqual(TVADBReply.authorization(.init(status: 0, text: "* daemon started successfully\nconnected to tv.local:5555\n")), .ready)
        XCTAssertEqual(TVADBReply.authorization(.init(status: 0, text: "device\n")), .ready)
        XCTAssertEqual(TVADBReply.authorization(.init(status: 0, text: "failed to authenticate to tv.local:5555")), .waiting)
        XCTAssertEqual(TVADBReply.authorization(.init(status: 1, text: "error: device unauthorized")), .waiting)
        XCTAssertEqual(TVADBReply.authorization(.init(status: 1, text: "authorization denied")), .rejected)
        XCTAssertEqual(TVADBReply.authorization(.init(status: 1, text: "connection refused")), .unreachable)
        XCTAssertFalse(TVADBReply.installed(.init(status: 1, text: "Success")))
        XCTAssertFalse(TVADBReply.launched(.init(status: 0, text: "Starting: Intent ...\nError type 3")))
    }

    func testInstallerUsesOnlySelectedTVAndRequestsCodeAfterInstall() async throws {
        let events = EventLog()
        let network = NetworkFixture(published: try release(), file: fixture, events: events)
        let process = ProcessFixture(events: events, replies: [
            .init(status: 0, text: "connected to \(address.serial)"),
            .init(status: 0, text: "device"),
            .init(status: 0, text: "Performing Streamed Install\nSuccess\n"),
            .init(status: 0, text: "Starting: Intent { (has extras) }"),
        ])
        let installer = TVInstaller(adb: adb, process: process, network: network)
        let state = try await installer.ask(address)
        XCTAssertEqual(state, .ready)
        var steps: [TVInstallStep] = []
        try await installer.install(on: address) { steps.append($0) }

        XCTAssertEqual(events.entries, ["connect", "-s", "release", "download", "-s", "code", "-s"])
        let calls = await process.calls
        XCTAssertEqual(calls[0], ["connect", address.serial])
        XCTAssertEqual(calls[1], ["-s", address.serial, "get-state"])
        XCTAssertEqual(Array(calls[2].prefix(4)), ["-s", address.serial, "install", "-r"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls[2][4]))
        XCTAssertEqual(calls[3], ["-s", address.serial, "shell", "am", "start", "-n", TVInstaller.component, "--es", "setup_code", "7QK-M2XD"])
        XCTAssertEqual(steps, [.approved, .verifying, .installing(version: "1.2.1"), .installed(version: "1.2.1"), .activating(version: "1.2.1"), .opened(version: "1.2.1")])
    }

    func testBadDigestStopsBeforeInstallOrSetupCode() async throws {
        let events = EventLog()
        let network = NetworkFixture(published: try release(), file: Data("damaged".utf8), events: events)
        let process = ProcessFixture(events: events, replies: [])
        let installer = TVInstaller(adb: adb, process: process, network: network)
        do {
            try await installer.install(on: address) { _ in }
            XCTFail("The damaged APK was accepted.")
        } catch { XCTAssertEqual(error as? TVInstallError, .badChecksum) }
        XCTAssertEqual(events.entries, ["release", "download"])
    }

    func testAskAgainReconnectsOnlyTheSelectedTV() async throws {
        let events = EventLog()
        let process = ProcessFixture(events: events, replies: [
            .init(status: 0, text: "disconnected"),
            .init(status: 0, text: "failed to authenticate"),
            .init(status: 0, text: "device"),
        ])
        let installer = TVInstaller(adb: adb, process: process, network: NetworkFixture(published: try release(), file: fixture, events: events))
        let waiting = try await installer.ask(address, again: true)
        XCTAssertEqual(waiting, .waiting)
        let ready = try await installer.authorization(address)
        XCTAssertEqual(ready, .ready)
        let calls = await process.calls
        XCTAssertEqual(calls, [["disconnect", address.serial], ["connect", address.serial], ["-s", address.serial, "get-state"]])
    }

    func testManifestRestrictsOriginAndAPKPath() throws {
        XCTAssertNoThrow(try release().validate(for: site))
        XCTAssertThrowsError(try release(url: "https://example.org/tv/whoprrr-tv-1.2.1.apk").validate(for: site))
        XCTAssertThrowsError(try release(url: "https://whoprrr.app/mac/whoprrr-tv-1.2.1.apk").validate(for: site))
        XCTAssertThrowsError(try release(url: "https://whoprrr.app/tv/whoprrr-tv-1.2.1.zip").validate(for: site))
    }

    private func release(url: String = "https://whoprrr.app/tv/whoprrr-tv-1.2.1.apk") throws -> TVRelease {
        let sha = SHA256.hash(data: fixture).map { String(format: "%02x", $0) }.joined()
        let data = try JSONSerialization.data(withJSONObject: [
            "product": "whoprrr-tv", "versionName": "1.2.1", "url": url, "sha256": sha, "size": fixture.count,
        ])
        return try JSONDecoder().decode(TVRelease.self, from: data)
    }

    private struct PortProbe: TVPortProbing {
        var open: Set<TVAddress>
        func isOpen(_ address: TVAddress) async -> Bool { open.contains(address) }
    }

    private actor ProcessFixture: TVProcessRunning {
        var calls: [[String]] = []
        var replies: [TVCommandOutput]
        let events: EventLog

        init(events: EventLog, replies: [TVCommandOutput]) { self.events = events; self.replies = replies }

        func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> TVCommandOutput {
            calls.append(arguments)
            await events.add(arguments[0])
            guard !replies.isEmpty else { throw TVInstallError.tools }
            return replies.removeFirst()
        }
    }

    @MainActor
    private final class EventLog {
        var entries: [String] = []
        func add(_ value: String) { entries.append(value) }
    }

    private struct NetworkFixture: TVInstallNetwork {
        let published: TVRelease
        let file: Data
        let events: EventLog

        func release() async throws -> TVRelease { events.add("release"); return published }
        func download(_ release: TVRelease) async throws -> URL {
            events.add("download")
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".apk")
            try file.write(to: path)
            return path
        }

        func setupCode() async throws -> String { events.add("code"); return "7qkm2xd" }
    }
}
