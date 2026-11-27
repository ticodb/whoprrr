import Darwin
import Foundation
import Security
import WhopperKit

/// Runs only the selected executable with separated arguments, with bounded output and a deadline.
struct TVProcessRunner: TVProcessRunning {
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> TVCommandOutput {
        let command = RunningTVCommand(executable: executable, arguments: arguments)
        let result = Task.detached { try command.run(timeout: timeout) }
        return try await withTaskCancellationHandler {
            try await result.value
        } onCancel: {
            result.cancel()
            command.cancel()
        }
    }
}

private final class RunningTVCommand: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var cancelled = false

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }

    func run(timeout: TimeInterval) throws -> TVCommandOutput {
        try start()
        try? output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        // Keep draining even after reaching the output limit. Don't wait for EOF from an ADB daemon.
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else {
            cancel()
            throw TVInstallError.tools
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)

        while process.isRunning {
            if Task.isCancelled { cancel() }
            if clock.now >= deadline || Task.isCancelled {
                stop()
                if Task.isCancelled { throw CancellationError() }
                throw TVInstallError.timedOut
            }
            drain(fd, buffer: &buffer, data: &data)
            Thread.sleep(forTimeInterval: 0.025)
        }
        drain(fd, buffer: &buffer, data: &data)
        try Task.checkCancellation()
        return TVCommandOutput(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }

    private func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !Task.isCancelled else { throw CancellationError() }
        try process.run()
    }

    private func stop() {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning { process.terminate() }
        for _ in 0..<10 where process.isRunning { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func drain(_ fd: Int32, buffer: inout [UInt8], data: inout Data) {
        for _ in 0..<16 {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return }
            data.append(contentsOf: buffer.prefix(min(n, 65_536 - data.count)))
        }
    }
}

enum TVPlatformTools {
    private static var directory: URL { JSONStore<SetupProgress>.directory().appendingPathComponent("TV", isDirectory: true) }
    static var cached: URL { directory.appendingPathComponent("platform-tools/adb") }

    /// adb the person already has (PATH, SDK, Homebrew), else Whoprrr's private copy if it still carries Google's signature.
    static func installedADB() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = (env["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/adb" }
        let sdk = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"]].compactMap { $0 }.filter { $0.hasPrefix("/") }.map { $0 + "/platform-tools/adb" }
        let common = [home.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path,
                      home.appendingPathComponent("Android/Sdk/platform-tools/adb").path,
                      "/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/opt/local/bin/adb"]
        if let local = (path + sdk + common).first(where: FileManager.default.isExecutableFile(atPath:)) { return URL(fileURLWithPath: local) }
        return FileManager.default.isExecutableFile(atPath: cached.path) && signedByGoogle(cached) ? cached : nil
    }

    /// The Developer ID signature of Google LLC, checked with the Security framework.
    static func signedByGoogle(_ file: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(PlatformToolsArchive.codeRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    /// Downloads Google's macOS platform-tools, pinned to the size and SHA-1 in Google's repository manifest, and keeps
    /// adb only if it carries Google's Developer ID signature.
    static func getADB(using process: any TVProcessRunning) async throws -> URL {
        if let local = installedADB() { return local }
        let fm = FileManager.default
        let (listing, listed) = try await URLSession.shared.data(for: URLRequest(url: PlatformToolsArchive.manifest, timeoutInterval: 30))
        guard (listed as? HTTPURLResponse)?.statusCode == 200, listed.url?.host == "dl.google.com",
              let archive = PlatformToolsArchive.fromManifest(listing) else { throw TVInstallError.tools }
        try Task.checkCancellation()
        let staging = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let (download, response) = try await URLSession.shared.download(for: URLRequest(url: archive.url, timeoutInterval: 120))
        defer { try? fm.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https",
              response.url?.host == "dl.google.com" else { throw TVInstallError.tools }
        try await Task.detached { try archive.verify(download) }.value
        try Task.checkCancellation()
        let output = try await process.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                           arguments: ["-x", "-k", download.path, staging.path], timeout: 30)
        let extracted = staging.appendingPathComponent("platform-tools", isDirectory: true)
        let adb = extracted.appendingPathComponent("adb")
        guard output.status == 0, fm.isExecutableFile(atPath: adb.path), signedByGoogle(adb) else { throw TVInstallError.tools }
        try Task.checkCancellation()
        let destination = cached.deletingLastPathComponent()
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        do { try fm.moveItem(at: extracted, to: destination) }
        catch { throw TVInstallError.tools }
        return cached
    }

    /// Stops the adb server of Whoprrr's private copy. A copy the person installed is left alone.
    static func stopPrivateServer(using process: any TVProcessRunning) {
        guard FileManager.default.isExecutableFile(atPath: cached.path) else { return }
        let adb = cached
        Task.detached { _ = try? await process.run(adb, arguments: ["kill-server"], timeout: 5) }
    }
}
