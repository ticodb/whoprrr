import XCTest
@testable import WhopperKit

/// How the review lists a shared setup's lines: what goes on now, then what stays off folded by reason.
@MainActor
final class ReviewGroupingTests: XCTestCase {
    let setup = Personal.setup()

    func grouping(_ env: ReceiverEnvironment, off: Set<String> = [], overrides: [Int: GearOverride] = [:]) -> ReviewGrouping {
        ReviewGrouping(plan: SharedSetupFit.plan(setup, for: env, overrides: overrides, switchedOff: off), gear: setup.gear)
    }

    // A podcast desk shaped like the prototype: nine lines, six of them Audio.
    static let gear = [SharedGear(role: "speaker", model: "Edifier R1280"), SharedGear(role: "microphone", model: "Shure MV7")]
    func line(_ id: String, _ part: String, _ title: String, off: String? = nil, cause: OffCause? = nil, note: String? = nil) -> ReviewLine {
        ReviewLine(id: id, part: part, title: title, note: note, offReason: off, cause: cause)
    }
    var podcast: [ReviewLine] {
        [line("eq", "audio", "Equalizer curve", off: "No speakers connected that match the Edifier R1280 this curve was made for.", cause: .gearMissing(0)),
         line("eqs", "audio", "Equalizer curve for the Edifier R1280", off: "No speaker connected that matches the Edifier R1280.", cause: .gearMissing(0)),
         line("fx", "audio", "Output compressor and limiter", note: "The output limiter is switched on and stays on."),
         line("plug", "audio", "Output plugins", off: "The plugin “Pro-Q 3” is not installed on this Mac.", cause: .pluginsMissing(["Pro-Q 3"])),
         line("awake", "audio", "Keep the Edifier R1280 awake", off: "No speaker connected that matches the Edifier R1280.", cause: .gearMissing(0)),
         line("keepin", "audio", "Keep a microphone as the input", off: "None of the microphones this keeps (Shure MV7) are connected.", cause: .gearMissing(1)),
         line("chain", "microphone", "Microphone chain", off: "No microphone connected that matches the Shure MV7.", cause: .gearMissing(1)),
         line("mplug", "microphone", "Microphone plugins", off: "The plugin “De-esser” is not installed on this Mac.", cause: .pluginsMissing(["De-esser"])),
         line("win", "windows", "Window layouts and shortcuts")]
    }
    func podcastGrouping(_ lines: [ReviewLine]? = nil) -> ReviewGrouping { ReviewGrouping(lines: lines ?? podcast, gear: Self.gear) }

    // MARK: Sections

    func testLinesThatCanGoOnComeFirstInTheSetupsOrder() {
        let g = podcastGrouping()
        XCTAssertEqual(g.goesOn.map(\.id), ["fx", "win"])
        XCTAssertEqual(g.onCount, 2); XCTAssertEqual(g.canGoOnCount, 2); XCTAssertEqual(g.goesOnCountText, "2 of 2")
        XCTAssertEqual(g.goesOn[0].note, "The output limiter is switched on and stays on.")
        XCTAssertEqual(g.stayCount, 7); XCTAssertEqual(g.stayCountText, "7 lines")
    }

    func testStayingOffLinesFoldIntoOneRowPerReasonWhereTheFirstLineWouldBe() {
        let g = podcastGrouping()
        XCTAssertEqual(g.stays.map(\.title), ["No Edifier R1280 speakers connected", "The plugin Pro-Q 3 is not installed",
                                              "No Shure MV7 microphone connected", "The plugin De-esser is not installed"])
        XCTAssertEqual(g.stays[0].lines.map(\.id), ["eq", "eqs", "awake"])
        XCTAssertEqual(g.stays[0].countText, "3 lines")
        XCTAssertEqual(g.stays[2].lines.map(\.id), ["keepin", "chain"])
        XCTAssertEqual(g.stays[1].countText, "1 line")
    }

    func testTheEndOfAnOpenedGroupSaysWhatToDo() {
        let g = podcastGrouping()
        XCTAssertEqual(g.stays[0].kind, .gear); XCTAssertEqual(g.stays[0].footnote, "Switch these on from the recipe once it is connected.")
        XCTAssertEqual(g.stays[1].kind, .plugin); XCTAssertEqual(g.stays[1].footnote, "Whoprrr never installs plugins.")
        XCTAssertEqual(g.stays[1].pluginNames, ["Pro-Q 3"])
        XCTAssertTrue(g.stays[0].pluginNames.isEmpty)
    }

    func testAPartIsNamedInsideAGroupOnlyWhenTheGroupMixesParts() {
        let g = podcastGrouping()
        XCTAssertFalse(g.stays[0].showsParts)                    // all Audio
        XCTAssertTrue(g.stays[2].showsParts)                     // Audio and Microphone, both wait for the microphone
    }

    func testAnyOtherReasonIsGroupedBySentenceAndNothingIsLost() {
        let r = "Needs macOS 14.2 or newer; this Mac has 13.0."
        let g = podcastGrouping([line("a", "audio", "A", off: r), line("b", "audio", "B", off: r), line("c", "windows", "C", off: "Accessibility is not allowed for Whoprrr on this Mac. Allow it in System Settings, then switch this on.")])
        XCTAssertEqual(g.stays.map(\.title), [r, "Accessibility is not allowed for Whoprrr on this Mac. Allow it in System Settings, then switch this on."])
        XCTAssertEqual(g.stays[0].lines.map(\.id), ["a", "b"]); XCTAssertEqual(g.stays[0].kind, .other); XCTAssertNil(g.stays[0].footnote)
    }

    func testALineThePersonSwitchedOffStaysInGoesOnWithItsSwitchOff() {
        var lines = podcast; lines[2] = line("fx", "audio", "Output compressor and limiter", off: SharedSetupFit.switchedOffReason, cause: .person)
        let g = podcastGrouping(lines)
        XCTAssertEqual(g.goesOn.map(\.id), ["fx", "win"])
        XCTAssertEqual(g.goesOn.map(\.isOn), [false, true])
        XCTAssertEqual(g.onCount, 1); XCTAssertEqual(g.goesOnCountText, "1 of 2")
        XCTAssertEqual(g.stayCount, 7)                           // not counted among those left out
        XCTAssertEqual(g.switchedOffByPerson.map(\.id), ["fx"])
    }

    func testTwoPluginsMissingFromOneLineMakeOneGroupNamingBoth() {
        let g = podcastGrouping([line("p", "audio", "P", off: "x", cause: .pluginsMissing(["Pro-Q 3", "De-esser"]))])
        XCTAssertEqual(g.stays[0].title, "The plugins Pro-Q 3 and De-esser are not installed")
        XCTAssertEqual(g.stays[0].pluginNames, ["Pro-Q 3", "De-esser"])
    }

    func testGearIsNamedByItsModelAndRole() {
        XCTAssertEqual(ReviewGrouping.gearTitle(SharedGear(role: "speaker", model: "Edifier R1280")), "No Edifier R1280 speakers connected")
        XCTAssertEqual(ReviewGrouping.gearTitle(SharedGear(role: "microphone", model: "Shure MV7")), "No Shure MV7 microphone connected")
        XCTAssertEqual(ReviewGrouping.gearTitle(SharedGear(role: "display", model: "S34CG50")), "No S34CG50 monitor connected")
        XCTAssertEqual(ReviewGrouping.gearTitle(nil), "No matching gear connected")
    }

    // MARK: More than three lines

    func testThreeLinesOrFewerAreFlatAndMoreThanThreeGoUnderOneHeadingPerPart() {
        XCTAssertFalse(podcastGrouping().isGrouped)
        let four = podcastGrouping([line("a", "audio", "A"), line("b", "audio", "B"), line("c", "windows", "C"), line("d", "audio", "D")])
        XCTAssertTrue(four.isGrouped)
        XCTAssertEqual(four.blocks.map(\.part), ["audio", "windows"])           // a part appears where its first line is
        XCTAssertEqual(four.blocks[0].lineIDs, ["a", "b", "d"])
        let three = podcastGrouping([line("a", "audio", "A"), line("b", "audio", "B"), line("c", "windows", "C")])
        XCTAssertFalse(three.isGrouped)
    }

    func testThePartSwitchShowsFromTwoLinesAndReadsOnWhenAnyIsOn() {
        let all = (1...4).map { line("a\($0)", "audio", "A\($0)") } + [line("w", "windows", "W")]
        var g = podcastGrouping(all)
        XCTAssertTrue(g.blocks[0].showsSwitch); XCTAssertFalse(g.blocks[1].showsSwitch)      // Windows has one line
        XCTAssertTrue(g.blocks[0].switchOn); XCTAssertFalse(g.blocks[0].switchTurnsOn)
        // One of four switched off: still reads on, so pressing turns them all off.
        var some = all; some[1] = line("a2", "audio", "A2", off: SharedSetupFit.switchedOffReason, cause: .person)
        g = podcastGrouping(some)
        XCTAssertTrue(g.blocks[0].switchOn); XCTAssertEqual(g.blocks[0].onCount, 3)
        // All of them off: reads off, so pressing turns them all on.
        var none = all; for i in 0..<4 { none[i] = line("a\(i + 1)", "audio", "A\(i + 1)", off: SharedSetupFit.switchedOffReason, cause: .person) }
        g = podcastGrouping(none)
        XCTAssertFalse(g.blocks[0].switchOn); XCTAssertTrue(g.blocks[0].switchTurnsOn); XCTAssertEqual(g.blocks[0].onCount, 0)
        XCTAssertEqual(g.blocks[0].lineIDs, ["a1", "a2", "a3", "a4"])
    }

    func testOnlyLinesThatCanGoOnAreInAPartBlock() {
        let g = podcastGrouping(podcast + [line("x", "audio", "X"), line("y", "audio", "Y")])
        XCTAssertTrue(g.isGrouped)
        XCTAssertEqual(g.blocks.map(\.part), ["audio", "windows"])
        XCTAssertEqual(g.blocks[0].lineIDs, ["fx", "x", "y"])
    }

    // MARK: The sentence

    func testTheSummaryInAllItsForms() {
        XCTAssertEqual(podcastGrouping().summary, "2 things go on now. 7 stay off until this Mac has the gear or plugins.")
        let one = podcastGrouping([line("a", "audio", "A"), line("b", "audio", "B", off: "r")])
        XCTAssertEqual(one.summary, "1 thing goes on now. 1 stays off until this Mac has the gear or plugins.")
        let every = podcastGrouping([line("a", "audio", "A"), line("b", "audio", "B")])
        XCTAssertEqual(every.summary, "2 things go on now. Nothing is left out.")
        let single = podcastGrouping([line("a", "audio", "A")])
        XCTAssertEqual(single.summary, "1 thing goes on now. Nothing is left out.")
        let off = podcastGrouping([line("a", "audio", "A", off: SharedSetupFit.switchedOffReason, cause: .person), line("b", "audio", "B")])
        XCTAssertEqual(off.summary, "1 thing goes on now. Nothing is left out.")        // the one the person switched off is not "left out"
    }

    func testNothingCanGoOn() {
        let g = podcastGrouping(podcast.filter { $0.isOff })
        XCTAssertTrue(g.nothingCanGoOn); XCTAssertTrue(g.goesOn.isEmpty)
        XCTAssertEqual(g.summary, "Nothing goes on yet. Every line needs gear or a plugin this Mac does not have. You can keep the setup, and switch its lines on when you have them.")
        XCTAssertEqual(g.stayCount, 7)
    }

    func testAnEmptySetupHasNoSentenceAndIsNotNothingCanGoOn() {
        let g = podcastGrouping([])
        XCTAssertNil(g.summary); XCTAssertFalse(g.nothingCanGoOn)
    }

    func testASetupWhereThePersonSwitchedEverythingOffIsNotNothingCanGoOn() {
        let g = podcastGrouping([line("a", "audio", "A", off: SharedSetupFit.switchedOffReason, cause: .person)])
        XCTAssertFalse(g.nothingCanGoOn); XCTAssertEqual(g.summary, "0 things go on now. Nothing is left out.")
    }

    // MARK: Built from a real fit

    func testARealFitPutsMissingGearUnderOneReason() {
        let g = grouping(Personal.env(gear: [Personal.rxMic, Personal.rxMonitor, Personal.rxMouse]))      // no speakers
        let speakers = g.stays.first { $0.title == "No Edifier R1280 speakers connected" }
        XCTAssertNotNil(speakers)
        XCTAssertTrue(speakers!.lines.map(\.id).contains("audio.equalizer"))
        XCTAssertTrue(speakers!.lines.map(\.id).contains("audio.equalizer.speaker.0"))
        XCTAssertTrue(speakers!.lines.map(\.id).contains("audio.keepAwake.0"))
        XCTAssertFalse(g.goesOn.map(\.id).contains("audio.equalizer"))
        XCTAssertTrue(g.goesOn.map(\.id).contains("audio.effects"))
    }

    func testARealFitPutsAMissingPluginUnderItsOwnReason() {
        let g = grouping(Personal.env(plugins: []))
        let p = g.stays.first { $0.kind == .plugin }
        XCTAssertEqual(p?.title, "The plugin Pro-Q 3 is not installed")
        XCTAssertEqual(p?.lines.map(\.id), ["audio.plugins"])
    }

    func testARealFitKeepsEveryReasonItGivesToday() {
        // macOS too old: the line keeps its own sentence, in a group of its own.
        let plan = SharedSetupFit.plan(setup, for: Personal.env(macOS: "13.0"))
        let g = ReviewGrouping(plan: plan, gear: setup.gear)
        let reasons = Set(plan.off.compactMap { $0.state.reason })
        XCTAssertFalse(reasons.isEmpty)
        for l in plan.off { XCTAssertTrue(g.stays.contains { grp in grp.lines.contains { $0.id == l.id } }, "\(l.id) is missing from the groups") }
        XCTAssertEqual(g.stayCount, plan.off.count)
        XCTAssertEqual(g.canGoOnCount + g.stayCount, plan.lines.count)
        for grp in g.stays where grp.kind == .other { XCTAssertTrue(reasons.contains(grp.title)) }
    }

    func testARealFitMarksAPersonsOwnSwitchAndKeepsOtherReasonsAsTheyWere() {
        let env = Personal.env(gear: [Personal.rxMic, Personal.rxMonitor, Personal.rxMouse])
        let g = grouping(env, off: ["audio.effects", "audio.equalizer"])       // the second is off for want of speakers anyway
        XCTAssertEqual(g.switchedOffByPerson.map(\.id), ["audio.effects"])
        XCTAssertTrue(g.stays.contains { $0.lines.contains { $0.id == "audio.equalizer" } })
    }

    func testEveryLineIsInExactlyOneSection() {
        for env in [Personal.env(), Personal.env(gear: []), Personal.env(plugins: []), Personal.env(macOS: "13.0"), Personal.env(permissions: [.accessibility: .denied, .microphone: .denied])] {
            let plan = SharedSetupFit.plan(setup, for: env)
            let g = ReviewGrouping(plan: plan, gear: setup.gear)
            let ids = g.goesOn.map(\.id) + g.stays.flatMap { $0.lines.map(\.id) }
            XCTAssertEqual(Set(ids), Set(plan.lines.map(\.id))); XCTAssertEqual(ids.count, plan.lines.count)
        }
    }

    func testTheSwitchedOffReasonIsWhatThePlanSays() {
        let plan = SharedSetupFit.plan(setup, for: Personal.env(), switchedOff: ["audio.effects"])
        XCTAssertEqual(plan.line("audio.effects")?.state, .off(SharedSetupFit.switchedOffReason))
        XCTAssertEqual(plan.line("audio.effects")?.cause, .person)
    }

    // MARK: Before you start

    func row(_ kind: RequirementRow.Kind, _ subject: String, _ status: RequirementRow.Status, plugin: String? = nil) -> RequirementRow {
        RequirementRow(kind: kind, title: "Needs \(subject)", detail: "d", status: status, pluginName: plugin, subject: subject)
    }

    func testReadyThingsBecomeOneSentenceAndTheRestOfTheRowsGo() {
        let rows = [row(.plugin, "Pro-Q 3", .missing, plugin: "Pro-Q 3"), row(.macOS, "macOS 14.2 or newer", .ready), row(.permission, "Accessibility", .ready), row(.permission, "Microphone", .ready)]
        let g = podcastGrouping()
        let r = ReviewRequirements(rows: rows, stays: g.stays)
        XCTAssertTrue(r.blocking.isEmpty)                      // the missing plugin is under "Stays off for now"
        XCTAssertEqual(r.sentence, "This Mac is ready for the rest: macOS 14.2 or newer, Accessibility and Microphone are allowed.")
    }

    func testAPermissionThatWillBeAskedForIsMentionedInTheSentence() {
        let r = ReviewRequirements(rows: [row(.permission, "Accessibility", .ready), row(.permission, "System Audio Recording", .ask)], stays: [])
        XCTAssertEqual(r.sentence, "This Mac is ready for the rest: Accessibility is allowed. Whoprrr will ask for System Audio Recording when it is needed.")
        let only = ReviewRequirements(rows: [row(.permission, "System Audio Recording", .ask)], stays: [])
        XCTAssertEqual(only.sentence, "Whoprrr will ask for System Audio Recording when it is needed.")
        XCTAssertNil(ReviewRequirements(rows: [], stays: []).sentence)
    }

    func testAProblemThatIsNotAMissingPluginIsNeverHidden() {
        let denied = row(.permission, "Accessibility", .missing), old = row(.macOS, "macOS 15 or newer", .missing)
        let r = ReviewRequirements(rows: [denied, old, row(.permission, "Microphone", .ready)], stays: podcastGrouping().stays)
        XCTAssertEqual(r.blocking.map(\.subject), ["Accessibility", "macOS 15 or newer"])
        XCTAssertEqual(r.sentence, "This Mac is ready for the rest: Microphone is allowed.")
    }

    func testAMissingPluginNoStayingOffLineNamesStaysVisible() {
        let rows = [row(.plugin, "Limiter X", .missing, plugin: "Limiter X"), row(.plugin, "pro-q 3", .missing, plugin: "pro-q 3")]
        let r = ReviewRequirements(rows: rows, stays: podcastGrouping().stays)
        XCTAssertEqual(r.blocking.map(\.subject), ["Limiter X"])              // Pro-Q 3 is named under "Stays off" (names compare without case)
    }

    func testRealRequirementRowsCarryTheirSubjects() {
        let rows = Requirements.rows(SharedRequirements(plugins: ["Pro-Q 3"], minMacOS: "14.2", permissions: ["accessibility"]), env: Personal.env(permissions: [.accessibility: .granted]))
        XCTAssertEqual(rows.map(\.subject), ["Pro-Q 3", "macOS 14.2 or newer", "Accessibility"])
    }

    // MARK: The done page

    func testTheDonePageListsWhatWentOnByPart() {
        let g = podcastGrouping()
        XCTAssertEqual(g.onNowByPart.map(\.part), ["audio", "windows"])
        XCTAssertEqual(g.onNowByPart[0].items.map(\.title), ["Output compressor and limiter"])
        var lines = podcast; lines[2] = line("fx", "audio", "Output compressor and limiter", off: SharedSetupFit.switchedOffReason, cause: .person)
        let h = podcastGrouping(lines)
        XCTAssertEqual(h.onNowByPart.map(\.part), ["windows"])
        XCTAssertEqual(h.switchedOffByPerson.map(\.title), ["Output compressor and limiter"])
    }
}
