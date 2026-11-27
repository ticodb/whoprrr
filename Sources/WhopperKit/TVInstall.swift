import CryptoKit
import Darwin
import Foundation

/// The ADB address of the selected TV. Discovery and manual entry both use the TV's TCP port 5555.
public struct TVAddress: Equatable, Hashable, Sendable {
    public let host: String
    public static let port: UInt16 = 5555

    public init?(_ text: String) {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let tail = host[host.index(after: close)...]
            guard tail.isEmpty || tail == ":5555" else { return nil }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if host.filter({ $0 == ":" }).count == 1, host.hasSuffix(":5555") {
            host.removeLast(5)
        }
        guard !host.isEmpty, host.utf8.count <= 254 else { return nil }
        if host.contains(":") {
            let parts = host.split(separator: "%", omittingEmptySubsequences: false)
            let scope = parts.count == 2 ? String(parts[1]) : nil
            guard parts.count <= 2, scope.map(Self.validLabel) ?? true else { return nil }
            var ip = in6_addr()
            guard inet_pton(AF_INET6, String(parts[0]), &ip) == 1 else { return nil }
        } else {
            let labels = host.trimmingSuffixDot.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.allSatisfy({ Self.validLabel(String($0)) }) else { return nil }
            if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                var ip = in_addr()
                guard inet_pton(AF_INET, host, &ip) == 1 else { return nil }
            }
        }
        self.host = host
    }

    public var serial: String { host.contains(":") ? "[\(host)]:\(Self.port)" : "\(host):\(Self.port)" }

    private static func validLabel(_ label: String) -> Bool {
        guard let first = label.utf8.first, let last = label.utf8.last, label.utf8.count <= 63,
              first != 45, last != 45 else { return false }
        return label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
}

private extension String {
    var trimmingSuffixDot: Substring { hasSuffix(".") ? dropLast() : self[...] }
}

public struct TVAnnouncement: Equatable, Sendable {
    public var id: String
    public var name: String
    /// An announcement may exist before the host has resolved. A TV can advertise both IPv4 and IPv6.
    public var addresses: [TVAddress]

    public init(id: String, name: String, addresses: [TVAddress]) {
        self.id = id
        self.name = name
        self.addresses = addresses
    }
}

public struct DiscoveredTV: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var address: TVAddress?
    public var isReady: Bool
}

public protocol TVPortProbing: Sendable {
    func isOpen(_ address: TVAddress) async -> Bool
}

public enum TVDiscovery {
    public static func check(_ announcements: [TVAnnouncement], using network: any TVPortProbing) async -> [DiscoveredTV] {
        await withTaskGroup(of: DiscoveredTV.self) { group in
            for tv in announcements {
                group.addTask {
                    for address in tv.addresses where !Task.isCancelled {
                        if await network.isOpen(address) {
                            return DiscoveredTV(id: tv.id, name: tv.name, address: address, isReady: true)
                        }
                    }
                    return DiscoveredTV(id: tv.id, name: tv.name, address: tv.addresses.first, isReady: false)
                }
            }
            var results: [DiscoveredTV] = []
            for await tv in group { results.append(tv) }
            return results.sorted {
                let name = $0.name.localizedStandardCompare($1.name)
                return name == .orderedSame ? $0.id < $1.id : name == .orderedAscending
            }
        }
    }
}

public struct TVRelease: Decodable, Equatable, Sendable {
    public let product: String
    public let versionName: String
    public let url: URL
    public let sha256: String
    public let size: Int?

    public var filename: String { url.lastPathComponent }
    public static let maxSize = 262_144_000

    public func validate(for site: URL) throws {
        let file = filename.utf8
        let goodFilename = file.count < 120 && filename.hasPrefix("whoprrr-tv-") && filename.hasSuffix(".apk")
            && file.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }
        let digest = sha256.lowercased().utf8
        guard product == "whoprrr-tv", !versionName.isEmpty, versionName.count < 50,
              url.scheme == site.scheme, url.host == site.host, url.port == site.port, url.user == nil, url.password == nil,
              url.path == "/tv/\(filename)", url.query == nil, url.fragment == nil, goodFilename,
              digest.count == 64, digest.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              size.map({ (1...262_144_000).contains($0) }) ?? true else { throw TVInstallError.badRelease }
    }

    public func verify(_ file: URL) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        var count = 0
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            count += bytes.count
            guard count <= 262_144_000 else { throw TVInstallError.badChecksum }
            hash.update(data: bytes)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard size.map({ $0 == count }) ?? true, actual == sha256.lowercased() else { throw TVInstallError.badChecksum }
    }
}

public struct TVCommandOutput: Equatable, Sendable {
    public var status: Int32
    public var text: String

    public init(status: Int32, text: String) { self.status = status; self.text = text }
}

public protocol TVProcessRunning: Sendable {
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> TVCommandOutput
}

@MainActor
public protocol TVInstallNetwork {
    func release() async throws -> TVRelease
    func download(_ release: TVRelease) async throws -> URL
    func setupCode() async throws -> String
}

public enum TVAuthorization: Equatable, Sendable { case ready, waiting, rejected, unreachable }

public enum TVADBReply {
    public static func authorization(_ result: TVCommandOutput) -> TVAuthorization {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lines = text.split(whereSeparator: \.isNewline)
        if result.status == 0 && lines.contains(where: { $0 == "device" || $0.hasPrefix("connected to ") || $0.hasPrefix("already connected to ") }) {
            return .ready
        }
        if text.contains("connection rejected") || text.contains("authorization denied") || text.contains("user denied") {
            return .rejected
        }
        if text.contains("unauthorized") || text.contains("authenticate") || text.contains("authorizing") || text.contains("offline") {
            return .waiting
        }
        return .unreachable
    }

    public static func installed(_ output: TVCommandOutput) -> Bool {
        output.status == 0 && output.text.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "Success" }
    }

    public static func launched(_ output: TVCommandOutput) -> Bool {
        let text = output.text.lowercased()
        return output.status == 0 && !text.contains("error:") && !text.contains("error type") &&
            !text.contains("exception") && text.contains("starting: intent")
    }
}

public enum TVInstallStep: Equatable, Sendable {
    case approved, verifying, installing(version: String), installed(version: String), activating(version: String), opened(version: String)
}

public enum TVInstallError: LocalizedError, Equatable, Sendable {
    case badRelease, badChecksum, installFailed, launchFailed, noSetupCode, timedOut, tools, service(String)

    public var errorDescription: String? {
        switch self {
        case .badRelease: "Whoprrr couldn’t read the current TV release. Try again in a few minutes."
        case .badChecksum: "The download didn’t match the published checksum. Nothing was installed."
        case .installFailed: "The TV couldn’t install Whoprrr. Keep it on and try again."
        case .launchFailed: "Whoprrr TV was installed. The Mac couldn’t open it. Try again or open Whoprrr on the TV."
        case .noSetupCode: "The Mac couldn’t get a setup code. Try again or open Whoprrr on the TV."
        case .timedOut: "The TV took too long to answer. Check that it’s on, then try again."
        case .tools: "Google’s platform-tools couldn’t be set up. Check your connection and try again."
        case .service(let message): message
        }
    }
}

@MainActor
public struct TVInstaller {
    public static let component = "gg.tico.whoprrr.tv/dev.tvcontrol.MainActivity"

    private let adb: URL
    private let process: any TVProcessRunning
    private let network: any TVInstallNetwork

    public init(adb: URL, process: any TVProcessRunning, network: any TVInstallNetwork) {
        self.adb = adb
        self.process = process
        self.network = network
    }

    public func ask(_ address: TVAddress, again: Bool = false) async throws -> TVAuthorization {
        if again {
            _ = try await process.run(adb, arguments: ["disconnect", address.serial], timeout: 6)
        }
        let result = try await process.run(adb, arguments: ["connect", address.serial], timeout: 12)
        let state = TVADBReply.authorization(result)
        if state == .ready { return try await authorization(address) }
        return state
    }

    public func authorization(_ address: TVAddress) async throws -> TVAuthorization {
        TVADBReply.authorization(try await run(address, ["get-state"], timeout: 6))
    }

    /// The UI calls this after ADB reports an authorized device. All commands after that target this serial.
    public func install(on address: TVAddress, report: (TVInstallStep) -> Void) async throws {
        try Task.checkCancellation()
        report(.approved)
        let release = try await network.release()
        report(.verifying)
        let file = try await network.download(release)
        defer { try? FileManager.default.removeItem(at: file) }
        try await Task.detached { try release.verify(file) }.value
        try Task.checkCancellation()
        report(.installing(version: release.versionName))
        let installed = try await run(address, ["install", "-r", file.path], timeout: 120)
        guard TVADBReply.installed(installed) else { throw TVInstallError.installFailed }
        report(.installed(version: release.versionName))
        try Task.checkCancellation()
        report(.activating(version: release.versionName))
        guard let code = SetupCode.normalize(try await network.setupCode()) else { throw TVInstallError.noSetupCode }
        try Task.checkCancellation()
        let launched = try await run(address, ["shell", "am", "start", "-n", Self.component, "--es", "setup_code", code], timeout: 15)
        guard TVADBReply.launched(launched) else { throw TVInstallError.launchFailed }
        report(.opened(version: release.versionName))
    }

    private func run(_ address: TVAddress, _ args: [String], timeout: TimeInterval) async throws -> TVCommandOutput {
        try await process.run(adb, arguments: ["-s", address.serial] + args, timeout: timeout)
    }
}

/// Google's SDK repository manifest (repository2-3.xml) lists each platform-tools archive with its size and SHA-1.
/// The macOS archive is pinned to that entry before anything in it runs.
public struct PlatformToolsArchive: Equatable, Sendable {
    public static let repository = URL(string: "https://dl.google.com/android/repository/")!
    public static let manifest = URL(string: "https://dl.google.com/android/repository/repository2-3.xml")!
    /// Google LLC's Developer ID team. The extracted adb must carry this signature.
    public static let codeRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "EQHXZ8M8AV""#
    public static let maxSize = 104_857_600

    public let file: String
    public let size: Int
    public let sha1: String

    public var url: URL { Self.repository.appendingPathComponent(file) }

    public init?(file: String, size: Int, sha1: String) {
        let name = file.utf8
        let digest = sha1.lowercased()
        guard file.hasPrefix("platform-tools_r"), file.hasSuffix("-darwin.zip"), name.count < 80,
              name.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }),
              (1...Self.maxSize).contains(size),
              digest.utf8.count == 40, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.file = file
        self.size = size
        self.sha1 = digest
    }

    /// The macOS archive of the `platform-tools` package, or nil when the manifest has none that passes the checks.
    public static func fromManifest(_ data: Data) -> PlatformToolsArchive? {
        let reader = ManifestReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { return nil }
        return reader.found
    }

    public func verify(_ file: URL) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = Insecure.SHA1()
        var count = 0
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            count += bytes.count
            guard count <= size else { throw TVInstallError.tools }
            hash.update(data: bytes)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == size, actual == sha1 else { throw TVInstallError.tools }
    }
}

private final class ManifestReader: NSObject, XMLParserDelegate {
    var found: PlatformToolsArchive?
    private var inPackage = false
    private var path: [String] = []
    private var text = ""
    private var size: Int?, sha1: String?, file: String?, host: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(name)
        text = ""
        if name == "remotePackage" { inPackage = attributes["path"] == "platform-tools" }
        if inPackage && name == "archive" { size = nil; sha1 = nil; file = nil; host = nil }
        if inPackage && name == "checksum" && attributes["type"] != "sha1" { sha1 = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast(); text = "" }
        guard inPackage else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inComplete = path.dropLast().last == "complete"
        switch name {
        case "size" where inComplete: size = Int(value)
        case "checksum" where inComplete: if sha1 == nil { sha1 = value } else { sha1 = nil }
        case "url" where inComplete: file = value
        case "host-os": host = value
        case "archive":
            if found == nil, host == "macosx", let file, let size, let sha1 {
                found = PlatformToolsArchive(file: file, size: size, sha1: sha1)
            }
        case "remotePackage": inPackage = false
        default: break
        }
    }
}
