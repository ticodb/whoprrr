# Privacy

**Short version: Whoprrr keeps everything on your Mac and sends nothing unless you press a button to send it.**

- No account, no analytics, no crash reporting. The only network request the app makes is the update check: once a day (or when you choose Check for Updates…) it downloads `https://whoprrr.app/mac/appcast.xml` through Sparkle. That request carries the app version and macOS version in its User-Agent, as any HTTP request does, and no system profile (Sparkle's optional profiling is off). Turn it off with "Check for updates automatically" in Features. Updates are verified against an EdDSA key built into the app before they install. Otherwise the app opens a web page only when you press a button such as "Report a problem", and then your browser does it.
- **Activation.** When you enter your key, Whoprrr sends it once to `https://whoprrr.app/api/activate` together with: an id for this Mac (a one-way keyed hash of the hardware id, so it reveals nothing and stays the same after a reinstall), this Mac's name as set in System Settings (it is what you see in your own device list), the model identifier and the app version. The answer is a pass: a small signed token that works on this Mac only. The app does not keep your key. About once a week it sends the pass back to `https://whoprrr.app/api/pass/renew` to get a fresh one; nothing else is in that request. The pass is checked on your Mac at every launch without contacting anyone, so Whoprrr works offline until the pass runs out (30 days).
- **Fit report (optional, one press).** After the gear scan, Whoprrr offers to send what worked on your gear. The exact text is shown first and it is sent only if you press Send, once, to `https://whoprrr.app/api/fit`. It holds the app version, Mac model, chip and macOS version, the model names and connection types of your gear, and which setup lines were on or off. It never holds serial numbers, device identifiers, the names you gave your devices, or anything about your clipboard, rules or files. The server keeps the report for up to 24 months and does not store the address it came from. Press "No thanks" and nothing is sent.
- Audio is processed live in memory. It is never recorded or written to disk, and never leaves your Mac.
- The camera is used only while you run camera-assisted display matching; frames are analysed in memory and not saved.

## What is stored, and where

All in `~/Library/Application Support/Whopper/` (the folder keeps the project's old working name so upgrades keep your data) unless noted:

| File | Contents |
|---|---|
| `input.json` | Your key and mouse rules and key replacements |
| `audio.json` | Equalizer, effects, plugin chains and their saved plugin settings, mic and routing settings, device names last seen |
| `windows.json`, `clipboard.json` | Settings for those modules |
| `license.json` | This Mac's pass and when it was last refreshed. No key |
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
