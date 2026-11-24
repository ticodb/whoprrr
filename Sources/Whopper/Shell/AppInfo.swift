import Foundation

/// Facts about this build, in one place so the About page, diagnostics and bug reports agree.
enum AppInfo {
    static let name = "Whoprrr"
    static let tagline = "Your Mac, stacked your way."
    /// Public project home. Change here (and in README/docs) if the repository moves.
    static let repoURL = URL(string: "https://github.com/ticodb/whoprrr")!
    static var issuesURL: URL { repoURL.appendingPathComponent("issues/new/choose") }
    static var licenseName: String { "MIT License" }

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
    /// "beta 1", "rc 2"… empty for a final release.
    static var channel: String { Bundle.main.infoDictionary?["WhoprrrReleaseLabel"] as? String ?? "" }
    static var versionLine: String { "Version \(version)" + (channel.isEmpty ? "" : " \(channel)") + " (build \(build))" }
    static var isBeta: Bool { channel.lowercased().contains("beta") }
}
