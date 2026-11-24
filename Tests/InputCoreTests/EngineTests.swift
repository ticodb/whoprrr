import XCTest
@testable import InputCore

final class EngineTests: XCTestCase {
    let caps = Trigger.key(79)        // F18 (Caps Lock after hidutil)
    let H = Trigger.key(4), J = Trigger.key(38), A = Trigger.key(0)

    func ev(_ k: InputEvent.Kind, _ t: Trigger, mods: Mods = [], app: String? = nil, at: TimeInterval = 0, rep: Bool = false) -> InputEvent {
        InputEvent(k, t, mods: mods, bundle: app, time: at, isRepeat: rep)
    }

    func testPlainRemapPressRepeatRelease() {
        let e = RemapEngine(rules: [Rule(trigger: A, tap: .chord(Chord(11)))])        // A -> B
        XCTAssertEqual(e.handle(ev(.down, A)), Decision(emits: [.key(code: 11, down: true, flags: [], autorepeat: false)], swallow: true))
        XCTAssertEqual(e.handle(ev(.down, A, rep: true)).emits, [.key(code: 11, down: true, flags: [], autorepeat: true)])
        XCTAssertEqual(e.handle(ev(.up, A)), Decision(emits: [.key(code: 11, down: false, flags: [], autorepeat: false)], swallow: true))
    }

    func testUnmappedKeyPassesThroughUntouched() {
        let e = RemapEngine(rules: [Rule(trigger: A, tap: .chord(Chord(11)))])
        XCTAssertTrue(e.handle(ev(.down, J)).isPlainPass)
        XCTAssertTrue(e.handle(ev(.up, J)).isPlainPass)
    }

    func testChordCarriesThroughUnconsumedModifiers() {
        // option+H -> left arrow; with shift also held we want shift+left (select).
        let e = RemapEngine(rules: [Rule(trigger: H, requiredMods: [.option], tap: .chord(Chord(123)))])
        let d = e.handle(ev(.down, H, mods: [.option, .shift]))
        XCTAssertTrue(d.emits.isEmpty)                      // exact-match required: option+shift+H is not option+H
        let d2 = e.handle(ev(.down, H, mods: [.option]))
        XCTAssertEqual(d2.emits, [.key(code: 123, down: true, flags: [], autorepeat: false)])   // option consumed
        _ = e.handle(ev(.up, H, mods: [.option]))
        let e2 = RemapEngine(rules: [Rule(trigger: H, requiredMods: [.option], tap: .chord(Chord(123)), ).with { $0.allowExtraModifiers = true }])
        let d3 = e2.handle(ev(.down, H, mods: [.option, .shift]))
        XCTAssertEqual(d3.emits, [.key(code: 123, down: true, flags: [.shift], autorepeat: false)])
    }

    func testTapHoldTapEmitsTapAction() {
        let e = RemapEngine(rules: [Rule(trigger: caps, tap: .chord(Chord(53)), hold: .modifiers(.control))])
        XCTAssertEqual(e.handle(ev(.down, caps, at: 0)), Decision(swallow: true))
        let up = e.handle(ev(.up, caps, at: 0.1))
        XCTAssertEqual(up.emits, [.key(code: 53, down: true, flags: [], autorepeat: false), .key(code: 53, down: false, flags: [], autorepeat: false)])
        XCTAssertTrue(up.swallow)
    }

    func testHoldByTimeoutActsAsModifierThenReleases() {
        let e = RemapEngine(rules: [Rule(trigger: caps, tap: .chord(Chord(53)), hold: .modifiers(.control))])
        _ = e.handle(ev(.down, caps, at: 0))
        XCTAssertEqual(e.nextDeadline!, 0.2, accuracy: 0.001)
        XCTAssertTrue(e.tick(now: 0.1).isEmpty)
        XCTAssertEqual(e.tick(now: 0.25), [.modifier(.control, down: true)])
        // Other keys now carry the virtual control modifier.
        XCTAssertEqual(e.handle(ev(.down, A)).addMods, .control)
        XCTAssertEqual(e.handle(ev(.up, caps)).emits, [.modifier(.control, down: false)])
        XCTAssertTrue(e.handle(ev(.down, A)).isPlainPass)
    }

    func testPermissiveHoldWhenAnotherKeyPressedBeforeTimeout() {
        let e = RemapEngine(rules: [Rule(trigger: caps, tap: .chord(Chord(53)), hold: .modifiers(.control))])
        _ = e.handle(ev(.down, caps, at: 0))
        let d = e.handle(ev(.down, A, at: 0.05))               // typed quickly: caps is acting as control
        XCTAssertEqual(d.emits, [.modifier(.control, down: true)])
        XCTAssertEqual(d.addMods, .control); XCTAssertFalse(d.swallow)
        XCTAssertNil(e.nextDeadline)
    }

    func testHyperHold() {
        let e = RemapEngine(rules: [Rule(trigger: caps, tap: .nothing, hold: .modifiers(.hyper))])
        _ = e.handle(ev(.down, caps, at: 0))
        XCTAssertEqual(e.tick(now: 1), [.modifier(.hyper, down: true)])
    }

    func testLayerHjklArrows() {
        let rules = [
            Rule(trigger: caps, tap: .chord(Chord(53)), hold: .layer("nav")),
            Rule(trigger: H, tap: .chord(Chord(123)), layer: "nav"),
            Rule(trigger: J, tap: .chord(Chord(125)), layer: "nav"),
        ]
        let e = RemapEngine(rules: rules)
        XCTAssertTrue(e.handle(ev(.down, H)).isPlainPass)                // layer off: plain H
        _ = e.handle(ev(.up, H))
        _ = e.handle(ev(.down, caps, at: 0))
        let d = e.handle(ev(.down, H, at: 0.05))                         // pressing H resolves caps as hold, then maps
        XCTAssertEqual(d.emits, [.key(code: 123, down: true, flags: [], autorepeat: false)])
        XCTAssertEqual(e.layers, ["nav"])
        _ = e.handle(ev(.up, H))
        _ = e.handle(ev(.up, caps))
        XCTAssertTrue(e.layers.isEmpty)
        XCTAssertTrue(e.handle(ev(.down, H)).isPlainPass)
    }

    func testScopeOnlyAndExceptAndPriority() {
        let global = Rule(trigger: A, tap: .chord(Chord(11)))
        let inTerm = Rule(trigger: A, tap: .chord(Chord(8)), scope: Scope(mode: .only, bundleIDs: ["com.apple.Terminal"]))
        let e = RemapEngine(rules: [global, inTerm])                    // scoped wins even though listed second
        XCTAssertEqual(e.handle(ev(.down, A, app: "com.apple.Terminal")).emits.first, .key(code: 8, down: true, flags: [], autorepeat: false))
        _ = e.handle(ev(.up, A, app: "com.apple.Terminal"))
        XCTAssertEqual(e.handle(ev(.down, A, app: "com.apple.Safari")).emits.first, .key(code: 11, down: true, flags: [], autorepeat: false))
        let ex = RemapEngine(rules: [Rule(trigger: A, tap: .nothing, scope: Scope(mode: .except, bundleIDs: ["x"]))])
        XCTAssertTrue(ex.handle(ev(.down, A, app: "x")).isPlainPass)
        XCTAssertTrue(ex.handle(ev(.down, A, app: "y")).swallow)
    }

    func testDisabledRulesIgnored() {
        var r = Rule(trigger: A, tap: .nothing); r.enabled = false
        XCTAssertTrue(RemapEngine(rules: [r]).handle(ev(.down, A)).isPlainPass)
    }

    func testMouseButtonToChordAndCommand() {
        let e = RemapEngine(rules: [
            Rule(trigger: .mouse(3), tap: .chord(Chord(33, .command))),        // back -> cmd-[
            Rule(trigger: .mouse(4), tap: .command("window.maximize")),
        ])
        XCTAssertEqual(e.handle(ev(.down, .mouse(3))).emits, [.key(code: 33, down: true, flags: .command, autorepeat: false)])
        XCTAssertEqual(e.handle(ev(.up, .mouse(3))).emits, [.key(code: 33, down: false, flags: .command, autorepeat: false)])
        XCTAssertEqual(e.handle(ev(.down, .mouse(4))).emits, [.command("window.maximize")])
        XCTAssertTrue(e.handle(ev(.up, .mouse(4))).swallow)
    }

    func testPanicChordDisablesEverythingAndReleasesHeldKeys() {
        let e = RemapEngine(rules: [Rule(trigger: A, tap: .chord(Chord(11)))])
        _ = e.handle(ev(.down, A))                                      // B is now held down
        let d = e.handle(ev(.down, .key(53), mods: .main))              // ctrl+opt+shift+cmd+esc
        XCTAssertEqual(d.emits, [.key(code: 11, down: false, flags: [], autorepeat: false)])
        XCTAssertTrue(e.panicked)
        XCTAssertTrue(e.handle(ev(.down, A)).isPlainPass)               // rules off
        _ = e.handle(ev(.down, .key(53), mods: .main))
        XCTAssertFalse(e.panicked)
        XCTAssertTrue(e.handle(ev(.down, A)).swallow)
    }

    func testCodableRoundTrip() throws {
        var s = InputSettings()
        s.rules = [Rule(name: "caps", trigger: caps, tap: .chord(Chord(53)), hold: .modifiers(.hyper)),
                   Rule(trigger: .mouse(3), tap: .openApp("com.apple.Safari"), scope: Scope(mode: .only, bundleIDs: ["a"]))]
        s.hidMappings = [HIDMapping(src: HIDMapping.capsLock, dst: HIDMapping.f18)]
        let back = try JSONDecoder().decode(InputSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testRuleSummaryReadable() {
        XCTAssertEqual(Rule(trigger: .key(4), requiredMods: .option, tap: .chord(Chord(123))).summary, "⌥H → ←")
        XCTAssertEqual(Rule(trigger: .key(79), tap: .chord(Chord(53)), hold: .modifiers(.control)).summary, "F18: tap → ⎋, hold → ⌃")
    }
}

extension Rule { func with(_ f: (inout Rule) -> Void) -> Rule { var r = self; f(&r); return r } }

final class PresetTests: XCTestCase {
    func testEveryPresetHasItsHidMappingForHeldKeysAndNoDuplicates() {
        for p in InputPresets.all {
            XCTAssertFalse(p.rules.isEmpty, p.id)
            // A rule on F18/F19 only works if hidutil maps a real key onto it.
            for r in p.rules { if case .key(let c) = r.trigger, c == 79 || c == 80, r.layer == nil { XCTAssertFalse(p.hid.isEmpty, p.id) } }
        }
        XCTAssertEqual(Set(InputPresets.all.map(\.id)).count, InputPresets.all.count)
    }

    func testApplyingTwiceDoesNotDuplicate() {
        let p = InputPresets.all[0]
        let once = InputPresets.apply(p, to: InputSettings())
        let twice = InputPresets.apply(p, to: once)
        XCTAssertEqual(once, twice)
    }

    func testNavPresetEndToEnd() {
        let s = InputPresets.apply(InputPresets.all.first { $0.id == "caps-nav" }!, to: InputSettings())
        let e = RemapEngine(rules: s.rules)
        _ = e.handle(InputEvent(.down, .key(79), time: 0))
        let d = e.handle(InputEvent(.down, .key(4), time: 0.05))
        XCTAssertEqual(d.emits, [.key(code: 123, down: true, flags: [], autorepeat: false)])
    }

    func testHidJSON() {
        XCTAssertEqual(HIDUtil.json([HIDMapping(src: HIDMapping.capsLock, dst: HIDMapping.f18)]),
                       "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771181}]}")
    }
}

final class HIDParseTests: XCTestCase {
    func testParsesRealHidutilOutputAcrossServicesDeduplicated() {
        let text = """
        RegistryID  Key                   Value
        100000416   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771177;
                HIDKeyboardModifierMappingSrc = 30064771176;
            }
        )
        100000579   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771177;
                HIDKeyboardModifierMappingSrc = 30064771176;
            }
        )
        1000004e6   UserKeyMapping   (null)
        """
        XCTAssertEqual(HIDUtil.parse(text), [HIDMapping(src: 30064771176, dst: 30064771177)])
        XCTAssertEqual(HIDUtil.parse("RegistryID  Key  Value\n1  UserKeyMapping   (null)"), [])
    }
}
