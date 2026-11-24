import Foundation

/// A macOS privacy grant a feature may need. Features declare these so the
/// Permissions page can say who needs what, and ask only for what is enabled.
public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case accessibility, inputMonitoring, camera, microphone, systemAudio
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .systemAudio: "System Audio Recording"
        }
    }

    /// Plain-words reason shown next to the grant.
    public var why: String {
        switch self {
        case .accessibility: "Move and resize windows, and remap keys and mouse buttons."
        case .inputMonitoring: "See keyboard and mouse input so remaps can apply."
        case .camera: "Match the two displays by looking at both with a camera. Frames are never saved."
        case .microphone: "Process and route the microphone."
        case .systemAudio: "Capture the system mix so the equalizer can process it."
        }
    }

    /// Deep link into System Settings > Privacy & Security.
    public var settingsURL: URL {
        let pane: String
        switch self {
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        case .camera: pane = "Privacy_Camera"
        case .microphone: pane = "Privacy_Microphone"
        case .systemAudio: pane = "Privacy_AudioCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

public enum PermissionStatus: Equatable, Sendable {
    case granted, denied, notDetermined
    /// macOS offers no public way to read this grant.
    case unknown
}

/// One user-facing capability. Each maps to a module; features the user has not
/// installed stay unloaded and never ask for permissions.
public enum Feature: String, CaseIterable, Sendable, Identifiable, Codable {
    case display, windows, clipboard, remap, audio, microphone
    public var id: String { rawValue }

    /// For narrow places such as the sidebar.
    public var shortTitle: String { self == .audio ? "Audio" : title }

    public var title: String {
        switch self {
        case .display: "External displays"
        case .windows: "Windows"
        case .clipboard: "Clipboard"
        case .remap: "Keys and mouse"
        case .audio: "Audio EQ and routing"
        case .microphone: "Microphone"
        }
    }

    public var symbol: String {
        switch self {
        case .display: "display"
        case .windows: "rectangle.split.2x2"
        case .clipboard: "doc.on.clipboard"
        case .remap: "keyboard"
        case .audio: "slider.vertical.3"
        case .microphone: "mic"
        }
    }

    public var summary: String {
        switch self {
        case .display: "Brightness, contrast and color for external monitors over DDC/CI, presets, and camera matching against the MacBook screen."
        case .windows: "Snap, tile and move windows across displays."
        case .clipboard: "Searchable history with pins, snippets and plain-text paste."
        case .remap: "Remap keys and mouse buttons, layers, per-app rules."
        case .audio: "System EQ per output device, input pinning, Bluetooth keep-alive."
        case .microphone: "Keep the PodMic as the input everywhere, with effects."
        }
    }

    public var requires: [Permission] {
        switch self {
        case .display: [.camera]
        case .windows: [.accessibility]
        case .clipboard: []
        case .remap: [.accessibility, .inputMonitoring]
        case .audio: [.systemAudio]
        case .microphone: [.microphone]
        }
    }

    /// False until the module exists; the hub shows it as "planned".
    public var isBuilt: Bool { true }
}
