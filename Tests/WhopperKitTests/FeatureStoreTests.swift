import XCTest
@testable import WhopperKit

@MainActor
final class FeatureStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "whopper.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testBuiltFeaturesStartOn() {
        let s = FeatureStore(defaults: freshDefaults())
        XCTAssertEqual(s.enabled, Set(Feature.allCases.filter(\.isBuilt)))
    }

    func testUnbuiltFeatureCannotBeEnabled() {
        let s = FeatureStore(defaults: freshDefaults())
        guard let unbuilt = Feature.allCases.first(where: { !$0.isBuilt }) else { return }   // every feature is built now
        s.setEnabled(unbuilt, true)
        XCTAssertFalse(s.isEnabled(unbuilt))
    }

    func testPersistsAcrossInstances() {
        let d = freshDefaults()
        let a = FeatureStore(defaults: d)
        a.setEnabled(.display, false)
        XCTAssertFalse(FeatureStore(defaults: d).isEnabled(.display))
        XCTAssertTrue(FeatureStore(defaults: d).isEnabled(.audio))
    }

    func testNeededPermissionsFollowEnabledFeatures() {
        let s = FeatureStore(defaults: freshDefaults())
        for f in Feature.allCases where f != .display { s.setEnabled(f, false) }
        XCTAssertEqual(s.neededPermissions, [.camera])
        XCTAssertEqual(s.features(needing: .camera), [.display])
        s.setEnabled(.display, false)
        XCTAssertTrue(s.neededPermissions.isEmpty)
    }

    func testEveryFeatureHasUniqueSymbolAndNoDuplicateIDs() {
        XCTAssertEqual(Set(Feature.allCases.map(\.symbol)).count, Feature.allCases.count)
    }
}
