# Whoprrr: internal roadmap and decision log

> Developer notes written while building the app. Kept for context; the user-facing docs are in `docs/` and the README.

One menu-bar app that replaces eqMac, Rectangle, Logi Options+ and Karabiner, and absorbs Samsung Display Control.
Name: **Whoprrr** (renamed from Whopper 2026-11-24; still a riff on a Burger King trademark, so rename before any public release). The Swift modules, bundle id (`gg.tico.whopper`) and data folder keep the old name on purpose, so grants and data survive. Brand manual: `docs/brand/brand-manual.html`.

## What the reference machine had (read-only check, 2026-11-23)
- Audio: RØDE PodMic USB is the current default input. Default output is the eqMac virtual device ("MacBook Air Speakers (eqMac)"). HAL drivers installed: eqMac, RodeConnect, ParrotAudioPlugin.
- Input: Karabiner DriverKit virtual keyboard is active; Logitech mouse is on a "USB Receiver".
- Apps to retire later: eqMac, Rectangle, Karabiner-Elements, Logi Options+. RØDE Connect keeps running; it is not on the replace list. "Voirssant" = Vorssaint (github.com/vorssaint/vorssaint-utils), studied below.

## Architecture
One Swift package, one menu-bar agent, one module per feature. Each module is a library with a fake backend so it can be tested without hardware (the pattern `DisplayCore` already uses).

| Module | Job | Core API |
|---|---|---|
| DisplayCore (exists) | Samsung DDC/CI brightness, presets, matcher | IOAVService (private) |
| WindowCore | Snap, halves/thirds/quarters, move across displays, drag-to-edge | Accessibility (AXUIElement), global hotkeys, event tap for drag |
| AudioCore | EQ, per-device profiles, routing, input pinning, BT keep-alive | Core Audio HAL, process taps, AudioUnits |
| ClipboardCore | History, search, pins, snippets, paste stack | NSPasteboard polling, SQLite (FTS5) |
| InputCore | Key + mouse remap, layers, per-app rules, Logitech buttons | CGEventTap, `hidutil`, HID++ over IOHIDManager |
| App shell | Menu bar, settings, permissions onboarding, login item | SwiftUI, SMAppService |

Two process rules, learned from eqMac being flaky:
1. The audio engine and the input tap each run on their own real-time / dedicated thread, never on the main thread. Prefer a bundled LaunchAgent helper for audio so a UI crash cannot cut your sound.
2. Every rule the user can create is data (JSON), applied by a small engine. No scripting language; that is where Voirssant-style complexity comes from.

## Hard truths per feature
**Window management.** Easy. Rectangle is MIT; reuse its geometry ideas, write our own code. Needs Accessibility.

**Clipboard.** Easy to build, hard to make "kickass". Needs: ignore concealed/transient pasteboard types (password managers), image + file + rich text, plain-text paste, paste by synthesized Cmd-V, instant panel on a hotkey. Verify how this macOS version gates programmatic pasteboard reads (Paste from Other Apps privacy prompt).

**Key and mouse remap.**
- `CGEventTap` covers most remaps, tap-vs-hold, layers, per-app rules. It does **not** see events in secure-input fields (password boxes) or at the login window.
- `hidutil` covers simple key-to-key swaps at HID level, including those cases, with no permission. Use it for Caps Lock and modifier swaps.
- Karabiner's DriverKit virtual keyboard needs an Apple DriverKit entitlement we cannot get casually. Plan: do not depend on it. Accept the secure-input limit, or keep Karabiner only for that if it ever bites.
- Logitech extra buttons, gesture button, thumb wheel, SmartShift, DPI are **not** normal mouse events. Logi Options+ diverts them over HID++ 2.0. We must speak HID++ ourselves via IOHIDManager (feature 0x1B04 for button diversion). Protocol is documented by Solaar (GPL: read, do not copy). Needs the exact mouse model to scope; this is the riskiest input item.
- Needs Accessibility + Input Monitoring. An event tap that stalls gets disabled by macOS, so the callback must do almost nothing.

**Audio: the hard part.**
- *Output EQ without a driver.* Use Core Audio process taps (macOS 14.2+): tap the system mix, mute the original, render through our EQ to the real device inside a private aggregate device with drift correction. This removes the virtual output device that makes eqMac fragile. Unknown until tested: behaviour on device switches, and whether protected (DRM) audio comes through the tap.
- *Per-device EQ.* Profiles keyed by device UID, swapped when the active output changes. Straightforward once the chain exists.
- *Mic always PodMic.* Two layers. (a) Pin: listen for default-input changes and set it back to the PodMic immediately. This also stops Bluetooth headsets from hijacking input and dropping to low-quality call audio. (b) Apps that choose their own device ignore the default. Only a **virtual mic** fixes that: a stable device named e.g. "Mic" that always carries the PodMic. It is also the only way to run input effects (EQ, gate, compressor) inside every app.
- *Virtual mic needs an AudioServerPlugIn driver* in `/Library/Audio/Plug-Ins/HAL`, installed with admin rights, loaded by coreaudiod. It must be properly signed; check whether ad-hoc is accepted on this OS before committing. Base on Apple's sample, not BlackHole (GPL-3.0 blocks selling it later). RØDE Connect also installs virtual devices; we must coexist with them.
- *Bluetooth keep-alive.* Hold an output stream open to the speaker and feed it an inaudible signal so the speaker never sees "no audio". The right level, frequency and interval depend on each speaker's auto-off logic. Build a probe tool, tune per device, then ship defaults. Not guaranteed until measured on your speakers.

## Phases (ordered by value over risk)
0. **Foundation (1-2 sessions).** Split the app into modules, add the shell + permissions onboarding, move Samsung control in as a module. **Stable code-signing identity**: the current ad-hoc signature makes macOS forget Accessibility/Input/Audio grants on every rebuild, which would make this project miserable.
1. **Quick wins.** WindowCore (replace Rectangle). Audio input pinning + BT keep-alive probe (no driver needed, fixes your two biggest annoyances immediately).
2. **Clipboard manager.**
3. **Keyboard remap** (`hidutil` + event tap), then **Logitech HID++** once the model is known.
4. **Output EQ via process tap**, per-device profiles. Retire eqMac when stable for a week.
5. **Virtual mic driver + input effects.** Last because it is the riskiest and the only piece with a system-level install.

Retire each old app only after its replacement has run for a week without a fallback to it.

## Lessons from Vorssaint (read 2026-11-24, `vorssaint/vorssaint-utils`)
Large (about 1,100 files), Swift, macOS 14+, Developer-ID signed. **GPL-3.0-or-later** with a separate trademark: we study the approach and write our own code. Copying code would force our app to be GPL and block ever selling it.

What it confirms (so these are proven, not guesses):
- **Driverless audio works.** Its per-app mixer uses Core Audio process taps (`mutedWhenTapped`) plus a private aggregate device whose main sub-device is the real output. It needs macOS 14.4+ and the "System Audio Recording" permission (`NSAudioCaptureUsageDescription`). Our output EQ uses the same mechanism with a *global* tap excluding our own process.
- **Input pinning is just HAL listeners** on default-input and device-list changes, with every HAL call kept off the main thread (a device being reconfigured can block a read). It also handles "preferred device unavailable" and avoids fighting its own priority list.
- **Remap = `hidutil` mapping + `CGEventTap`.** Super key maps Caps Lock to F18 with `hidutil`, then the tap adds modifiers. It always removes the mapping on quit, so a crash never leaves a dead key. We copy that safety rule.
- **Clipboard polls `changeCount`** every 0.8 s with tolerance, stores JSON, honours ignored apps and retention, and can skip its own writes.
- **Mouse side buttons use `otherMouse*` taps.** No HID++ anywhere: it cannot see Logitech's diverted buttons.
- **UX worth taking:** a feature hub where unused features are uninstalled and stop loading, presets, and a Permissions page that says which feature needs which grant and flags grants nothing uses any more.

What it does **not** do, which is our reason to exist: EQ, input effects / virtual mic, Bluetooth keep-alive (its Bluetooth feature switches Bluetooth *off* on sleep, the opposite), per-device EQ profiles, HID++, and your Samsung DDC + camera matching. Its Developer-ID signing is why "permissions survive updates"; see signing below.

## Reference devices: MX Keys and MX Ergo
- **MX Keys:** ordinary HID keyboard. Remaps, layers and the F-row work through `hidutil` + event tap. Backlight and Easy-Switch are firmware, nothing to do.
- **MX Ergo (trackball):** left/right/middle, back/forward and wheel arrive as normal events. The **precision-mode button** and DPI/ball-speed settings are Logitech-specific and need HID++; until then the precision button is simply unmapped. That makes HID++ a small, optional, late task (one device, a handful of controls) rather than a general port of Options+.
- Both may sit behind the same "USB Receiver" or Bluetooth. HID++ discovery must handle both.

## Signing without a paid account
- Ad-hoc signing (`codesign --sign -`) gives a new identity per build, so macOS drops Accessibility / Input Monitoring / audio grants every rebuild. Fix in Phase 0: create a stable local signing identity (a self-signed "Code Signing" certificate in the login keychain, or a free Apple Development certificate from Xcode with a free Apple ID) and sign every build with it. Verify grants survive a rebuild before moving on.
- Phases 1 to 5 need nothing paid. The **virtual mic driver (Phase 6)** is the one place a paid Developer ID may matter: coreaudiod's acceptance of a locally signed HAL plug-in must be tested on this macOS first. Decide on the $99/year account then, not now.

## Status (2026-11-24)
All modules are built, unit-tested and wired into the app (Features hub, Permissions page, per-module panels):
display, windows, clipboard, keys and mouse (+ Logitech HID++), audio (EQ, pinning, keep-alive), microphone (virtual mic + effects).
The app is installed at `/Applications/Whopper.app`, signed with the stable local identity (`gg.tico.whopper`).

Verified live on this Mac: window actions through the real Accessibility API; mic pinning restoring the PodMic; keep-alive feeding a device;
clipboard capture, concealed-copy skip and write-back; `hidutil` apply/readback/restore; HID++ enumeration of the MX Keys S (21 controls);
the virtual-mic driver against a simulated coreaudiod host (28 checks). Not verifiable without the user's grants/install:
real key events through the tap (needs Input Monitoring for Whopper.app), the system-audio tap and EQ (needs System Audio Recording),
the installed Whopper Mic (needs the administrator install), the MX Ergo (asleep / on another host when probed).

## Update 2026-11-24: brand, UI, transforms
- **Identity:** burger icon (M2 margin, 12 chunky RGB subpixel columns, 15-bar waveform patty), one-colour menu-bar glyph, tokens, manual (`docs/brand/`). Artwork is SwiftUI (`Brand.swift`, `MenuBarIcon.swift`); `WHOPPER_RENDER_ICON=<dir>` renders the iconset/icns/PNGs; `Resources/AppIcon.icns` is what the build embeds. `scripts/brand/gen_manual.py` regenerates the manual and SVGs.
- **UI:** new shell (logo header, status chip, nav pills, scrolling content, footer), brand components, "Open in window" (600 pt). App is `Whoprrr.app`.
- **Transforms (InputCore):** new outputs `Output.text` (types a literal string, layout- and locale-proof) and `Output.sequence` (combos in order, e.g. dead-key accents). Rules can be limited to a keyboard layout class (ANSI/ISO/JIS, via `KBGetLayoutType`) or to a raw keyboard type number learned from a key press. New presets: numpad decimal always ".", Spanish accents on ANSI keyboards, comma adds a space.
- **Karabiner import:** `KarabinerImport` converts karabiner.json or rule files (basic manipulators, sequences, to_if_alone / to_if_held_down, simple modifications incl. per-device, app and keyboard-type conditions). Device-specific rules (vendor/product ID) become "ANSI keyboards only"; unsupported rules are skipped and listed.
- **Logitech:** the hub was never started by the app (syncLogitech was not called); fixed. MX Ergo seen awake: 9 controls, `0x00D7` is the DPI / precision button (divertable). New "Learn a button" (press the mouse button to pick it) and an Assign menu per button (Clipboard history, window actions, other).
- **Honest limit:** two ANSI keyboards that report the same raw keyboard type cannot be told apart by an event tap. The panel shows the types seen so you can check; true per-device targeting would need IOHID attribution (not built).

## Update 2026-11-24 (later): recipes, presets, plugins, dynamics
- **Recipes** (`WhopperKit/Recipes.swift`, `Sources/Whopper/Recipes/`): a named setup for a set of gear. Sections = whole surfaces as JSON (audio incl. plugin states, windows, clipboard, keys and mouse, installed features, Samsung preset name). Gear = display / audio in-out / Logitech signatures. One click applies everything; "Switch automatically" applies when all of a recipe's gear is connected (checked every 4 s); "changed" is shown when settings drifted. Menu-bar panel has a Recipe row with a Switch menu.
- **Per-surface presets** (`PresetMenu`): every settings surface has a Presets menu (EQ, output effects, mic chain, input/keep-awake, windows, clipboard, keys and mouse rules). Stored in `presets.json`.
- **Audio Unit plugin hosting** (`AudioCore/PluginHost.swift`): effect AUs on the mic and on the system output, in order, with on/off, reorder, own editor window, state saved in settings/presets/recipes. Hosted through AVAudioEngine manual rendering (direct renderBlock calls returned silence for third-party AUs). Out of process by default (a plugin crash cannot take Whoprrr down); per-plugin "Run inside Whoprrr" for the ones that refuse. Pre-checks stereo support because AVAudioEngine raises uncatchable exceptions.
- **Output dynamics**: stereo-linked compressor + peak limiter on the system output (`StereoDynamics`).
- Sweep on this Mac (`audioprobe plugins`): 102 of 124 effect AUs load and process out of process; 19 (mostly newer Slate Digital, Eiosis, Repeater) need "Run inside Whoprrr"; 3 Waves mono variants unsupported (their stereo versions work). **VST3 is not hosted**: VST3-only plugins (anything without an AU version) are not available yet; that needs a VST3 host layer (Steinberg SDK, MIT since 3.8) bridged from C++.

## What still needs the user
1. Grant Accessibility, Input Monitoring, System Audio Recording, Microphone to Whopper.app (Permissions page has Grant buttons).
2. Microphone tab > Install: administrator password once; coreaudiod restarts (audio drops for a second or two).
3. Retire the old apps one at a time after Whopper's version has run for a week: Rectangle, eqMac, Karabiner-Elements, Logi Options+.
   Whopper's shortcuts show a lock icon while another app still owns them.
4. Rename before any public release (Whopper is a Burger King trademark).

## Known limits
- Keys typed into secure fields (passwords) bypass every remap tool that is not a DriverKit driver; Karabiner has one, Whopper does not.
- Process taps need macOS 14.2+; DRM-protected playback may arrive silent in the tap.
- The EQ refuses to run on virtual outputs (the eqMac device): quit eqMac and select the real speakers first.
- HID++ button names for the MX Ergo are best-effort until it has been seen awake; unknown buttons show their hex ID.
