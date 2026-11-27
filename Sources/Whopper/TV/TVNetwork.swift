import AppKit
import Darwin
import Network
import WhopperKit

/// The browser stays live while Add a TV is open. A new snapshot re-resolves the visible TVs every few seconds.
@MainActor
final class TVBrowser: ObservableObject {
    static let service = "_androidtvremote2._tcp"
    @Published private(set) var accessDenied = false
    private var browser: NWBrowser?
    private var endpoints: Set<NWEndpoint> = []

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.service, domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                self.endpoints = Set(results.map(\.endpoint))
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .waiting(.dns(-65_570)), .failed(.dns(-65_570)): self.accessDenied = true
                case .ready: self.accessDenied = false
                case .failed: self.stop()
                default: break
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        endpoints = []
    }

    func announcements() async -> [TVAnnouncement] {
        struct Service: Hashable {
            let name: String
            let type: String
            let domain: String
        }
        let services = Set(endpoints.compactMap { endpoint -> Service? in
            guard case .service(let name, let type, let domain, _) = endpoint else { return nil }
            return Service(name: name, type: type, domain: domain)
        })
        return await withTaskGroup(of: TVAnnouncement.self) { group in
            for service in services {
                group.addTask { @MainActor in
                    let resolver = TVServiceResolver(name: service.name, type: service.type, domain: service.domain)
                    let addresses = await resolver.resolve()
                    return TVAnnouncement(id: service.name + "@" + service.domain, name: service.name, addresses: addresses)
                }
            }
            var resolved: [TVAnnouncement] = []
            for await tv in group { resolved.append(tv) }
            return resolved
        }
    }
}

@MainActor
private final class TVServiceResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private var pending: CheckedContinuation<[TVAddress], Never>?

    init(name: String, type: String, domain: String) {
        service = NetService(domain: domain, type: type.hasSuffix(".") ? type : type + ".", name: name)
    }

    func resolve() async -> [TVAddress] {
        await withTaskCancellationHandler {
            await withCheckedContinuation { next in
                guard !Task.isCancelled else { next.resume(returning: []); return }
                pending = next
                service.delegate = self
                service.resolve(withTimeout: 2)
            }
        } onCancel: {
            Task { @MainActor in self.finish([]) }
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        var addresses = (sender.addresses ?? []).compactMap(Self.address)
        addresses.sort { a, b in
            let aIPv6 = a.host.contains(":"), bIPv6 = b.host.contains(":")
            return aIPv6 == bIPv6 ? a.host < b.host : !aIPv6
        }
        if let host = sender.hostName.flatMap(TVAddress.init), !addresses.contains(host) { addresses.append(host) }
        finish(addresses)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) { finish([]) }

    private static func address(_ data: Data) -> TVAddress? {
        guard data.count >= MemoryLayout<sockaddr>.size else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = data.withUnsafeBytes { bytes in
            getnameinfo(bytes.baseAddress?.assumingMemoryBound(to: sockaddr.self), socklen_t(data.count),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        }
        return status == 0 ? TVAddress(String(cString: host)) : nil
    }

    private func finish(_ addresses: [TVAddress]) {
        guard let pending else { return }
        self.pending = nil
        service.stop()
        service.delegate = nil
        pending.resume(returning: addresses)
    }
}

struct TVPortProbe: TVPortProbing {
    func isOpen(_ address: TVAddress) async -> Bool {
        let attempt = await TVPortAttempt(address)
        return await attempt.check()
    }
}

@MainActor
private final class TVPortAttempt {
    private let connection: NWConnection
    private var pending: CheckedContinuation<Bool, Never>?
    private var deadline: Task<Void, Never>?

    init(_ address: TVAddress) {
        connection = NWConnection(host: NWEndpoint.Host(address.host), port: NWEndpoint.Port(rawValue: TVAddress.port)!, using: .tcp)
    }

    func check() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { next in
                guard !Task.isCancelled else { next.resume(returning: false); return }
                pending = next
                connection.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated {
                        switch state {
                        case .ready: self?.finish(true)
                        case .failed, .cancelled: self?.finish(false)
                        default: break
                        }
                    }
                }
                deadline = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { self?.finish(false) }
                }
                connection.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor in self.finish(false) }
        }
    }

    private func finish(_ open: Bool) {
        guard let pending else { return }
        self.pending = nil
        deadline?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.resume(returning: open)
    }
}

@MainActor
struct TVDownloads: TVInstallNetwork {
    let license: LicenseController
    private var site: URL { license.server }

    func release() async throws -> TVRelease {
        var request = URLRequest(url: site.appendingPathComponent("tv/latest.json"), timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(TVRelease.self, from: data) else { throw TVInstallError.badRelease }
        try release.validate(for: site)
        return release
    }

    func download(_ release: TVRelease) async throws -> URL {
        let request = URLRequest(url: release.url, timeoutInterval: 60)
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TVInstallError.badRelease }
        // Cap the size before hashing: the published size when there is one, otherwise the release limit.
        let cap = Int64(release.size ?? TVRelease.maxSize)
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? .max
        guard response.expectedContentLength <= cap, size <= cap else { throw TVInstallError.badChecksum }
        // adb install requires an .apk suffix.
        let apk = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + release.filename)
        try FileManager.default.moveItem(at: temporary, to: apk)
        return apk
    }

    func setupCode() async throws -> String { try await license.makeTVSetupCode() }
}
