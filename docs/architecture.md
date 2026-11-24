# Architecture

One Swift package, one menu-bar app. Each feature is a library with **no UI** and a fake backend so it can be tested without hardware; the SwiftUI app in `Sources/Whopper` wires them together.

| Module | Job | Core API |
|---|---|---|
| `DisplayCore` + `CDDC` | External-display DDC/CI: brightness, contrast, RGB, presets, camera matching | IOAVService (private), vendored m1ddc transport |
| `WindowCore` | Snapping, halves/thirds/quarters, move between displays, drag-to-edge | Accessibility (AXUIElement), Carbon hotkeys, NSEvent monitors |
| `ClipboardCore` | History, search, pins, snippets, paste | NSPasteboard polling, SQLite |
| `InputCore` | Rule engine, event tap, `hidutil`, Karabiner import | CGEventTap, hidutil |
| `LogitechCore` | HID++ 2.0 framing, device hub, button diversion | IOHIDManager |
| `AudioCore` | Devices, input pinner, keep-alive tone, EQ/dynamics DSP, output engine (process tap), mic engine, Audio Unit plugin host | Core Audio HAL, process taps, AVAudioEngine manual rendering |
| `Driver/WhopperMic` | The virtual microphone (AudioServerPlugIn, C) | coreaudiod plug-in API |
| `WhopperKit` | Feature catalogue, permissions, hotkeys, JSON store, recipes and presets | none (pure Swift) |
| `Sources/Whopper` | The app: shell (menu-bar panel, main window, brand), one UI folder per module | SwiftUI |

## Rules we keep

1. **Real-time work never runs on the main thread.** The audio engines and the input tap have their own threads. Real-time callbacks do not allocate or take locks that the UI holds (they use try-locks and pass audio through if busy).
2. **User rules are data.** Key rules, recipes and presets are JSON applied by small engines. There is no scripting language, on purpose.
3. **Pure cores, thin shells.** The remap engine, window geometry, DSP and recipe logic have no OS calls, so they are unit-tested exhaustively. OS-facing code is small and exercised by probes.
4. **Recoverable by construction.** Anything that takes over input or hardware is released on stop and on quit: held keys, `hidutil` mappings, Logitech button diversion, the audio tap (which stays unmuted until real signal proves the permission), and display writes are verified by reading back.
5. **Settings migrate silently.** Every saved settings type decodes tolerantly so old files keep loading.

## Data flow, in short

- **Keys and mouse:** `CGEventTap` thread → `RemapEngine` (pure state machine) → `EventPoster`. Logitech presses arrive from `LogitechHub` on its own thread and go through the same engine.
- **System audio:** process tap + private aggregate device → IOProc → EQ → plugin rack → dynamics → output device.
- **Microphone:** aggregate (real mic + Whoprrr Mic) → IOProc → gain/high-pass/EQ/gate/compressor/plugins → the virtual device, which every app reads.
- **Plugins:** `PluginRack` loads Audio Units (out of process by default) into an `AVAudioEngine` in manual real-time rendering mode, rebuilt off-thread when the chain changes.
- **Recipes:** every settings surface implements `RecipeSurface` (capture/apply as JSON). `RecipeStore` snapshots and applies surfaces, tracks which recipe is active and whether it has drifted, and picks one when gear changes.

## Private or fragile interfaces

| Interface | Used for | If macOS changes it |
|---|---|---|
| `IOAVService*`, `CoreDisplay_DisplayCreateInfoDictionary` | DDC/CI to the display | Display control stops; nothing else is affected |
| `CoreDockSendNotification` | Mission Control, App Exposé, Show Desktop | Falls back to opening Mission Control or a keyboard shortcut |
| HID++ over `IOHIDManager` | Logitech buttons | Only Logitech button rules stop |

## Identifiers

The product is *Whoprrr*. The Swift modules, the bundle id `gg.tico.whopper`, the data folder `Application Support/Whopper` and the driver's UID keep the original working name so renaming the product never costs users their permissions or data.

Background and decision log: [dev/roadmap.md](dev/roadmap.md).
