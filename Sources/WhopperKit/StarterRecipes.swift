import Foundation

/// One thing a starter recipe would set up. The app turns the action into real settings; nothing here touches the Mac.
public enum StarterAction: Equatable, Sendable {
    /// Window layouts to show in the menu-bar drawer (raw values of `WindowAction`).
    case windowLayouts([String])
    /// Keep the external-display feature on.
    case displayControl
    /// Apply the system equalizer to the current output.
    case outputEQ
    /// Stop a Bluetooth speaker from powering off between sounds.
    case keepAwake(uid: String)
    /// Keep this device as the system microphone.
    case pinInput(uid: String)
    /// Use this device as the source of the Whoprrr Mic.
    case micSource(uid: String)
    /// A built-in key or mouse preset (`InputPresets` id).
    case inputPreset(String)
    /// Clipboard history on.
    case clipboard
}

public struct StarterLine: Identifiable, Equatable, Sendable {
    public var id: String
    public var feature: Feature
    public var detail: String
    public var fit: Fit
    /// Whether the line starts switched on. Opinionated changes start off.
    public var on: Bool
    public var action: StarterAction
}

/// A device as shown in "Found on this Mac".
public struct GearNote: Identifiable, Equatable, Sendable {
    public var id: String
    public var symbol: String
    public var name: String
    public var detail: String
    public var fit: Fit
}

public struct StarterPlan: Equatable, Sendable {
    public var name: String
    public var symbol: String
    public var gear: [GearNote]
    public var lines: [StarterLine]
    /// Features that do not fit this setup, with the reason in plain words.
    public var off: [Off]

    public struct Off: Identifiable, Equatable, Sendable {
        public var feature: Feature
        public var reason: String
        public var id: String { feature.rawValue }
    }
}

/// The rules that turn a gear scan into a proposed recipe. Each rule reads a trait of the gear (screen shape, connection type),
/// never a specific model, so unknown gear still gets a sensible proposal.
public enum StarterRecipes {
    public static func plan(for scan: GearScan, firstSetup: Bool = false) -> StarterPlan {
        var lines: [StarterLine] = []
        var off: [StarterPlan.Off] = []
        var gear: [GearNote] = []
        let externals = scan.externals

        // Windows: layouts follow the shape of the widest screen.
        let widest = externals.max { $0.aspect < $1.aspect }
        var layouts: [String]
        var windowsText: String
        if let w = widest, w.isUltrawide {
            layouts = ["leftHalf", "rightHalf", "firstThird", "centerThird", "lastThird", "firstTwoThirds", "lastTwoThirds", "center", "maximize", "restore"]
            windowsText = "Thirds and two-thirds for the ultrawide, plus halves"
        } else if widest != nil {
            layouts = ["leftHalf", "rightHalf", "topLeft", "topRight", "bottomLeft", "bottomRight", "maximize", "center", "restore"]
            windowsText = "Halves and quarters"
        } else {
            layouts = ["leftHalf", "rightHalf", "maximize", "center", "restore"]
            windowsText = "Halves and maximize for the laptop screen"
        }
        if scan.screens.count >= 2 {
            layouts.append("nextDisplay")
            if scan.screens.count >= 3 { layouts.append("previousDisplay") }
            windowsText += ", and a shortcut to send a window to the other display"
        }
        lines.append(StarterLine(id: "windows.layouts", feature: .windows, detail: windowsText, fit: .tested, on: true, action: .windowLayouts(layouts)))

        // External displays.
        for (i, s) in externals.enumerated() {
            let size = "\(s.width)×\(s.height)"
            let (detail, fit): (String, Fit) = {
                if !scan.mac.appleSilicon { return ("\(size) · display control needs an Apple Silicon Mac", .unavailable) }
                switch s.answers {
                case true?: return ("\(size) · answers display control", KnownGear.isTested(s.name) ? .tested : .checked)
                case false?: return ("\(size) · does not answer display control on this connection", .unavailable)
                case nil: return ("\(size) · has not answered yet", .untested)
                }
            }()
            gear.append(GearNote(id: "screen.\(i)", symbol: "display", name: s.name, detail: detail, fit: fit))
        }
        if externals.isEmpty {
            off.append(.init(feature: .display, reason: "No external display is connected."))
        } else if !scan.mac.appleSilicon {
            off.append(.init(feature: .display, reason: "Display control needs an Apple Silicon Mac."))
        } else if let s = externals.first(where: { $0.answers == true }) {
            let tested = KnownGear.isTested(s.name)
            lines.append(StarterLine(id: "display.control", feature: .display,
                                     detail: tested ? "Brightness, contrast and color on the \(s.name)"
                                                    : "The \(s.name) answered. The controls it supports appear on the External displays page",
                                     fit: tested ? .tested : .checked, on: true, action: .displayControl))
        } else if externals.contains(where: { $0.answers == nil }) {
            lines.append(StarterLine(id: "display.control", feature: .display, detail: "The display has not answered yet. Left on so you can try it",
                                     fit: .untested, on: true, action: .displayControl))
        } else {
            off.append(.init(feature: .display, reason: "\(externals[0].name) does not answer display control on this connection."))
        }

        // Audio and microphone.
        let external = scan.audio.filter { $0.transport != "builtIn" }
        for a in external {
            let isMic = a.hasInput && (!a.hasOutput || a.name.localizedCaseInsensitiveContains("mic"))
            let what = isMic ? "microphone" : a.hasInput ? "headset" : "speakers or headphones"
            // A monitor's own speakers share the monitor's name; "tested" is about the display, not them.
            let viaDisplay = a.transport == "displayPort" || a.transport == "hdmi"
            gear.append(GearNote(id: "audio.\(a.uid)", symbol: isMic ? "mic" : "speaker.wave.2", name: a.name,
                                 detail: "\(transportName(a.transport)) \(what)", fit: KnownGear.isTested(a.name) && !viaDisplay ? .tested : .untested))
        }
        if firstSetup, scan.audio.contains(where: \.hasOutput) {
            lines.append(.init(id: "audio.eq", feature: .audio, detail: "Equalizer for the current speakers", fit: .tested, on: true, action: .outputEQ))
        }
        for a in external where a.transport == "bluetooth" && a.hasOutput && !a.hasInput {
            lines.append(StarterLine(id: "audio.keepAwake.\(a.uid)", feature: .audio, detail: "Keep \(a.name) awake so it does not power off between sounds",
                                     fit: KnownGear.isTested(a.name) ? .tested : .untested, on: true, action: .keepAwake(uid: a.uid)))
        }
        // A USB webcam also has a microphone. Prefer gear we know, then anything that calls itself a microphone.
        func micRank(_ a: GearScan.Audio) -> Int { KnownGear.isTested(a.name) ? 2 : a.name.localizedCaseInsensitiveContains("mic") ? 1 : 0 }
        let usbMic = external.filter { $0.transport == "usb" && $0.hasInput }.enumerated().max { (micRank($0.element), -$0.offset) < (micRank($1.element), -$1.offset) }?.element
        if let m = usbMic {
            let fit: Fit = KnownGear.isTested(m.name) ? .tested : .untested
            lines.append(StarterLine(id: "audio.pin", feature: .audio, detail: "Keep \(m.name) as the microphone in every app", fit: fit, on: true, action: .pinInput(uid: m.uid)))
            lines.append(StarterLine(id: "mic.source", feature: .microphone,
                                     detail: firstSetup ? "Use \(m.name) with the Whoprrr Mic"
                                         : "Use \(m.name) as the source for the Whoprrr Mic. Install the virtual mic on the Microphone page to add effects",
                                     fit: fit, on: !firstSetup, action: .micSource(uid: m.uid)))
        } else {
            off.append(.init(feature: .microphone, reason: "No external microphone found."))
            if let headset = external.first(where: { $0.transport == "bluetooth" && $0.hasInput && $0.hasOutput }),
               let builtIn = scan.audio.first(where: { $0.transport == "builtIn" && $0.hasInput }) {
                lines.append(StarterLine(id: "audio.pin", feature: .audio,
                                         detail: "Keep the Mac’s own microphone as the input when \(headset.name) connects, so its sound stays in high quality",
                                         fit: .untested, on: true, action: .pinInput(uid: builtIn.uid)))
            }
        }

        // Keys and mouse.
        for (i, name) in scan.logitech.enumerated() {
            gear.append(GearNote(id: "logi.\(i)", symbol: "computermouse", name: name, detail: "Logitech device", fit: KnownGear.isTested(name) ? .tested : .untested))
        }
        if !scan.logitech.isEmpty {
            let tested = scan.logitech.contains(where: KnownGear.isTested)
            lines.append(StarterLine(id: "input.backForward", feature: .remap, detail: "Mouse side buttons go back and forward in browsers and Finder",
                                     fit: tested ? .tested : .untested, on: true, action: .inputPreset("mouse-back-forward")))
        }
        lines.append(StarterLine(id: "input.capsHyper", feature: .remap, detail: "Caps Lock: Escape on a tap, Hyper (⌃⌥⇧⌘) while held",
                                 fit: .tested, on: false, action: .inputPreset("caps-hyper")))

        lines.append(StarterLine(id: "clipboard.history", feature: .clipboard, detail: "Clipboard history with search, pins and plain-text paste",
                                 fit: .tested, on: !firstSetup, action: .clipboard))

        let desk = !externals.isEmpty || usbMic != nil
        return StarterPlan(name: desk ? "Desk" : "On the road", symbol: desk ? "house" : "laptopcomputer", gear: gear, lines: lines, off: off)
    }

    static func transportName(_ t: String) -> String {
        switch t {
        case "usb": "USB"
        case "bluetooth": "Bluetooth"
        case "hdmi": "HDMI"
        case "displayPort": "DisplayPort"
        case "airplay": "AirPlay"
        default: "External"
        }
    }

    /// A name no existing recipe uses: "Desk", then "Desk 2", "Desk 3".
    public static func uniqueName(_ base: String, existing: [String]) -> String {
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

/// What the user can choose to send after setup: models and results only. Built here so tests can hold it to that.
public enum FitReport {
    public static func payload(app: String, scan: GearScan, plan: StarterPlan, accepted: Set<String>) -> [String: Any] {
        [
            "kind": "mac",
            "app": app,
            "mac": ["model": scan.mac.model, "chip": scan.mac.appleSilicon ? "arm64" : "x86_64", "os": scan.mac.os],
            "gear": plan.gear.map { ["name": KnownGear.publicName($0.name), "detail": $0.detail, "fit": $0.fit.rawValue] },
            "lines": plan.lines.map { ["id": publicID($0.id), "fit": $0.fit.rawValue, "on": accepted.contains($0.id)] as [String: Any] },
            "off": plan.off.map { ["feature": $0.feature.rawValue] },
        ]
    }

    public static func json(app: String, scan: GearScan, plan: StarterPlan, accepted: Set<String>) -> Data {
        (try? JSONSerialization.data(withJSONObject: payload(app: app, scan: scan, plan: plan, accepted: accepted), options: [.sortedKeys])) ?? Data()
    }

    /// The same content as readable text, shown to the user before anything is sent.
    public static func text(app: String, scan: GearScan, plan: StarterPlan, accepted: Set<String>) -> String {
        var out = ["Whoprrr \(app) · \(scan.mac.model) · \(scan.mac.appleSilicon ? "Apple Silicon" : "Intel") · macOS \(scan.mac.os)"]
        out += plan.gear.map { "\(KnownGear.publicName($0.name)): \($0.detail) (\($0.fit.rawValue))" }
        out += plan.lines.map { "\(publicID($0.id)): \(accepted.contains($0.id) ? "on" : "off") (\($0.fit.rawValue))" }
        out += plan.off.map { "\($0.feature.rawValue): not on this setup" }
        return out.joined(separator: "\n")
    }

    /// Line ids can end in a device identifier ("audio.keepAwake.<uid>"); only the rule name leaves the Mac.
    static func publicID(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".") }
}
