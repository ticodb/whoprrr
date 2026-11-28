import Foundation

/// Identity for an optional diagnostic run. Cancellation releases the run at once;
/// an older task finishing later cannot clear a newer run's state.
public struct SetupCheckRun: Sendable {
    public private(set) var active: UUID?
    public init() {}

    public mutating func begin() -> UUID? {
        guard active == nil else { return nil }
        let id = UUID()
        active = id
        return id
    }

    @discardableResult public mutating func finish(_ id: UUID) -> Bool {
        guard active == id else { return false }
        active = nil
        return true
    }

    public mutating func cancel() { active = nil }
}
