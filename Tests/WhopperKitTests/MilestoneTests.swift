import XCTest
@testable import WhopperKit

final class MilestoneTests: XCTestCase {
    func testExistingShelfFileLoadsAndBaselinesWithoutCelebrating() throws {
        let legacy = Data("""
            {"formatVersion":1,"count":"unasked","takes":[],"shared":[],"notices":[]}
            """.utf8)
        var state = try JSONDecoder().decode(PicklsssState.self, from: legacy)
        XCTAssertNil(state.milestones)
        state.takes = [TakeRecord(picklsssId: "desk", title: "Desk", handle: "cook", recipeID: UUID(), takenAt: Date(), counted: false)]
        state.prepareMilestones()
        state.milestones?.observeCook(ShelfCook(handle: "cook", rank: "line cook", keeps: 23), sharedCount: 3)
        XCTAssertEqual(state.milestones?.takes, 1)
        XCTAssertEqual(state.milestones?.pickles, 4)
        XCTAssertEqual(state.milestones?.highestRank, .lineCook)
        XCTAssertEqual(state.milestones?.keeps, 23)
        XCTAssertEqual(state.milestones?.queued, [])
    }

    func testFirstAcceptanceKeepAndRankChangesAreQueuedInOrder() {
        var progress = MilestoneProgress(previousTakes: 0, previousShares: 0)
        progress.observeCook(nil, sharedCount: 0)
        progress.recordShare()
        progress.observeCook(ShelfCook(handle: "cook", rank: "dishwasher"), sharedCount: 1)
        progress.observeCook(ShelfCook(handle: "cook", rank: "line cook", keeps: 22), sharedCount: 1)
        XCTAssertEqual(progress.queued.map(\.kind), [.pickle, .rank(.dishwasher), .firstKeep, .rank(.prepCook), .rank(.lineCook)])
        XCTAssertEqual(progress.queued.map(\.rank), [nil, .dishwasher, .dishwasher, .prepCook, .lineCook])
        XCTAssertEqual(progress.queued.map(\.pickles), [1, 1, 1, 1, 1])
    }

    func testRepeatedAndOlderMineResultsCannotRepeatMilestones() {
        var progress = MilestoneProgress(previousTakes: 0, previousShares: 0)
        let old = ShelfCook(handle: "cook", rank: "sous chef", keeps: 120)
        let newest = ShelfCook(handle: "cook", rank: "head chef", keeps: 207)
        progress.observeCook(old, sharedCount: 3)
        progress.observeCook(newest, sharedCount: 3)
        XCTAssertEqual(progress.next(windowOpen: true)?.kind, .rank(.headChef))
        progress.observeCook(old, sharedCount: 3)
        progress.observeCook(nil, sharedCount: 0)
        progress.observeCook(newest, sharedCount: 3)
        XCTAssertNil(progress.next(windowOpen: true))
        XCTAssertEqual(progress.keeps, 207)
        XCTAssertEqual(progress.highestRank, .headChef)
    }

    func testTakingThresholdsEachDropOnePickle() {
        var progress = MilestoneProgress(previousTakes: 0, previousShares: 0)
        for i in 1...52 { progress.recordTake(title: "Desk \(i)", inRecipes: true) }
        XCTAssertEqual(progress.queued.count, 52)
        XCTAssertEqual(progress.queued.map(\.pickles), Array(1...52))
        let milestones = progress.queued.filter { $0.kind != .pickle }
        XCTAssertEqual(milestones.map(\.kind), [.firstTake(title: "Desk 1", inRecipes: true), .tenTakes, .twentyFiveTakes, .fiftyTakes])
        XCTAssertEqual(milestones.map(\.pickles), [1, 10, 25, 50])
        XCTAssertTrue(progress.queued.allSatisfy { $0.dropsPickle && $0.rank == nil })
        XCTAssertEqual(milestones.first?.detail, "“Desk 1” is in your recipes. One button puts everything back.")
        XCTAssertEqual(Set(progress.queued.map(\.id)).count, 52)
    }

    func testTakesFromBeforeThisVersionCountTowardTheNextThreshold() {
        var progress = MilestoneProgress(previousTakes: 24, previousShares: 4)
        XCTAssertEqual(progress.queued, [])
        progress.recordTake(title: "Desk", inRecipes: true)
        XCTAssertEqual(progress.queued.first?.kind, .twentyFiveTakes)
        XCTAssertEqual(progress.queued.first?.pickles, 29)
    }

    func testAFirstTakeOfOnePartSaysWhereItLanded() {
        var progress = MilestoneProgress(previousTakes: 0, previousShares: 0)
        progress.recordTake(title: "Desk", inRecipes: false)
        XCTAssertEqual(progress.next(windowOpen: true)?.detail, "“Desk” is in your presets.")
    }

    func testAClosedWindowKeepsTheQueueAndConsumedMilestonesStayConsumedAfterRelaunch() throws {
        var state = PicklsssState()
        state.prepareMilestones()
        state.milestones?.recordTake(title: "Desk", inRecipes: true)
        state.milestones?.recordShare()
        XCTAssertNil(state.milestones?.next(windowOpen: false))

        let pending = try JSONEncoder().encode(state)
        var reopened = try JSONDecoder().decode(PicklsssState.self, from: pending)
        XCTAssertEqual(reopened.milestones?.next(windowOpen: true)?.kind, .firstTake(title: "Desk", inRecipes: true))
        let afterFirst = try JSONEncoder().encode(reopened)
        var relaunched = try JSONDecoder().decode(PicklsssState.self, from: afterFirst)
        XCTAssertEqual(relaunched.milestones?.next(windowOpen: true)?.kind, .pickle)
        XCTAssertNil(relaunched.milestones?.next(windowOpen: true))
        XCTAssertEqual(relaunched.milestones?.pickles, 2)
    }
}
