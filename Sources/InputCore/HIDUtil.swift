import Foundation

/// Hardware-level key remaps via `/usr/bin/hidutil`. Used for Caps Lock and modifier keys, which an event tap
/// cannot remap cleanly. Mappings vanish on reboot, and are always taken back out when we stop.
public final class HIDUtil: @unchecked Sendable {
    public static let shared = HIDUtil()
    private let path = "/usr/bin/hidutil"
    private let lock = NSLock()
    private var before: [HIDMapping]?

    public init() {}

    private func run(_ args: [String]) -> (ok: Bool, out: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return (false, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    public static func json(_ maps: [HIDMapping]) -> String {
        let items = maps.map { "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}" }
        return "{\"UserKeyMapping\":[\(items.joined(separator: ","))]}"
    }

    /// Mappings currently in force (ours or anyone's).
    public func current() -> [HIDMapping] {
        let r = run(["property", "--get", "UserKeyMapping"])
        guard r.ok else { return [] }
        // One text block per HID service, each listing its mappings as `{ Dst = n; Src = n; }` in either order.
        return Self.parse(r.out)
    }

    public static func parse(_ text: String) -> [HIDMapping] {
        var out: [HIDMapping] = [], src: UInt64?, dst: UInt64?
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            func num(_ key: String) -> UInt64? {
                guard t.hasPrefix(key), let eq = t.firstIndex(of: "=") else { return nil }
                return UInt64(t[t.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " ;")))
            }
            if let s = num("HIDKeyboardModifierMappingSrc") { src = s }
            if let d = num("HIDKeyboardModifierMappingDst") { dst = d }
            if t.hasPrefix("}") {
                if let s = src, let d = dst { let m = HIDMapping(src: s, dst: d); if !out.contains(m) { out.append(m) } }
                src = nil; dst = nil
            }
        }
        return out
    }

    /// Applies exactly these mappings, remembering what was there so `restore` can put it back.
    @discardableResult
    public func apply(_ maps: [HIDMapping]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if before == nil { before = current() }
        return run(["property", "--set", Self.json(maps)]).ok
    }

    @discardableResult
    public func restore() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let prev = before ?? []
        before = nil
        return run(["property", "--set", Self.json(prev)]).ok
    }
}
