import Foundation
import AppKit

/// Installs the bundled Whoprrr Mic driver into /Library/Audio/Plug-Ins/HAL. That folder is root-owned, so macOS shows its
/// standard administrator password prompt; coreaudiod is then restarted to load the driver (audio drops for a moment).
@MainActor
enum DriverInstaller {
    static let target = "/Library/Audio/Plug-Ins/HAL/WhopperMic.driver"
    static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("WhopperMic.driver") }

    private static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Returns an error message, or nil on success.
    static func install() -> String? {
        guard let src = bundled, FileManager.default.fileExists(atPath: src.path) else {
            return "The driver is not bundled with this build. Run scripts/build-app.sh."
        }
        let cmd = "set -e; rm -rf \(shq(target)); cp -R \(shq(src.path)) \(shq(target)); chown -R root:wheel \(shq(target)); chmod -R go-w \(shq(target)); killall coreaudiod || true"
        return runAsAdmin(cmd)
    }

    static func uninstall() -> String? {
        runAsAdmin("rm -rf \(shq(target)); killall coreaudiod || true")
    }

    private static func runAsAdmin(_ shell: String) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&err)
        if let err {
            let n = err[NSAppleScript.errorNumber] as? Int
            if n == -128 { return "Cancelled." }
            return (err[NSAppleScript.errorMessage] as? String) ?? "Installation failed."
        }
        return nil
    }
}
