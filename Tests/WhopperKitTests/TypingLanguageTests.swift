import XCTest
import WindowCore
@testable import WhopperKit

final class TypingLanguageTests: XCTestCase {
    func testManualSwitchWinsAcrossAutomaticRecipesAndRelaunch() throws {
        var rule = TypingLanguageRule()
        rule.observe("US", recipeActive: true)
        XCTAssertTrue(rule.permitsSwitch(automatic: true))
        rule.selectedByRecipe("Spanish-ISO")
        rule.observe("Spanish-ISO", recipeActive: true)
        XCTAssertTrue(rule.permitsSwitch(automatic: true))

        rule.observe("British", recipeActive: true)
        for _ in 0..<2 { XCTAssertFalse(rule.permitsSwitch(automatic: true)) }
        let data = try JSONEncoder().encode(rule)
        rule = try JSONDecoder().decode(TypingLanguageRule.self, from: data)
        XCTAssertFalse(rule.permitsSwitch(automatic: true))
        XCTAssertTrue(rule.permitsSwitch(automatic: false))
        rule.selectedByRecipe("US")
        rule.observe("US", recipeActive: true)
        XCTAssertTrue(rule.permitsSwitch(automatic: true))
    }

    func testChangingLanguageWithoutARecipeKeepsAutomaticSwitchingAvailable() {
        var rule = TypingLanguageRule()
        rule.observe("US", recipeActive: false)
        rule.observe("British", recipeActive: false)
        XCTAssertTrue(rule.permitsSwitch(automatic: true))
    }

    func testMissingSharedLanguageStaysOffAndAnEnabledLanguageFits() throws {
        let language = SharedTypingLanguage(id: "com.apple.keylayout.Spanish-ISO", name: "Spanish – ISO")
        let setup = SharedSetup(title: "Desk", line: "A desk recipe.", parts: [], gear: [],
                                requirements: .init(), settings: [:], typingLanguage: language)
        let receiver = ReceiverEnvironment()
        let missing = SharedSetupFit.plan(setup, for: receiver)
        XCTAssertEqual(missing.line("typingLanguage")?.state, .off("Spanish – ISO is not on this Mac"))
        XCTAssertNil(SharedSetupFit.fit(setup, plan: missing, for: receiver).recipe.inputSourceID)

        let ready = ReceiverEnvironment(installedInputSources: [language.id], enabledInputSources: [language.id])
        let fits = SharedSetupFit.plan(setup, for: ready)
        XCTAssertFalse(try XCTUnwrap(fits.line("typingLanguage")).state.isOff)
        XCTAssertEqual(SharedSetupFit.fit(setup, plan: fits, for: ready).recipe.inputSourceID, language.id)
        let disabled = SharedSetupFit.plan(setup, for: ready, switchedOff: ["typingLanguage"])
        XCTAssertNil(SharedSetupFit.fit(setup, plan: disabled, for: ready).recipe.inputSourceID)
    }

    func testRecipeFromBeforeTypingLanguageDefaultsToDontChange() throws {
        let original = Recipe(name: "Desk")
        let encoded = try JSONEncoder().encode(original)
        let reread = try JSONDecoder().decode(Recipe.self, from: encoded)
        XCTAssertNil(reread.inputSourceID)
        XCTAssertNil(reread.inputSourceName)
    }

    func testSharingFileCarriesTypingLanguageOnlyWhenIncluded() throws {
        let windows = try XCTUnwrap(RecipeJSON.encode(WindowSettings()))
        var recipe = Recipe(name: "Desk", sections: ["windows": windows])
        recipe.inputSourceID = "com.apple.keylayout.Spanish-ISO"
        recipe.inputSourceName = "Spanish – ISO"
        let setup = try XCTUnwrap(SharedSetupExport.export(title: "Desk", line: "Desk settings.", recipe: recipe).setup)
        let file = try SharedSetupFile.encode(setup, madeBy: "key-id").get()
        XCTAssertEqual(SharedSetupFile.decode(file).setup?.typingLanguage,
                       SharedTypingLanguage(id: "com.apple.keylayout.Spanish-ISO", name: "Spanish – ISO"))

        let omitted = try XCTUnwrap(SharedSetupExport.export(title: "Desk", line: "Desk settings.", recipe: recipe,
                                                           includeTypingLanguage: false).setup)
        XCTAssertNil(omitted.typingLanguage)
    }
}
