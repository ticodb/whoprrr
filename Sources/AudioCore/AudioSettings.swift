import Foundation

public struct AudioSettings: Codable, Equatable, Sendable {
    public var inputPin = InputPinPolicy(enabled: false, preferredUIDs: [])
    public var keepAlive: [String: KeepAliveSettings] = [:]
    public var eq = OutputEQSettings()
    public var mic = MicSettings()
    public var mix = MixSettings()
    /// Last-seen names, so a device's settings stay visible while it is disconnected.
    public var knownNames: [String: String] = [:]
    public init() {}

    private enum CodingKeys: String, CodingKey { case inputPin, keepAlive, eq, mic, knownNames, mix }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputPin = try c.decode(InputPinPolicy.self, forKey: .inputPin)
        keepAlive = try c.decode([String: KeepAliveSettings].self, forKey: .keepAlive)
        eq = try c.decode(OutputEQSettings.self, forKey: .eq)
        mic = try c.decode(MicSettings.self, forKey: .mic)
        knownNames = try c.decode([String: String].self, forKey: .knownNames)
        mix = try c.decodeIfPresent(MixSettings.self, forKey: .mix) ?? MixSettings()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(inputPin, forKey: .inputPin)
        try c.encode(keepAlive, forKey: .keepAlive)
        try c.encode(eq, forKey: .eq)
        try c.encode(mic, forKey: .mic)
        try c.encode(knownNames, forKey: .knownNames)
        // Keep the previous canonical bytes for recipes without any adjustments.
        if !mix.apps.isEmpty { try c.encode(mix, forKey: .mix) }
    }
}
