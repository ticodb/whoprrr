import ServiceManagement

/// Open-at-login via SMAppService. Needs a bundled, signed app; from `swift run` it reports unavailable.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch { return false }
    }
}
