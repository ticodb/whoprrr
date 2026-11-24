import Foundation

public struct AudioSettings: Codable, Equatable, Sendable {
    public var inputPin = InputPinPolicy(enabled: false, preferredUIDs: [])
    public var keepAlive: [String: KeepAliveSettings] = [:]
    public var eq = OutputEQSettings()
    public var mic = MicSettings()
    /// Last-seen names, so a device's settings stay visible while it is disconnected.
    public var knownNames: [String: String] = [:]
    public init() {}
}
