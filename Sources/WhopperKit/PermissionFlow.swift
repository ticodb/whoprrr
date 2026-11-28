import Foundation

/// One deliberate grant or repair. Persisted so a macOS restart resumes without
/// opening another pane, asking again, or repeating a reset.
public struct PermissionFlow: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case prepare, working, waiting, checkAudio, ready }
    public let permission: Permission
    public let repair: Bool
    public let tracksSetup: Bool
    public private(set) var stage: Stage = .prepare
    public var suspended = false
    public var returnPage: String?

    public init(_ permission: Permission, repair: Bool = false, tracksSetup: Bool = true) {
        self.permission = permission
        self.repair = repair
        self.tracksSetup = tracksSetup
    }

    /// Repeated clicks cannot repeat a reset or launch overlapping system UI.
    @discardableResult public mutating func begin() -> Bool {
        guard stage == .prepare else { return false }
        stage = .working
        return true
    }

    public mutating func wait() { if stage == .working { stage = .waiting } }
    public mutating func needsAudioCheck() { if stage == .waiting { stage = .checkAudio } }
    public mutating func finish() { if stage == .waiting || stage == .checkAudio { stage = .ready } }

    /// A process may quit while a reset or a prompt is in flight. Never replay it.
    public mutating func reopened() {
        if stage == .working { stage = .waiting }
    }
}
