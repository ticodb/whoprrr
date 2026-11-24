import Foundation
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
        case .systemAudio: return .unknown
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
        case .systemAudio:
            break   // granted by the first tap; no API to ask ahead of time
        }
    }
}
