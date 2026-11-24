import Foundation
import LogitechCore

// Read-only: lists Logitech HID++ interfaces, asks each paired device its name and which features it supports.
// Sends only IRoot / IFeatureSet / DeviceName queries. Changes nothing on any device.
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

// Diagnostic: `logiprobe --divert <cid hex> <3|5> <seconds>` diverts one control (3 or 5 parameter bytes), prints the
// device's answer and then every report it sends while you press buttons. Releases the control before exiting.
if let i = CommandLine.arguments.firstIndex(of: "--query") {
    let cid = UInt16(CommandLine.arguments.dropFirst(i + 1).first ?? "00D7", radix: 16) ?? 0x00D7
    for ch in LogitechDiscovery.channels() where ch.openChannel() {
        for idx in ([1, 2, 3, 4, 5, 6] as [UInt8]) {
            guard case .message? = ch.transact(device: idx, feature: 0, function: 1, params: [0, 0, 0x5A], timeout: 0.3) else { continue }
            guard case .message(let f)? = ch.transact(device: idx, feature: 0, function: 0, params: [0x1B, 0x04]), f.params[0] != 0 else { continue }
            if case .message(let m)? = ch.transact(device: idx, feature: f.params[0], function: 2, params: [UInt8(cid >> 8), UInt8(cid & 0xFF)]) {
                print(String(format: "device %d cid 0x%04X reporting flags: %@  (bit0 = diverted)", idx, cid, hex(Array(m.params.prefix(5)))))
            }
        }
        ch.close()
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--divert") {
    let args = Array(CommandLine.arguments.dropFirst(i + 1))
    let cids = (args.first ?? "00D7").split(separator: ",").compactMap { UInt16($0, radix: 16) }
    let plen = Int(args.dropFirst().first ?? "5") ?? 5
    let secs = Double(args.dropFirst(2).first ?? "20") ?? 20
    for ch in LogitechDiscovery.channels() where ch.openChannel() {
        let indices: [UInt8] = ch.info.transport.contains("USB") ? [1, 2, 3, 4, 5, 6] : [0xFF]
        for idx in indices {
            guard case .message? = ch.transact(device: idx, feature: 0, function: 1, params: [0, 0, 0x5A], timeout: 0.3) else { continue }
            func feature(_ id: UInt16) -> UInt8? {
                if case .message(let m)? = ch.transact(device: idx, feature: 0, function: 0, params: [UInt8(id >> 8), UInt8(id & 0xFF)]), m.params[0] != 0 { return m.params[0] }
                return nil
            }
            guard let rf = feature(0x1B04) ?? feature(0x1B00) else { continue }
            func params(_ cid: UInt16, _ flags: UInt8) -> [UInt8] { var p: [UInt8] = [UInt8(cid >> 8), UInt8(cid & 0xFF), flags]; if plen == 5 { p += [0, 0] }; return p }
            print("device \(idx) pid 0x\(String(ch.info.productID, radix: 16)) reprog feature index \(rf)")
            for cid in cids {
                print(String(format: "  divert 0x%04X reply:", cid), ch.transact(device: idx, feature: rf, function: 3, params: params(cid, 0x03)).map { "\($0)" } ?? "no answer")
            }
            ch.onReport = { b in print("  report:", hex(b)) }
            print("  listening \(Int(secs)) s: press the button now")
            let end = Date().addingTimeInterval(secs)
            var pinged = false
            while Date() < end {
                CFRunLoopRunInMode(.defaultMode, 0.05, true)
                // Sanity check of the receive path: one ping a second in, whose answer must be printed as a report.
                if !pinged, Date() > end.addingTimeInterval(-secs + 1) { pinged = true; print("  (sending a ping to prove reports are received)"); ch.send(HIDPP.request(device: idx, feature: 0, function: 1, params: [0, 0, 0x5A])) }
            }
            ch.onReport = nil
            for cid in cids { _ = ch.transact(device: idx, feature: rf, function: 3, params: params(cid, 0x02)) }
            print("  released")
        }
        ch.close()
    }
    exit(0)
}

let channels = LogitechDiscovery.channels()
print("HID++ interfaces:", channels.count)
for ch in channels {
    print("\n== \(ch.info.product) pid 0x\(String(ch.info.productID, radix: 16)) \(ch.info.transport) page 0x\(String(ch.info.usagePage, radix: 16)) usage \(ch.info.usage)")
    guard ch.openChannel() else { print("   could not open (permission?)"); continue }
    let indices: [UInt8] = ch.info.transport.contains("USB") ? [1, 2, 3, 4, 5, 6] : [0xFF, 0]
    for idx in indices {
        // IRoot.GetProtocolVersion (feature 0, function 1) doubles as a ping.
        guard case .message(let pong)? = ch.transact(device: idx, feature: 0, function: 1, params: [0, 0, 0x5A]) else { continue }
        print("-- device index \(idx): HID++ \(pong.params[0]).\(pong.params[1])")
        func feature(_ id: UInt16) -> UInt8? {
            if case .message(let m)? = ch.transact(device: idx, feature: 0, function: 0, params: [UInt8(id >> 8), UInt8(id & 0xFF)]), m.params[0] != 0 { return m.params[0] }
            return nil
        }
        if let nameIdx = feature(0x0005), case .message(let c)? = ch.transact(device: idx, feature: nameIdx, function: 0) {
            var name = "", got = 0; let total = Int(c.params[0])
            while got < total, case .message(let part)? = ch.transact(device: idx, feature: nameIdx, function: 1, params: [UInt8(got)]) {
                let chunk = part.params.prefix { $0 != 0 }; if chunk.isEmpty { break }
                name += String(decoding: chunk, as: UTF8.self); got += chunk.count
            }
            print("   name:", name)
        }
        if let fs = feature(0x0001), case .message(let c)? = ch.transact(device: idx, feature: fs, function: 0) {
            let count = Int(c.params[0])
            var list: [String] = []
            for i in 1...max(count, 1) {
                if case .message(let m)? = ch.transact(device: idx, feature: fs, function: 1, params: [UInt8(i)]) {
                    let id = UInt16(m.params[0]) << 8 | UInt16(m.params[1])
                    list.append("[\(i)] \(HIDPP.name(of: id))")
                }
            }
            print("   features(\(count)):", list.joined(separator: ", "))
        }
    }
    ch.close()
}

// Button list for each device (read-only): which controls exist and which can be diverted.
let hub = LogitechHub()
let done = DispatchSemaphore(value: 0)
hub.onDevices = { devices in
    for d in devices {
        print("\n[\(d.name)] HID++ \(d.protocolVersion), \(d.controls.count) controls")
        for c in d.controls { print(String(format: "   cid 0x%04X  %@%@%@", c.cid, c.name.padding(toLength: 30, withPad: " ", startingAt: 0), c.isDivertable ? " divertable" : "", c.isMouse ? " mouse" : "")) }
    }
    done.signal()
}
hub.start()
_ = done.wait(timeout: .now() + 8)
hub.stop()
