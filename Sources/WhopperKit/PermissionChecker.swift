import Foundation
import AppKit
import ApplicationServices
import AVFoundation
import IOKit.hid

public protocol PermissionChecking: Sendable {
    func status(_ p: Permission) -> PermissionStatus
}

/// Reads the real macOS grants. Never prompts; prompting is an explicit action elsewhere.
public struct LivePermissionChecker: PermissionChecking {
    public init() {}

    public func status(_ p: Permission) -> PermissionStatus {
        switch p {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeDenied: return .denied
            default: return .notDetermined
            }
        case .camera: return Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone: return Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .micDriver: return .unknown
        case .paste:
            guard #available(macOS 15.4, *) else { return .granted }
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: return .granted
            case .alwaysDeny: return .denied
            case .default, .ask: return .notDetermined
            @unknown default: return .unknown
            }
        case .systemAudio: return Self.systemAudioStatus()
        }
    }

    /// System Audio Recording has no public way to read its grant. macOS answers through the same call its own apps use
    /// (`TCCAccessPreflight` in the system's TCC framework), looked up at run time so nothing links against it. It only
    /// reads the grant and never shows a prompt. If the call is missing on some macOS version, the answer stays unknown,
    /// which the Permissions page shows as before.
    private static func systemAudioStatus() -> PermissionStatus {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW) else { return .unknown }
        defer { dlclose(tcc) }
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    private static func map(_ s: AVAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}

/// Test double.
public struct FakePermissionChecker: PermissionChecking {
    public var table: [Permission: PermissionStatus]
    public init(_ table: [Permission: PermissionStatus] = [:]) { self.table = table }
    public func status(_ p: Permission) -> PermissionStatus { table[p] ?? .notDetermined }
}

/// Asking for a grant. Always an explicit user action; macOS shows its own prompt or we open the pane.
public enum PermissionRequester {
    public static func request(_ p: Permission) {
        switch p {
        case .accessibility:
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .systemAudio, .paste, .micDriver:
            break   // granted by the first tap; no API to ask ahead of time
        }
    }
}
