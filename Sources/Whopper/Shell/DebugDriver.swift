#if DEBUG
import SwiftUI
import AppKit
import WhopperKit

/// Debug builds only: runs a JSON list of steps against the same controllers the buttons call, and takes screenshots of the main
/// window, so the shelf can be exercised end to end against a local test server without any synthetic click or keystroke.
///
///   WHOPRRR_SCRIPT=/path/steps.json  WHOPRRR_SHOTS_DIR=/dir  (WHOPRRR_SCRIPT_QUIT=1 quits at the end)
///
/// Each step is an object with a `do` name; see `step(_:)`. Output goes to stderr and `driver.log` in the shots folder.
@MainActor
enum DebugDriver {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var log: FileHandle?
    private static var presetPreview: (key: String, managing: Bool, more: String)?

    static func startIfRequested() {
        guard let path = env["WHOPRRR_SCRIPT"], let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        if let dir = env["WHOPRRR_SHOTS_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let p = dir + "/driver.log"
            FileManager.default.createFile(atPath: p, contents: nil)
            log = FileHandle(forWritingAtPath: p)
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)       // let the window, the pass and the gear settle
            for s in steps { await step(s) }
            emit("script done")
            if env["WHOPRRR_SCRIPT_QUIT"] == "1" { NSApp.terminate(nil) }
        }
    }

    private static func emit(_ s: String) {
        FileHandle.standardError.write(Data("driver: \(s)\n".utf8))
        log?.write(Data((s + "\n").utf8))
    }

    private static var c: PicklsssController { PicklsssController.shared }

    private static func waitUntil(_ timeout: Double = 8, _ ok: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if ok() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
        return ok()
    }

    private static func step(_ s: [String: Any]) async {
        let name = s["do"] as? String ?? ""
        let str = { (k: String) in s[k] as? String ?? "" }
        switch name {
        case "wait": try? await Task.sleep(nanoseconds: UInt64((s["secs"] as? Double ?? 1) * 1e9))
        case "page": Shared.nav.page = AppPage(name: str("name")) ?? .recipes
        case "shot": shot(str("name"))
        case "recipe-save-seed":
            Shared.nav.page = .feature(.windows)
            _ = Shared.recipes.create(name: "Home Office", symbol: "house", includes: ["windows"], devices: [], autoApply: false)
        case "recipe-save-change":
            Shared.windows.settings.gap = s["gap"] as? Double ?? 18
            Shared.saveBar.settingsDidChange()
        case "recipe-save-now": Shared.saveBar.save()
        case "recipe-save-state":
            emit("recipe save: \(Shared.saveBar.changedTitles.joined(separator: ", "))")
        case "preset-seed":
            Shared.nav.page = .feature(.audio)
            let uid = "debug-xm4"
            Shared.audio.settings.eq.targetUID = uid
            Shared.audio.settings.knownNames[uid] = "Tico’s XM4s"
            Shared.audio.settings.eq.profiles[uid] = .flat
            let surface = PresetSurfaces.eq(Shared.audio)
            if let data = surface.capture() {
                Shared.presets.save("M1 MacBook Air", data: data, for: surface.key)
                Shared.presets.save("Xiaomi SO", data: data, for: surface.key)
                Shared.presets.saveNew("Sony XM4", data: data, at: surface.location)
            }
            _ = Shared.recipes.create(name: "Home Office", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
        case "preset-menu-open": presetPreview = (str("key"), false, "")
        case "preset-manage-open": presetPreview = (str("key"), true, str("more"))
        case "preset-preview-close": presetPreview = nil
        case "preset-change-eq":
            Shared.audio.eqProfile.preampDB = s["preamp"] as? Double ?? -2
            Shared.saveBar.settingsDidChange()
        case "preset-update":
            if let surface = PresetSurfaces.surface(str("key")), let entry = surface.groups(in: Shared.presets).inUse {
                Shared.presetActions.update(entry, on: surface)
                emit("preset update: \(Shared.saveBar.confirmation?.message ?? "-")")
            }
        case "preset-undo":
            Shared.saveBar.undoSave()
            emit("preset undo: preamp=\(Shared.audio.eqProfile.preampDB)")
        case "milestone-show":
            let rank = CookRank(shelfName: s["rank"] as? String)
            let count = s["pickles"] as? Int ?? 0
            let kind: PicklsssMilestone.Kind
            switch str("kind") {
            case "rank":
                guard let rank else { emit("milestone: missing rank"); return }
                kind = .rank(rank)
            case "keep": kind = .firstKeep
            case "first-take": kind = .firstTake(title: str("title"), inRecipes: true)
            case "ten": kind = .tenTakes
            case "twenty-five": kind = .twentyFiveTakes
            case "fifty": kind = .fiftyTakes
            default: kind = .pickle
            }
            let sample = PicklsssMilestone(kind: kind, rank: rank, pickles: count)
            c.showDebugMilestone(sample)
            emit("milestone: \(sample.title), rank=\(rank?.name ?? "-"), pickles=\(count)")
        case "say": emit("\(str("what")): \(describe())")
        case "shelf":
            if let t = s["tab"] as? String, let tab = PicklsssController.BrowseTab(rawValue: t) { c.tab = tab }
            if let q = s["search"] as? String { c.search = q }
            c.route = .shelf; c.close(); await c.loadShelf()
            emit("shelf: \(c.cards.map(\.title)) failure=\(String(describing: c.shelfFailure))")
        case "open":
            guard let card = c.cards.first(where: { $0.title.hasPrefix(str("title")) }) else { emit("open: no card \(str("title"))"); return }
            Shared.nav.page = .picklsss
            await c.open(card)
            _ = await waitUntil { c.take?.stage != .loading }
            emit("open: stage=\(String(describing: c.take?.stage)) lines=\(c.take?.plan?.lines.map { "\($0.id):\($0.state.isOff ? "off" : "on")" } ?? [])")
        case "match": c.take?.toMatch()
        case "review": c.take?.toReview()
        case "toggle": c.take?.toggle(str("line"), on: s["on"] as? Bool ?? true)
        case "toggle-part": c.take?.toggle(s["lines"] as? [String] ?? [], on: s["on"] as? Bool ?? true)
        case "open-groups":
            if let t = c.take { t.openGroups = Set((s["ids"] as? [String]) ?? (t.grouping?.stays.map(\.id) ?? [])) }
            emit("groups: \(c.take?.grouping?.stays.map { "\($0.title) [\($0.lines.count)]" } ?? [])")
        case "choose":
            if let t = c.take, let i = s["index"] as? Int {
                let m = str("model"); t.choose(authorIndex: i, device: t.env.gear.first { $0.model == m })
            }
        case "apply":
            c.take?.requestApply()
            if s["nowait"] as? Bool == true { return }
            _ = await waitUntil(12) { c.take?.stage == .done || c.take?.showLock == true || c.take?.askCount == true || c.take?.message != nil }
            emit("apply: stage=\(String(describing: c.take?.stage)) lock=\(c.take?.showLock ?? false) ask=\(c.take?.askCount ?? false) message=\(c.take?.message ?? "-")")
        case "count":
            c.take?.answerCount(str("answer") == "yes" ? .yes : .no)
            if s["nowait"] as? Bool == true { return }
            _ = await waitUntil(12) { c.take?.stage == .done || c.take?.showLock == true || c.take?.message != nil }
            emit("count: stage=\(String(describing: c.take?.stage)) lock=\(c.take?.showLock ?? false) message=\(c.take?.message ?? "-")")
        case "part":
            c.take?.requestPart(str("part"), tryNow: s["try"] as? Bool ?? false)
            _ = await waitUntil(12) { c.take?.presetNote != nil || c.take?.showLock == true || c.take?.askCount == true || c.take?.message != nil }
            emit("part: note=\(c.take?.presetNote ?? "-") lock=\(c.take?.showLock ?? false) ask=\(c.take?.askCount ?? false) message=\(c.take?.message ?? "-")")
        case "part-picker": c.take?.openPartPicker()
        case "put-back": c.take?.putEverythingBack(); emit("put-back: recipes=\(c.recipes.recipes.map(\.name))")
        case "preview-report": c.take?.previewReport(str("outcome") == "off" ? .somethingOff : .works)
        case "send-report": c.take?.sendReport(); try? await Task.sleep(nanoseconds: 1_500_000_000); emit("report: \(String(describing: c.take?.sending))")
        case "flag": c.take?.markSomethingOff(); try? await Task.sleep(nanoseconds: 1_500_000_000); emit("flag: \(String(describing: c.take?.flag))")
        case "close": c.close(); c.fileProblem = nil; c.sharing = nil
        case "checknow": await c.checkNow(); emit("checknow: pick=\(c.hasExtra) status=\(c.checkStatus)")
        case "awaiting": c.openPersonalPage()
        case "front": NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil); try? await Task.sleep(nanoseconds: 2_000_000_000); emit("front: pick=\(c.hasExtra)")
        case "daily": await c.runDaily(); emit("daily: day=\(c.state.lastDayCall ?? "-") shared=\(c.state.shared.map { "\($0.title):\($0.state)" }) notices=\(c.notices.map(\.kind.rawValue))")
        case "notices": await c.refreshNotices(); emit("notices: \(c.notices.map { "\($0.kind.rawValue):\($0.title)" })")
        case "see-update":
            if let n = c.notices.first(where: { $0.kind == .update }) { await c.seeUpdate(n); _ = await waitUntil { c.take?.stage != .loading }; emit("see-update: stage=\(String(describing: c.take?.stage)) note=\(c.take?.updateNote ?? "-")") }
        case "put-back-notice":
            if let n = c.notices.first(where: { $0.kind == .removed }) { emit("put-back-notice: can=\(c.canPutBack(n))"); if c.canPutBack(n) { c.putBack(n) }; emit("recipes=\(c.recipes.recipes.map(\.name))") }
        case "mine": c.route = .mine; Shared.nav.page = .picklsss; await c.refreshMine(); emit("mine: \(c.mine?.picklsss.map { "\($0.title):\($0.state ?? "?")" } ?? []) failure=\(String(describing: c.mineFailure))")
        case "share-open":
            guard let r = c.recipes.recipes.first(where: { $0.name == str("recipe") }) else { emit("share-open: no recipe"); return }
            let mode: ShareSession.Mode = str("mode") == "file" ? .file : .share
            c.sharing = ShareSession(controller: c, recipe: r, mode: mode)
            emit("share-open: rows=\(c.sharing?.rows.map { "\($0.part):\($0.violations.count)v" } ?? []) blocking=\(c.sharing?.blocking.map(\.message) ?? [])")
        case "share-open-update":
            guard let r = c.recipes.recipes.first(where: { $0.name == str("recipe") }), let rec = c.sharedRecord(forRecipe: r.id) else { emit("share-open-update: nothing shared"); return }
            c.sharing = ShareSession(controller: c, recipe: r, mode: .update(rec))
            await c.sharing?.loadPrevious()
            emit("share-open-update: newer=\(c.isNewerThanShared(rec)) rows=\(c.sharing?.rows.map { "\($0.part):\(String(describing: $0.changed))" } ?? []) canSend=\(c.sharing?.canSend ?? false)")
        case "tweak-recipe":
            // Changes a saved recipe's window gap, as a save would.
            if var r = c.recipes.recipes.first(where: { $0.name == str("recipe") }), let d = r.sections["windows"], var j = JSONValue.parse(d)?.object { j["gap"] = .int(s["gap"] as? Int ?? 21); r.sections["windows"] = JSONValue.object(j).encoded(); r.updatedAt = Date(); c.recipes.replaceTaken(r); emit("tweak-recipe: ok newer=\(c.sharedRecord(forRecipe: r.id).map(c.isNewerThanShared) ?? false)") }
        case "share-set":
            guard let sh = c.sharing else { return }
            if let t = s["title"] as? String { sh.title = t }
            if let l = s["line"] as? String { sh.line = l }
            if let h = s["handle"] as? String { sh.handleText = h }
            if let n = s["note"] as? String { sh.note = n }
            if let off = s["off"] as? [String] { for p in off { sh.toggle(p, on: false) } }
            if let on = s["on"] as? [String] { for p in on { sh.toggle(p, on: true) } }
            emit("share-set: canContinue=\(sh.canContinue) canSend=\(sh.canSend) blocking=\(sh.blocking.count)")
        case "share-next": c.sharing?.next()
        case "share-back": c.sharing?.back()
        case "share-send":
            await c.sharing?.send()
            emit("share-send: step=\(String(describing: c.sharing?.step)) outcome=\(String(describing: c.sharing?.outcome)) message=\(c.sharing?.message ?? "-") errors=\(c.sharing?.errors.map(\.message) ?? []) closed=\(c.sharing?.closedReason ?? "-") handleProblem=\(c.sharing?.handleProblem ?? "-")")
        case "share-file":
            // Saves the file without the panel: same encoder, written where the script says.
            if let sh = c.sharing, var setup = sh.export?.setup {
                setup.title = sh.title; setup.line = sh.line
                if case .success(let d) = SharedSetupFile.encode(setup, madeBy: c.license.currentPass?.kid ?? "") { try? d.write(to: URL(fileURLWithPath: str("path"))); emit("share-file: wrote \(d.count) bytes madeBy=\(c.license.currentPass?.kid ?? "")") }
            }
        case "takedown":
            if let card = c.mine?.picklsss.first(where: { $0.title.hasPrefix(str("title")) }) { do { try await c.takeDown(card.id); emit("takedown: ok") } catch { emit("takedown: \(error)") } }
        case "open-file": c.openFile(URL(fileURLWithPath: str("path"))); try? await Task.sleep(nanoseconds: 500_000_000); emit("open-file: stage=\(String(describing: c.take?.stage)) problem=\(c.fileProblem?.why ?? "-") lines=\(c.take?.plan?.lines.map(\.id) ?? [])")
        case "recipe-menu-original":
            if let r = c.recipes.recipes.first(where: { $0.name.hasPrefix(str("recipe")) }) { emit("original: \(String(describing: c.recipes.goToAuthorsOriginal(r.id)))") }
        case "http":
            guard let url = URL(string: str("url")) else { return }
            var req = URLRequest(url: url); req.httpMethod = s["method"] as? String ?? "POST"
            if let b = s["body"] { req.httpBody = try? JSONSerialization.data(withJSONObject: b); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let r = try? await URLSession.shared.data(for: req)
            emit("http \(url.path): \(String(data: r?.0 ?? Data(), encoding: .utf8)?.prefix(200) ?? "-")")
        case "recipes": emit("recipes: \(c.recipes.recipes.map { "\($0.name)[prev=\($0.previous != nil) orig=\($0.authorsOriginal != nil) skipped=\($0.skipped.count)]" }) active=\(c.recipes.active?.name ?? "-")")
        case "take-record": emit("takes: \(c.state.takes.map { "\($0.title) counted=\($0.counted) token=\($0.takeToken != nil) days=\($0.activeDays.count) verdict=\(String(describing: $0.verdict))" })")
        default: emit("unknown step \(name)")
        }
    }

    private static func describe() -> String {
        "stage=\(String(describing: c.take?.stage)) lock=\(c.take?.showLock ?? false) pick=\(c.hasExtra) count=\(c.countChoice) handle=\(c.handle ?? "-") notices=\(c.notices.count)"
    }

    /// The main window's content as a PNG, drawn by SwiftUI itself (no screen-recording permission). The window's own view cannot be
    /// copied (its text lives in layers `cacheDisplay` does not see), so the same view is rendered from the same controllers. Sheets
    /// are separate windows, so the one that is open is drawn into its own file.
    private static func shot(_ name: String) {
        guard let dir = env["WHOPRRR_SHOTS_DIR"] else { return }
        let size = env["WHOPRRR_WINDOW_SIZE"]?.split(separator: "x").compactMap { Double($0) }.filter { $0 > 0 } ?? [940, 700]
        let w = size.count == 2 ? size[0] : 940, h = size.count == 2 ? size[1] : 700
        func write(_ content: some View, _ file: String, _ width: Double, _ height: Double?) {
            let framed = content.frame(width: CGFloat(width), height: height.map { CGFloat($0) }).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, env["WHOPPER_APPEARANCE"] == "light" ? .light : .dark)
            let r = ImageRenderer(content: framed)
            r.scale = 1.5
            guard let cg = r.cgImage else { emit("shot \(file) FAILED"); return }
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(file).png"))
            emit("shot \(file) \(cg.width)x\(cg.height)")
        }
        if name.hasPrefix("window-") {
            write(Shared.wrap(MainWindowView()).preferredColorScheme(env["WHOPPER_APPEARANCE"] == "light" ? .light : .dark), name, w, h)
            return
        }
        // The page as the window lays it out (a ScrollView draws nothing in an image, so the page is drawn without one): the same
        // 680-wide column with 28 points around it, the save bar pinned above it, followed by any notices.
        let page = VStack(alignment: .leading, spacing: 16) {
            SaveBarArea()
            NoticesBar()
            PageContent(page: Shared.nav.page)
        }.padding(28).frame(width: 680 + 56, alignment: .topLeading)
            .overlay(alignment: .top) {
                if let milestone = c.milestone {
                    PicklsssMilestoneView(milestone: milestone).padding(.top, 76)
                }
            }
        write(Shared.wrap(page).tint(Brand.violetBright), name, 680 + 56, nil)
        if let preview = presetPreview, let surface = PresetSurfaces.surface(preview.key) {
            let groups = surface.groups(in: Shared.presets)
            if preview.managing {
                let more = (groups.yours + groups.builtIn).first { $0.name == preview.more }?.id
                write(Shared.wrap(ManagePresetsView(surface: surface, previewActionsFor: more, renderAllRows: true)), "\(name)-sheet", 480, nil)
            } else {
                let picker = PresetPickerContents(surface: surface, groups: groups, close: {}, saveNew: {}, manage: {}, renderAllRows: true)
                write(Shared.wrap(picker), "\(name)-menu", 268, nil)
            }
        }
        if let t = c.take, t.askCount { write(Shared.wrap(CountSheet(s: t)).padding(20), "\(name)-sheet", 560, nil) }
        if let sh = c.sharing { write(Shared.wrap(ShareFlowView(s: sh).content), "\(name)-share", 560, nil) }
    }
}
#endif
