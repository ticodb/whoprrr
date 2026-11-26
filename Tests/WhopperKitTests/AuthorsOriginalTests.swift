import XCTest
@testable import WhopperKit

/// A recipe taken from a shared setup has two ways back: the version before the person's last save (existing) and the author's
/// original as first fitted to this Mac. Both swap with what the recipe holds now, so each can be undone.
@MainActor
final class AuthorsOriginalTests: RecipeHarnessCase {
    func d(_ s: String) -> Data { RecipeJSON.encode(["v": s])! }
    func taken(_ h: Harness) -> UUID {
        var r = Recipe(name: "Podcast desk", sections: ["audio": d("fitted-audio"), "windows": d("fitted-windows")])
        r.authorsOriginal = AuthorsOriginal(title: "Podcast desk", madeBy: "lucia.r", setup: Data("{}".utf8),
                                            fittedSections: ["audio": d("fitted-audio"), "windows": d("fitted-windows")], takenAt: clock)
        return h.store.addTaken(r).id
    }

    func testGoingToTheOriginalAfterTwoSavesSwapsAndCanBeUndone() {
        let h = harness()
        let id = taken(h)
        h.store.apply(id)
        h.audio.value = "mine-1"; tick(); h.store.save(id)
        h.audio.value = "mine-2"; tick(); h.store.save(id)
        XCTAssertEqual(h.store.recipe(id)?.sections["audio"], d("mine-2"))
        XCTAssertTrue(h.store.canGoToAuthorsOriginal(id))

        XCTAssertEqual(h.store.goToAuthorsOriginal(id), [])
        XCTAssertEqual(h.store.recipe(id)?.sections["audio"], d("fitted-audio"))
        XCTAssertEqual(h.audio.value, "fitted-audio", "an active recipe's settings change to match")
        XCTAssertEqual(h.store.recipe(id)?.previous?.sections["audio"], d("mine-2"), "what was put aside is one step away")
        XCTAssertEqual(h.store.recipe(id)?.previous?.isNewer, true)

        h.store.goBack(id)
        XCTAssertEqual(h.store.recipe(id)?.sections["audio"], d("mine-2"), "both ways swap, so you can come back")
        XCTAssertEqual(h.store.recipe(id)?.authorsOriginal?.fittedSections["audio"], d("fitted-audio"), "the original itself is never touched")
    }

    func testARecipeThatWasNotTakenHasNoOriginal() {
        let h = harness()
        let r = h.store.create(name: "Desk", symbol: "house", includes: ["audio"], devices: [], autoApply: false)
        XCTAssertFalse(h.store.canGoToAuthorsOriginal(r.id))
        XCTAssertNil(h.store.goToAuthorsOriginal(r.id))
    }

    func testTheOriginalSurvivesAFileRoundTrip() {
        let h = harness()
        let id = taken(h)
        h.store.goToAuthorsOriginal(id)
        let again = RecipeStore(url: h.url, now: { [unowned self] in self.clock })
        XCTAssertEqual(again.recipe(id)?.authorsOriginal?.title, "Podcast desk")
        XCTAssertNotNil(again.recipe(id)?.previous)
    }
}
