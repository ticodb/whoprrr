import XCTest
@testable import WhopperKit

/// Loads `Fixtures/shared-setup-vectors.json`: the same file the server runs against its JavaScript checker.
enum SharedVectors {
    struct Vector {
        var name: String
        var document: JSONValue
        var ok: Bool, ordinary: Bool, tampered: Bool
        var limits: [String]
    }

    static func load() -> [Vector] {
        guard let url = Bundle.module.url(forResource: "shared-setup-vectors", withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url), let root = JSONValue.parse(data), let list = root["vectors"]?.array else { return [] }
        return list.compactMap { v in
            guard let name = v["name"]?.string, let doc = v["document"], let e = v["expect"],
                  let ok = e["ok"]?.bool, let ordinary = e["ordinary"]?.bool, let tampered = e["tampered"]?.bool else { return nil }
            return Vector(name: name, document: doc, ok: ok, ordinary: ordinary, tampered: tampered, limits: (e["limits"]?.array ?? []).compactMap(\.string))
        }
    }

    /// A vector's document, by name.
    static func document(_ name: String) -> JSONValue { load().first { $0.name == name }!.document }
}

extension JSONValue {
    /// A copy with the value at a path set ("settings.audio.effects.limiter.enabled", "gear.0.model").
    func with(_ path: String, _ value: JSONValue?) -> JSONValue {
        func go(_ v: JSONValue, _ keys: ArraySlice<String>) -> JSONValue {
            guard let k = keys.first else { return value ?? .null }
            if case .array(var a) = v, let i = Int(k) {
                if keys.count == 1, value == nil { a.remove(at: i) } else { a[i] = go(a[i], keys.dropFirst()) }
                return .array(a)
            }
            var o = v.object ?? [:]
            if keys.count == 1, value == nil { o[k] = nil } else { o[k] = go(o[k] ?? .object([:]), keys.dropFirst()) }
            return .object(o)
        }
        return go(self, path.split(separator: ".").map(String.init)[...])
    }
}

final class SharedSetupVectorTests: XCTestCase {
    func testTheVectorFileIsThere() {
        XCTAssertGreaterThan(SharedVectors.load().count, 100)
    }

    func testEveryVectorGivesTheExpectedAnswer() {
        for v in SharedVectors.load() {
            let r = SharedSetupLimits.check(value: v.document)
            XCTAssertEqual(r.ok, v.ok, "\(v.name): ok")
            XCTAssertEqual(r.limits, v.limits, "\(v.name): rules broken\n\(r.violations.map { "\($0.line) [\($0.limit)] \($0.message)" }.joined(separator: "\n"))")
            XCTAssertEqual(r.tampered, v.tampered, "\(v.name): tampered")
            XCTAssertEqual(r.ordinary, v.ordinary, "\(v.name): ordinary (\(r.unusual))")
        }
    }

    func testVectorsGiveTheSameAnswerFromBytes() {
        for v in SharedVectors.load() {
            let viaBytes = SharedSetupLimits.check(json: v.document.encoded())
            XCTAssertEqual(viaBytes.limits, SharedSetupLimits.check(value: v.document).limits, v.name)
        }
    }

    func testEveryRuleNameIsExercisedByAVector() {
        let seen = Set(SharedVectors.load().flatMap(\.limits))
        for rule in SharedSetupTable.ruleNames { XCTAssertTrue(seen.contains(rule), "no vector breaks “\(rule)”") }
        for rule in seen { XCTAssertTrue(SharedSetupTable.ruleNames.contains(rule), "“\(rule)” is not in the table of rule names") }
    }

    func testEveryViolationHasALineALimitAndAPlainSentence() {
        for v in SharedVectors.load() where !v.ok {
            for x in SharedSetupLimits.check(value: v.document).violations {
                XCTAssertFalse(x.message.isEmpty, "\(v.name)")
                XCTAssertTrue(x.message.hasSuffix(".") || x.message.hasSuffix("."), "\(v.name): “\(x.message)” should be a sentence")
                XCTAssertFalse(x.limit.isEmpty)
            }
        }
    }

    func testViolationsComeInAStableOrder() {
        let doc = SharedVectors.document("boost-band-plus-40-tampered")
        XCTAssertEqual(SharedSetupLimits.check(value: doc).violations, SharedSetupLimits.check(value: doc).violations)
    }
}

/// The limits named in the owner's brief, at their edges, written out so a failure names the number.
final class SharedSetupLimitsTests: XCTestCase {
    let base = SharedVectors.document("ordinary-audio-only")
    let full = SharedVectors.document("full-example")
    func check(_ v: JSONValue) -> SharedSetupReport { SharedSetupLimits.check(value: v) }

    func testTheFullExamplePassesButIsUnusualBecauseOfTheDisplay() {
        let r = check(full)
        XCTAssertTrue(r.ok); XCTAssertFalse(r.ordinary); XCTAssertFalse(r.tampered)
        XCTAssertTrue(r.unusual.contains { $0.contains("monitor") })
    }

    func testExactlySixDecibelsOfBoostPassesAndSixPointZeroOneFails() {
        let path = "settings.audio.equalizer.curve.bands.0.gainDb"
        let low = base.with("settings.audio.equalizer.curve.preampDb", .number(-12))
        XCTAssertTrue(check(low.with(path, .number(6))).ok)
        let over = check(low.with(path, .number(6.01)))
        XCTAssertFalse(over.ok); XCTAssertEqual(over.limits, ["boost-6db"]); XCTAssertFalse(over.tampered)
    }

    func testThePlusEighteenBassExampleReadsAsTheBriefSays() {
        let d = base.with("settings.audio.equalizer.curve.preampDb", .number(-12))
            .with("settings.audio.equalizer.curve.bands.1.gainDb", .number(12))
        let m = check(d).violations.first { $0.limit == "boost-6db" }?.message ?? ""
        XCTAssertEqual(m, "Equalizer: bass +12 dB at 64 Hz. Shared setups cannot boost more than +6 dB, so nobody’s speakers or ears are hurt.")
    }

    func testCutsAreNotLimited() {
        XCTAssertTrue(check(base.with("settings.audio.equalizer.curve.bands.0.gainDb", .number(-12))).ok)
    }

    func testKeepAwakeToneAtMinusFiftyPassesAndMinusFortyNinePointNineFails() {
        let p = "settings.audio.keepAwake.0.levelDb"
        XCTAssertTrue(check(base.with(p, .number(-50))).ok)
        XCTAssertEqual(check(base.with(p, .number(-49.9))).limits, ["keepawake-level"])
        XCTAssertEqual(check(base.with(p, .number(-20))).limits, ["keepawake-level"])
    }

    func testKeepAwakeFrequencyStaysInsideTheAppsOwnRange() {
        let p = "settings.audio.keepAwake.0.frequencyHz"
        XCTAssertTrue(check(base.with(p, .number(15))).ok)
        XCTAssertTrue(check(base.with(p, .number(2000))).ok)
        XCTAssertTrue(check(base.with(p, .number(14.99))).limits.contains("keepawake-frequency"))
        XCTAssertTrue(check(base.with(p, .number(2000.01))).limits.contains("keepawake-frequency"))
    }

    func testTheLimiterCannotBeSwitchedOffOrRaised() {
        let l = "settings.audio.effects.limiter"
        XCTAssertEqual(check(base.with(l + ".enabled", .bool(false))).limits, ["limiter-on"])
        XCTAssertTrue(check(base.with(l + ".ceilingDb", .number(-1))).ok)
        XCTAssertEqual(check(base.with(l + ".ceilingDb", .number(-0.5))).limits, ["limiter-ceiling"])
        XCTAssertTrue(check(base.with(l + ".enabled", .bool(false))).tampered)
    }

    func testTheAudioPartMustCarryTheLimiter() {
        XCTAssertFalse(check(base.with("settings.audio.effects.limiter", nil)).ok)
    }

    func testEmergencyOffCanNeverBeRemappedOrSwitchedOff() {
        let rule = full.with("settings.keys.rules.0.trigger", .object(["type": .string("key"), "code": .number(53)]))
            .with("settings.keys.rules.0.mods", .strings(["shift", "control", "option", "command"]))
        let r = check(rule)
        XCTAssertEqual(r.limits, ["keys-emergency-off"]); XCTAssertTrue(r.tampered)
    }

    func testTheProtectedKeysCannotBeLeftDoingNothing() {
        let nothing = JSONValue.object(["type": .string("nothing")])
        for code in [36, 49, 53, 48, 51, 123, 124, 125, 126] {
            let d = full.with("settings.keys.rules.0.trigger", .object(["type": .string("key"), "code": .number(Double(code))])).with("settings.keys.rules.0.tap", nothing)
            XCTAssertEqual(check(d).limits, ["keys-protected-key"], "key \(code)")
        }
    }

    func testThePrimaryMouseClickCannotBeSwallowed() {
        let d = full.with("settings.keys.rules.1.trigger", .object(["type": .string("mouse"), "button": .number(0)]))
        XCTAssertEqual(check(d).limits, ["keys-primary-click"])
    }

    func testAnIgnoreListThatRemovesADefaultIsRefusedAndTampered() {
        let d = SharedVectors.document("clipboard-ignore-list-removes-a-default")
        let r = check(d)
        XCTAssertEqual(r.limits, ["clipboard-ignore-list"]); XCTAssertTrue(r.tampered)
    }

    func testDisplayRefusesInputSwitchingAndManufacturerCodes() {
        for code in ["input", "vcpe0", "volume", "red"] {
            let d = SharedVectors.document("display-input-switch-code").with("settings.display.values", .object(["brightness": .number(10), code: .number(1)]))
            XCTAssertEqual(check(d).limits, ["display-codes"], code); XCTAssertTrue(check(d).tampered)
        }
    }

    func testTitleAndLineLengths() {
        XCTAssertTrue(check(base.with("title", .string(String(repeating: "t", count: 60)))).ok)
        XCTAssertEqual(check(base.with("title", .string(String(repeating: "t", count: 61)))).limits, ["text-length"])
        XCTAssertTrue(check(base.with("line", .string(String(repeating: "l", count: 160)))).ok)
        XCTAssertEqual(check(base.with("line", .string(String(repeating: "l", count: 161)))).limits, ["text-length"])
    }

    func testMoreThanFortyRulesIsUnusualNotRefused() {
        let rules = (0..<41).map { i in JSONValue.object(["enabled": .bool(true), "trigger": .object(["type": .string("key"), "code": .number(Double(i))]), "mods": .array([]), "anyExtraMods": .bool(false),
                                                          "tap": .object(["type": .string("chord"), "key": .number(36), "mods": .array([])]), "holdMs": .number(200),
                                                          "scope": .object(["mode": .string("everywhere"), "apps": .array([])])]) }
        let d = SharedVectors.document("windows-gap-30-passes").with("parts", .strings(["keys"]))
            .with("settings", .object(["keys": .object(["enabled": .bool(true), "invertMouseWheel": .bool(false), "hid": .array([]), "rules": .array(rules)])]))
        let r = check(d)
        XCTAssertTrue(r.ok, "\(r.violations)"); XCTAssertFalse(r.ordinary); XCTAssertFalse(r.tampered)
    }

    func testTheSizeCapIsSixtyFourKilobytes() {
        let over = SharedVectors.document("keys-over-64kb")
        XCTAssertGreaterThan(over.encoded().count, SharedSetupTable.maxBytes)
        XCTAssertEqual(check(over).limits, ["size"])
        XCTAssertLessThan(full.encoded().count, SharedSetupTable.maxBytes)
    }

    func testAnUnknownFieldIsRefusedAndTampered() {
        let r = check(base.with("settings.audio.extra", .bool(true)))
        XCTAssertEqual(r.limits, ["shape"]); XCTAssertTrue(r.tampered)
    }

    func testANewerFormatIsRefusedWithoutBeingCalledTampered() {
        let r = check(base.with("formatVersion", .number(2)))
        XCTAssertEqual(r.limits, ["format"]); XCTAssertFalse(r.tampered)
    }

    func testBytesThatAreNotASetupAreRefused() {
        XCTAssertFalse(SharedSetupLimits.check(json: Data("not json".utf8)).ok)
        XCTAssertFalse(SharedSetupLimits.check(json: Data("[1,2]".utf8)).ok)
    }

    func testTheCheckerReadsBytesLikeTheServerWould() {
        let r = SharedSetupLimits.check(json: Data(#"{"formatVersion":1,"title":"x","line":"y","parts":["audio"],"gear":[],"requirements":{"plugins":[],"minMacOS":null,"permissions":[]},"settings":{"audio":{"typo":1}}}"#.utf8))
        XCTAssertTrue(r.tampered); XCTAssertEqual(r.limits, ["shape"])
    }
}
