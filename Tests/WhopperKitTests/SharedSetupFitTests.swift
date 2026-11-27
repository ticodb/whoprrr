import XCTest
import AudioCore
import WindowCore
import ClipboardCore
import InputCore
@testable import WhopperKit

@MainActor
final class SharedSetupFitTests: XCTestCase {
    let setup = Personal.setup()

    func plan(_ env: ReceiverEnvironment, overrides: [Int: GearOverride] = [:], off: Set<String> = []) -> FitPlan {
        SharedSetupFit.plan(setup, for: env, overrides: overrides, switchedOff: off)
    }
    func fit(_ env: ReceiverEnvironment, overrides: [Int: GearOverride] = [:]) -> SharedSetupFitResult {
        SharedSetupFit.fit(setup, plan: plan(env, overrides: overrides), for: env, madeBy: "FP-1234")
    }
    func audio(_ r: SharedSetupFitResult) -> AudioSettings { RecipeJSON.decode(AudioSettings.self, from: r.recipe.sections["audio"]!)! }

    // MARK: Matching the author's gear

    func testExactModelsMatchFirst() {
        let p = plan(Personal.env())
        XCTAssertEqual(p.matches.map(\.quality), [.exactModel, .exactModel, .exactModel, .exactModel])
        XCTAssertEqual(p.matches[0].receiver?.key, "RX-SPK")
        XCTAssertTrue(p.off.isEmpty, "\(p.off.map { "\($0.id): \($0.state)" })")
    }

    func testTheSameRoleMatchesWhenTheModelDiffers() {
        let bose = DeviceSignature(kind: .audioOutput, key: "RX-BOSE", name: "Bose Mini II")
        let p = plan(Personal.env(gear: [bose, Personal.rxMic, Personal.rxMonitor, Personal.rxMouse]))
        XCTAssertEqual(p.matches[0].quality, .sameRole)
        XCTAssertEqual(p.matches[0].receiver?.key, "RX-BOSE")
    }

    func testAnExactModelBeatsAnEarlierDeviceOfTheSameRole() {
        let bose = DeviceSignature(kind: .audioOutput, key: "RX-BOSE", name: "Bose Mini II")
        let p = plan(Personal.env(gear: [bose, Personal.rxSpeaker, Personal.rxMic, Personal.rxMonitor, Personal.rxMouse]))
        XCTAssertEqual(p.matches[0].receiver?.key, "RX-SPK"); XCTAssertEqual(p.matches[0].quality, .exactModel)
    }

    func testNoDeviceOfThatRoleMeansNoMatch() {
        let p = plan(Personal.env(gear: [Personal.rxMic]))
        XCTAssertEqual(p.matches.map(\.quality), [.none, .exactModel, .none, .none])
        XCTAssertNil(p.matches[0].receiver)
    }

    func testModelNamesAreComparedIgnoringCase() {
        let p = plan(Personal.env(gear: [DeviceSignature(kind: .audioOutput, key: "k", name: "EDIFIER r1280")]))
        XCTAssertEqual(p.matches[0].quality, .exactModel)
    }

    func testAPersonCanOverrideTheProposal() {
        let bose = DeviceSignature(kind: .audioOutput, key: "RX-BOSE", name: "Bose Mini II")
        let env = Personal.env(gear: [Personal.rxSpeaker, bose, Personal.rxMic, Personal.rxMonitor, Personal.rxMouse])
        let p = plan(env, overrides: [0: .device(bose.id)])
        XCTAssertEqual(p.matches[0].receiver?.key, "RX-BOSE"); XCTAssertEqual(p.matches[0].quality, .sameRole)
        XCTAssertTrue(p.line("audio.equalizer")!.state.isOff)
        let none = plan(env, overrides: [0: .none])
        XCTAssertNil(none.matches[0].receiver); XCTAssertEqual(none.matches[0].quality, .none)
        XCTAssertTrue(none.line("audio.keepAwake.0")!.state.isOff)
    }

    func testTwoOfTheAuthorsDevicesDoNotLandOnTheSameDeviceWhenAnotherIsFree() {
        var s = setup
        s.gear.append(SharedGear(role: "speaker", model: "Other speaker"))
        let a = DeviceSignature(kind: .audioOutput, key: "A", name: "Foo"), b = DeviceSignature(kind: .audioOutput, key: "B", name: "Bar")
        let m = SharedSetupFit.plan(s, for: Personal.env(gear: [a, b]), overrides: [:]).matches.filter { $0.author.role == "speaker" }
        XCTAssertEqual(Set(m.compactMap { $0.receiver?.key }), ["A", "B"])
    }

    // MARK: The state of each line

    func testEveryLineAppliesOnTheSameGear() {
        let p = plan(Personal.env())
        for l in p.lines { XCTAssertFalse(l.state.isOff, "\(l.id)") }
        XCTAssertNotNil(p.line("audio.effects")?.state.reason, "the limiter note")
    }

    func testADifferentSpeakerModelSkipsTheCurveAndKeepsTheReceiversOwn() throws {
        let bose = DeviceSignature(kind: .audioOutput, key: "RX-BOSE", name: "Bose Mini II")
        let env = Personal.env(gear: [bose, Personal.rxMic, Personal.rxMonitor, Personal.rxMouse])
        let p = plan(env)
        let l = try XCTUnwrap(p.line("audio.equalizer"))
        XCTAssertEqual(l.state, .off("Your speakers are the Bose Mini II, not the Edifier R1280 this curve was made for, so the equalizer curve is skipped and yours is kept."))
        XCTAssertTrue(p.line("audio.equalizer.speaker.0")!.state.isOff)
        let r = fit(env)
        XCTAssertEqual(audio(r).eq.defaultProfile, RecipeJSON.decode(AudioSettings.self, from: Personal.receiversOwn()["audio"]!)!.eq.defaultProfile, "the receiver's curve is kept")
        XCTAssertNil(audio(r).eq.profiles["RX-BOSE"])
        XCTAssertTrue(r.recipe.skipped.contains { $0.id == "audio.equalizer" && $0.reason.contains("skipped") })
    }

    func testNoSpeakerAtAllGivesAReason() {
        let p = plan(Personal.env(gear: [Personal.rxMic]))
        XCTAssertEqual(p.line("audio.equalizer")?.state, .off("No speakers connected that match the Edifier R1280 this curve was made for."))
        XCTAssertEqual(p.line("audio.keepAwake.0")?.state, .off("No speaker connected that matches the Edifier R1280."))
    }

    func testAMonitorOfADifferentModelSwitchesTheDisplayValuesOff() {
        let other = DeviceSignature(kind: .display, key: "RX-D2", name: "U2723QE")
        XCTAssertEqual(plan(Personal.env(gear: [other])).line("display")?.state,
                       .off("Your monitor is the U2723QE, not the S34CG50 these values were made for, so they are skipped."))
        XCTAssertEqual(plan(Personal.env(gear: [])).line("display")?.state, .off("No monitor connected matches the S34CG50 these values were made for."))
    }

    func testTheDisplayBecomesAPresetRequestForTheMonitor() throws {
        let r = fit(Personal.env())
        XCTAssertEqual(r.displayPreset, DisplayPresetRequest(name: "Quiet desk", model: "S34CG50", values: ["brightness": 40, "contrast": 60, "colorPreset": 2, "sharpness": 5]))
        XCTAssertEqual(RecipeJSON.decode([String: String].self, from: r.recipe.sections["display"]!), ["preset": "Quiet desk"])
        let off = fit(Personal.env(gear: [DeviceSignature(kind: .display, key: "x", name: "U2723QE")]))
        XCTAssertNil(off.displayPreset); XCTAssertNil(off.recipe.sections["display"])
    }

    func testAPluginThatIsNotInstalledSwitchesItsLineOff() {
        let p = plan(Personal.env(plugins: [Personal.deEsser]))
        XCTAssertEqual(p.line("audio.plugins")?.state, .off("The plugin “Pro-Q 3” is not installed on this Mac."))
        XCTAssertFalse(p.line("microphone.plugins")!.state.isOff)
        XCTAssertEqual(plan(Personal.env(plugins: [])).line("microphone.plugins")?.state, .off("The plugin “De-esser” is not installed on this Mac."))
    }

    func testPluginsComeFromTheReceiversOwnInstallAndCarryNoState() throws {
        let a = audio(fit(Personal.env()))
        XCTAssertEqual(a.eq.plugins.count, 1)
        let slot = a.eq.plugins[0]
        XCTAssertEqual(slot.name, "Pro-Q 3"); XCTAssertNil(slot.state); XCTAssertFalse(slot.inProcess)
        XCTAssertEqual(slot.subtype, Personal.proQ.subtype)
    }

    func testANewerMacOSIsNeededForTheEqualizer() {
        let p = plan(Personal.env(macOS: "13.6"))
        XCTAssertEqual(p.line("audio.equalizer")?.state, .off("Needs macOS 14.2 or newer; this Mac has 13.6."))
        XCTAssertFalse(p.line("windows")!.state.isOff)
        XCTAssertFalse(plan(Personal.env(macOS: "14.2")).line("audio.equalizer")!.state.isOff)
        XCTAssertTrue(plan(Personal.env(macOS: "14.1.9")).line("audio.equalizer")!.state.isOff)
    }

    func testAMissingPermissionSwitchesALineOffAndAnUnaskedOneAddsANote() {
        let p = plan(Personal.env(permissions: [.accessibility: .denied, .microphone: .notDetermined]))
        XCTAssertEqual(p.line("windows")?.state, .off("Accessibility is not allowed for Whoprrr on this Mac. Allow it in System Settings, then switch this on."))
        XCTAssertTrue(p.line("keys.rules")!.state.isOff)
        XCTAssertEqual(p.line("microphone.chain")?.state, .appliesWithNote("Whoprrr will ask for Microphone."))
    }

    func testLogitechRulesNeedALogitechDevice() {
        let p = plan(Personal.env(gear: [Personal.rxSpeaker, Personal.rxMic, Personal.rxMonitor]))
        XCTAssertEqual(p.line("keys.logitech")?.state, .off("No Logitech device is connected."))
        XCTAssertFalse(p.line("keys.rules")!.state.isOff)
    }

    func testAnotherMicrophoneModelAppliesWithANote() throws {
        let sm = DeviceSignature(kind: .audioInput, key: "RX-SM", name: "SM7B")
        let p = plan(Personal.env(gear: [Personal.rxSpeaker, sm, Personal.rxMonitor, Personal.rxMouse]))
        XCTAssertEqual(p.line("microphone.chain")?.state, .appliesWithNote("Made for the Shure MV7; yours is the SM7B. Check the level."))
        XCTAssertEqual(audio(fit(Personal.env(gear: [Personal.rxSpeaker, sm, Personal.rxMonitor, Personal.rxMouse]))).mic.sourceUID, "RX-SM")
        XCTAssertTrue(p.line("audio.keepInput")!.state.isOff)
    }

    func testAPersonCanSwitchALineOffBeforeTaking() {
        let env = Personal.env()
        let p = plan(env, off: ["windows"])
        XCTAssertEqual(p.line("windows")?.state, .off("You switched this off."))
        let r = SharedSetupFit.fit(setup, plan: p, for: env)
        XCTAssertEqual(RecipeJSON.decode(WindowSettings.self, from: r.recipe.sections["windows"]!)?.gap, 2, "the receiver's own gap stays")
        XCTAssertEqual(r.recipe.skipped.map(\.id), ["windows"])
    }

    // MARK: The recipe

    func testTheFittedRecipeIsAnOrdinaryRecipeInTheAppsOwnSettings() throws {
        let r = fit(Personal.env())
        XCTAssertEqual(r.recipe.name, "Quiet desk"); XCTAssertFalse(r.recipe.autoApply)
        XCTAssertEqual(Set(r.recipe.devices.map(\.key)), ["RX-SPK", "RX-MIC", "RX-DISP", "MX Ergo"])
        let a = audio(r)
        XCTAssertTrue(a.eq.enabled); XCTAssertTrue(a.eq.permissionVerified, "the receiver's own flag stays")
        XCTAssertEqual(a.knownNames, ["RX-SPK": "My speaker"])
        XCTAssertTrue(a.eq.dynamics.limiterEnabled); XCTAssertEqual(a.eq.dynamics.ceilingDB, -1)
        XCTAssertEqual(a.keepAlive["RX-SPK"], KeepAliveSettings(enabled: true, levelDB: -60, frequencyHz: 40))
        XCTAssertEqual(a.inputPin, InputPinPolicy(enabled: true, preferredUIDs: ["RX-MIC"]))
        XCTAssertEqual(a.mic.sourceUID, "RX-MIC"); XCTAssertEqual(a.mic.gainDB, 3)
        XCTAssertEqual(a.mic.plugins.map(\.name), ["De-esser"])

        let w = try XCTUnwrap(RecipeJSON.decode(WindowSettings.self, from: r.recipe.sections["windows"]!))
        XCTAssertEqual(w.gap, 8); XCTAssertEqual(w.custom["maximize"], Shortcut(36, Shortcut.ctrl | Shortcut.opt)); XCTAssertEqual(w.drawerActions, ["leftHalf", "rightHalf", "maximize"]); XCTAssertEqual(w.disabled, ["topHalf"])

        let c = try XCTUnwrap(RecipeJSON.decode(ClipboardSettings.self, from: r.recipe.sections["clipboard"]!))
        XCTAssertEqual(c.maxItems, 1000)
        XCTAssertTrue(c.ignoredBundles.contains("com.receiver.notes"), "the receiver's own ignored apps stay")
        for d in ClipboardSettings.defaultIgnored { XCTAssertTrue(c.ignoredBundles.contains(d)) }

        let i = try XCTUnwrap(RecipeJSON.decode(InputSettings.self, from: r.recipe.sections["input"]!))
        XCTAssertEqual(i.hidMappings, [HIDMapping(src: HIDMapping.capsLock, dst: HIDMapping.f18)])
        XCTAssertEqual(i.rules.count, 4)
        XCTAssertNil(r.recipe.sections["features"], "installed features are never part of a shared setup")
    }

    func testFittingNeverChangesTheReceiversSettingsOrTheDocument() {
        let env = Personal.env(), before = env.sections
        _ = fit(env)
        XCTAssertEqual(env.sections, before)
    }

    func testPartsThatAreAllOffKeepTheReceiversOwnSections() throws {
        let env = Personal.env(gear: [])        // nothing connected: audio, keys' Logitech and display lines are off, but windows and clipboard still apply
        let r = fit(env)
        let w = try XCTUnwrap(RecipeJSON.decode(WindowSettings.self, from: r.recipe.sections["windows"]!))
        XCTAssertEqual(w.gap, 8)
        XCTAssertEqual(audio(r).eq.defaultProfile.bands.last?.gainDB, 1, "the receiver's own curve is kept")
        XCTAssertNil(r.recipe.sections["display"])
    }

    func testTheAuthorsOriginalIsKeptWithTheRecipe() throws {
        let r = fit(Personal.env())
        let o = try XCTUnwrap(r.recipe.authorsOriginal)
        XCTAssertEqual(o.title, "Quiet desk"); XCTAssertEqual(o.madeBy, "FP-1234")
        XCTAssertEqual(o.fittedSections, r.recipe.sections)
        XCTAssertEqual(JSONValue.parse(o.setup), setup.json)
        XCTAssertNil(r.recipe.previous, "the previous-version slot is separate and starts empty")
    }

    func testTheAuthorsOriginalSurvivesTheReceiversOwnSavesAndSwaps() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("whoprrr-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var clock = Date(timeIntervalSince1970: 1_795_000_000)
        let store = RecipeStore(url: url, now: { clock })
        let a = FakeSurface("audio", "taken-audio"), w = FakeSurface("windows", "taken-windows")
        store.register(a); store.register(w)

        var r = fit(Personal.env()).recipe
        r.sections = ["audio": RecipeJSON.encode(["v": "taken-audio"])!, "windows": RecipeJSON.encode(["v": "taken-windows"])!]
        let original = try XCTUnwrap(r.authorsOriginal), skipped = r.skippedLines
        let taken = store.addTaken(r)
        XCTAssertNotEqual(store.activeID, taken.id, "taking does not switch to it")
        store.apply(taken.id)

        clock.addTimeInterval(60); a.value = "my-edit"; XCTAssertTrue(store.save(taken.id))          // a save
        XCTAssertEqual(store.recipe(taken.id)?.authorsOriginal, original)
        clock.addTimeInterval(60); store.goBack(taken.id)                                           // a swap
        XCTAssertEqual(a.value, "taken-audio")
        XCTAssertEqual(store.recipe(taken.id)?.authorsOriginal, original)
        clock.addTimeInterval(60); store.goBack(taken.id)                                           // and back
        XCTAssertEqual(store.recipe(taken.id)?.authorsOriginal, original)
        XCTAssertEqual(store.recipe(taken.id)?.skippedLines, skipped)
        XCTAssertNotNil(store.recipe(taken.id)?.previous)

        // It also survives being written to disk and read again.
        let again = RecipeStore(url: url, now: { clock })
        XCTAssertEqual(again.recipe(taken.id)?.authorsOriginal, original)
    }

    func testARecipeFromBeforeSharedSetupsStillReads() throws {
        let old = #"{"id":"B23E8868-2B26-444B-A9C5-7EEC9E7CC718","name":"Desk","symbol":"house","createdAt":780000000,"updatedAt":780100000,"devices":[],"sections":{},"autoApply":false}"#
        let r = try JSONDecoder().decode(Recipe.self, from: Data(old.utf8))
        XCTAssertNil(r.authorsOriginal); XCTAssertTrue(r.skipped.isEmpty)
    }

    // MARK: Switching a skipped line on later

    func testASkippedLineCanBeSwitchedOnLaterWithoutTouchingTheRest() throws {
        let noPlugin = Personal.env(plugins: [Personal.deEsser])
        var r = fit(noPlugin).recipe
        XCTAssertTrue(r.skipped.contains { $0.id == "audio.plugins" })
        XCTAssertTrue(audio(SharedSetupFitResult(recipe: r, plan: FitPlan(matches: [], lines: []), displayPreset: nil)).eq.plugins.isEmpty)

        // The person edits the recipe's windows after taking it.
        var w = try XCTUnwrap(RecipeJSON.decode(WindowSettings.self, from: r.sections["windows"]!)); w.gap = 20
        r.sections["windows"] = RecipeJSON.encode(w)

        XCTAssertNil(SharedSetupFit.switchOn("audio.plugins", in: r, for: noPlugin), "still not installed: nothing to put there")
        let installed = Personal.env(plugins: [Personal.deEsser, Personal.proQ])
        let on = try XCTUnwrap(SharedSetupFit.switchOn("audio.plugins", in: r, for: installed))
        XCTAssertEqual(RecipeJSON.decode(AudioSettings.self, from: on.recipe.sections["audio"]!)?.eq.plugins.map(\.name), ["Pro-Q 3"])
        XCTAssertEqual(RecipeJSON.decode(WindowSettings.self, from: on.recipe.sections["windows"]!)?.gap, 20, "the person's own edit stays")
        XCTAssertFalse(on.recipe.skipped.contains { $0.id == "audio.plugins" })
        XCTAssertEqual(on.recipe.authorsOriginal, r.authorsOriginal)
        XCTAssertNil(SharedSetupFit.switchOn("audio.plugins", in: on.recipe, for: installed), "it is no longer skipped")
    }

    func testADifferentModelCurveCanBeSwitchedOnOnPurpose() throws {
        let bose = DeviceSignature(kind: .audioOutput, key: "RX-BOSE", name: "Bose Mini II")
        let env = Personal.env(gear: [bose, Personal.rxMic, Personal.rxMonitor, Personal.rxMouse])
        let r = fit(env).recipe
        let on = try XCTUnwrap(SharedSetupFit.switchOn("audio.equalizer", in: r, for: env))
        XCTAssertEqual(RecipeJSON.decode(AudioSettings.self, from: on.recipe.sections["audio"]!)?.eq.defaultProfile, Personal.audio().eq.defaultProfile)
    }

    func testAStoredSetupThatNoLongerPassesTheChecksIsNotApplied() throws {
        var r = fit(Personal.env(plugins: [Personal.deEsser])).recipe
        var o = try XCTUnwrap(r.authorsOriginal)
        let hacked = try XCTUnwrap(JSONValue.parse(o.setup)).with("settings.audio.effects.limiter.enabled", .bool(false))
        o.setup = hacked.encoded(); r.authorsOriginal = o
        XCTAssertNil(SharedSetupFit.switchOn("audio.plugins", in: r, for: Personal.env()))
    }

    // MARK: A single part

    func testASinglePartYieldsPresetLikeResults() throws {
        let env = Personal.env()
        let p = plan(env)
        let audioParts = SharedSetupFit.take(part: "audio", of: setup, plan: p, for: env)
        XCTAssertEqual(audioParts.map(\.key), ["audio.eq", "audio.outputfx", "audio.routing"])
        XCTAssertEqual(RecipeJSON.decode(EQProfile.self, from: audioParts[0].data), Personal.audio().eq.defaultProfile)
        let fx = try XCTUnwrap(JSONValue.parse(audioParts[1].data))
        XCTAssertEqual(fx["dynamics"]?["limiterEnabled"], .bool(true))
        XCTAssertEqual(fx["plugins"]?.array?.count, 1)

        XCTAssertEqual(SharedSetupFit.take(part: "microphone", of: setup, plan: p, for: env).map(\.key), ["audio.mic"])
        let win = try XCTUnwrap(SharedSetupFit.take(part: "windows", of: setup, plan: p, for: env).first)
        XCTAssertEqual(win.key, "windows"); XCTAssertEqual(RecipeJSON.decode(WindowSettings.self, from: win.data)?.gap, 8)
        XCTAssertEqual(SharedSetupFit.take(part: "keys", of: setup, plan: p, for: env).first?.key, "input")
        XCTAssertEqual(SharedSetupFit.take(part: "clipboard", of: setup, plan: p, for: env).first?.key, "clipboard")
        XCTAssertEqual(SharedSetupFit.take(part: "display", of: setup, plan: p, for: env).first?.key, "display")
    }

    func testTakingAPartLeavesOutLinesThatAreSwitchedOff() {
        let bose = DeviceSignature(kind: .audioOutput, key: "RX-BOSE", name: "Bose Mini II")
        let env = Personal.env(gear: [bose, Personal.rxMic, Personal.rxMonitor, Personal.rxMouse])
        let keys = SharedSetupFit.take(part: "audio", of: setup, plan: plan(env), for: env).map(\.key)
        XCTAssertFalse(keys.contains("audio.eq"), "the curve was made for other speakers")
        XCTAssertTrue(keys.contains("audio.outputfx"))
    }

    func testAPartTheSetupDoesNotHoldGivesNothing() {
        XCTAssertTrue(SharedSetupFit.take(part: "keys", of: Personal.export(parts: ["windows"]).setup!, plan: plan(Personal.env()), for: Personal.env()).isEmpty)
    }
}
