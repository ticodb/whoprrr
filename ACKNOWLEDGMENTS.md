# Acknowledgments

Whoprrr exists because other people built excellent tools and shared how they work. Thank you.

## Code that is included

| Project | What we use | License |
|---|---|---|
| [m1ddc](https://github.com/waydabber/m1ddc) by waydabber | The DDC/CI transport for external displays on Apple Silicon (`Sources/CDDC/upstream`, unmodified). The knowledge of which private macOS calls to use comes from this project. | MIT (full text in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)) |
| [Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/) by Robert Bristow-Johnson | The biquad filter formulas behind the equalizer. Formulas are public; the code is our own. | Public formulas |

## Projects we learned from (no code taken)

These shaped the design. We read their documentation or behaviour and wrote our own code. Where a project is GPL-licensed we did not
copy from it, so that Whoprrr can stay MIT.

- **[Rectangle](https://github.com/rxhanson/Rectangle)** (MIT): the window-snapping vocabulary and default shortcuts. Whoprrr's Windows module is deliberately compatible so Rectangle users feel at home.
- **[Karabiner-Elements](https://github.com/pqrs-org/Karabiner-Elements)** (public domain): the model for remapping (tap vs hold, layers, per-app rules). Whoprrr can import Karabiner rule files.
- **[Solaar](https://github.com/pwr-Solaar/Solaar)** (GPL-2.0): its public documentation of the Logitech HID++ 2.0 protocol (feature IDs, framing, button diversion). Read, not copied.
- **[eqMac](https://github.com/bitgapp/eqMac)**: proof that a system-wide equalizer is something Mac users want, and a list of the ways such a tool can be fragile.
- **[Vorssaint](https://github.com/vorssaint/vorssaint-utils)** (GPL-3.0): its public source confirmed that Core Audio process taps, HAL property listeners and `hidutil` plus an event tap are the approaches that work in practice. Studied, not copied.
- **[BlackHole](https://github.com/ExistentialAudio/BlackHole)** (GPL-3.0): the reference virtual audio driver. Whoprrr Mic is a separate implementation written from Apple's documentation.
- **Apple's documentation and sample code** for Core Audio, `AudioServerPlugIn`, Audio Units, `CGEventTap`, the Accessibility API and `IOHIDManager`.

## Made with

Swift, SwiftUI, AVFoundation, Core Audio, IOKit and the system SQLite library. Interface icons are SF Symbols; type is SF Pro; both come
from macOS and are not bundled.

## Trademarks

All product and company names are trademarks of their respective owners. Whoprrr is an independent project and is not affiliated with,
endorsed by or sponsored by Apple, Samsung, Logitech, RØDE, or the authors of the projects named above.

## Missing someone?

If your work influenced Whoprrr and is not credited here, please open an issue. We will fix it.
