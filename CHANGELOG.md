# Changelog

All notable changes to Whoprrr. Versions follow [Semantic Versioning](https://semver.org); betas are labelled `0.9.0 beta N`.

## 0.9.0 beta 1: first public beta

### Added
- **Recipes**: save your whole setup for a set of gear (display, mic, speakers, Logitech devices) and switch with one click, or let Whoprrr switch automatically when the gear is connected.
- **Presets** on every settings panel.
- **Samsung display**: brightness, contrast and RGB over DDC/CI with verified writes, presets, and camera-assisted matching against the MacBook panel.
- **Windows**: Rectangle-compatible shortcuts, halves/quarters/thirds, cycling, gaps, drag-to-edge snapping, restore, move across displays.
- **Clipboard**: searchable history, pins, snippets, images and files, plain-text paste, per-app ignore list; skips password-manager copies.
- **Keys and mouse**: rule engine with remaps, tap-vs-hold, Hyper, layers, per-app and per-keyboard rules, text and key-sequence outputs (numpad decimal, accents), mouse buttons, Logitech HID++ buttons, system actions (Mission Control and more), Karabiner import, emergency off (⌃⌥⇧⌘⎋).
- **Audio**: system-wide equalizer per output device without a driver (Core Audio process tap), compressor and limiter, Audio Unit plugins on the system output, mic pinning, Bluetooth keep-alive.
- **Microphone**: "Whoprrr Mic" virtual device with gain, high-pass, gate, compressor, equalizer and Audio Unit plugins for every app.
- Mouse back and forward buttons do Back and Forward out of the box, and every button has an Assign menu with everyday actions (navigation, tabs, edit, scrolling, media, system).
- Menu-bar panel for quick actions, main window for setup, About page with diagnostics and acknowledgments.

### Known limits
See [docs/known-issues.md](docs/known-issues.md). Notably: builds are not notarized, VST3 plugins are not hosted, and several features were only exercised on one reference setup.
