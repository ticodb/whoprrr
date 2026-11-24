# Privacy

**Short version: Whoprrr keeps everything on your Mac and talks to nobody.**

- No account, no analytics, no crash reporting, no update pinger. The app contains no networking code. The only time it opens a web page is when you press a button such as "Report a problem", and then your browser does it.
- Audio is processed live in memory. It is never recorded or written to disk, and never leaves your Mac.
- The camera is used only while you run camera-assisted display matching; frames are analysed in memory and not saved.

## What is stored, and where

All in `~/Library/Application Support/Whopper/` (the folder keeps the project's old working name so upgrades keep your data) unless noted:

| File | Contents |
|---|---|
| `input.json` | Your key and mouse rules and key replacements |
| `audio.json` | Equalizer, effects, plugin chains and their saved plugin settings, mic and routing settings, device names last seen |
| `windows.json`, `clipboard.json` | Settings for those modules |
| `recipes.json`, `presets.json` | Your recipes (including the settings and device names they cover) and saved presets |
| `Clipboard/clipboard.sqlite` and `Clipboard/images/` | **Everything you copy** while clipboard history is on |
| `~/Library/Application Support/SamsungDisplayControl/` | Display presets and learned display settings |

These are plain, unencrypted files readable by your user account. Anyone with access to your account can read them, including your clipboard history.

## Clipboard history

- Items marked *concealed* or *transient* by apps (password managers set these) are not saved.
- You can ignore specific apps, turn off images and files, cap the number of items, set an expiry, and clear history at any time.
- If you copy a secret from an app that does not mark it as concealed, Whoprrr will store it until it expires or you clear it. Turn history off, or add the app to the ignore list, if that matters to you.

## Permissions

Whoprrr asks only for what your enabled features need and explains each one on the Permissions page and in [docs/permissions.md](docs/permissions.md). Granting a permission lets the app do the thing; it does not send anything anywhere.

## System changes it can make

- Installs `Whoprrr Mic` into `/Library/Audio/Plug-Ins/HAL/` only when you press Install (administrator password; audio restarts briefly). Remove it from the same page or with `scripts/uninstall.sh`.
- Sets key replacements with `hidutil` while running (Caps Lock etc.) and removes them on quit.
- Temporarily takes over Logitech buttons that have a rule, and releases them on quit.
- Creates private audio devices while the equalizer or microphone engine runs.
- Runs shell commands only if *you* create a rule whose action is a shell command.

## Diagnostics you choose to share

"Report a problem" copies a short summary to your clipboard: app and macOS versions, which features are on, permission states and counts of devices and rules. It contains no device names, clipboard contents, rules or file paths. Display diagnostics exports are redacted by default.

## Questions

Open an issue. If you find that Whoprrr does something this document does not describe, that is a bug.
