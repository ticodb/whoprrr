import Foundation
import DisplayCore

// ddcprobe: command-line slice over the same DisplayCore the app uses.
//   ddcprobe list
//   ddcprobe read
//   ddcprobe brightness-test --yes [--delta -10] [--hold 5]
//   add --fake to run against the fake transport; --raw to print unredacted identifiers.

@main
struct Probe {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let fake = args.contains("--fake")
        args.removeAll { $0 == "--fake" }
        let raw = args.contains("--raw")
        args.removeAll { $0 == "--raw" }
        guard let cmd = args.first else { usage(); exit(2) }

        let transport: DDCTransport = fake ? Self.makeFake() : HardwareTransport()
        let controller = DisplayController(transport: transport)
        let snap = await controller.refresh()
        let tag = transport.kind == .fake ? "[FAKE] " : "[HARDWARE] "

        func shown(_ d: DisplayDescriptor) -> String {
            let id = raw ? d.uuid : Redaction.token(d.uuid, label: "uuid")
            return "\(d.identity.productName) \(id)"
        }

        switch cmd {
        case "list":
            for d in snap.displays {
                print("\(tag)\(shown(d)) builtIn=\(d.isBuiltIn) ddcEndpoint=\(d.hasEndpoint) vendor=\(d.identity.vendor) model=\(d.identity.model)")
            }

        case "read":
            let t = pickExternal(snap, controller)
            print("\(tag)target: \(shown(snap.displays.first { $0.uuid == t.uuid }!))")
            for c in Control.allCases {
                let s = Date()
                do {
                    let v = try await controller.read(c, target: t)
                    print("  \(c.label): \(v.current)/\(v.maximum)  (\(Int(Date().timeIntervalSince(s) * 1000)) ms)")
                } catch { print("  \(c.label): \(error)") }
            }

        case "scan":
            // Read-only discovery of every VCP code the display answers. No writes.
            guard let hw = transport as? HardwareTransport else { print("scan needs hardware"); exit(2) }
            let t = pickExternal(snap, controller)
            var found = 0
            for code in 0...255 {
                do {
                    let v = try hw.readRaw(vcp: UInt8(code), uuid: t.uuid)
                    found += 1
                    print(String(format: "0x%02X  cur=%d  max=%d", code, v.current, v.maximum))
                } catch DDCFailure.unsupported {
                } catch DDCFailure.timeout {
                } catch { print(String(format: "0x%02X  error %@", code, "\(error)")) }
            }
            print("\(found) codes answered")

        case "set":
            // set <hex code> <value> --yes: single opt-in write with readback (for restoring state).
            guard args.contains("--yes"), args.count >= 3, let code = UInt8(args[1].replacingOccurrences(of: "0x", with: ""), radix: 16), let v = Int(args[2]) else {
                print("usage: ddcprobe set <hex vcp code> <value> --yes"); exit(2)
            }
            let t = pickExternal(snap, controller)
            controller.writableControls.insert(Control(code))
            let o = try! await controller.write(Control(code), value: v, target: t)
            print("\(tag)\(Control(code).label): wrote \(o.applied), readback \(o.readback.map(String.init) ?? "none") -> \(o.verified ? "VERIFIED" : "UNVERIFIED")")

        case "write-test":
            // write-test <hexcode> [--to N | --delta N] [--hold S]: opt-in write proof for one control.
            guard args.contains("--yes"), args.count >= 2, let code = UInt8(args[1].replacingOccurrences(of: "0x", with: ""), radix: 16) else {
                print("usage: ddcprobe write-test <hex vcp code> --yes [--to N | --delta N] [--hold S]"); exit(2)
            }
            let c = Control(code)
            let t = pickExternal(snap, controller)
            controller.writableControls.insert(c)
            controller.writableControls.insert(.colorPreset)
            let hold = Double(value(after: "--hold", in: args) ?? "3") ?? 3
            let base = try! await controller.read(c, target: t)
            let preBase = try? await controller.read(.colorPreset, target: t)
            var probe: Int
            if let to = value(after: "--to", in: args).flatMap(Int.init) { probe = to }
            else {
                let d = Int(value(after: "--delta", in: args) ?? "-5") ?? -5
                probe = base.current + d
                if probe < 0 || probe > base.maximum { probe = base.current - d }
            }
            print("\(tag)\(c.label) baseline \(base.current)/\(base.maximum), probing \(probe); color preset before: \(preBase.map { String($0.current) } ?? "n/a")")
            do {
                let o = try await controller.write(c, value: probe, target: t)
                print("  wrote \(o.applied), readback \(o.readback.map(String.init) ?? "none") -> \(o.verified ? "VERIFIED" : "UNVERIFIED (display did not take it)")")
                if let post = try? await controller.read(.colorPreset, target: t), let pre = preBase, post.current != pre.current {
                    print("  SIDE EFFECT: color preset changed \(pre.current) -> \(post.current)")
                }
                try? await Task.sleep(nanoseconds: UInt64(hold * 1e9))
            } catch { print("  write failed: \(error)") }
            var ok = true
            do {
                let r = try await controller.write(c, value: base.current, target: t)
                ok = r.verified
                print("  restored \(r.applied), readback \(r.readback.map(String.init) ?? "none") -> \(r.verified ? "VERIFIED" : "UNVERIFIED")")
            } catch { ok = false; print("  RESTORE FAILED: \(error)") }
            if let pre = preBase, let post = try? await controller.read(.colorPreset, target: t), post.current != pre.current {
                let r = try? await controller.write(.colorPreset, value: pre.current, target: t)
                print("  restored color preset -> \(r.map { $0.verified ? "VERIFIED" : "UNVERIFIED" } ?? "FAILED")")
            }
            if !ok { exit(1) }

        case "brightness-test":
            guard args.contains("--yes") else {
                print("Refusing to write without --yes. This changes brightness briefly, then restores it."); exit(2)
            }
            let delta = Int(value(after: "--delta", in: args) ?? "-10") ?? -10
            let hold = Double(value(after: "--hold", in: args) ?? "5") ?? 5
            let t = pickExternal(snap, controller)
            let original = try! await controller.read(.brightness, target: t)
            print("\(tag)baseline brightness \(original.current)/\(original.maximum)")
            let probe = max(0, min(original.maximum, original.current + delta))
            guard probe != original.current, abs(probe - original.current) <= 20 else {
                print("Probe value \(probe) is not a modest change from \(original.current); aborting."); exit(1)
            }
            var restored = false
            do {
                let o = try await controller.write(.brightness, value: probe, target: t)
                print("  wrote \(o.applied) (requested \(o.requested)), readback \(o.readback.map(String.init) ?? "none") -> \(o.verified ? "VERIFIED" : "UNVERIFIED")")
                print("  holding \(hold)s: check the Samsung OSD / panel now ...")
                try? await Task.sleep(nanoseconds: UInt64(hold * 1e9))
            } catch { print("  write failed: \(error)") }
            do {
                let r = try await controller.write(.brightness, value: original.current, target: t)
                restored = r.verified
                print("  restored \(r.applied), readback \(r.readback.map(String.init) ?? "none") -> \(r.verified ? "VERIFIED" : "UNVERIFIED")")
            } catch { print("  RESTORE FAILED: \(error)") }
            if !restored { print("!! Brightness may not be at \(original.current). Check the monitor."); exit(1) }

        default: usage(); exit(2)
        }

        print("--- log ---")
        for e in controller.log.events where e.kind == .ddc {
            print("  \(e.transport?.rawValue ?? "?") \(e.ok == true ? "ok " : "ERR") \(raw ? e.message : Redaction.scrub(e.message, displays: snap.displays))")
        }
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func pickExternal(_ snap: DisplayController.Snapshot, _ c: DisplayController) -> DisplayTarget {
        let ext = snap.displays.filter { !$0.isBuiltIn && $0.hasEndpoint }
        guard ext.count == 1, let d = ext.first, let t = try? c.target(for: d, in: snap) else {
            print("Need exactly one external display with a DDC endpoint; found \(ext.count). Writes require an unambiguous target.")
            exit(1)
        }
        return t
    }

    static func usage() {
        print("usage: ddcprobe (list | read | brightness-test --yes [--delta N] [--hold S]) [--fake] [--raw]")
    }

    static func makeFake() -> FakeTransport {
        let id = DisplayIdentity(vendor: 1, model: 2, serial: 3, alphaSerial: "FAKE0001", productName: "Fake Monitor", manufacturer: "FAK")
        let ext = DisplayDescriptor(uuid: "FAKE-UUID-EXT", edidUUID: nil, displayID: 10, identity: id, isBuiltIn: false, hasEndpoint: true)
        let bi = DisplayIdentity(vendor: 0x610, model: 0xa047, serial: 9, alphaSerial: nil, productName: "Color LCD", manufacturer: nil)
        let int = DisplayDescriptor(uuid: "FAKE-UUID-BUILTIN", edidUUID: nil, displayID: 1, identity: bi, isBuiltIn: true, hasEndpoint: false)
        let f = FakeTransport(displays: [int, ext])
        for c in Control.allCases { f.setValue(ControlValue(current: 50, maximum: 100), c, uuid: ext.uuid) }
        return f
    }
}
