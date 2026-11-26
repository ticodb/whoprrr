import SwiftUI
import AppKit
import Combine
import AudioCore
import DisplayCore
import WhopperKit

/// Everything the Picklsss page, the Extras page and the notices need: the shelf, the person's takes and shared setups, the lock,
/// the daily check. The rules live in WhopperKit (Picklsss/*); this file is storage, network and timing.
@MainActor
final class PicklsssController: ObservableObject {
    static let shared = PicklsssController()

    enum BrowseTab: String, CaseIterable, Identifiable { case forGear = "For your gear", popular = "Popular", new = "New"; var id: String { rawValue } }
    enum Route { case shelf, mine }
    enum CheckStatus: Equatable { case idle, checking, found, notYet }

    let license = LicenseController.shared
    private let store: JSONStore<PicklsssState>
    @Published private(set) var state: PicklsssState
    private(set) var client: ShelfClient
    let tracker = KeepTracker()

    // The shelf
    @Published var tab: BrowseTab = .forGear
    @Published var search = ""
    @Published var route: Route = .shelf
    @Published private(set) var cards: [ShelfCard] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var loading = false
    @Published private(set) var loadedOnce = false
    @Published private(set) var shelfFailure: ShelfFailure?
    @Published private(set) var gear: [DeviceSignature] = []
    private var loadGeneration = 0
    /// For your gear is ranked on this Mac, so it reads as many pages as that takes, up to this many cards.
    private static let rankingCap = 500

    // What is open
    @Published var take: TakeSession?
    @Published var sharing: ShareSession?
    @Published var fileProblem: FileProblem?

    // The lock
    @Published private(set) var checkStatus: CheckStatus = .idle
    /// Set when the person was sent to the browser to pay; the app then re-checks its pass when it comes to the front.
    @Published private(set) var awaitingPurchase = false
    private var lastCheck = Date.distantPast
    private var becameActive: NSObjectProtocol?

    // Notices and the cook's page
    @Published private(set) var notices: [ShelfNotice] = []
    @Published private(set) var mine: ShelfMine?
    @Published private(set) var mineFailure: ShelfFailure?
    @Published private(set) var mineLoading = false

    struct FileProblem: Identifiable { let id = UUID(); var name: String; var title: String; var why: String; var violations: [String]; var tampered: Bool }

    private var bag = Set<AnyCancellable>()

    private init() {
        let s = JSONStore<PicklsssState>(name: "picklsss")
        store = s
        state = s.load(default: PicklsssState())
        client = ShelfClient(transport: URLSessionShelfTransport(server: LicenseController.shared.server))
    }

    var recipes: RecipeStore { Shared.recipes }
    var handle: String? { state.handle ?? mine?.cook?.handle }
    var hasExtra: Bool { license.hasPicklsss }

    /// Call once at launch, after the recipes are registered.
    func start() {
        recipes.$recipes.sink { [weak self] _ in DispatchQueue.main.async { self?.recomputeNotices() } }.store(in: &bag)
        recipes.$activeID.sink { [weak self] _ in DispatchQueue.main.async { self?.noteActive() } }.store(in: &bag)
        becameActive = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cameToFront() }
        }
        recomputeNotices()
        noteActive()
        #if DEBUG
        if ProcessInfo.processInfo.environment["WHOPRRR_DAILY_NOW"] == "1" { Task { await runDaily() } }
        #endif
    }

    private func save(_ change: (inout PicklsssState) -> Void) { var s = state; change(&s); state = s; store.save(s) }

    // MARK: Calls with the pass

    /// Runs a call that needs the pass. A pass that has run out is renewed and the call repeated once; a pass the server refuses
    /// (removed device, key switched off) is dropped, the same way a refused renewal drops it. Network trouble never costs anyone their pass.
    func withPass<T>(_ op: (ShelfClient, String) async throws -> T) async throws -> T {
        guard let pass = await license.passForShelf() else {
            throw ShelfFailure.invalidPass("This Mac is not activated yet. Enter your key to use shared setups.")
        }
        do { return try await op(client, pass) }
        catch ShelfFailure.passExpired {
            await license.renewIfDue(force: true)
            guard let fresh = await license.passForShelf() else { throw ShelfFailure.invalidPass("This Mac’s activation needs to be refreshed. Connect to the internet and try again.") }
            return try await op(client, fresh)
        } catch let e as ShelfFailure where e.dropsThePass {
            license.passRejected(e.message)
            throw e
        }
    }

    // MARK: Browsing

    func refreshGear() { gear = Gear.current() }

    /// Reads the shelf. Nothing about this Mac's gear is sent: "For your gear" reads the pages and ranks them here.
    func loadShelf() async {
        refreshGear()
        loadGeneration += 1
        let gen = loadGeneration
        loading = true; shelfFailure = nil
        defer { if gen == loadGeneration { loading = false; loadedOnce = true } }
        var all: [ShelfCard] = []
        var cursor: String?
        let apiTab: ShelfTab = tab == .new ? .new : .popular
        do {
            repeat {
                let page = try await client.list(tab: apiTab, search: search, cursor: cursor)
                all += page.items; cursor = page.next
                if tab != .forGear { break }
            } while cursor != nil && all.count < Self.rankingCap
            guard gen == loadGeneration else { return }
            cards = all; nextCursor = cursor
        } catch let e as ShelfFailure {
            guard gen == loadGeneration else { return }
            shelfFailure = e; cards = []; nextCursor = nil
        } catch { shelfFailure = .offline }
    }

    func loadMore() async {
        guard let c = nextCursor, !loading, tab != .forGear else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await client.list(tab: tab == .new ? .new : .popular, search: search, cursor: c)
            cards += page.items; nextCursor = page.next
        } catch let e as ShelfFailure { shelfFailure = e } catch {}
    }

    var ranked: (fitting: [ShelfRanking.Ranked], others: [ShelfRanking.Ranked]) {
        tab == .forGear ? ShelfRanking.forYourGear(cards, gear: gear) : (ShelfRanking.inShelfOrder(cards, gear: gear), [])
    }

    // MARK: Opening one

    func open(_ card: ShelfCard) async {
        let session = TakeSession(controller: self, card: card)
        take = session
        await session.load()
    }

    func openOwn(_ card: ShelfCard) async {
        let session = TakeSession(controller: self, card: card)
        session.isOwn = true
        take = session
        await session.load()
    }

    func close() { take = nil }

    /// Opens a `.whoprrr-setup` file. The checker runs every time; a hand-edited file is refused with the plain explanation.
    func openFile(_ url: URL) {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            fileProblem = FileProblem(name: name, title: PicklsssWords.tamperedTitle, why: "This file could not be read.", violations: [], tampered: false); return
        }
        let opened = SharedSetupFile.decode(data)
        guard let setup = opened.setup else {
            let tampered = opened.report.tampered
            let lines = opened.report.violations.map(\.message)
            let why = tampered ? PicklsssWords.tamperedWhy : (opened.problem?.message ?? "This setup breaks Whoprrr’s limits.")
            fileProblem = FileProblem(name: name, title: PicklsssWords.tamperedTitle, why: why, violations: lines, tampered: tampered)
            Shared.showWindow(page: .picklsss)
            return
        }
        let session = TakeSession(controller: self, file: setup, madeBy: opened.madeBy, name: name)
        take = session
        route = .shelf
        Shared.showWindow(page: .picklsss)
        session.prepare()
    }

    // MARK: The lock

    func openPersonalPage() {
        awaitingPurchase = true
        NSWorkspace.shared.open(PersonalPage.url(server: license.server))
    }

    /// "Check now", and what the app does when it comes to the front after the person went to pay.
    func checkNow() async {
        guard checkStatus != .checking else { return }
        checkStatus = .checking
        let had = hasExtra
        let has = await license.checkNow()
        lastCheck = Date()
        if has { awaitingPurchase = false; checkStatus = had ? .idle : .found } else { checkStatus = .notYet }
        objectWillChange.send()
    }

    private func cameToFront() {
        noteActive()
        guard awaitingPurchase, !hasExtra, Date().timeIntervalSince(lastCheck) > 5 else { return }
        Task { await checkNow() }
    }

    func clearCheckStatus() { checkStatus = .idle }
    func stopWaiting() { awaitingPurchase = false; checkStatus = .idle }

    // MARK: Counting what you keep

    var countChoice: CountChoice { state.count }

    func setCount(_ choice: CountChoice) { save { $0.count = choice } }

    // MARK: Taking: the bookkeeping

    func record(_ t: TakeRecord) {
        save { s in
            if let i = s.takes.firstIndex(where: { $0.picklsssId == t.picklsssId }) {
                var old = s.takes[i]
                // Taking again keeps the first take's token and counting; only a recipe it lost is replaced.
                if old.recipeID == nil || !recipes.recipes.contains(where: { $0.id == old.recipeID }) { old.recipeID = t.recipeID }
                if !t.before.isEmpty { old.before = t.before; old.beforeParts = t.beforeParts }
                old.title = t.title; old.version = max(old.version, t.version)
                s.takes[i] = old
            } else { s.takes.append(t) }
        }
        noteActive()
    }

    func takeRecord(forRecipe id: UUID) -> TakeRecord? { state.take(forRecipe: id) }

    func forgetTake(_ picklsssId: String) { save { $0.takes.removeAll { $0.picklsssId == picklsssId } } }

    // MARK: Active days and the day-7 answer

    private func noteActive() {
        var takes = state.takes
        if tracker.noteActive(recipeID: recipes.activeID, in: &takes) { save { $0.takes = takes } }
    }

    /// Works out and sends the day-7 answers that are due. One yes or no with the take token, once.
    func answerKeeps() async {
        noteActive()
        var takes = state.takes
        let due = tracker.due(takes: &takes, recipeIDs: Set(recipes.recipes.map(\.id)))
        save { $0.takes = takes }
        for a in due {
            var err: ShelfFailure?
            do { try await client.kept(takeToken: a.takeToken, kept: a.kept) } catch { err = error as? ShelfFailure ?? .offline }
            var t = state.takes
            tracker.settle(a.picklsssId, error: err, in: &t)
            save { $0.takes = t }
        }
    }

    // MARK: Notices

    func recomputeNotices() {
        notices = NoticeBox.visible(state.notices, takes: state.takes, recipeIDs: Set(recipes.recipes.map(\.id)))
    }

    func refreshNotices() async {
        guard license.currentPass != nil else { return }
        guard let fresh = try? await withPass({ c, p in try await c.notices(pass: p) }) else { return }
        save { NoticeBox.merge(fresh, into: &$0.notices, now: Date()) }
        recomputeNotices()
    }

    func dismissNotice(_ id: String) { save { NoticeBox.dismiss(id, from: &$0.notices) }; recomputeNotices() }

    func canPutBack(_ n: ShelfNotice) -> Bool { NoticeBox.canPutBack(n, takes: state.takes, recipeIDs: Set(recipes.recipes.map(\.id))) }

    /// "Put back": the parts the take changed go back to how they were just before it, and the copy that was taken is removed.
    func putBack(_ n: ShelfNotice) {
        guard let t = state.take(for: n.picklsssId) else { return }
        putBack(take: t)
        dismissNotice(n.id)
    }

    func putBack(take t: TakeRecord) {
        recipes.restore(t.before)
        if let id = t.recipeID { recipes.delete(id) }
        recipes.notice = "Put back: \(t.title) is off this Mac."
        save { s in if let i = s.takes.firstIndex(where: { $0.picklsssId == t.picklsssId }) { s.takes[i].before = [:]; s.takes[i].recipeID = nil } }
    }

    /// An update is offered with the author's note and a before-and-after: a plain choice between yours and the new one.
    func seeUpdate(_ n: ShelfNotice) async {
        guard let t = state.take(for: n.picklsssId), let rid = t.recipeID, recipes.recipe(rid) != nil else { dismissNotice(n.id); return }
        let session = TakeSession(controller: self, updating: t, notice: n)
        take = session
        Shared.showWindow(page: .picklsss)
        route = .shelf
        await session.load()
    }

    // MARK: The cook's page

    func refreshMine() async {
        guard license.currentPass != nil else { return }
        mineLoading = true; mineFailure = nil
        defer { mineLoading = false }
        do {
            let m = try await withPass { c, p in try await c.mine(pass: p) }
            mine = m
            save { s in
                if let c = m.cook { s.handle = c.handle; s.sharingClosedReason = c.sharingClosed?.reason }
                for card in m.picklsss {
                    if let i = s.shared.firstIndex(where: { $0.picklsssId == card.id }) {
                        s.shared[i].state = card.state ?? s.shared[i].state; s.shared[i].version = card.version; s.shared[i].title = card.title
                    } else {
                        s.shared.append(SharedRecord(picklsssId: card.id, recipeID: nil, title: card.title, state: card.state ?? "public", version: card.version,
                                                     parts: card.parts, digest: "", sharedAt: card.updated ?? Date()))
                    }
                }
            }
            // The first accepted setup switches the extra on for the purchase; the pass learns at its next renewal, so ask for one.
            if state.hasPublicSetup, !hasExtra { await checkNow() }
        } catch let e as ShelfFailure { mineFailure = e } catch { mineFailure = .offline }
    }

    var sharingClosedReason: String? { mine?.cook?.sharingClosed?.reason ?? state.sharingClosedReason }

    func recordShared(_ r: SharedRecord) {
        save { s in if let i = s.shared.firstIndex(where: { $0.picklsssId == r.picklsssId }) { s.shared[i] = r } else { s.shared.append(r) } }
    }
    func rememberHandle(_ h: String) { save { $0.handle = h } }
    func updateVersion(_ id: String, _ version: Int) { save { s in if let i = s.takes.firstIndex(where: { $0.picklsssId == id }) { s.takes[i].version = version } } }

    /// What the display module knows, as a shared setup can use it: preset name to monitor model and values.
    func displaySources() -> [String: SharedDisplaySource] {
        Dictionary(Shared.model.presets.map { ($0.name, SharedDisplaySource(model: $0.identity.productName, values: $0.values)) }, uniquingKeysWith: { a, _ in a })
    }

    private var dirtyCache: [String: Bool] = [:]
    /// The recipe moved on since it was shared: "Your copy is newer than the shared one". Saving locally never publishes; this only says so.
    func isNewerThanShared(_ r: SharedRecord) -> Bool {
        guard let rid = r.recipeID, let recipe = recipes.recipe(rid), r.state != ShelfState.removed.rawValue, !r.digest.isEmpty else { return false }
        let key = "\(r.picklsssId)|\(recipe.updatedAt.timeIntervalSince1970)|\(r.digest)"
        if let v = dirtyCache[key] { return v }
        let out = SharedSetupExport.export(title: r.title, line: "A shared setup.", recipe: recipe, parts: Set(r.parts), display: displaySources())
        let v = out.setup.map { ShareDigest.of(setup: $0) != r.digest } ?? false
        dirtyCache[key] = v
        return v
    }
    func sharedRecord(forRecipe id: UUID) -> SharedRecord? { state.sharedRecord(forRecipe: id) }

    func takeDown(_ id: String) async throws {
        try await withPass { c, p in try await c.takedown(pass: p, id: id) }
        save { s in if let i = s.shared.firstIndex(where: { $0.picklsssId == id }) { s.shared[i].state = ShelfState.removed.rawValue } }
        await refreshMine()
    }

    // MARK: The daily check

    /// Run by the update check that already happens once a day (the Sparkle callback), so there is no timer of its own.
    /// Asks for notices, sends any day-7 answer that is due, and, only for someone who has a public shared setup, counts kitchen time.
    func runDaily() async {
        guard license.currentPass != nil else { return }
        save { $0.lastDaily = Date() }
        await refreshNotices()
        await answerKeeps()
        // Nobody else's app makes these two calls: they are for people who have shared something.
        guard !state.shared.isEmpty else { return }
        await refreshMine()
        if DailyCheck.shouldCallDay(hasPublicSetup: state.hasPublicSetup, lastCall: state.lastDayCall, now: Date()) {
            do { try await withPass { c, p in try await c.day(pass: p) }; save { $0.lastDayCall = DailyCheck.utcDay(Date()) } } catch {}
        }
    }

    // MARK: Receiver

    /// What this Mac looks like to a setup being fitted: its gear, installed plugins, macOS, permissions and own settings.
    func receiverEnvironment() -> ReceiverEnvironment {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let checker = LivePermissionChecker()
        let plugins = PluginCatalog.effects().map { InstalledPlugin(name: $0.name, maker: $0.manufacturer, type: $0.type, subtype: $0.subtype, manufacturerCode: $0.manufacturerCode) }
        return ReceiverEnvironment(gear: Gear.current(), plugins: plugins, macOS: "\(v.majorVersion).\(v.minorVersion)",
                                   permissions: Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, checker.status($0)) }),
                                   sections: recipes.snapshot(recipes.surfaceKeys))
    }
}

/// Where the person pays. The pass carries no link to their personal page (it never says who they are), so the app opens the
/// "Find your downloads" page on the same server, which sends the personal link to the address they paid with.
enum PersonalPage {
    static func url(server: URL) -> URL { server.appendingPathComponent("get") }
}
