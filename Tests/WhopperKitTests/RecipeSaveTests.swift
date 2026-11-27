import XCTest
@testable import WhopperKit

/// Runs scheduled work when the test says time has passed.
@MainActor
final class ManualScheduler: RecipeScheduler {
    private struct Job { let id: Int; let due: TimeInterval; let work: @MainActor () -> Void }
    private var jobs: [Job] = []
    private var cancelled = Set<Int>()
    private var next = 0
    private(set) var now: TimeInterval = 0
    var pending: Int { jobs.filter { !cancelled.contains($0.id) }.count }

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        next += 1
        let id = next
        jobs.append(Job(id: id, due: now + seconds, work: work))
        return { [weak self] in self?.cancelled.insert(id) }
    }

    func advance(_ seconds: TimeInterval) {
        let target = now + seconds
        while let job = jobs.filter({ !cancelled.contains($0.id) && $0.due <= target + 1e-9 }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            now = max(now, job.due)
            jobs.removeAll { $0.id == job.id }
            job.work()
        }
        now = target
    }
}

@MainActor
class RecipeHarnessCase: XCTestCase {
    var clock = Date(timeIntervalSince1970: 1_795_000_000)       // 2026-11-18
    var dirs: [URL] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.path); try? FileManager.default.removeItem(at: d) }
        dirs = []
        super.tearDown()
    }

    func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("whoprrr-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    struct Harness {
        let store: RecipeStore
        let bar: SaveBarController
        let sched: ManualScheduler
        let audio: FakeSurface
        let windows: FakeSurface
        let url: URL
    }

    func harness(url: URL? = nil) -> Harness {
        let u = url ?? tmpDir().appendingPathComponent("recipes.json")
        let s = RecipeStore(url: u, now: { [unowned self] in self.clock })
        let a = FakeSurface("audio", "home-audio"), w = FakeSurface("windows", "home-windows")
        s.register(a); s.register(w)
        let sched = ManualScheduler()
        let bar = SaveBarController(store: s, scheduler: sched, now: { sched.now })
        return Harness(store: s, bar: bar, sched: sched, audio: a, windows: w, url: u)
    }

    func tick(_ s: TimeInterval = 60) { clock = clock.addingTimeInterval(s) }

    let home: [DeviceSignature] = [.init(kind: .display, key: "samsung", name: "S34CG50"), .init(kind: .audioInput, key: "rode", name: "RØDE PodMic USB")]
    let road: [DeviceSignature] = [.init(kind: .audioOutput, key: "airpods", name: "AirPods")]
}

// MARK: Save bar, Cookin' and the waits

final class SaveBarTests: RecipeHarnessCase {
    func makeDesk(_ h: Harness) -> Recipe {
        h.store.create(name: "Desk", symbol: "house", includes: ["audio", "windows"], devices: home, autoApply: true)
    }
    func change(_ h: Harness, _ v: String) { h.audio.value = v; h.bar.settingsDidChange() }

    func testNothingShowsWhileTheRecipeMatchesTheSettings() {
        let h = harness(); _ = makeDesk(h)
        h.bar.pageDidChange()
        XCTAssertEqual(h.bar.phase, .idle)
        XCTAssertNil(h.bar.reminderRecipe)
    }

    func testTheMarkStaysQuietWhileYouTune() {
        let h = harness(); _ = makeDesk(h)
        change(h, "bass+3")
        h.sched.advance(60)
        change(h, "bass+4")
        h.sched.advance(120)
        XCTAssertEqual(h.bar.phase, .changing(recipe: "Desk"))
        XCTAssertNil(h.bar.reminderRecipe)
        XCTAssertEqual(h.sched.pending, 0)
    }

    func testLeavingChecksTheVeryLatestSetting() {
        let h = harness(); _ = makeDesk(h)
        h.audio.value = "bass+3"
        h.bar.pageDidChange()
        XCTAssertEqual(h.bar.phase, .changing(recipe: "Desk"))
        XCTAssertEqual(h.bar.reminderRecipe, "Desk")
    }

    func testNotYetSuppressesTheReminderThroughMorePageChanges() {
        let h = harness(); _ = makeDesk(h)
        change(h, "bass+3")
        h.bar.pageDidChange()
        h.bar.dismissReminder()
        h.bar.settingsDidChange()
        h.bar.pageDidChange()
        XCTAssertNil(h.bar.reminderRecipe)
        XCTAssertEqual(h.bar.phase, .changing(recipe: "Desk"))
    }

    func testARealChangeRearmsTheReminderForTheNextPage() {
        let h = harness(); _ = makeDesk(h)
        change(h, "bass+3")
        h.bar.pageDidChange()
        XCTAssertEqual(h.bar.reminderRecipe, "Desk")
        change(h, "bass+4")
        XCTAssertNil(h.bar.reminderRecipe)
        h.bar.pageDidChange()
        XCTAssertEqual(h.bar.reminderRecipe, "Desk")
    }

    func testChangingItBackRemovesTheMarkAndReminder() {
        let h = harness(); _ = makeDesk(h)
        change(h, "bass+3")
        h.bar.pageDidChange()
        change(h, "home-audio")
        XCTAssertEqual(h.bar.phase, .idle)
        XCTAssertNil(h.bar.reminderRecipe)
        XCTAssertEqual(h.sched.pending, 0)
    }

    func testSavingShowsTheFillThenServedAndDismissesTheConfirmationAfterFourSeconds() {
        let h = harness(); let r = makeDesk(h)
        change(h, "bass+3")
        h.bar.save()
        XCTAssertEqual(h.bar.phase, .saving(recipe: "Desk"))
        h.sched.advance(0.49)
        XCTAssertFalse(h.bar.served)
        h.sched.advance(0.01)
        let saved = SaveBarController.Phase.saved(.init(message: "Saved to Desk.", undoRecipeID: r.id))
        XCTAssertEqual(h.bar.phase, saved)
        XCTAssertTrue(h.bar.served)
        h.sched.advance(3.99)
        XCTAssertFalse(h.bar.served)
        XCTAssertEqual(h.bar.phase, saved)
        h.sched.advance(0.01)
        XCTAssertEqual(h.bar.phase, .idle)
        XCTAssertEqual(h.sched.pending, 0)
        XCTAssertFalse(h.store.isModified(r.id))
    }

    func testHoverPausesTheConfirmationAndLeavingResumesTheRemainingTime() {
        let h = harness(); _ = makeDesk(h)
        change(h, "bass+3")
        h.bar.save(); h.sched.advance(0.5)
        h.sched.advance(3)
        h.bar.hoverConfirmation(true)
        h.sched.advance(30)
        guard case .saved = h.bar.phase else { return XCTFail("Hovered confirmation should stay") }
        h.bar.hoverConfirmation(false)
        h.sched.advance(0.99)
        guard case .saved = h.bar.phase else { return XCTFail("Confirmation should resume its remaining time") }
        h.sched.advance(0.01)
        XCTAssertEqual(h.bar.phase, .idle)
    }

    func testSavedSettingsAreWhatTheRecipeAppliesNow() {
        let h = harness(); let r = makeDesk(h)
        change(h, "bass+3"); h.bar.save()
        h.audio.value = "other"
        h.store.apply(r.id)
        XCTAssertEqual(h.audio.value, "bass+3")
    }

    func testUndoOnTheConfirmationGoesBackAndLeavesTheNewerVersionToGoForwardTo() {
        let h = harness(); let r = makeDesk(h)
        change(h, "bass+3"); h.bar.save(); h.sched.advance(0.6)
        h.bar.undoSave()
        XCTAssertEqual(h.audio.value, "home-audio")                         // the settings are back
        XCTAssertEqual(h.store.recipe(r.id)?.sections, RecipeStore.sections(["audio": "home-audio", "windows": "home-windows"]))
        XCTAssertEqual(h.store.recipe(r.id)?.previous?.isNewer, true)       // and the undo can be undone
        XCTAssertEqual(h.bar.phase, .idle)
        XCTAssertFalse(h.store.isModified(r.id))
        XCTAssertEqual(h.sched.pending, 0)
    }

    func testChangingSomethingDuringTheConfirmationDropsIt() {
        let h = harness(); _ = makeDesk(h)
        change(h, "bass+3"); h.bar.save(); h.sched.advance(0.6)
        change(h, "bass+4")
        XCTAssertEqual(h.bar.phase, .changing(recipe: "Desk"))
        h.bar.undoSave()                                                    // nothing to undo any more
        XCTAssertEqual(h.audio.value, "bass+4")
    }

    func testChangingSomethingWhileSavingCancelsTheConfirmation() {
        let h = harness(); _ = makeDesk(h)
        change(h, "bass+3"); h.bar.save()
        change(h, "bass+4")
        h.sched.advance(0.6)
        XCTAssertEqual(h.bar.phase, .changing(recipe: "Desk"))
    }

    func testSavingWhenNothingChangedOffersNoUndoAndKeepsTheEarlierVersion() {
        let h = harness(); let r = makeDesk(h)
        change(h, "bass+3"); h.bar.save(); h.sched.advance(11)
        let before = h.store.recipe(r.id)!
        h.bar.save(); h.sched.advance(0.6)
        XCTAssertEqual(h.bar.phase, .saved(.init(message: "Saved to Desk.", undoRecipeID: nil)))
        XCTAssertEqual(h.store.recipe(r.id)?.previous, before.previous)
        XCTAssertEqual(h.store.recipe(r.id)?.sections, before.sections)
    }

    func testPutBackDiscardsTheChange() {
        let h = harness(); let r = makeDesk(h)
        change(h, "bass+3")
        h.bar.putBack()
        XCTAssertEqual(h.audio.value, "home-audio")
        XCTAssertEqual(h.bar.phase, .idle)
        XCTAssertFalse(h.store.isModified(r.id))
        XCTAssertNil(h.store.recipe(r.id)?.previous)                        // nothing was saved
        XCTAssertEqual(h.sched.pending, 0)
    }

    func testSaveAsNewLeavesTheOriginalAndMakesTheCopyActive() {
        let h = harness(); let r = makeDesk(h)
        change(h, "bass+3")
        XCTAssertEqual(h.store.suggestedCopyName(of: r.id), "Desk 2")
        h.bar.saveAsNew(name: "Desk 2")
        let copy = h.store.active!
        XCTAssertEqual(copy.name, "Desk 2"); XCTAssertNotEqual(copy.id, r.id)
        XCTAssertEqual(copy.devices, home); XCTAssertEqual(copy.symbol, "house")
        XCTAssertFalse(copy.autoApply)                                      // two recipes never fight over the same gear
        XCTAssertEqual(copy.sections["audio"], RecipeJSON.encode(["v": "bass+3"]))
        XCTAssertNil(copy.previous)
        XCTAssertEqual(h.store.recipe(r.id)?.sections["audio"], RecipeJSON.encode(["v": "home-audio"]))   // original untouched
        XCTAssertEqual(h.store.recipes.map(\.name), ["Desk", "Desk 2"])
        XCTAssertEqual(h.bar.phase, .saving(recipe: "Desk 2"))
        h.sched.advance(0.6)
        XCTAssertEqual(h.bar.phase, .saved(.init(message: "Saved as “Desk 2”.", undoRecipeID: nil)))
        XCTAssertFalse(h.store.isModified(copy.id))
    }

    func testSwitchingRecipeClearsTheBar() {
        let h = harness(); let r = makeDesk(h)
        h.audio.value = "road"
        let roadR = h.store.create(name: "Road", symbol: "airplane", includes: ["audio"], devices: road, autoApply: false)
        change(h, "x")
        XCTAssertEqual(h.bar.phase, .changing(recipe: "Road"))
        h.store.apply(r.id)
        XCTAssertEqual(h.bar.phase, .idle)
        XCTAssertNotNil(roadR)
    }

    func testChangesLeftUnsavedLastTimeShowOnlyTheMark() {
        let url = tmpDir().appendingPathComponent("recipes.json")
        do {
            let h = harness(url: url); let r = makeDesk(h)
            change(h, "bass+3")
            XCTAssertTrue(h.store.isModified(r.id))
        }
        let h2 = harness(url: url)
        h2.audio.value = "bass+3"                    // the surfaces load what they saved themselves
        h2.bar.start()
        XCTAssertEqual(h2.bar.phase, .changing(recipe: "Desk"))
        XCTAssertNil(h2.bar.reminderRecipe)
        XCTAssertEqual(h2.sched.pending, 0)
    }
}

// MARK: Previous version

final class PreviousVersionTests: RecipeHarnessCase {
    func testEverySaveKeepsTheVersionBeforeIt() {
        let h = harness()
        let r = h.store.create(name: "Desk", symbol: "house", includes: ["audio"], devices: home, autoApply: false)
        let t0 = h.store.recipe(r.id)!.updatedAt
        h.audio.value = "v2"; tick(); h.store.save(r.id)
        XCTAssertEqual(h.store.recipe(r.id)?.previous?.sections["audio"], RecipeJSON.encode(["v": "home-audio"]))
        XCTAssertEqual(h.store.recipe(r.id)?.previous?.savedAt, t0)
        XCTAssertEqual(h.store.recipe(r.id)?.previous?.replacedAt, clock)
        h.audio.value = "v3"; tick(); h.store.save(r.id)
        XCTAssertEqual(h.store.recipe(r.id)?.previous?.sections["audio"], RecipeJSON.encode(["v": "v2"]))     // one version only
        XCTAssertEqual(h.store.recipe(r.id)?.sections["audio"], RecipeJSON.encode(["v": "v3"]))
    }

    func testGoingBackSwapsAndDoingItAgainReturns() {
        let h = harness()
        let r = h.store.create(name: "Desk", symbol: "house", includes: ["audio", "windows"], devices: home, autoApply: false)
        h.audio.value = "v2"; tick(); h.store.save(r.id)
        let saved = h.store.recipe(r.id)!

        XCTAssertEqual(h.store.goBack(r.id), [])
        XCTAssertEqual(h.audio.value, "home-audio")
        XCTAssertEqual(h.store.recipe(r.id)?.sections["audio"], RecipeJSON.encode(["v": "home-audio"]))
        XCTAssertEqual(h.store.recipe(r.id)?.previous?.sections, saved.sections)
        XCTAssertTrue(h.store.recipe(r.id)!.previous!.isNewer)
        XCTAssertFalse(h.store.isModified(r.id))

        XCTAssertEqual(h.store.goBack(r.id), [])                            // and back again
        XCTAssertEqual(h.audio.value, "v2")
        XCTAssertEqual(h.store.recipe(r.id)?.sections, saved.sections)
        XCTAssertEqual(h.store.recipe(r.id)?.updatedAt, saved.updatedAt)
        XCTAssertEqual(h.store.recipe(r.id)?.previous?.sections, saved.previous?.sections)
        XCTAssertFalse(h.store.recipe(r.id)!.previous!.isNewer)
        XCTAssertFalse(h.store.isModified(r.id))
    }

    func testGoingBackOnARecipeThatIsNotActiveChangesOnlyTheRecipe() {
        let h = harness()
        let a = h.store.create(name: "Desk", symbol: "house", includes: ["audio"], devices: home, autoApply: false)
        h.audio.value = "v2"; h.store.save(a.id)
        h.audio.value = "road-audio"
        let b = h.store.create(name: "Road", symbol: "airplane", includes: ["audio"], devices: road, autoApply: false)
        XCTAssertEqual(h.store.activeID, b.id)
        XCTAssertEqual(h.store.goBack(a.id), [])
        XCTAssertEqual(h.audio.value, "road-audio")
        XCTAssertEqual(h.store.activeID, b.id)
        XCTAssertEqual(h.store.recipe(a.id)?.sections["audio"], RecipeJSON.encode(["v": "home-audio"]))
    }

    func testNothingToGoBackToIsReportedNotInvented() {
        let h = harness()
        let r = h.store.create(name: "Desk", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
        XCTAssertFalse(h.store.canGoBack(r.id))
        XCTAssertNil(h.store.goBack(r.id))
        XCTAssertNil(h.store.goBack(UUID()))
    }

    func testGoingBackReportsAPartThatCouldNotBeApplied() {
        let h = harness()
        let r = h.store.create(name: "Desk", symbol: "house", includes: ["audio", "windows"], devices: [], autoApply: false)
        h.windows.value = "w2"; h.store.save(r.id)
        h.windows.failApply = true
        XCTAssertEqual(h.store.goBack(r.id), ["Windows"])
    }

    func testPreviousVersionSurvivesARelaunch() {
        let url = tmpDir().appendingPathComponent("recipes.json")
        let h = harness(url: url)
        let r = h.store.create(name: "Desk", symbol: "house", includes: ["audio"], devices: home, autoApply: false)
        h.audio.value = "v2"; tick(); h.store.save(r.id); _ = h.store.goBack(r.id)
        let h2 = harness(url: url)
        XCTAssertEqual(h2.store.recipe(r.id), h.store.recipe(r.id))
        XCTAssertEqual(h2.store.recipe(r.id)?.previous?.isNewer, true)
    }

    func testSavingKeepsEachRecipesOwnCopy() {
        let h = harness()
        let a = h.store.create(name: "Desk", symbol: "house", includes: ["audio"], devices: home, autoApply: false)
        let b = h.store.create(name: "Road", symbol: "airplane", includes: ["audio"], devices: road, autoApply: false)
        h.audio.value = "bass"; h.store.save(b.id)
        XCTAssertEqual(h.store.recipe(a.id)?.sections["audio"], RecipeJSON.encode(["v": "home-audio"]))
        XCTAssertNil(h.store.recipe(a.id)?.previous)
    }

    func testMenuWording() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let loc = Locale(identifier: "en_GB")
        let now = utc(2026, 11, 26, 10, 0)
        func title(replaced: Date, newer: Bool = false, saved: Date? = nil) -> String {
            RecipeWording.goBackTitle(RecipeVersion(sections: [:], savedAt: saved ?? replaced, replacedAt: replaced, isNewer: newer), now: now, calendar: cal, locale: loc)
        }
        XCTAssertEqual(title(replaced: utc(2026, 11, 26, 8, 0)), "Go back to the version before today’s save")
        XCTAssertEqual(title(replaced: utc(2026, 11, 25, 18, 42)), "Go back to the version before yesterday’s save")
        XCTAssertEqual(title(replaced: utc(2026, 11, 23, 9, 0)), "Go back to the version before Monday’s save")
        XCTAssertEqual(title(replaced: utc(2026, 11, 12, 9, 0)), "Go back to the version before the save on 12 Nov")
        XCTAssertEqual(title(replaced: utc(2026, 11, 25, 18, 42), newer: true), "Go forward to the version you saved yesterday")
    }

    func testStoveWording() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let loc = Locale(identifier: "en_GB")
        let now = utc(2026, 11, 26, 10, 0)
        func detail(_ d: Date, _ parts: [String] = ["Audio"]) -> String { RecipeWording.stoveDetail(parts: parts, recipe: "Desk", changedAt: d, now: now, calendar: cal, locale: loc) }
        XCTAssertEqual(RecipeWording.stoveTitle, "You left something on the stove.")
        XCTAssertEqual(detail(utc(2026, 11, 25, 18, 42)), "You changed Audio yesterday at 18:42 and did not save it to Desk.")
        XCTAssertEqual(detail(utc(2026, 11, 26, 9, 15), ["Audio", "Windows"]), "You changed Audio and Windows today at 09:15 and did not save it to Desk.")
        XCTAssertEqual(detail(utc(2026, 11, 23, 7, 5), ["Audio", "Windows", "Clipboard"]), "You changed Audio, Windows and Clipboard on Monday at 07:05 and did not save it to Desk.")
        XCTAssertEqual(detail(utc(2026, 11, 26, 9, 59, 30)), "You changed Audio just now and did not save it to Desk.")
        XCTAssertEqual(detail(utc(2025, 12, 30, 12, 0)), "You changed Audio on 30 Dec 2025 at 12:00 and did not save it to Desk.")
        XCTAssertEqual(RecipeWording.unsavedSummary(recipe: "Desk", parts: ["Audio", "Windows"]), "Desk has changes you have not saved: Audio, Windows")
    }

    func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int = 0) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min; c.second = s
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }
}

extension RecipeStore {
    /// The sections a recipe of the fake surfaces holds, for comparing.
    static func sections(_ values: [String: String]) -> [String: Data] { values.mapValues { RecipeJSON.encode(["v": $0])! } }
}

// MARK: Unsaved state, left on the stove

final class UnsavedStateTests: RecipeHarnessCase {
    func testUnsavedStateSurvivesQuitAndRelaunch() {
        let url = tmpDir().appendingPathComponent("recipes.json")
        let h = harness(url: url)
        let r = h.store.create(name: "Desk", symbol: "house", includes: ["audio", "windows"], devices: home, autoApply: true)
        h.audio.value = "bass+3"                    // the surface saves its own settings; the recipe file keeps the baseline
        XCTAssertTrue(h.store.isModified(r.id))
        tick(); h.store.noteChange(persist: true)

        let h2 = harness(url: url)                  // relaunch: the audio surface loads what it saved
        h2.audio.value = "bass+3"
        XCTAssertEqual(h2.store.activeID, r.id)
        XCTAssertTrue(h2.store.isModified(r.id))
        XCTAssertEqual(h2.store.changedPartTitles(), ["Audio"])
        XCTAssertEqual(h2.store.recipe(r.id)?.sections["audio"], RecipeJSON.encode(["v": "home-audio"]))     // the recipe itself is untouched
    }

    func testClosingTheWindowWithChangesLeavesAReminderThatSurvivesRelaunch() {
        let url = tmpDir().appendingPathComponent("recipes.json")
        let h = harness(url: url)
        let r = h.store.create(name: "Desk", symbol: "house", includes: ["audio", "windows"], devices: [], autoApply: false)
        h.audio.value = "bass+3"; h.bar.settingsDidChange()
        let changedAt = clock
        tick(3600)
        h.store.noteLeaving()
        XCTAssertEqual(h.store.stove, LeftOnStove(recipeID: r.id, parts: ["audio"], changedAt: changedAt, landed: false))
        XCTAssertTrue(h.store.isModified(r.id))                              // the change stays live

        let h2 = harness(url: url)
        h2.audio.value = "bass+3"
        XCTAssertEqual(h2.store.stove, h.store.stove)
        XCTAssertEqual(h2.store.takeLandingPart(), "audio")                  // lands on the page that changed, once
        XCTAssertNil(h2.store.takeLandingPart())
        XCTAssertNotNil(h2.store.stove)                                      // the reminder stays
        h2.store.noteLeaving()                                               // leaving again lands again
        XCTAssertEqual(h2.store.takeLandingPart(), "audio")
        XCTAssertEqual(h2.store.stove?.changedAt, changedAt)                 // still "changed yesterday", not "just now"
    }

    func testLeavingWithNothingUnsavedLeavesNoReminder() {
        let h = harness()
        _ = h.store.create(name: "Desk", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
        h.store.noteLeaving()
        XCTAssertNil(h.store.stove)
        XCTAssertNil(h.store.takeLandingPart())
    }

    func testReminderClearsOnSavePutBackApplyDeleteAndChangingItBack() {
        func leave(_ h: Harness) -> Recipe {
            let r = h.store.create(name: "Desk", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
            h.audio.value = "x"; h.bar.settingsDidChange(); h.store.noteLeaving()
            XCTAssertNotNil(h.store.stove)
            return r
        }
        var h = harness(); var r = leave(h)
        h.bar.save(); XCTAssertNil(h.store.stove)
        h = harness(); r = leave(h)
        h.bar.putBack(); XCTAssertNil(h.store.stove)
        h = harness(); r = leave(h)
        h.store.apply(r.id); XCTAssertNil(h.store.stove)
        h = harness(); r = leave(h)
        h.store.delete(r.id); XCTAssertNil(h.store.stove)
        h = harness(); r = leave(h)
        h.audio.value = "home-audio"; h.bar.settingsDidChange(); XCTAssertNil(h.store.stove)
        h = harness(); r = leave(h)
        h.bar.saveAsNew(name: "Desk 2"); XCTAssertNil(h.store.stove)
    }

    func testReminderThatNoLongerAppliesIsDroppedAtLaunch() {
        let url = tmpDir().appendingPathComponent("recipes.json")
        let h = harness(url: url)
        _ = h.store.create(name: "Desk", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
        h.audio.value = "x"; h.bar.settingsDidChange(); h.store.noteLeaving()
        let h2 = harness(url: url)                  // relaunch, but the audio settings are back to what the recipe holds
        h2.bar.start()
        XCTAssertNil(h2.store.stove)
        XCTAssertEqual(h2.bar.phase, .idle)
        let h3 = harness(url: url)
        XCTAssertNil(h3.store.stove)                // and that was written down
    }

    func testTheBarAndTheReminderGoTogether() {
        let h = harness()
        _ = h.store.create(name: "Desk", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
        h.audio.value = "x"; h.bar.settingsDidChange(); h.store.noteLeaving()
        XCTAssertNotNil(h.store.stove)
        if case .changing = h.bar.phase {} else { XCTFail("the bar should show") }
        h.bar.putBack()
        XCTAssertNil(h.store.stove); XCTAssertEqual(h.bar.phase, .idle)
    }
}

// MARK: Auto-switch

final class AutoSwitchTests: RecipeHarnessCase {
    /// Home is the active recipe with the road gear connected: Road wants to take over.
    func scene() -> (Harness, Recipe, Recipe) {
        let h = harness()
        let homeR = h.store.create(name: "Desk", symbol: "house", includes: ["audio", "windows"], devices: home, autoApply: true)
        h.audio.value = "road-audio"
        let roadR = h.store.create(name: "Road", symbol: "airplane", includes: ["audio", "windows"], devices: road, autoApply: true)
        h.store.apply(homeR.id)
        return (h, homeR, roadR)
    }

    func testWithNothingUnsavedItSwitchesAsBefore() {
        let (h, _, roadR) = scene()
        XCTAssertEqual(h.store.autoSwitchDecision(connected: road), .switchNow(roadR.id))
        h.store.considerAutoSwitch(connected: road)
        XCTAssertEqual(h.store.activeID, roadR.id)
        XCTAssertEqual(h.audio.value, "road-audio")
        XCTAssertEqual(h.store.notice, "Switched to “Road” because its gear is connected")
        XCTAssertNil(h.store.pendingSwitch)
    }

    func testWithUnsavedChangesItAsksAndChangesNothing() {
        let (h, homeR, roadR) = scene()
        h.audio.value = "bass+3"
        let d = h.store.considerAutoSwitch(connected: road)
        let expected = PendingSwitch(candidateID: roadR.id, candidateName: "Road", currentID: homeR.id, currentName: "Desk", parts: ["Audio"])
        XCTAssertEqual(d, .ask(expected))
        XCTAssertEqual(h.store.pendingSwitch, expected)
        XCTAssertEqual(h.store.activeID, homeR.id)                       // not switched
        XCTAssertEqual(h.audio.value, "bass+3")                          // not dropped
        XCTAssertNil(h.store.notice.flatMap { $0.hasPrefix("Switched") ? $0 : nil })
    }

    func testStayKeepsTheWorkAndTheRecipe() {
        let (h, homeR, _) = scene()
        h.audio.value = "bass+3"; h.store.considerAutoSwitch(connected: road)
        h.store.resolveSwitch(.stay)
        XCTAssertEqual(h.store.activeID, homeR.id); XCTAssertEqual(h.audio.value, "bass+3")
        XCTAssertTrue(h.store.isModified(homeR.id)); XCTAssertNil(h.store.pendingSwitch)
    }

    func testSaveThenSwitchKeepsTheWorkInTheRecipeItWasMadeIn() {
        let (h, homeR, roadR) = scene()
        h.audio.value = "bass+3"; h.store.considerAutoSwitch(connected: road)
        h.store.resolveSwitch(.saveThenSwitch)
        XCTAssertEqual(h.store.activeID, roadR.id)
        XCTAssertEqual(h.audio.value, "road-audio")
        XCTAssertEqual(h.store.recipe(homeR.id)?.sections["audio"], RecipeJSON.encode(["v": "bass+3"]))
        XCTAssertEqual(h.store.recipe(homeR.id)?.previous?.sections["audio"], RecipeJSON.encode(["v": "home-audio"]))
        h.store.apply(homeR.id)                                          // coming back to Desk, the change is in it
        XCTAssertEqual(h.audio.value, "bass+3")
    }

    func testSwitchWithoutSavingLeavesTheRecipeAsItWas() {
        let (h, homeR, roadR) = scene()
        h.audio.value = "bass+3"; h.store.considerAutoSwitch(connected: road)
        h.store.resolveSwitch(.switchWithoutSaving)
        XCTAssertEqual(h.store.activeID, roadR.id)
        XCTAssertEqual(h.store.recipe(homeR.id)?.sections["audio"], RecipeJSON.encode(["v": "home-audio"]))
        XCTAssertNil(h.store.recipe(homeR.id)?.previous)
    }

    func testChangesInAPartTheRecipeDoesNotHoldAreNotUnsaved() {
        let h = harness()
        let a = h.store.create(name: "Desk", symbol: "house", includes: ["audio"], devices: home, autoApply: true)
        h.audio.value = "r"
        let b = h.store.create(name: "Road", symbol: "airplane", includes: ["audio"], devices: road, autoApply: true)
        h.store.apply(a.id)
        h.windows.value = "tweaked"                                      // Desk does not hold windows
        XCTAssertEqual(h.store.autoSwitchDecision(connected: road), .switchNow(b.id))
    }

    func testTheQuestionIsWithdrawnWhenTheGearComesBack() {
        let (h, _, _) = scene()
        h.audio.value = "bass+3"; h.store.considerAutoSwitch(connected: road)
        XCTAssertNotNil(h.store.pendingSwitch)
        h.store.considerAutoSwitch(connected: home)                      // the desk gear is back: Desk is already active
        XCTAssertNil(h.store.pendingSwitch)
    }

    func testAnAnswerAfterThingsMovedOnIsIgnored() {
        let (h, homeR, roadR) = scene()
        h.audio.value = "bass+3"; h.store.considerAutoSwitch(connected: road)
        h.store.apply(roadR.id)                                          // the person switched by hand meanwhile
        h.store.resolveSwitch(.switchWithoutSaving)
        XCTAssertEqual(h.store.activeID, roadR.id)
        XCTAssertNil(h.store.recipe(homeR.id)?.previous)

        h.audio.value = "x"; h.store.apply(homeR.id); h.audio.value = "bass+3"; h.store.considerAutoSwitch(connected: road)
        h.store.delete(roadR.id)
        h.store.resolveSwitch(.switchWithoutSaving)
        XCTAssertEqual(h.store.activeID, homeR.id)
    }

    func testAskingTwiceOnlyKeepsTheLatestQuestion() {
        let (h, _, roadR) = scene()
        h.audio.value = "bass+3"
        h.store.considerAutoSwitch(connected: road); h.store.considerAutoSwitch(connected: road)
        XCTAssertEqual(h.store.pendingSwitch?.candidateID, roadR.id)
        h.store.resolveSwitch(.stay)
        XCTAssertNil(h.store.pendingSwitch)
        h.store.resolveSwitch(.switchWithoutSaving)                      // no question, so nothing happens
        XCTAssertNotEqual(h.store.activeID, roadR.id)
    }

    func testNoActiveRecipeSwitchesWithoutAsking() {
        let h = harness()
        let a = h.store.create(name: "Desk", symbol: "house", includes: ["audio"], devices: home, autoApply: true)
        h.store.delete(a.id)
        let b = h.store.create(name: "Road", symbol: "airplane", includes: ["audio"], devices: road, autoApply: true)
        h.store.delete(b.id)
        XCTAssertEqual(h.store.autoSwitchDecision(connected: road), .none)
    }

    func testWordingOfTheQuestion() {
        XCTAssertEqual(RecipeWording.switchQuestionDetail(candidate: "On the road", current: "Desk", parts: ["Audio"]), "On the road fits what is connected now. Desk has unsaved changes to Audio.")
        XCTAssertEqual(RecipeWording.saveThenSwitch(current: "Desk"), "Save to Desk, then switch")
        XCTAssertEqual(RecipeWording.switchWithoutSaving, "Switch without saving")
        XCTAssertEqual(RecipeWording.stay(current: "Desk"), "Stay on Desk")
    }
}
