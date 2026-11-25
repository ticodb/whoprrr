import XCTest
@testable import WhopperKit

final class StarterRecipeTests: XCTestCase {
    let m1 = GearScan.Mac(model: "MacBookAir10,1", appleSilicon: true, os: "27.2")
    let intel = GearScan.Mac(model: "MacBookPro16,1", appleSilicon: false, os: "15.6")
    let laptop = GearScan.Screen(name: "Built-in", width: 2560, height: 1600, builtIn: true, answers: nil)
    let builtInMic = GearScan.Audio(uid: "builtin-mic", name: "MacBook Air Microphone", transport: "builtIn", hasInput: true, hasOutput: false)

    func line(_ p: StarterPlan, _ id: String) -> StarterLine? { p.lines.first { $0.id == id } }
    func layouts(_ p: StarterPlan) -> [String] { if case .windowLayouts(let l)? = line(p, "windows.layouts")?.action { return l }; return [] }

    func testReferenceDeskIsAllTested() {
        let scan = GearScan(mac: m1,
                            screens: [laptop, .init(name: "S34CG50", width: 3440, height: 1440, builtIn: false, answers: true)],
                            audio: [builtInMic, .init(uid: "rode", name: "RØDE PodMic USB", transport: "usb", hasInput: true, hasOutput: true),
                                    .init(uid: "spk", name: "Soundcore 3", transport: "bluetooth", hasInput: false, hasOutput: true)],
                            logitech: ["MX Keys S", "MX Ergo"])
        let p = StarterRecipes.plan(for: scan)
        XCTAssertEqual(p.name, "Desk")
        XCTAssertTrue(layouts(p).contains("firstThird")); XCTAssertTrue(layouts(p).contains("nextDisplay"))
        XCTAssertFalse(layouts(p).contains("topLeft"))
        XCTAssertEqual(line(p, "display.control")?.fit, .tested)
        XCTAssertEqual(line(p, "audio.pin")?.action, .pinInput(uid: "rode"))
        XCTAssertEqual(line(p, "mic.source")?.fit, .tested)
        XCTAssertEqual(line(p, "audio.keepAwake.spk")?.action, .keepAwake(uid: "spk"))
        XCTAssertEqual(line(p, "input.backForward")?.fit, .tested)
        XCTAssertTrue(p.off.isEmpty)
    }

    func testUnknownMonitorThatAnswersIsCheckedNotTested() {
        let scan = GearScan(mac: m1, screens: [laptop, .init(name: "DELL U2723QE", width: 3840, height: 2160, builtIn: false, answers: true)],
                            audio: [builtInMic, .init(uid: "pods", name: "Ana’s AirPods Pro", transport: "bluetooth", hasInput: true, hasOutput: true)],
                            logitech: ["MX Master 3S"])
        let p = StarterRecipes.plan(for: scan)
        XCTAssertEqual(line(p, "display.control")?.fit, .checked)
        XCTAssertTrue(layouts(p).contains("topLeft")); XCTAssertFalse(layouts(p).contains("firstThird"))
        // A headset is never kept awake, and the Mac's own microphone stays the input.
        XCTAssertNil(p.lines.first { $0.id.hasPrefix("audio.keepAwake") })
        XCTAssertEqual(line(p, "audio.pin")?.action, .pinInput(uid: "builtin-mic"))
        XCTAssertEqual(line(p, "input.backForward")?.fit, .untested)
        XCTAssertEqual(p.off.map(\.feature), [.microphone])
    }

    func testSilentDisplayAndIntelSwitchDisplayControlOff() {
        let tv = GearScan.Screen(name: "LG TV", width: 1920, height: 1080, builtIn: false, answers: false)
        let silent = StarterRecipes.plan(for: GearScan(mac: m1, screens: [laptop, tv]))
        XCTAssertNil(line(silent, "display.control"))
        XCTAssertTrue(silent.off.contains { $0.feature == .display && $0.reason.contains("does not answer") })

        let old = StarterRecipes.plan(for: GearScan(mac: intel, screens: [laptop, .init(name: "S34CG50", width: 3440, height: 1440, builtIn: false, answers: nil)]))
        XCTAssertNil(line(old, "display.control"))
        XCTAssertTrue(old.off.contains { $0.feature == .display && $0.reason.contains("Apple Silicon") })
        XCTAssertEqual(old.gear.first?.fit, .unavailable)
    }

    func testLaptopOnly() {
        let p = StarterRecipes.plan(for: GearScan(mac: m1, screens: [laptop], audio: [builtInMic]))
        XCTAssertEqual(p.name, "On the road")
        XCTAssertEqual(layouts(p), ["leftHalf", "rightHalf", "maximize", "center", "restore"])
        XCTAssertEqual(Set(p.off.map(\.feature)), [.display, .microphone])
        XCTAssertTrue(p.gear.isEmpty)
        XCTAssertNil(line(p, "input.backForward"))
    }

    func testOpinionatedLinesStartOff() {
        let p = StarterRecipes.plan(for: GearScan(mac: m1, screens: [laptop]))
        XCTAssertEqual(line(p, "input.capsHyper")?.on, false)
        XCTAssertEqual(line(p, "clipboard.history")?.on, true)
    }

    func testDisplayStillCheckingStaysOnAsUntested() {
        let p = StarterRecipes.plan(for: GearScan(mac: m1, screens: [laptop, .init(name: "BenQ", width: 2560, height: 1440, builtIn: false, answers: nil)]))
        XCTAssertEqual(line(p, "display.control")?.fit, .untested)
    }

    func testUniqueName() {
        XCTAssertEqual(StarterRecipes.uniqueName("Desk", existing: []), "Desk")
        XCTAssertEqual(StarterRecipes.uniqueName("Desk", existing: ["Desk", "Desk 2"]), "Desk 3")
    }

    func testReportCarriesModelsAndResultsOnly() throws {
        let scan = GearScan(mac: m1, screens: [laptop],
                            audio: [builtInMic, .init(uid: "AA-BB-CC-DD-EE-FF:output", name: "Ana’s Speaker", transport: "bluetooth", hasInput: false, hasOutput: true)])
        let p = StarterRecipes.plan(for: scan)
        let accepted = Set(p.lines.filter(\.on).map(\.id))
        let json = String(decoding: FitReport.json(app: "0.9.0", scan: scan, plan: p, accepted: accepted), as: UTF8.self)
        let text = FitReport.text(app: "0.9.0", scan: scan, plan: p, accepted: accepted)
        for out in [json, text] {
            XCTAssertFalse(out.contains("Ana"), "a person's name left the Mac")
            XCTAssertFalse(out.contains("AA-BB"), "a device identifier left the Mac")
            XCTAssertTrue(out.contains("Speaker"))
            XCTAssertTrue(out.contains("audio.keepAwake"))
        }
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["kind", "app", "mac", "gear", "lines", "off"])
        XCTAssertEqual(obj["kind"] as? String, "mac")
    }

    func testPublicName() {
        XCTAssertEqual(KnownGear.publicName("Ana’s AirPods Pro"), "AirPods Pro")
        XCTAssertEqual(KnownGear.publicName("Tom's MX Ergo"), "MX Ergo")
        XCTAssertEqual(KnownGear.publicName("S34CG50"), "S34CG50")
    }
}

@MainActor
final class RecipeRestoreTests: XCTestCase {
    func testRestorePutsSettingsBackWithoutChangingTheActiveRecipe() {
        let s = RecipeStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("whoprrr-\(UUID().uuidString).json"))
        let a = FakeSurface("audio", "before"); s.register(a)
        let backup = s.snapshot(s.surfaceKeys)
        a.value = "starter"
        let r = s.create(name: "Desk", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
        XCTAssertTrue(s.restore(backup).isEmpty)
        XCTAssertEqual(a.value, "before")
        XCTAssertEqual(s.activeID, r.id)
    }
}
