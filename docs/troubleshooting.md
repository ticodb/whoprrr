# Troubleshooting

First: **About → Copy diagnostics** gives a safe summary to paste into an issue.

## A key stays remapped / Caps Lock does something odd after a crash
Remaps made with `hidutil` are removed on quit, but a crash can skip that. Clear them:
```sh
hidutil property --set '{"UserKeyMapping":[]}'
```

## Keys or mouse rules do nothing
- **Keys and mouse** shows *Running*? If it says it needs a permission, grant **Accessibility** and **Input Monitoring** (switch off and on if already granted).
- Press **Test remapping**. "Working" means the event tap sees and changes keys.
- Is **Karabiner-Elements** running with the same rule? Two tools can fight. Quit one.
- Is the rule scoped to an app or a keyboard type? The **Keyboards seen** line shows which keyboard types macOS reports.
- Passwords fields and the login window bypass every remapper; this is a macOS rule.
- **⌃⌥⇧⌘⎋** toggles pause. The status chip says *Paused* if it was pressed.

## A Logitech button does nothing / still does its default thing
- Quit **Logi Options+**; two apps cannot own the same button.
- Use **Learn a button** and press the physical button: names differ between models, the learned ID is what counts. The line *Last press seen* proves presses reach Whoprrr.
- Buttons are taken over only while a rule uses them. Delete the rule and the button goes back to normal; quitting Whoprrr releases everything.

## System equalizer does not change the sound
- Needs **System Audio Recording**. Until the first real sound arrives Whoprrr does not mute the original, so a missing permission never silences you.
- It refuses virtual outputs (for example eqMac's device). Quit eqMac and choose the real speakers.
- DRM-protected audio can arrive silent in a process tap; that is a macOS limit.

## Whoprrr Mic is missing
- Microphone → Install, then wait a few seconds. If it still does not appear, restart the Mac (or run `sudo killall coreaudiod`; audio restarts).
- Some macOS configurations do not load unsigned drivers. The status line says *Installed; waiting for macOS to load it*.
- Apps that ask which mic to use must be set to **Whoprrr Mic**; while the engine runs it is also the system input.

## An effect plugin does not run
- Open the plugin row's menu → **Run inside Whoprrr**, for older plugins that refuse to start in a separate process. A crash then takes the app down: use plugins you trust.
- Plugins that only support mono or surround (some `(m)` variants) are not supported; use their stereo version.
- VST and VST3 plugins appear only if they also installed an Audio Unit version.

## Brightness changes nothing on my display
- DDC/CI must be enabled in the display's own menu. Some docks and adapters block it; try another cable or port.
- Only an external display you selected is ever written. The built-in screen is never touched.
- **Display → Log** lists every command and whether it was read back and verified.

## Permissions look granted but nothing works after an update
Beta builds are ad-hoc signed, so macOS sees each version as new. Toggle the permission off and on, or `tccutil reset All gg.tico.whopper` and grant again.

## Start over
Quit Whoprrr and delete `~/Library/Application Support/Whopper` (rules, recipes, presets, clipboard history), or run `scripts/uninstall.sh`.
