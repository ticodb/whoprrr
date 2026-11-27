import AppKit
import SwiftUI
import WhopperKit

@MainActor
private final class AddTVModel: ObservableObject {
    enum Stage: Equatable {
        case browse, gettingTools, waiting(Date), rejected, sending(TVInstallStep), failed(String)
    }

    @Published private(set) var stage = Stage.browse
    @Published private(set) var tvs: [DiscoveredTV] = []
    @Published private(set) var selected: DiscoveredTV?
    @Published private(set) var addressProblem: String?
    @Published private(set) var needsTools = TVPlatformTools.installedADB() == nil
    @Published private(set) var showNetworkHelp = false
    @Published var address = ""
    @Published var showSettings = false

    let browser = TVBrowser()
    private let process = TVProcessRunner()
    private let probe = TVPortProbe()
    private var discovery: Task<Void, Never>?
    private var connection: Task<Void, Never>?
    private var manual: TVAnnouncement?

    var isInstalling: Bool {
        if case .sending(let step) = stage {
            if case .opened = step { return false }
            return true
        }
        return false
    }

    func start() {
        guard discovery == nil else { return }
        let began = ContinuousClock.now
        discovery = Task {
            while !Task.isCancelled {
                browser.start()
                await refresh()
                if !showNetworkHelp, began.duration(to: .now) >= .seconds(120), !tvs.contains(where: \.isReady) {
                    showNetworkHelp = true
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func close() {
        discovery?.cancel()
        discovery = nil
        browser.stop()
        connection?.cancel()
        connection = nil
    }

    private func refresh() async {
        let announced = await browser.announcements()
        let manual = self.manual
        let all = manual.map { record in
            [record] + announced.filter { Set($0.addresses).isDisjoint(with: record.addresses) }
        }
        let results = await TVDiscovery.check(all ?? announced, using: probe)
        guard !Task.isCancelled, self.manual == manual else { return }
        tvs = results
    }

    func checkAddress() {
        guard let parsed = TVAddress(address) else {
            addressProblem = "Enter the address from Settings › Network on your TV."
            return
        }
        addressProblem = nil
        let record = TVAnnouncement(id: "manual", name: parsed.host, addresses: [parsed])
        manual = record
        Task { await refresh() }
    }

    func add(_ tv: DiscoveredTV) {
        guard tv.isReady, tv.address != nil else { return }
        selected = tv
        attempt(again: false)
    }

    func askAgain() { attempt(again: true) }

    func back() {
        connection?.cancel()
        connection = nil
        selected = nil
        stage = .browse
    }

    private func attempt(again: Bool) {
        guard let target = selected?.address else { return }
        connection?.cancel()
        connection = Task {
            do {
                if needsTools { stage = .gettingTools }
                let executable = try await TVPlatformTools.getADB(using: process)
                try Task.checkCancellation()
                needsTools = false
                let installer = TVInstaller(adb: executable, process: process, network: TVDownloads(license: .shared))
                stage = .waiting(Date())
                switch try await installer.ask(target, again: again) {
                case .ready: break
                case .rejected: stage = .rejected; return
                case .unreachable:
                    stage = .failed("The TV couldn’t be reached. Check that it’s on and USB debugging is enabled.")
                    return
                case .waiting:
                    guard try await waitForAllow(installer, address: target) else { return }
                }
                try Task.checkCancellation()
                pauseDiscoveryWhileSending()
                try await installer.install(on: target) { stage = .sending($0) }
            } catch {
                guard !Task.isCancelled else { return }
                stage = .failed((error as? TVInstallError)?.errorDescription ?? "Whoprrr couldn’t finish. Check the connection and try again.")
            }
        }
    }

    private func pauseDiscoveryWhileSending() {
        discovery?.cancel()
        discovery = nil
        browser.stop()
    }

    private func waitForAllow(_ installer: TVInstaller, address: TVAddress) async throws -> Bool {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(2))
            let state: TVAuthorization
            do { state = try await installer.authorization(address) }
            catch TVInstallError.timedOut { continue }
            switch state {
            case .ready: return true
            case .rejected:
                stage = .rejected
                return false
            case .waiting, .unreachable: continue
            }
        }
        return false
    }
}

struct AddTVView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AddTVModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.stage {
                    case .browse: browse
                    case .gettingTools:
                        title
                        BrandCard { Label("Downloading Google’s Android SDK Platform-Tools…", systemImage: "arrow.down.circle") }
                    case .waiting(let began): waiting(began)
                    case .rejected:
                        PanelHeader("The TV said no", symbol: "tv", subtitle: model.selected.map { "Nothing was installed on \($0.name)" })
                        Text("Ask again and choose Allow on the TV.").font(Brand.body)
                    case .sending(let step): sending(step)
                    case .failed(let message):
                        title
                        BrandCard { Text(message).font(Brand.body).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer.padding(18)
        }
        .frame(width: 590, height: 510)
        .tint(Brand.violetBright)
        .interactiveDismissDisabled(model.isInstalling)
        .onAppear(perform: model.start)
        .onDisappear(perform: model.close)
    }

    private var title: some View {
        PanelHeader(model.selected.map { "Adding \($0.name)" } ?? "Add a TV", symbol: "tv")
    }

    private var browse: some View {
        Group {
            PanelHeader("Add a TV", symbol: "tv", subtitle: "TVs found on your network")
            BrowserNetworkNotice(browser: model.browser)
            BrandCard {
                if model.tvs.isEmpty {
                    Text("Looking for Android TVs…").font(Brand.headline)
                    Text("Make sure the TV is on and connected to the same network as this Mac.").font(Brand.caption).foregroundStyle(.secondary)
                }
                ForEach(model.tvs) { tv in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tv.name).font(Brand.headline)
                            if let address = tv.address, address.host != tv.name {
                                Text(address.host).font(Brand.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        StatusChip(text: tv.isReady ? "Ready" : "Needs one setting", tone: tv.isReady ? .good : .warn).fixedSize()
                        if tv.isReady {
                            Button("Install") { model.add(tv) }.buttonStyle(.brand).accessibilityLabel("Install on \(tv.name)")
                        } else {
                            Button("Show me") { model.showSettings = true }.buttonStyle(.brandPlain)
                        }
                    }
                    if tv.id != model.tvs.last?.id { Divider() }
                }
            }
            if model.showSettings { tvSettings }
            else if model.tvs.isEmpty {
                Button("Show me the TV setting") { model.showSettings = true }.buttonStyle(.brandQuiet)
            }
            if model.showNetworkHelp {
                BrandCard {
                    Text("No TV has opened access yet").font(Brand.headline)
                    Text("A guest network can hide devices. If this Mac is using a VPN, pause it for a minute.")
                        .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            manualAddress
            if model.needsTools {
                Text("The first install downloads Google’s Android SDK Platform-Tools into Whoprrr’s Application Support folder.")
                    .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("Google’s SDK terms", destination: URL(string: "https://developer.android.com/tools/releases/platform-tools")!)
                    .font(Brand.caption)
            }
        }
    }

    private var tvSettings: some View {
        BrandCard {
            Text("On your TV").font(Brand.headline)
            Text("1. Settings › System › About")
            Text("2. Press OK on “Android TV OS build” seven times")
            Text("3. Back › Developer options › USB debugging: On")
            Text("Looking again every few seconds").font(Brand.caption).foregroundStyle(.secondary)
        }
    }

    private var manualAddress: some View {
        BrandCard {
            Text("Type the TV’s address").font(Brand.headline)
            Text("On the TV, look under Settings › Network.").font(Brand.caption).foregroundStyle(.secondary)
            HStack {
                TextField("192.168.1.50", text: $model.address)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("TV address").onSubmit(model.checkAddress)
                Button("Check address", action: model.checkAddress).buttonStyle(.brandQuiet)
                    .disabled(model.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let problem = model.addressProblem { Text(problem).font(Brand.caption).foregroundStyle(StatusChip.Tone.warn.text) }
        }
    }

    private func waiting(_ began: Date) -> some View {
        TimelineView(.periodic(from: began, by: 1)) { time in
            VStack(alignment: .leading, spacing: 12) {
                title
                BrandCard {
                    Text("Allow USB debugging?").font(Brand.headline)
                    Text("On the TV, select Always allow from this computer, then choose Allow.").font(Brand.body)
                    StatusChip(text: "Waiting for the TV", tone: .warn)
                    if time.date.timeIntervalSince(began) >= 30 {
                        Divider()
                        Text("The TV is waiting for someone with the remote. If the question went away, choose Ask again.")
                            .font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func sending(_ step: TVInstallStep) -> some View {
        let opened: Bool = { if case .opened = step { return true }; return false }()
        let version: String? = {
            switch step {
            case .installing(let version), .installed(let version), .activating(let version), .opened(let version): return version
            default: return nil
            }
        }()
        let installed: Bool = {
            switch step {
            case .installed, .activating, .opened: true
            default: false
            }
        }()
        return Group {
            if opened {
                PanelHeader("Whoprrr TV is open", symbol: "checkmark.circle", subtitle: "Finish setup on the TV")
            } else { title }
            BrandCard {
                installRow("The TV said yes", state: "Done", tone: .good)
                Divider()
                installRow(version.map { "Whoprrr TV \($0) sent and installed" } ?? "Download and check Whoprrr TV",
                           state: installed ? "Done" : "Working", tone: installed ? .good : .neutral)
                Divider()
                installRow("Open Whoprrr TV with your key", state: opened ? "Done" : installed ? "Working" : "Next",
                           tone: opened ? .good : .neutral)
            }
            if opened {
                Text("The TV will guide you through its own setup.").font(Brand.body)
            }
        }
    }

    private func installRow(_ text: String, state: String, tone: StatusChip.Tone) -> some View {
        HStack {
            Text(text).font(Brand.headline)
            Spacer()
            StatusChip(text: state, tone: tone)
        }
    }

    private var footer: some View {
        HStack {
            switch model.stage {
            case .browse:
                Button("Close") { dismiss() }.buttonStyle(.brandPlain)
            case .gettingTools:
                Button("Cancel") { model.back(); model.start() }.buttonStyle(.brandPlain)
            case .waiting, .rejected, .failed:
                Button("Ask again") { model.askAgain() }.buttonStyle(.brand)
                Button("Back to TVs") { model.back(); model.start() }.buttonStyle(.brandPlain)
            case .sending(.opened):
                Button("Done") { dismiss() }.buttonStyle(.brand)
            case .sending:
                ProgressView().controlSize(.small).accessibilityLabel("Adding this TV")
            }
            Spacer()
        }
    }
}

private struct BrowserNetworkNotice: View {
    @ObservedObject var browser: TVBrowser

    var body: some View {
        if browser.accessDenied {
            BrandCard {
                Text("Allow Whoprrr under Local Network in Privacy & Security.").font(Brand.body)
                Button("Open Local Network") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                }.buttonStyle(.brandQuiet)
            }
        }
    }
}
