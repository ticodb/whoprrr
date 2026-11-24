import AppKit
import ClipboardCore

// Live check of the pasteboard watcher against a throwaway database. Saves and restores your clipboard text.
MainActor.assumeIsolated {
    let pb = NSPasteboard.general
    let original = pb.string(forType: .string)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whopper-clipprobe-\(UUID().uuidString)")
    let store = try! ClipStore(directory: dir)
    let watcher = PasteboardWatcher(store: store, settings: { ClipboardSettings() })
    watcher.start()
    var ok = true
    func check(_ name: String, _ cond: Bool) { print(cond ? "PASS" : "FAIL", name); if !cond { ok = false } }

    func run(after t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }

    pb.clearContents(); pb.setString("whopper-probe-123", forType: .string)
    run(after: 1.0) {
        check("plain copy is recorded", store.list().contains { $0.preview == "whopper-probe-123" })
        pb.clearContents()
        pb.setString("secret-should-not-be-kept", forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        run(after: 1.0) {
            check("concealed copy is skipped", !store.list().contains { $0.preview.contains("secret-should-not") })
            check("skip counted", watcher.skipped == 1)
            if let item = store.list().first, let payload = store.payload(item.id) {
                let n = Paster.write(payload, imagesDir: store.imagesDir, plain: true)
                watcher.ignore(changeCount: n)
                check("write-back restores text", pb.string(forType: .string) == "whopper-probe-123")
            }
            run(after: 1.0) {
                check("own write not re-recorded", store.count() == 1)
                pb.clearContents()
                if let o = original { pb.setString(o, forType: .string) }
                try? FileManager.default.removeItem(at: dir)
                print(ok ? "ALL PASS" : "FAILED"); exit(ok ? 0 : 1)
            }
        }
    }
    NSApplication.shared.run()
}
