# Known issues (beta)

## Distribution
- Builds are **not notarized**. macOS blocks the first launch (see [install.md](install.md)). They are ad-hoc signed, so macOS asks for permissions again after each update.
- No automatic updates yet. Watch the Releases page.

## Keys and mouse
- Keys typed into password fields and at the login window cannot be remapped (macOS rule).
- Rules can be limited to a keyboard layout class (ANSI, ISO, JIS) or to a keyboard type learned from a key press. Two keyboards that report the same type cannot be told apart.
- Logitech: buttons are named for the controls whose IDs are well established; others show their hex ID. Use **Learn a button**.
- Shortcuts sent by actions such as Back and Forward depend on the keyboard layout: ⌘[ and ⌘] where the layout types those keys directly, ⌘← and ⌘→ otherwise (Spanish layouts). Apps that only accept ⌘[ may ignore the fallback.
- Quit Logi Options+ and Karabiner-Elements when you use the same buttons or keys in Whoprrr.

## Audio
- The system equalizer and effects refuse virtual output devices. DRM-protected playback may arrive silent in the process tap.
- **VST and VST3 plugins are not supported**, only Audio Units. A plugin with no Audio Unit version will not appear.
- Plugins that only support mono or surround are not supported. About 15% of tested plugins need **Run inside Whoprrr** (the app then shares their risk of crashing).
- Plugin editor windows have had little real-world use; report rendering problems.
- Whoprrr Mic is tested on one Mac. An unsigned audio driver may not load on every macOS setup.

## Display
- Verified on one display model. Other monitors may ignore DDC/CI or behave differently. The write allowlist and read-back verification limit what can go wrong, but please test carefully.

## Recipes
- Gear is matched by device identifiers, polled every few seconds. After plugging in gear, automatic switching can take up to a few seconds.
- A recipe stores settings, not Whoprrr's runtime state; permissions and drivers are never part of a recipe.

## General
- English only. Light and dark mode follow the system.
- Intel Macs are untested.
