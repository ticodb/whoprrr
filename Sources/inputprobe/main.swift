import Foundation
if CommandLine.arguments.dropFirst().first == "hid" {
    // Round trip with a harmless mapping (F13 -> F14): apply, read back, restore.
    let h = HIDUtil()
    let before = h.current()
    let m = HIDMapping(src: 0x700000068, dst: 0x700000069)
    let ok = h.apply([m]); let during = h.current()
    let back = h.restore(); let after = h.current()
    print("apply", ok, "readback", during == [m], "restore", back, "restored", after == before)
    exit(ok && during == [m] && back && after == before ? 0 : 1)
}
import AppKit
import InputCore

// Live check of the event tap: remaps F13 -> F14 (keys no app uses), posts F13, and watches what arrives downstream.
var seen: [(Int, Bool)] = []
let engine = RemapEngine(rules: [Rule(trigger: .key(105), tap: .chord(Chord(107)))])
let poster = EventPoster()
let runner = EventTapRunner(engine: engine, poster: poster)
print("permissions: AX", AXIsProcessTrusted(), "Input Monitoring", CGPreflightListenEventAccess())
let r = runner.start()
print("start:", r)
guard r == .running else { exit(2) }

// A passive tap at the tail sees what apps would receive.
let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
let watch = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, e, _ in
    let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
    if code == 105 || code == 107 { seen.append((code, type == .keyDown)) }
    return Unmanaged.passUnretained(e)
}, userInfo: nil)
guard let watch else { print("could not create watcher"); exit(2) }
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, watch, 0), .commonModes)
CGEvent.tapEnable(tap: watch, enable: true)

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 105, keyDown: down)?.post(tap: .cghidEventTap) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
    print("downstream saw:", seen, "engine saw \(runner.eventsSeen) events")
    let ok = seen.count == 2 && seen[0] == (107, true) && seen[1] == (107, false)
    print(ok ? "PASS: F13 became F14, original swallowed" : "FAIL")
    runner.stop()
    exit(ok ? 0 : 1)
}
CFRunLoopRun()
