import AppKit
import AudioCore
import ClipboardCore
import DisplayCore
import InputCore
import UniformTypeIdentifiers
import WhopperKit
import WindowCore

struct BackupSummary: Equatable {
    let recipes: Int
    let presets: Int
    let devices: Int

    var description: String {
        "\(count(recipes, "recipe")), \(count(presets, "preset")) and settings for \(count(devices, "device"))"
    }

    private func count(_ number: Int, _ singular: String) -> String {
        "\(number) \(singular)" + (number == 1 ? "" : "s")
    }
}

struct BackupContents {
    let backup: WhopperBackup
    let recipes: [Recipe]
    let displayPresets: [Preset]
    let summary: BackupSummary
    let liveSections: [String: Data]

    init(_ backup: WhopperBackup) throws {
        self.backup = backup
        recipes = try backup.recipeContents()
        displayPresets = try backup[.displayPresets].map(PresetStore.decode) ?? []
        let learned = try backup[.displayLearned].map(LearnedStore.decode) ?? []
        try backup.validateDraft()
        let decoder = JSONDecoder()
        let audio = try backup[.audio].map { try decoder.decode(AudioSettings.self, from: $0) }
        let input = try backup[.input].map { try decoder.decode(InputSettings.self, from: $0) }
        if let data = backup[.windows] { _ = try decoder.decode(WindowSettings.self, from: data) }
        if let data = backup[.clipboard] { _ = try decoder.decode(ClipboardSettings.self, from: data) }

        var devices = Set<String>()
        if let audio {
            devices.formUnion(audio.eq.profiles.keys.map { "audio:\($0)" })
            devices.formUnion(audio.keepAlive.keys.map { "audio:\($0)" })
            devices.formUnion(audio.inputPin.preferredUIDs.map { "audio:\($0)" })
            if let uid = audio.eq.targetUID { devices.insert("audio:\(uid)") }
            if let uid = audio.mic.sourceUID { devices.insert("audio:\(uid)") }
        }
        if let input {
            devices.formUnion(input.rules.flatMap(\.keyboardTypes).map { "keyboard:\($0)" })
        }
        for display in displayPresets.map(\.identity) + learned.map(\.identity) {
            devices.insert("display:\(display.vendor):\(display.model):\(display.alphaSerial ?? String(display.serial))")
        }
        summary = BackupSummary(recipes: recipes.count, presets: try backup.presetCount() + displayPresets.count,
                                devices: devices.count)
        liveSections = ["audio": backup[.audio], "input": backup[.input],
                        "windows": backup[.windows], "clipboard": backup[.clipboard]].compactMapValues { $0 }
    }
}

@MainActor
final class BackupController: ObservableObject {
    enum Action { case export, restore, take }

    struct Review: Identifiable {
        let id = UUID()
        let action: Action
        let fileName: String
        let contents: BackupContents
        var current: BackupSummary?
    }

    enum Problem: Equatable {
        case newer
        case picklsssNeeded
        case message(String)
    }

    @Published var review: Review?
    @Published var problem: Problem?
    @Published var status: String?
    private var waitingForActivation: URL?

    private static let directory = JSONStore<WhopperBackup>.directory()
    private static let fileType = UTType(exportedAs: "gg.tico.whoprrr.backup", conformingTo: .json)
    private static let files = WhopperBackupFiles(urls: [
        .recipes: directory.appendingPathComponent("recipes.json"),
        .presets: directory.appendingPathComponent("presets.json"),
        .audio: directory.appendingPathComponent("audio.json"),
        .input: directory.appendingPathComponent("input.json"),
        .windows: directory.appendingPathComponent("windows.json"),
        .clipboard: directory.appendingPathComponent("clipboard.json"),
        .saveDraft: directory.appendingPathComponent("save-draft.json"),
        .displayPresets: PresetStore.defaultURL(),
        .displayLearned: LearnedStore.defaultURL(),
    ], journal: directory.appendingPathComponent("backup-restore-in-progress.json"))

    static func recoverInterruptedRestore() throws { try files.recoverInterruptedRestore() }

    private var keyID: String? { LicenseController.shared.currentPass?.kid }

    func prepareExport() {
        guard let keyID else { problem = .message("Activate Whoprrr to make a backup with your key."); return }
        do {
            let backup = try capture(keyID)
            let name = "Whoprrr backup \(backup.createdAt.ISO8601Format().prefix(10)).\(WhopperBackup.fileExtension)"
            review = Review(action: .export, fileName: name, contents: try BackupContents(backup))
        } catch { show(error) }
    }

    func save(_ item: Review) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.nameFieldStringValue = item.fileName
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try item.contents.backup.encoded().write(to: url, options: .atomic)
            review = nil
            status = "Backup saved to \(url.deletingLastPathComponent().lastPathComponent). It opens on Macs with your key."
        } catch {
            review = nil
            show(error)
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        guard LicenseController.shared.isLicensed else {
            waitingForActivation = url
            Shared.showWindow(page: .recipes)
            return
        }
        Shared.showWindow(page: .recipes)
        review = nil
        do {
            let backup = try WhopperBackup.decode(Data(contentsOf: url, options: .mappedIfSafe))
            let contents = try BackupContents(backup)
            let own = PicklsssLock.isOwnFile(madeBy: backup.madeWithKeyID, pass: LicenseController.shared.currentPass)
            let current = own ? try? BackupContents(Self.files.capture(keyID: backup.madeWithKeyID, appVersion: AppInfo.version)).summary : nil
            review = Review(action: own ? .restore : .take, fileName: url.lastPathComponent,
                            contents: contents, current: current)
        } catch { show(error) }
    }

    func openAfterActivation() {
        guard let url = waitingForActivation else { return }
        waitingForActivation = nil
        open(url)
    }

    func restore(_ item: Review) {
        review = nil
        guard let keyID, keyID == item.contents.backup.madeWithKeyID else {
            problem = .message("Your activation changed. Open the backup again to check its key.")
            return
        }
        do {
            try Self.recoverInterruptedRestore()
            let current = try capture(keyID)
            let stamp = Date.now.ISO8601Format().replacingOccurrences(of: ":", with: "-")
            let recovery = Self.directory.appendingPathComponent("Backup Recovery", isDirectory: true)
                .appendingPathComponent("Before restore \(stamp) \(UUID().uuidString).\(WhopperBackup.fileExtension)")
            try Self.files.restore(item.contents.backup, keeping: current, at: recovery)
            Shared.audio.reloadAfterBackup()
            Shared.input.reloadAfterBackup()
            Shared.windows.reloadAfterBackup()
            Shared.clipboard.reloadAfterBackup()
            Shared.model.reloadAfterBackup()
            Shared.recipes.reloadAfterBackup()
            Shared.presets.reloadAfterBackup(recipes: Shared.recipes)
            Shared.saveBar.reloadDraft()
            PicklsssController.shared.recomputeNotices()
            status = "Restored \(item.contents.summary.description). The prior settings are in Backup Recovery."
        } catch { show(error) }
    }

    func take(_ item: Review, recipe: Recipe) {
        review = nil
        let action = PicklsssLock.Action.takeFromFile(madeBy: item.contents.backup.madeWithKeyID)
        guard PicklsssLock.decision(action, pass: LicenseController.shared.currentPass) == .free else {
            problem = .picklsssNeeded
            return
        }
        var displays: [String: SharedDisplaySource] = [:]
        for preset in item.contents.displayPresets where displays[preset.name] == nil {
            displays[preset.name] = SharedDisplaySource(model: preset.identity.productName, values: preset.values)
        }
        let result = SharedSetupExport.export(title: recipe.name, line: "From a Whoprrr backup.", recipe: recipe, display: displays)
        guard let setup = result.setup else {
            problem = .message(result.violations.first?.message ?? "This recipe could not be opened as a shared setup.")
            return
        }
        PicklsssController.shared.openFileSetup(setup, madeBy: item.contents.backup.madeWithKeyID, name: item.fileName)
    }

    func getPicklsss() {
        Shared.nav.page = .extras
        Task { await PicklsssController.shared.openBuyPage(.picklsss) }
    }

    var problemTitle: String {
        switch problem {
        case .newer: "Update Whoprrr to open this file"
        case .picklsssNeeded: "Picklsss is needed"
        default: "Whoprrr backup"
        }
    }

    private func capture(_ keyID: String) throws -> WhopperBackup {
        Shared.audio.syncPluginStates()
        Shared.saveBar.settingsDidChange()
        return try Self.files.capture(keyID: keyID, appVersion: AppInfo.version)
    }

    private func show(_ error: Error) {
        if case .newerVersion = error as? WhopperBackup.Problem { problem = .newer; return }
        if case .unsupportedVersion = error as? PresetStoreError { problem = .newer; return }
        problem = .message(error.localizedDescription)
    }
}
