import Foundation
import WhopperKit
import Carbon.HIToolbox

public enum ClipKind: String, Codable, Sendable, CaseIterable { case text, image, files }

/// A history entry as the list shows it (no heavy payloads).
public struct ClipItem: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var kind: ClipKind
    public var title: String?            // snippet name
    public var preview: String           // first part of the text, or file names
    public var imageFile: String?        // file name inside the images directory
    public var files: [String]
    public var sourceApp: String?
    public var sourceBundle: String?
    public var createdAt: Date
    public var lastUsedAt: Date
    public var useCount: Int
    public var pinned: Bool
    public var isSnippet: Bool
    public var byteSize: Int
    public var hasRich: Bool
}

/// Everything needed to put an item back on the pasteboard.
public struct ClipPayload: Sendable {
    public var kind: ClipKind
    public var text: String?
    public var rtf: Data?
    public var html: Data?
    public var imageFile: String?
    public var files: [String]
}

/// What the watcher read from the pasteboard, before it is stored.
public struct ClipCapture: Sendable {
    public var kind: ClipKind
    public var text: String?
    public var rtf: Data?
    public var html: Data?
    public var imageData: Data?          // PNG
    public var files: [String] = []
    public var sourceApp: String?
    public var sourceBundle: String?

    public init(kind: ClipKind, text: String? = nil, rtf: Data? = nil, html: Data? = nil, imageData: Data? = nil,
                files: [String] = [], sourceApp: String? = nil, sourceBundle: String? = nil) {
        self.kind = kind; self.text = text; self.rtf = rtf; self.html = html; self.imageData = imageData
        self.files = files; self.sourceApp = sourceApp; self.sourceBundle = sourceBundle
    }
}

public struct ClipboardSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var hotkey = Shortcut(kVK_ANSI_V, Shortcut.ctrl | Shortcut.cmd)
    public var maxItems = 1000
    public var maxAgeDays = 30
    public var captureImages = true
    public var captureFiles = true
    public var maxImageMB = 20
    public var maxTextKB = 1024
    /// Paste straight into the front app on selection (needs Accessibility); otherwise only copy.
    public var autoPaste = true
    /// Selecting an item pastes it as plain text unless Shift is held.
    public var plainTextByDefault = false
    public var ignoredBundles: [String] = ClipboardSettings.defaultIgnored
    public init() {}

    public static let defaultIgnored = [
        "com.1password.1password", "com.1password.1password7", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc",
        "com.dashlane.dashlanephonefinal", "com.lastpass.lastpassmacdesktop", "in.sinew.Enpass-Desktop",
    ]
}

public enum ClipListFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All", text = "Text", images = "Images", files = "Files", pinned = "Pinned"
    public var id: String { rawValue }
}
