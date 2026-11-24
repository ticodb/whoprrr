import AppKit
import ApplicationServices

/// Watches the general pasteboard and records what is copied. Polling `changeCount` is the only way macOS
/// offers; it is cheap, and contents are read only when the count changes.
@MainActor
public final class PasteboardWatcher {
    private let store: ClipStore
    private let settings: () -> ClipboardSettings
    private var timer: Timer?
    private var lastCount: Int
    public var onCapture: (() -> Void)?
    public private(set) var skipped = 0

    public init(store: ClipStore, settings: @escaping () -> ClipboardSettings) {
        self.store = store; self.settings = settings
        lastCount = NSPasteboard.general.changeCount
    }

    public func start() {
        guard timer == nil else { return }
        lastCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() { timer?.invalidate(); timer = nil }

    /// Ignore the change we just caused by writing to the pasteboard ourselves.
    public func ignore(changeCount: Int) { lastCount = max(lastCount, changeCount) }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        let s = settings()
        guard s.enabled else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let types = (pb.types ?? []).map(\.rawValue)
        if CaptureRules.shouldSkip(types: types, frontBundle: front?.bundleIdentifier, settings: s) { skipped += 1; return }
        guard let cap = Self.read(pb, settings: s, app: front?.localizedName, bundle: front?.bundleIdentifier) else { return }
        let store = store
        Task.detached { [onCapture] in
            store.add(cap)
            store.prune(maxItems: s.maxItems, maxAgeDays: s.maxAgeDays)
            await MainActor.run { onCapture?() }
        }
    }

    static func read(_ pb: NSPasteboard, settings s: ClipboardSettings, app: String?, bundle: String?) -> ClipCapture? {
        if s.captureFiles,
           let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return ClipCapture(kind: .files, text: urls.map(\.path).joined(separator: "\n"), files: urls.map(\.path), sourceApp: app, sourceBundle: bundle)
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            guard text.utf8.count <= s.maxTextKB * 1024 else { return nil }
            if text.allSatisfy(\.isWhitespace) { return nil }
            return ClipCapture(kind: .text, text: text, rtf: pb.data(forType: .rtf), html: pb.data(forType: .html), sourceApp: app, sourceBundle: bundle)
        }
        if s.captureImages, let png = imagePNG(pb), png.count <= s.maxImageMB * 1_048_576 {
            return ClipCapture(kind: .image, imageData: png, sourceApp: app, sourceBundle: bundle)
        }
        return nil
    }

    private static func imagePNG(_ pb: NSPasteboard) -> Data? {
        if let d = pb.data(forType: .png) { return d }
        guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

public enum Paster {
    public enum Result: Equatable { case pasted, copiedOnly(reason: String) }

    /// Puts an item on the pasteboard. Returns the new change count so the watcher can ignore it.
    @MainActor @discardableResult
    public static func write(_ p: ClipPayload, imagesDir: URL, plain: Bool) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch p.kind {
        case .text:
            pb.setString(p.text ?? "", forType: .string)
            if !plain {
                if let r = p.rtf { pb.setData(r, forType: .rtf) }
                if let h = p.html { pb.setData(h, forType: .html) }
            }
        case .image:
            if let f = p.imageFile, let d = try? Data(contentsOf: imagesDir.appendingPathComponent(f)) {
                pb.setData(d, forType: .png)
                if let img = NSImage(data: d), let tiff = img.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            }
        case .files:
            let urls = p.files.map { URL(fileURLWithPath: $0) as NSURL }
            if plain { pb.setString(p.files.joined(separator: "\n"), forType: .string) } else { pb.writeObjects(urls) }
        }
        return pb.changeCount
    }

    /// Sends Cmd-V to whatever app is in front. Needs Accessibility; without it the item stays on the pasteboard.
    public static func postPaste() -> Result {
        guard AXIsProcessTrusted() else { return .copiedOnly(reason: "Grant Accessibility to paste automatically") }
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)   // V
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        return .pasted
    }
}
