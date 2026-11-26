# Changelog

All notable changes to Whoprrr. Versions follow [Semantic Versioning](https://semver.org); betas are labelled `0.9.0 beta N`.

## Unreleased

## 0.9.0 beta 2: gear scan and activation

### Added
- **Gear scan and starter recipe**: first launch looks at the connected screens, audio devices and Logitech gear, labels each as tested, checked, untested or not available, and proposes one recipe to review. Nothing changes before Apply, and one button puts everything back. Also under Recipes, "Scan my gear".
- **Activation**: Whoprrr asks for your key on first launch and keeps a pass for this Mac. It is checked offline at every launch and refreshed by itself about once a week; features stay off without a valid pass. Debug builds can skip the check (`WHOPPER_LICENSE=skip`) or point at a test server.
- **Fit report**: after setup, an optional one-press report of what worked on your gear (models and results only; the text is shown first).

## 0.9.0 beta 1: first public beta

### Added
- **Recipes**: save your whole setup for a set of gear (display, mic, speakers, Logitech devices) and switch with one click, or let Whoprrr switch automatically when the gear is connected.
- **Presets** on every settings panel.
- **External displays**: detects monitors that answer DDC/CI and selects the one you have automatically; brightness, contrast and RGB with verified writes, presets, and camera-assisted matching against the MacBook panel.
- **Windows**: Rectangle-compatible shortcuts, halves/quarters/thirds, cycling, gaps, drag-to-edge snapping, restore, move across displays.
- **Clipboard**: searchable history, pins, snippets, images and files, plain-text paste, per-app ignore list; skips password-manager copies.
- **Keys and mouse**: rule engine with remaps, tap-vs-hold, Hyper, layers, per-app and per-keyboard rules, text and key-sequence outputs (numpad decimal, accents), mouse buttons, Logitech HID++ buttons, system actions (Mission Control and more), Karabiner import, emergency off (⌃⌥⇧⌘⎋).
- **Audio**: system-wide equalizer per output device without a driver (Core Audio process tap), compressor and limiter, Audio Unit plugins on the system output, mic pinning, Bluetooth keep-alive.
- **Microphone**: "Whoprrr Mic" virtual device with gain, high-pass, gate, compressor, equalizer and Audio Unit plugins for every app.
- Every mouse and Logitech button has an Assign menu with everyday actions (navigation, tabs, edit, scrolling, media, system). The mouse's Back and Forward buttons do Back and Forward in every app: Whoprrr presses the app's own Back/Forward menu item, which is the same on every keyboard layout (a Spanish layout has ⌘Ñ and ⌘´ instead of ⌘[ and ⌘]), and only falls back to a key shortcut when an app has no such menu item.
- **Automatic updates** (Sparkle 2): a daily check for a newer version, "Check for Updates…" in the menu-bar panel, and a switch in Features. Updates are verified with an EdDSA signature.
- Menu-bar panel for quick actions, main window for setup, About page with diagnostics and acknowledgments.

### Known limits
See [docs/known-issues.md](docs/known-issues.md). Notably: builds are not notarized, VST3 plugins are not hosted, and several features were only exercised on one reference setup.
