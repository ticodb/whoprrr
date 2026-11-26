import Foundation

/// How sure we are that something works on a given piece of gear.
public enum Fit: String, Codable, Sendable {
    /// Proven on this exact model (the gear Whoprrr was developed on, later the fit feed).
    case tested
    /// This Mac just checked it (for a display: it answered a read).
    case checked
    /// Nothing says it will fail, nobody has confirmed it works.
    case untested
    /// Cannot work on this setup.
    case unavailable

    public var label: String {
        switch self {
        case .tested: "Tested on this gear"
        case .checked: "Checked just now"
        case .untested: "Should work, untested"
        case .unavailable: "Not on this setup"
        }
    }
}

/// What is connected to this Mac, reduced to the traits a starter recipe depends on. Plain data, so the rules that read it
/// can be tested without hardware.
public struct GearScan: Codable, Equatable, Sendable {
    public struct Mac: Codable, Equatable, Sendable {
        /// Model identifier, e.g. "MacBookAir10,1".
        public var model: String
        public var appleSilicon: Bool
        /// "27.2"
        public var os: String
        public init(model: String, appleSilicon: Bool, os: String) { self.model = model; self.appleSilicon = appleSilicon; self.os = os }
    }

    public struct Screen: Codable, Equatable, Sendable {
        public var name: String
        public var width: Int
        public var height: Int
        public var builtIn: Bool
        /// Whether it answered a read-only brightness query. Nil while that is still unknown.
        public var answers: Bool?
        public init(name: String, width: Int, height: Int, builtIn: Bool, answers: Bool?) {
            self.name = name; self.width = width; self.height = height; self.builtIn = builtIn; self.answers = answers
        }
        public var aspect: Double { height > 0 ? Double(width) / Double(height) : 0 }
        /// 21:9 and wider.
        public var isUltrawide: Bool { aspect >= 2.0 }
    }

    public struct Audio: Codable, Equatable, Sendable {
        public var uid: String
        public var name: String
        /// "builtIn", "usb", "bluetooth", "hdmi", "displayPort", "airplay", "other".
        public var transport: String
        public var hasInput: Bool
        public var hasOutput: Bool
        public init(uid: String, name: String, transport: String, hasInput: Bool, hasOutput: Bool) {
            self.uid = uid; self.name = name; self.transport = transport; self.hasInput = hasInput; self.hasOutput = hasOutput
        }
    }

    public var mac: Mac
    public var screens: [Screen]
    public var audio: [Audio]
    /// Names of Logitech devices that answered.
    public var logitech: [String]

    public init(mac: Mac, screens: [Screen] = [], audio: [Audio] = [], logitech: [String] = []) {
        self.mac = mac; self.screens = screens; self.audio = audio; self.logitech = logitech
    }

    public var externals: [Screen] { screens.filter { !$0.builtIn } }
}

/// Gear Whoprrr was developed and verified on (docs/compatibility.md). Matched by a fragment of the model name.
public enum KnownGear {
    public static let tested = ["S34CG50", "MX Keys S", "MX Ergo", "PodMic"]
    public static func isTested(_ name: String) -> Bool { tested.contains { name.localizedCaseInsensitiveContains($0) } }

    /// A device name with a person's name taken out: "Ana’s AirPods Pro" becomes "AirPods Pro". Used wherever a name leaves the Mac.
    public static func publicName(_ name: String) -> String {
        guard let r = name.range(of: #"^.*?['’]s\s+"#, options: .regularExpression) else { return name }
        let rest = String(name[r.upperBound...])
        return rest.isEmpty ? name : rest
    }
}
