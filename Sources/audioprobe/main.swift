import Foundation
setvbuf(stdout, nil, _IONBF, 0)
import AudioCore

// Read-mostly probe for the audio module. Usage:
//   audioprobe list
//   audioprobe keepalive <uid-or-name-substring> [--db -60] [--hz 40] [--pulse 0] [--seconds 10]
let args = CommandLine.arguments.dropFirst()
let system = CoreAudioSystem.shared

func flag(_ n: String, _ d: Double) -> Double {
    if let i = args.firstIndex(of: n), let v = args.dropFirst(args.distance(from: args.startIndex, to: i) + 1).first, let x = Double(v) { return x }
    return d
}

switch args.first {
case "plugins":
    // audioprobe plugins [name-substring]: loads each matching effect Audio Unit in a PluginRack, pushes a sine through it, reports.
    let filter = args.dropFirst().first?.lowercased()
    for info in PluginCatalog.effects() where filter == nil || info.name.lowercased().contains(filter!) {
        let rack = PluginRack(); let slot = info.makeSlot()
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = "timeout"
        rack.onStatus = { st in switch st[slot.id] { case .ready?: result = "ready"; sem.signal(); case .failed(let e)?: result = "FAILED \(e)"; sem.signal(); default: break } }
        rack.apply(slots: [slot], sampleRate: 48000)
        _ = sem.wait(timeout: .now() + 12)
        if result == "ready" {
            // Run 60 blocks of 512 (about 0.6 s) so latency and start-up silence pass; report the last block.
            var lastPeak: Float = 0
            for b in 0..<60 {
                var l = (0..<512).map { 0.3 * Float(sin(2 * Double.pi * 440 * Double(b * 512 + $0) / 48000)) }, r = l
                l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in rack.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: 512) } }
                lastPeak = l.map { abs($0) }.max() ?? 0
                Thread.sleep(forTimeInterval: 0.008)
            }
            result += " peak \(String(format: "%.3f", lastPeak))"
        }
        rack.clear(); Thread.sleep(forTimeInterval: 0.2)
        print("\(info.manufacturer) / \(info.name): \(result)")
    }
    exit(0)
case "list":
    let din = system.defaultInputUID(), dout = system.defaultOutputUID()
    for d in system.devices() {
        let role = [d.hasInput ? "in\(d.inputChannels)" : nil, d.hasOutput ? "out\(d.outputChannels)" : nil].compactMap { $0 }.joined(separator: "/")
        let def = [d.uid == din ? "DEFAULT-IN" : nil, d.uid == dout ? "DEFAULT-OUT" : nil].compactMap { $0 }.joined(separator: " ")
        print("\(d.name)\t\(d.transport.rawValue)\t\(role)\t\(def)\t\(d.uid)")
    }
case "keepalive":
    guard let q = args.dropFirst().first,
          let dev = system.devices().filter(\.hasOutput).first(where: { $0.uid == q || $0.name.localizedCaseInsensitiveContains(q) }) else {
        print("no matching output device"); exit(1)
    }
    let s = KeepAliveSettings(enabled: true, levelDB: flag("--db", -60), frequencyHz: flag("--hz", 40), pulseEverySeconds: flag("--pulse", 0))
    let engine = KeepAliveEngine(system: system)
    engine.onStatus = { print("status:", $0) }
    engine.apply([dev.uid: s])
    let secs = flag("--seconds", 10)
    print("feeding \(dev.name) at \(s.clamped.levelDB) dBFS / \(s.clamped.frequencyHz) Hz for \(secs)s")
    Thread.sleep(forTimeInterval: secs)
    print("IOProc callbacks:", engine.callbackCount(uid: dev.uid))
    engine.stop()
case "tap":
    // Unmuted, silent: proves the tap works. Play something while it runs, e.g. `afplay /System/Library/Sounds/Ping.aiff`.
    guard let q = args.dropFirst().first,
          let dev = system.devices().filter(\.hasOutput).first(where: { $0.uid == q || $0.name.localizedCaseInsensitiveContains(q) }) else { print("no matching output"); exit(1) }
    print("tapping system audio via \(dev.name) for \(flag("--seconds", 4))s ...")
    let r = TapProbe.peak(onDeviceUID: dev.uid, seconds: flag("--seconds", 4))
    print("peak:", r.peak, r.error ?? "")
case "setinput":
    guard let q = args.dropFirst().first,
          let dev = system.devices().filter(\.hasInput).first(where: { $0.uid == q || $0.name.localizedCaseInsensitiveContains(q) }) else { print("no matching input"); exit(1) }
    print(system.setDefaultInput(uid: dev.uid) ? "default input -> \(dev.name)" : "failed")
case "pin":
    guard let q = args.dropFirst().first,
          let dev = system.devices().filter(\.hasInput).first(where: { $0.uid == q || $0.name.localizedCaseInsensitiveContains(q) }) else { print("no matching input"); exit(1) }
    let pinner = InputPinner(system: system)
    pinner.onStatus = { print("status:", $0) }
    pinner.start(policy: InputPinPolicy(enabled: true, preferredUIDs: [dev.uid]))
    Thread.sleep(forTimeInterval: flag("--seconds", 10))
    pinner.stop()
default:
    print("usage: audioprobe setinput <device> | pin <device> [--seconds 10] | audioprobe list | keepalive <device> [--db -60] [--hz 40] [--pulse 0] [--seconds 10]")
}
