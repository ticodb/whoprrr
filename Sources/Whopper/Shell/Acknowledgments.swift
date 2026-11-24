import Foundation

/// Everyone whose work Whoprrr includes or learned from. Keep in step with ACKNOWLEDGMENTS.md.
struct Acknowledgment: Identifiable {
    enum Kind: String, CaseIterable { case included = "Included in Whoprrr", inspired = "Inspired by (no code used)", tooling = "Built on" }
    var id: String { name }
    let name: String
    let what: String
    let license: String
    let url: String
    let kind: Kind
}

enum Acknowledgments {
    static let all: [Acknowledgment] = [
        Acknowledgment(name: "m1ddc by waydabber", what: "The DDC/CI transport for Apple Silicon displays, vendored unmodified in Sources/CDDC/upstream.", license: "MIT", url: "https://github.com/waydabber/m1ddc", kind: .included),
        Acknowledgment(name: "Rectangle", what: "The window-snapping shortcuts and behaviours Whoprrr's Windows module follows, so Rectangle users feel at home.", license: "MIT", url: "https://github.com/rxhanson/Rectangle", kind: .inspired),
        Acknowledgment(name: "Karabiner-Elements", what: "The model for key remapping (tap vs hold, layers, per-app rules). Whoprrr imports Karabiner rule files.", license: "Public domain (Unlicense)", url: "https://github.com/pqrs-org/Karabiner-Elements", kind: .inspired),
        Acknowledgment(name: "Solaar", what: "Its public documentation of the Logitech HID++ 2.0 protocol was read to write Whoprrr's own implementation. No code was copied.", license: "GPL-2.0", url: "https://github.com/pwr-Solaar/Solaar", kind: .inspired),
        Acknowledgment(name: "eqMac", what: "Showed how much people want a system-wide equalizer on the Mac.", license: "see project", url: "https://github.com/bitgapp/eqMac", kind: .inspired),
        Acknowledgment(name: "Vorssaint", what: "Its public source confirmed which Core Audio and event-tap approaches work in practice. No code was copied.", license: "GPL-3.0", url: "https://github.com/vorssaint/vorssaint-utils", kind: .inspired),
        Acknowledgment(name: "Audio EQ Cookbook", what: "Robert Bristow-Johnson's biquad filter formulas, used for the equalizer.", license: "Public formulas", url: "https://www.w3.org/TR/audio-eq-cookbook/", kind: .included),
        Acknowledgment(name: "Apple Core Audio, AudioServerPlugIn and Audio Unit documentation", what: "The contracts behind the process-tap equalizer, the Whoprrr Mic driver and plugin hosting.", license: "Apple documentation", url: "https://developer.apple.com/documentation/coreaudio", kind: .tooling),
        Acknowledgment(name: "SF Symbols and SF Pro", what: "Interface icons and type come from macOS itself; nothing is bundled.", license: "Apple", url: "https://developer.apple.com/sf-symbols/", kind: .tooling),
    ]
}
