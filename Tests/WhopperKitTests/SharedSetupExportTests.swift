import XCTest
import AudioCore
import WindowCore
import ClipboardCore
import InputCore
@testable import WhopperKit

final class SharedSetupExportTests: XCTestCase {
    func testExportWorksOnARecipeMadeOfTheAppsOwnSettings() {
        let r = Personal.export()
        XCTAssertNotNil(r.setup, "\(r.violations)")
        XCTAssertTrue(r.violations.isEmpty)
        XCTAssertEqual(r.setup?.parts, ["audio", "microphone", "windows", "keys", "clipboard", "display"])
        XCTAssertEqual(r.setup?.formatVersion, 1)
    }

    func testNothingPersonalIsInTheBytes() throws {
        let text = try XCTUnwrap(Personal.export().setup).encoded().text
        let forbidden = [
            "AppleUSBAudioEngine", "SOME-OTHER", "UNKNOWN-MIC", "RX-", "SN-7731", "EDID", "C02XK1234567", "0001",       // identifiers and serials
            "Ana", "Evening", "Greeting", "Precision", "Mine",                                                                // names the person gave
            "SECRETSTATE", "/Users/", "/Library", "Library/Audio",                                                           // plugin state, paths
            "http", "ana@", "example.com", "Hello", "rm -rf", "Safari", "com.private.vault",
            "Ana’s", "Ana's",
        ]
        for f in forbidden where !f.isEmpty { XCTAssertFalse(text.contains(f), "the shared setup contains “\(f)”") }
    }

    func testMixStaysOutOfSharedSetupAndFileBytes() throws {
        var recipe = Personal.recipe()
        let before = try XCTUnwrap(SharedSetupExport.export(title: "Test", line: "Test", recipe: recipe).setup)
        let audio = try XCTUnwrap(recipe.sections["audio"])
        var settings = try JSONDecoder().decode(AudioSettings.self, from: audio)
        settings.mix.set("com.personal.app-volume", volume: 0.32, muted: true, name: "Personal Music App")
        recipe.sections["audio"] = RecipeJSON.encode(settings)
        let after = try XCTUnwrap(SharedSetupExport.export(title: "Test", line: "Test", recipe: recipe).setup)

        XCTAssertEqual(after.encoded(), before.encoded())
        let file = try SharedSetupFile.encode(after, madeBy: "tester").get()
        XCTAssertEqual(file, try SharedSetupFile.encode(before, madeBy: "tester").get())
        XCTAssertTrue(SharedSetupExport.alwaysLeftOut.contains("Your app volumes. The list of apps you use is personal."))
    }

    func testTheGearIsRoleAndModelOnly() throws {
        let s = try XCTUnwrap(Personal.export().setup)
        XCTAssertEqual(s.gear, [SharedGear(role: "speaker", model: "Edifier R1280"), SharedGear(role: "microphone", model: "Shure MV7"),
                                SharedGear(role: "display", model: "S34CG50"), SharedGear(role: "mouse", model: "MX Ergo")])
        for g in s.json["gear"]!.array! { XCTAssertEqual(Set(g.object!.keys), ["role", "model"]) }
    }

    func testTextRulesOpenersAndShellCommandsAreDroppedAndListed() throws {
        let r = Personal.export()
        let rules = try XCTUnwrap(r.setup?.settings["keys"]?["rules"]?.array)
        let types = rules.compactMap { $0["tap"]?["type"]?.string }
        XCTAssertFalse(types.contains { ["text", "openURL", "openApp", "shell"].contains($0) })
        XCTAssertEqual(rules.count, 4, "the caps rule, back, precision and the sequence; the lock command is dropped too")
        let whats = r.removed.map(\.what)
        for w in ["Key rules that type text", "Key rules that open a web address", "Key rules that run a shell command", "Key rules that open an app",
                  "Key rules that run a command a shared setup may not run"] { XCTAssertTrue(whats.contains(w), w) }
        XCTAssertTrue(r.removed.contains { $0.what == "Rule names" && $0.count == 3 })
    }

    func testKeyMappingsOtherThanTheAllowedOnesAreDropped() throws {
        let r = Personal.export()
        XCTAssertEqual(r.setup?.settings["keys"]?["hid"]?.array?.count, 1)
        XCTAssertTrue(r.removed.contains { $0.what.hasPrefix("Key mappings other than") })
    }

    func testDeviceKeyedSettingsFollowTheGearAndOthersAreDropped() throws {
        let r = Personal.export()
        let a = try XCTUnwrap(r.setup?.settings["audio"])
        XCTAssertEqual(a["equalizer"]?["speakerCurves"]?.array?.count, 1)
        XCTAssertEqual(a["equalizer"]?["speakerCurves"]?.array?.first?["gear"]?.integer, 0)
        XCTAssertEqual(a["keepAwake"]?.array?.count, 1)
        XCTAssertEqual(a["keepInput"]?["gear"]?.array, [.int(1)], "only the microphone that is in the recipe's gear")
        XCTAssertEqual(r.setup?.settings["microphone"]?["source"]?.integer, 1)
        for w in ["Equalizer curves for speakers that are not in this recipe’s gear", "Keep-awake settings for speakers that are not in this recipe’s gear",
                  "Preferred microphones that are not in this recipe’s gear", "The device the equalizer follows (a device identifier)",
                  "Remembered names of audio devices"] { XCTAssertTrue(r.removed.contains { $0.what == w }, w) }
    }

    func testPluginsAreNamedNeverIncluded() throws {
        let r = Personal.export()
        let p = try XCTUnwrap(r.setup?.settings["audio"]?["effects"]?["plugins"]?.array?.first)
        XCTAssertEqual(p, .object(["name": .string("Pro-Q 3"), "maker": .string("FabFilter"), "enabled": .bool(true)]))
        XCTAssertEqual(r.setup?.requirements.plugins, ["De-esser", "Pro-Q 3"])
        XCTAssertTrue(r.removed.contains { $0.what.hasPrefix("Plugin settings") && $0.part == "audio" })
    }

    func testClipboardIgnoreListIsLeftOutWholly() throws {
        let r = Personal.export()
        XCTAssertNil(r.setup?.settings["clipboard"]?["ignoredApps"])
        XCTAssertTrue(r.removed.contains { $0.what == "The list of apps the clipboard ignores" })
        XCTAssertEqual(r.setup?.settings["clipboard"]?["maxImageMb"]?.integer, 20)
    }

    func testDisplayKeepsFourValuesOnly() throws {
        let r = Personal.export()
        let d = try XCTUnwrap(r.setup?.settings["display"])
        XCTAssertEqual(d["values"], .object(["brightness": .int(40), "contrast": .int(60), "color": .int(2), "sharpness": .int(5)]))
        XCTAssertEqual(d["monitor"]?.integer, 2)
        XCTAssertTrue(r.removed.contains { $0.part == "display" && $0.count == 4 }, "input, volume, red and the learned code")
    }

    func testAPresetWithOnlyCustomToneOrNoValuesGivesNoDisplayPart() {
        let src = ["Evening": SharedDisplaySource(model: "S34CG50", values: ["colorPreset": 5, "input": 17])]
        let r = SharedSetupExport.export(title: "t", line: "l", recipe: Personal.recipe(), parts: ["display", "audio"], display: src)
        XCTAssertNil(r.setup?.settings["display"])
        XCTAssertEqual(r.setup?.parts, ["audio"])
    }

    func testAMissingDisplayPresetIsNotInventedAndIsListed() {
        let r = SharedSetupExport.export(title: "t", line: "l", recipe: Personal.recipe(), parts: ["display", "windows"], display: [:])
        XCTAssertEqual(r.setup?.parts, ["windows"])
        XCTAssertTrue(r.removed.contains { $0.part == "display" })
    }

    func testTheWholeRecipeIsNeverChanged() {
        let r = Personal.recipe(), before = r
        _ = SharedSetupExport.export(title: "t", line: "l", recipe: r, display: Personal.display)
        _ = SharedSetupExport.export(title: "t", line: "l", recipe: Personal.recipe(audio: Personal.audio(band0: 9)), display: Personal.display)
        XCTAssertEqual(r, before)
        let audio = RecipeJSON.decode(AudioSettings.self, from: r.sections["audio"]!)
        XCTAssertEqual(audio?.eq.dynamics.limiterEnabled, false, "the person's own limiter setting is untouched")
        XCTAssertEqual(audio?.eq.targetUID, Personal.speakerUID)
    }

    func testTheLimiterIsSwitchedOnAndLoweredInTheSharedCopyOnly() throws {
        let r = Personal.export()
        let l = try XCTUnwrap(r.setup?.settings["audio"]?["effects"]?["limiter"])
        XCTAssertEqual(l["enabled"], .bool(true)); XCTAssertEqual(l["ceilingDb"], .number(-1))
        XCTAssertEqual(r.adjusted.count, 2)
        let quiet = Personal.export(Personal.recipe(audio: Personal.audio(limiterOn: true, ceiling: -3)))
        XCTAssertTrue(quiet.adjusted.isEmpty)
        XCTAssertEqual(quiet.setup?.settings["audio"]?["effects"]?["limiter"]?["ceilingDb"], .number(-3))
    }

    func testAnEqualizerBoostPastSixDecibelsIsRefusedWithTheLine() {
        let r = Personal.export(Personal.recipe(audio: Personal.audio(band0: 8)))
        XCTAssertNil(r.setup)
        XCTAssertEqual(r.violations.map(\.limit), ["boost-6db"])
        XCTAssertEqual(r.violations.first?.line, "settings.audio.equalizer.curve.bands[0].gainDb")
        XCTAssertTrue(r.violations[0].message.contains("+8 dB"))
        XCTAssertFalse(r.removed.isEmpty, "what would have been left out is still reported")
    }

    func testExactlySixDecibelsExports() {
        var a = Personal.audio(band0: 6); a.eq.defaultProfile.preampDB = -6
        XCTAssertNotNil(Personal.export(Personal.recipe(audio: a)).setup)
    }

    func testAMicrophoneGainOrMakeUpOverSixIsRefused() {
        var a = Personal.audio(); a.mic.gainDB = 8
        XCTAssertEqual(Personal.export(Personal.recipe(audio: a)).violations.map(\.limit), ["boost-6db"])
        a.mic.gainDB = 3; a.mic.compressor.makeupDB = 9
        XCTAssertEqual(Personal.export(Personal.recipe(audio: a)).violations.map(\.limit), ["boost-6db"])
    }

    func testAKeepAwakeToneLouderThanMinusFiftyIsRefused() {
        var a = Personal.audio(); a.keepAlive[Personal.speakerUID] = KeepAliveSettings(enabled: true, levelDB: -30)
        XCTAssertEqual(Personal.export(Personal.recipe(audio: a)).violations.map(\.limit), ["keepawake-level"])
    }

    func testARuleOnEmergencyOffIsRefused() {
        var i = Personal.input()
        i.rules.append(Rule(name: "x", trigger: .key(53), requiredMods: .main, tap: .chord(Chord(36))))
        XCTAssertEqual(Personal.export(Personal.recipe(input: i)).violations.map(\.limit), ["keys-emergency-off"])
    }

    func testARuleThatLeavesReturnDoingNothingOrSwallowsTheClickIsRefused() {
        var i = Personal.input()
        i.rules.append(Rule(trigger: .key(36), tap: .nothing))
        i.rules.append(Rule(trigger: .mouse(0), tap: .chord(Chord(36))))
        XCTAssertEqual(Set(Personal.export(Personal.recipe(input: i)).violations.map(\.limit)), ["keys-protected-key", "keys-primary-click"])
    }

    func testAShortcutThatWouldTakeOverTypingIsRefused() {
        var w = Personal.windows(); w.custom["maximize"] = Shortcut(36, 0)
        XCTAssertEqual(Personal.export(Personal.recipe(windows: w)).violations.map(\.limit), ["shortcut-safe"])
    }

    func testOnlyTheRequestedPartsAreExported() {
        let r = Personal.export(parts: ["windows", "clipboard"])
        XCTAssertEqual(r.setup?.parts, ["windows", "clipboard"])
        XCTAssertEqual(r.setup?.requirements.permissions, ["accessibility"])
        XCTAssertNil(r.setup?.requirements.minMacOS)
        XCTAssertTrue(r.setup?.requirements.plugins.isEmpty ?? false)
    }

    func testNothingToShareIsRefused() {
        let r = SharedSetupExport.export(title: "t", line: "l", recipe: Recipe(name: "Empty"), display: [:])
        XCTAssertNil(r.setup); XCTAssertFalse(r.violations.isEmpty)
    }

    func testRequirementsNameThePluginsTheMacOSAndThePermissions() throws {
        let s = try XCTUnwrap(Personal.export().setup)
        XCTAssertEqual(s.requirements.minMacOS, "14.2")
        XCTAssertEqual(s.requirements.permissions, ["accessibility", "inputMonitoring", "microphone", "systemAudio"])
    }

    func testTheExportedBytesAreStableAndPassTheCheckerAsBytes() throws {
        let a = try XCTUnwrap(Personal.export().setup), b = try XCTUnwrap(Personal.export().setup)
        XCTAssertEqual(a.encoded(), b.encoded())
        let r = SharedSetupLimits.check(json: a.encoded())
        XCTAssertTrue(r.ok); XCTAssertFalse(r.tampered)
        XCTAssertEqual(SharedSetup(json: JSONValue.parse(a.encoded())!), a)
    }

    func testAnOrdinaryAudioOnlyExportIsOrdinary() throws {
        var a = Personal.audio(); a.eq.profiles = [:]
        let r = Personal.export(Personal.recipe(audio: a), parts: ["audio", "microphone", "windows", "clipboard"])
        XCTAssertTrue(try XCTUnwrap(r.report).ordinary, "\(r.report?.unusual ?? [])")
    }

    func testTheRealSettingsRoundTripThroughTheDocument() throws {
        // Export, then fit onto a Mac with the same gear: the app's own decoders read the result, and the values are the author's.
        let s = try XCTUnwrap(Personal.export().setup)
        let plan = SharedSetupFit.plan(s, for: Personal.env())
        let fit = SharedSetupFit.fit(s, plan: plan, for: Personal.env())
        let audio = try XCTUnwrap(RecipeJSON.decode(AudioSettings.self, from: fit.recipe.sections["audio"]!))
        XCTAssertEqual(audio.eq.defaultProfile, Personal.audio().eq.defaultProfile)
        XCTAssertEqual(audio.eq.profiles["RX-SPK"], Personal.audio().eq.profiles[Personal.speakerUID])
        XCTAssertEqual(audio.mic.eq, Personal.audio().mic.eq)
        let input = try XCTUnwrap(RecipeJSON.decode(InputSettings.self, from: fit.recipe.sections["input"]!))
        XCTAssertTrue(input.rules.contains { $0.trigger == .key(79) && $0.tap == .chord(Chord(53)) && $0.hold == .modifiers(.control) })
        XCTAssertTrue(input.rules.contains { $0.trigger == .logi(0x00ED) && $0.tap == .command("clipboard.open") })
        XCTAssertTrue(input.rules.contains { $0.tap == .sequence([Chord(58, .option), Chord(0)]) && $0.requiredMods == [.control, .shift] && $0.scope == Scope(mode: .only, bundleIDs: ["com.apple.Notes"]) && $0.layouts == [.ansi] })
    }
}
