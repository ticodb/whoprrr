import Foundation

/// One thing a shared setup needs from this Mac, listed before anything starts: a plugin, a macOS version, a permission.
public struct RequirementRow: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case plugin, macOS, permission }
    public enum Status: Equatable, Sendable {
        /// Installed, new enough, allowed.
        case ready
        /// Not installed, too old, or not allowed: the lines that need it are switched off.
        case missing
        /// Not decided yet: Whoprrr asks when it is needed.
        case ask
    }
    public var kind: Kind
    public var title: String
    public var detail: String
    public var status: Status
    public var id: String { "\(kind)-\(title)" }
    /// The plugin's name, so the screen can offer a link the person clicks. Plugins are never downloaded or installed.
    public var pluginName: String?
}

public enum Requirements {
    public static func rows(_ r: SharedRequirements, env: ReceiverEnvironment) -> [RequirementRow] {
        var out: [RequirementRow] = []
        for name in r.plugins {
            let have = env.plugins.contains { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
            out.append(RequirementRow(kind: .plugin, title: "Needs the plugin \(name)", detail: have ? "Installed on this Mac" : "Not installed on this Mac. Whoprrr never installs plugins; the lines that need it stay off",
                                      status: have ? .ready : .missing, pluginName: name))
        }
        if let need = r.minMacOS, !need.isEmpty {
            let ok = atLeast(env.macOS, need)
            out.append(RequirementRow(kind: .macOS, title: "Needs macOS \(need) or newer", detail: ok ? "This Mac has \(env.macOS)" : "This Mac has \(env.macOS). The lines that need it stay off", status: ok ? .ready : .missing))
        }
        for raw in r.permissions {
            guard let p = Permission(rawValue: raw) else { continue }
            switch env.permissions[p] {
            case .granted?: out.append(RequirementRow(kind: .permission, title: "Needs \(p.title)", detail: "Allowed for Whoprrr", status: .ready))
            case .denied?: out.append(RequirementRow(kind: .permission, title: "Needs \(p.title)", detail: "Not allowed for Whoprrr on this Mac. Allow it in System Settings and the lines can be switched on", status: .missing))
            default: out.append(RequirementRow(kind: .permission, title: "Needs \(p.title)", detail: "Whoprrr will ask when it is needed", status: .ask))
            }
        }
        return out
    }

    public static func atLeast(_ have: String, _ need: String) -> Bool {
        let a = have.split(separator: ".").map { Int($0) ?? 0 }, b = need.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) { let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0; if x != y { return x > y } }
        return true
    }
}
