import XCTest
@testable import InputCore

final class TransformTests: XCTestCase {
    func ev(_ k: InputEvent.Kind, _ code: Int, mods: Mods = [], kb: Int? = nil, rep: Bool = false) -> InputEvent {
        InputEvent(k, .key(code), mods: mods, bundle: nil, time: 0, isRepeat: rep, keyboardType: kb)
    }

    // MARK: Text and sequences

    func testKeypadDecimalTypesAPeriod() {
        let e = RemapEngine(rules: InputPresets.all.first { $0.id == "numpad-period" }!.rules)
        XCTAssertEqual(e.handle(ev(.down, 65)), Decision(emits: [.text(".")], swallow: true))
        XCTAssertEqual(e.handle(ev(.up, 65)), Decision(swallow: true))
        XCTAssertEqual(e.handle(ev(.down, 95)).emits, [.text(".")])         // the JIS "keypad comma" some keyboards send
        XCTAssertTrue(e.handle(ev(.down, 82)).isPlainPass)                   // keypad 0 untouched
    }

    func testTextRepeatsWhileHeld() {
        let e = RemapEngine(rules: [Rule(trigger: .key(65), tap: .text("."))])
        _ = e.handle(ev(.down, 65))
        XCTAssertEqual(e.handle(ev(.down, 65, rep: true)), Decision(emits: [.text(".")], swallow: true))
    }

    func testSequenceTapsEachComboInOrder() {
        // ⌃A → ⌥E then A (a dead-key accent on a US layout), the way the Karabiner rule does it.
        let r = Rule(trigger: .key(0), requiredMods: .control, tap: .sequence([Chord(14, .option), Chord(0)]))
        let e = RemapEngine(rules: [r])
        let d = e.handle(ev(.down, 0, mods: .control))
        XCTAssertEqual(d.emits, [
            .key(code: 14, down: true, flags: .option, autorepeat: false), .key(code: 14, down: false, flags: .option, autorepeat: false),
            .key(code: 0, down: true, flags: [], autorepeat: false), .key(code: 0, down: false, flags: [], autorepeat: false)])
        XCTAssertTrue(d.swallow)
        XCTAssertEqual(e.handle(ev(.up, 0, mods: .control)), Decision(swallow: true))
    }

    // MARK: Keyboard filters

    func testLayoutFilterOnlyMatchesThatKeyboardClass() {
        let r = Rule(trigger: .key(65), tap: .text("."), layouts: [.ansi])
        let e = RemapEngine(rules: [r])
        XCTAssertEqual(KeyboardLayout(keyboardType: 40), .ansi)
        XCTAssertEqual(KeyboardLayout(keyboardType: 41), .iso)
        XCTAssertEqual(KeyboardLayout(keyboardType: 42), .jis)
        XCTAssertEqual(e.handle(ev(.down, 65, kb: 40)).emits, [.text(".")])
        _ = e.handle(ev(.up, 65, kb: 40))
        XCTAssertTrue(e.handle(ev(.down, 65, kb: 41)).isPlainPass)         // ISO keyboard: rule does not apply
        XCTAssertTrue(e.handle(ev(.down, 65)).isPlainPass)                 // unknown keyboard: rule does not apply
    }

    func testRawKeyboardTypeFilterTellsTwoANSIKeyboardsApart() {
        let r = Rule(trigger: .key(65), tap: .text("."), keyboardTypes: [40])
        let e = RemapEngine(rules: [r])
        XCTAssertEqual(e.handle(ev(.down, 65, kb: 40)).emits, [.text(".")])
        _ = e.handle(ev(.up, 65, kb: 40))
        XCTAssertTrue(e.handle(ev(.down, 65, kb: 91)).isPlainPass)         // built-in keyboard (also ANSI class) untouched
    }

    func testSpanishAccentPresetOnlyOnANSI() {
        let e = RemapEngine(rules: InputPresets.all.first { $0.id == "spanish-accents" }!.rules)
        XCTAssertEqual(e.handle(ev(.down, 0, mods: .control, kb: 40)).emits, [.text("á")])
        _ = e.handle(ev(.up, 0, mods: .control, kb: 40))
        XCTAssertEqual(e.handle(ev(.down, 45, mods: [.control, .shift], kb: 40)).emits, [.text("Ñ")])
        _ = e.handle(ev(.up, 45, mods: [.control, .shift], kb: 40))
        XCTAssertTrue(e.handle(ev(.down, 0, mods: .control, kb: 41)).isPlainPass)   // Spanish ISO keyboard keeps ⌃A
        XCTAssertTrue(e.handle(ev(.down, 0, kb: 40)).isPlainPass)                    // plain A untouched
    }

    func testSettingsSavedBeforeFiltersStillLoad() throws {
        let old = #"{"id":"\#(UUID().uuidString)","name":"x","enabled":true,"trigger":{"key":{"_0":4}},"requiredMods":0,"allowExtraModifiers":false,"tap":{"nothing":{}},"holdMs":200,"scope":{"mode":"everywhere","bundleIDs":[]}}"#
        let r = try JSONDecoder().decode(Rule.self, from: Data(old.utf8))
        XCTAssertEqual(r.layouts, []); XCTAssertEqual(r.keyboardTypes, [])
        let round = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(Rule(trigger: .key(1), tap: .text("é"), layouts: [.ansi], keyboardTypes: [40])))
        XCTAssertEqual(round.tap, .text("é")); XCTAssertEqual(round.layouts, [.ansi]); XCTAssertEqual(round.keyboardTypes, [40])
    }

    // MARK: Karabiner import (fixtures are typical accent and numpad rules from a real Karabiner setup)

    static let karabiner = """
    {"profiles":[{"name":"Default","selected":true,
     "complex_modifications":{"rules":[
      {"description":"Add lowercase a with accent mark (á)","manipulators":[{"from":{"key_code":"a","modifiers":{"mandatory":["control"]}},"to":[{"key_code":"e","modifiers":["option"]},{"key_code":"a"}],"type":"basic"}]},
      {"description":"Add uppercase e (É)","manipulators":[{"from":{"key_code":"e","modifiers":{"mandatory":["shift","control"]}},"to":[{"key_code":"e","modifiers":["option"]},{"key_code":"e","modifiers":["shift"]}],"type":"basic"}]},
      {"description":"Add inverted question mark","manipulators":[{"from":{"key_code":"slash","modifiers":{"mandatory":["control"]}},"to":[{"key_code":"slash","modifiers":["option","shift"]}],"type":"basic"}]},
      {"description":"Add space after using comma","manipulators":[{"from":{"key_code":"comma"},"to_if_alone":[{"key_code":"comma","repeat":false},{"key_code":"spacebar","repeat":false}],"type":"basic"}]},
      {"description":"Only in Terminal","manipulators":[{"from":{"key_code":"f1"},"to":[{"key_code":"f2"}],"conditions":[{"type":"frontmost_application_if","bundle_identifiers":["^com\\\\.apple\\\\.Terminal$"]}],"type":"basic"}]},
      {"description":"Uses a variable","manipulators":[{"from":{"key_code":"f3"},"to":[{"set_variable":{"name":"x","value":1}}],"conditions":[{"type":"variable_if","name":"x","value":1}],"type":"basic"}]}
     ]},
     "devices":[{"identifiers":{"is_keyboard":true,"product_id":50475,"vendor_id":1133},"simple_modifications":[{"from":{"key_code":"keypad_comma"},"to":[{"key_code":"period"}]}]},
                {"identifiers":{"is_pointing_device":true,"product_id":50475,"vendor_id":1133},"ignore_vendor_events":true}]}]}
    """

    func testImportsRealKarabinerRules() throws {
        let r = try KarabinerImport.parse(Data(Self.karabiner.utf8))
        let byName = Dictionary(uniqueKeysWithValues: r.rules.map { ($0.name, $0) })

        let a = try XCTUnwrap(byName["Add lowercase a with accent mark (á)"])
        XCTAssertEqual(a.trigger, .key(0)); XCTAssertEqual(a.requiredMods, .control)
        XCTAssertEqual(a.tap, .sequence([Chord(14, .option), Chord(0)]))

        let E = try XCTUnwrap(byName["Add uppercase e (É)"])
        XCTAssertEqual(E.requiredMods, [.shift, .control]); XCTAssertEqual(E.tap, .sequence([Chord(14, .option), Chord(14, .shift)]))

        XCTAssertEqual(byName["Add inverted question mark"]?.tap, .chord(Chord(44, [.option, .shift])))
        XCTAssertEqual(byName["Add space after using comma"]?.tap, .sequence([Chord(43), Chord(49)]))

        let t = try XCTUnwrap(byName["Only in Terminal"])
        XCTAssertEqual(t.scope, Scope(mode: .only, bundleIDs: ["com.apple.Terminal"]))

        // keypad_comma → period was limited to one Logitech keyboard: here it becomes "ANSI keyboards only".
        let dev = try XCTUnwrap(r.rules.first { $0.trigger == .key(95) })
        XCTAssertEqual(dev.tap, .chord(Chord(47))); XCTAssertEqual(dev.layouts, [.ansi])
        XCTAssertTrue(r.warnings.contains { $0.contains("instead of that specific device") })

        XCTAssertEqual(r.skipped, 1)                                           // the variable rule
        XCTAssertTrue(r.warnings.contains { $0.contains("Uses a variable") })
        XCTAssertEqual(r.rules.count, 6)
    }

    func testImportedRulesActuallyRun() throws {
        let e = RemapEngine(rules: try KarabinerImport.parse(Data(Self.karabiner.utf8)).rules)
        let d = e.handle(ev(.down, 0, mods: .control, kb: 40))
        XCTAssertEqual(d.emits.count, 4)
        _ = e.handle(ev(.up, 0, mods: .control, kb: 40))
        XCTAssertEqual(e.handle(ev(.down, 95, kb: 40)).emits.first, .key(code: 47, down: true, flags: [], autorepeat: false))
        _ = e.handle(ev(.up, 95, kb: 40))
        XCTAssertTrue(e.handle(ev(.down, 95, kb: 41)).isPlainPass)             // an ISO keyboard keeps its comma
    }

    func testImportCapsLockDualRoleAndRuleFiles() throws {
        let caps = #"{"title":"t","rules":[{"description":"caps","manipulators":[{"from":{"key_code":"caps_lock","modifiers":{"optional":["any"]}},"to":[{"key_code":"left_control"}],"to_if_alone":[{"key_code":"escape"}],"type":"basic"}]}]}"#
        let r = try KarabinerImport.parse(Data(caps.utf8))
        XCTAssertEqual(r.hidMappings, [HIDMapping(src: HIDMapping.capsLock, dst: HIDMapping.f18)])
        XCTAssertEqual(r.rules.first?.trigger, .key(79))
        XCTAssertEqual(r.rules.first?.tap, .chord(Chord(53)))
        XCTAssertEqual(r.rules.first?.hold, .modifiers(.control))
        XCTAssertTrue(r.rules.first?.allowExtraModifiers == true)
        XCTAssertThrowsError(try KarabinerImport.parse(Data("nope".utf8)))
        XCTAssertThrowsError(try KarabinerImport.parse(Data("{}".utf8)))
    }
}
