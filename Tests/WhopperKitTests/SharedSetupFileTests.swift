import XCTest
import AudioCore
import ClipboardCore
import InputCore
import WindowCore
import DisplayCore
@testable import WhopperKit

final class SharedSetupFileTests: XCTestCase {
    let setup = Personal.setup()

    func testAFileRoundTrips() throws {
        let data = try SharedSetupFile.encode(setup, madeBy: "FP-AB12 ünï").get()
        let o = SharedSetupFile.decode(data)
        XCTAssertNil(o.problem)
        XCTAssertEqual(o.setup, setup); XCTAssertEqual(o.madeBy, "FP-AB12 ünï")
        XCTAssertTrue(o.report.ok)
        XCTAssertEqual(SharedSetupFile.fileExtension, "whoprrr-setup")
    }

    func testTheFileIsPlainJSONWithTheWrapperAndNothingElse() throws {
        let v = try XCTUnwrap(JSONValue.parse(try SharedSetupFile.encode(setup, madeBy: "x").get()))
        XCTAssertEqual(Set(v.object!.keys), ["fileVersion", "madeBy", "setup"])
        XCTAssertEqual(v["setup"], setup.json)
    }

    func testOpeningAlwaysRunsTheChecker() throws {
        let file = try XCTUnwrap(JSONValue.parse(try SharedSetupFile.encode(setup, madeBy: "x").get()))
        let edited = file.with("setup.settings.audio.equalizer.curve.bands.0.gainDb", .number(40)).encoded()
        let o = SharedSetupFile.decode(edited)
        XCTAssertNil(o.setup)
        XCTAssertEqual(o.report.limits, ["boost-6db", "range"]); XCTAssertTrue(o.report.tampered)
        if case .violations(let v)? = o.problem { XCTAssertEqual(v.first?.limit, "boost-6db") } else { XCTFail("expected violations") }
        XCTAssertEqual(o.madeBy, "x", "who it says made it is still shown")
    }

    func testAHandEditedFileWithAnEmergencyOffRemapIsRefused() throws {
        let file = try XCTUnwrap(JSONValue.parse(try SharedSetupFile.encode(setup, madeBy: "x").get()))
        let edited = file.with("setup.settings.keys.rules.0.trigger", .object(["type": .string("key"), "code": .number(53)]))
            .with("setup.settings.keys.rules.0.mods", .strings(["shift", "control", "option", "command"]))
        let o = SharedSetupFile.decode(edited.encoded())
        XCTAssertNil(o.setup); XCTAssertTrue(o.report.tampered)
    }

    func testAnUnusualButAllowedSetupOpensAndSaysSo() throws {
        let o = SharedSetupFile.decode(try SharedSetupFile.encode(setup, madeBy: "x").get())
        XCTAssertNotNil(o.setup); XCTAssertFalse(o.report.ordinary)            // it holds a display part
    }

    func testAnUnknownFieldInTheWrapperIsRefused() throws {
        let file = try XCTUnwrap(JSONValue.parse(try SharedSetupFile.encode(setup, madeBy: "x").get()))
        XCTAssertEqual(SharedSetupFile.decode(file.with("script", .string("x")).encoded()).problem, .unreadable)
    }

    func testANewerFileVersionIsNotRead() throws {
        let file = try XCTUnwrap(JSONValue.parse(try SharedSetupFile.encode(setup, madeBy: "x").get()))
        XCTAssertEqual(SharedSetupFile.decode(file.with("fileVersion", .number(2)).encoded()).problem, .newerFile(2))
    }

    func testThingsThatAreNotAFileAreUnreadable() {
        for junk in ["", "hello", "[]", "{}", #"{"fileVersion":1}"#] { XCTAssertEqual(SharedSetupFile.decode(Data(junk.utf8)).problem, .unreadable, junk) }
    }

    func testAFileOverTheCapIsRefusedBeforeItIsParsed() {
        let big = Data(repeating: 0x20, count: SharedSetupFile.maxFileBytes + 1)
        XCTAssertEqual(SharedSetupFile.decode(big).problem, .tooBig)
    }

    func testASetupThatBreaksALimitCannotBeWrittenToAFile() {
        var s = setup
        s.settings["audio"] = s.settings["audio"]!.with("equalizer.curve.bands.0.gainDb", .number(9))
        guard case .failure(.violations(let v)) = SharedSetupFile.encode(s, madeBy: "x") else { return XCTFail("should be refused") }
        XCTAssertEqual(v.first?.limit, "boost-6db")
    }

    func testASetupOverSixtyFourKilobytesCannotBeWrittenToAFile() {
        let big = SharedVectors.document("keys-over-64kb")
        let s = SharedSetup(json: big)!
        guard case .failure(.violations(let v)) = SharedSetupFile.encode(s, madeBy: "x") else { return XCTFail("should be refused") }
        XCTAssertEqual(v.map(\.limit), ["size"])
        XCTAssertEqual(SharedSetupFile.Problem.violations(v).message, v[0].message)
    }

    func testMadeByIsOpaqueButBounded() {
        XCTAssertNotNil(try? SharedSetupFile.encode(setup, madeBy: "").get())
        XCTAssertNotNil(try? SharedSetupFile.encode(setup, madeBy: String(repeating: "a", count: 200)).get())
        XCTAssertNil(try? SharedSetupFile.encode(setup, madeBy: String(repeating: "a", count: 201)).get())
        XCTAssertNil(try? SharedSetupFile.encode(setup, madeBy: "a\nb").get())
    }

    func testProblemsAreInPlainWords() {
        for p in [SharedSetupFile.Problem.unreadable, .newerFile(2), .tooBig] { XCTAssertTrue(p.message.hasSuffix(".")) }
    }
}

/// The table copies a few things from the app's own modules. These tests break when the app changes under them.
final class SharedSetupTableDriftTests: XCTestCase {
    typealias T = SharedSetupTable

    func testTheClipboardDefaultsAreTheAppsOwn() { XCTAssertEqual(T.clipboardDefaultIgnored, ClipboardSettings.defaultIgnored) }

    func testTheWindowActionNamesAreTheAppsOwn() { XCTAssertEqual(T.windowActions, WindowAction.allCases.map(\.rawValue)) }

    func testTheKeepAwakeRangesAreTheAppsOwnClamp() {
        let lo = KeepAliveSettings(enabled: true, levelDB: -500, frequencyHz: 0, pulseEverySeconds: -5, burstSeconds: 0).clamped
        let hi = KeepAliveSettings(enabled: true, levelDB: 500, frequencyHz: 99999, pulseEverySeconds: 99999, burstSeconds: 99999).clamped
        XCTAssertEqual(T.Span(lo.levelDB, hi.levelDB), T.keepAwakeLevelDB)
        XCTAssertEqual(T.Span(lo.frequencyHz, hi.frequencyHz), T.keepAwakeHz)
        XCTAssertEqual(T.Span(lo.pulseEverySeconds, hi.pulseEverySeconds), T.keepAwakePulseSeconds)
        XCTAssertEqual(T.Span(lo.burstSeconds, hi.burstSeconds), T.keepAwakeBurstSeconds)
        XCTAssertEqual(hi.levelDB, -20, "the app itself allows up to -20 dBFS; shared setups stop at \(T.keepAwakeLevelMaxDB)")
    }

    func testTheHIDCodesAreTheAppsOwn() {
        XCTAssertEqual(T.hidCodes["capsLock"], HIDMapping.capsLock); XCTAssertEqual(T.hidCodes["rightCommand"], HIDMapping.rightCommand)
        XCTAssertEqual(T.hidCodes["rightOption"], HIDMapping.rightOption)
        XCTAssertEqual(T.hidCodes["f18"], HIDMapping.f18); XCTAssertEqual(T.hidCodes["f19"], HIDMapping.f19)
        XCTAssertNotEqual(T.hidCodes["capsLock"], 0x700000029, "Escape is never an allowed source")
    }

    func testTheModifierBitsAreTheAppsOwn() {
        XCTAssertEqual(InputMods.bits(["shift"]), Mods.shift.rawValue); XCTAssertEqual(InputMods.bits(["control"]), Mods.control.rawValue)
        XCTAssertEqual(InputMods.bits(["option"]), Mods.option.rawValue); XCTAssertEqual(InputMods.bits(["command"]), Mods.command.rawValue)
        XCTAssertEqual(InputMods.bits(["fn"]), Mods.fn.rawValue)
        XCTAssertEqual(CarbonMods.bits(["command"]), Int(Shortcut.cmd)); XCTAssertEqual(CarbonMods.bits(["shift"]), Int(Shortcut.shift))
        XCTAssertEqual(CarbonMods.bits(["option"]), Int(Shortcut.opt)); XCTAssertEqual(CarbonMods.bits(["control"]), Int(Shortcut.ctrl))
    }

    func testTheEmergencyOffKeyIsTheEnginesOwn() {
        let e = RemapEngine()
        let down = InputEvent(.down, .key(T.emergencyKey), mods: .main, bundle: nil, time: 0)
        _ = e.handle(down)
        XCTAssertTrue(e.panicked, "⌃⌥⇧⌘⎋ pauses every rule")
        XCTAssertEqual(Mods.main, [.shift, .control, .option, .command])
    }

    func testTheMediaKeyNamesAreTheAppsOwn() {
        XCTAssertEqual(Set(MediaKeys.table.map(\.1)), Set(MediaKey.allCases.map(\.rawValue)))
    }

    func testTheBandKindsAreTheAppsOwn() { XCTAssertEqual(T.bandKinds, BiquadCoefficients.Kind.allCases.map(\.rawValue)) }

    /// Paste and the Whoprrr Mic driver are setup grants the shared-setup format doesn't carry. Any other new permission trips this.
    func testThePermissionNamesAreTheAppsOwn() {
        XCTAssertEqual(T.permissions + ["paste", "micDriver"], Permission.allCases.map(\.rawValue))
        XCTAssertEqual(T.permissions, Permission.sharedSetupCases.map(\.rawValue))
    }

    func testTheKeyboardLayoutNamesAreTheAppsOwn() { XCTAssertEqual(T.layouts, KeyboardLayout.allCases.map(\.rawValue)) }

    func testTheAppsOwnPresetsAreInsideTheLimits() throws {
        for (name, profile) in EQProfile.presets {
            XCTAssertLessThanOrEqual(profile.preampDB + (profile.bands.map(\.gainDB).max() ?? 0), T.maxBoostDB + 1e-9, name)
        }
    }

    func testTheDisplayRangesAreTheCatalogs() {
        XCTAssertEqual(T.displayColor.lo, Double(Catalog.tonePresetRange.lowerBound)); XCTAssertEqual(T.displayColor.hi, Double(Catalog.tonePresetRange.upperBound))
        XCTAssertEqual(T.displayControls.sorted(), ["brightness", "color", "contrast", "sharpness"])
        XCTAssertEqual(Control.brightness.key, "brightness"); XCTAssertEqual(Control.contrast.key, "contrast"); XCTAssertEqual(Control.sharpness.key, "sharpness")
        XCTAssertEqual(Control.colorPreset.key, "colorPreset")
    }

    func testTheAppsOwnDefaultsMatchWhatExportAssumesForOldRecipes() {
        let c = CompressorSettings()
        XCTAssertEqual([c.thresholdDB, c.ratio, c.attackMs, c.releaseMs, c.makeupDB], [-20, 3, 8, 150, 3])
        let g = GateSettings()
        XCTAssertEqual([g.thresholdDB, g.attackMs, g.releaseMs], [-55, 3, 120])
        let cl = ClipboardSettings()
        XCTAssertEqual(cl.hotkey.keyCode, 9); XCTAssertEqual(Int(cl.hotkey.modifiers), 4352)
    }

    func testDefaultSectionsDecodeWithTheAppsOwnTypes() throws {
        let env = ReceiverEnvironment(gear: Personal.gear, plugins: [], macOS: "27.2", sections: [:])
        let s = Personal.setup()
        let r = SharedSetupFit.fit(s, plan: SharedSetupFit.plan(s, for: env), for: env)
        XCTAssertNotNil(RecipeJSON.decode(AudioSettings.self, from: r.recipe.sections["audio"]!))
        XCTAssertNotNil(RecipeJSON.decode(WindowSettings.self, from: r.recipe.sections["windows"]!))
        XCTAssertNotNil(RecipeJSON.decode(ClipboardSettings.self, from: r.recipe.sections["clipboard"]!))
        XCTAssertNotNil(RecipeJSON.decode(InputSettings.self, from: r.recipe.sections["input"]!))
    }
}
