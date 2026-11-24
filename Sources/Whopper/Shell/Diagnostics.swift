import AppKit
import WhopperKit

/// A short text report for bug reports. It lists versions, settings counts and permission states, never device names,
/// clipboard contents, rules or file paths.
@MainActor
enum DiagnosticsReport {
    static func make() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var arch = "unknown"
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #endif
        let checker = LivePermissionChecker()
        let perms = Permission.allCases.map { "\($0.title): \(label(checker.status($0)))" }
        let a = Shared.audio
        let features = Shared.features.enabledInOrder.map(\.rawValue).joined(separator: ", ")
        let transports = Dictionary(grouping: a.devices.filter { !$0.isWhopperInternal }, by: { $0.transport.rawValue }).mapValues(\.count)
            .sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        return """
        \(AppInfo.name) \(AppInfo.versionLine)
        macOS \(os) · \(arch)
        Features on: \(features)
        Permissions: \(perms.joined(separator: "; "))
        Audio devices by type: \(transports.isEmpty ? "none" : transports)
        External displays: \(Shared.model.displays.filter { !$0.isBuiltIn }.count)
        Logitech devices: \(Shared.input.logiDevices.count)
        Key rules: \(Shared.input.settings.rules.count) · remap status: \(Shared.input.status)
        System sound chain: \(a.eqState) · plugins mic/output: \(a.settings.mic.plugins.count)/\(a.settings.eq.plugins.count)
        Recipes: \(Shared.recipes.recipes.count)
        """
    }

    private static func label(_ s: PermissionStatus) -> String {
        switch s { case .granted: "granted"; case .denied: "denied"; case .notDetermined: "not asked"; case .unknown: "unknown" }
    }

    static func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(make(), forType: .string)
    }
}
