import Foundation
import Combine

/// Which features are installed. Persisted, observable, and the single source
/// for "which permissions does anything still need".
@MainActor
public final class FeatureStore: ObservableObject {
    private let defaults: UserDefaults
    private let key = "whopper.enabledFeatures"

    @Published public private(set) var enabled: Set<Feature>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.array(forKey: key) as? [String] {
            enabled = Set(raw.compactMap(Feature.init(rawValue:)).filter(\.isBuilt))
        } else {
            enabled = Set(Feature.allCases.filter(\.isBuilt))   // built features start on
        }
    }

    public func isEnabled(_ f: Feature) -> Bool { enabled.contains(f) }

    /// Unbuilt features cannot be enabled.
    public func setEnabled(_ f: Feature, _ on: Bool) {
        guard f.isBuilt || !on else { return }
        setEnabled(on ? enabled.union([f]) : enabled.subtracting([f]))
    }

    public func setEnabled(_ selection: Set<Feature>) {
        let available = selection.filter(\.isBuilt)
        guard enabled != available else { return }
        enabled = available
        defaults.set(available.map(\.rawValue).sorted(), forKey: key)
    }

    /// Enabled features in catalogue order, for stable UI.
    public var enabledInOrder: [Feature] { Feature.allCases.filter(enabled.contains) }

    /// Permissions some enabled feature needs.
    public var neededPermissions: Set<Permission> {
        Set(enabled.flatMap(\.requires))
    }

    public func features(needing p: Permission) -> [Feature] {
        Feature.allCases.filter { $0.requires.contains(p) && enabled.contains($0) }
    }
}
