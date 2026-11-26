# Known issues (beta)

## Distribution
- Builds are **not notarized**. macOS blocks the first launch (see [install.md](install.md)). They are ad-hoc signed, so macOS asks for permissions again after each update.
- Automatic updates (Sparkle) are built in, but because builds are ad-hoc signed, **each update changes the app's code signature and macOS may drop its privacy grants** (Accessibility, Input Monitoring, Microphone, Camera, Audio capture). After an update, open Whoprrr's Permissions page and grant again if a feature stops working. Developer ID signing (see [releasing.md](releasing.md)) keeps the grants across updates.
- Whoprrr checks `https://whoprrr.app/mac/appcast.xml` once a day. Turn it off in Features > "Check for updates automatically", or use "Check for Updates…" in the menu-bar panel.

## Keys and mouse
- Keys typed into password fields and at the login window cannot be remapped (macOS rule).
- Rules can be limited to a keyboard layout class (ANSI, ISO, JIS) or to a keyboard type learned from a key press. Two keyboards that report the same type cannot be told apart.
- Logitech: buttons are named for the controls whose IDs are well established; others show their hex ID. Use **Learn a button**.
- Back, Forward, previous/next tab: Whoprrr presses the frontmost app's own menu item for that shortcut (needs Accessibility). If the app has no such item it sends a key shortcut instead, which depends on the keyboard layout and may not work in every app. Safari ignores the mouse's native side buttons, so Whoprrr's default Back/Forward rules matter there.
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
