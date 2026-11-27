# Privacy

**Short version: Whoprrr keeps everything on your Mac and sends nothing unless you press a button to send it.**

- No account, no analytics, no crash reporting. Apart from activation, the optional fit report and, if you use shared setups, the calls described below, the only network request the app makes is the update check: once a day (or when you choose Check for Updates…) it downloads `https://whoprrr.app/mac/appcast.xml` through Sparkle. That request carries the app version and macOS version in its User-Agent, as any HTTP request does, and no system profile (Sparkle's optional profiling is off). Turn it off with "Check for updates automatically" in Features. Updates are verified against an EdDSA key built into the app before they install. Otherwise the app opens a web page only when you press a button such as "Report a problem", and then your browser does it.
- **Activation.** When you enter your key, Whoprrr sends it once to `https://whoprrr.app/api/activate` together with: an id for this Mac (a one-way keyed hash of the hardware id, so it reveals nothing and stays the same after a reinstall), this Mac's name as set in System Settings (it is what you see in your own device list), the model identifier and the app version. The answer is a pass: a small signed token that works on this Mac only. The app does not keep your key. About once a week it sends the pass back to `https://whoprrr.app/api/pass/renew` to get a fresh one; nothing else is in that request. The pass is checked on your Mac at every launch without contacting anyone, so Whoprrr works offline until the pass runs out (30 days).
- **Fit report (optional, one press).** After the gear scan, Whoprrr offers to send what worked on your gear. The exact text is shown first and it is sent only if you press Send, once, to `https://whoprrr.app/api/fit`. It holds the app version, Mac model, chip and macOS version, the model names and connection types of your gear, and which setup lines were on or off. It never holds serial numbers, device identifiers, the names you gave your devices, or anything about your clipboard, rules or files. The server keeps the report for up to 24 months and does not store the address it came from. Press "No thanks" and nothing is sent.
- **Shared setups (the shelf called Picklsss).** None of this happens unless you open the Picklsss page, take or share something, or open a `.whoprrr-setup` file. All calls go to `https://whoprrr.app` (the same server as activation) and are described in the website's `docs/picklsss.md`.
  - **Browsing** sends only what you type in the search box. It does **not** send your gear: the shelf's API can rank by gear model names, but Whoprrr does not use that; it reads the shelf's pages and ranks "For your gear" on your Mac, so the shelf is never told what you own. (Reading many pages for that ranking is the price; it is capped at 500 setups.)
  - **Opening one, taking it, "Something is off", notices** send your pass (a signed token that never says who you are) and which shared setup. Taking also sends your answer to "Count what you keep?" (yes or no) and, if you chose one part, which part.
  - **Count what you keep** is asked once, at your first take, and can be changed on the Extras page. If you said yes, the shelf gives this Mac a take code, and 7 days later (between day 7 and day 30, once) Whoprrr sends that code with a single yes or no: yes means the setup was still among your recipes and was your active recipe on at least 3 different days. The days are noted on your Mac only, only for setups you took and only if you said yes, and they are never sent. Nothing else goes with the answer: no settings, no gear, no device. Your answer is private.
  - **A shared setup holds** Whoprrr's own settings in a fixed format, and the model names of the gear it was made for. It never holds serial numbers, the names you gave your devices, identifiers of your Mac or devices, clipboard history or snippets, text your key rules type, web addresses, shell commands, rules that open apps, file paths, or plugin files and plugin settings (plugins are only named). Before you share or send a file, the screen lists what goes and what is always left out, and a setting past a safety limit is refused on your Mac before anything is sent. Whoprrr checks every setup and every file it opens against the same limits, whoever sent it.
  - **If you share**, the shelf stores your title and one line, the setup, the gear model names, your handle (which you choose), and the days and keeps counted for it. Your handle, rank, keeps and kitchen time are public. From then on, **only on a Mac that has at least one public shared setup**, Whoprrr also makes one extra request a day (`/api/shelf/day`) carrying your pass, so the shelf can count a "kitchen day" under your handle; it stops when you take down everything you shared. If you have taken or shared a setup, the once-a-day shelf calls (notices about what you took, a day-7 answer you agreed to, and this one) are made even when automatic update checks are switched off; if you have done neither, switching update checks off means no daily call at all. Every other Mac makes no such call.
  - **Files** (`.whoprrr-setup`) are made and opened on your Mac; nothing is uploaded. A file carries a key id so Whoprrr can tell a file you made yourself from someone else's; it is not your key.
  - **Paying** happens in your browser on whoprrr.app. Whoprrr never handles a card; it re-checks its pass when you come back.
  - On your Mac, `picklsss.json` remembers what you took (with the settings from just before, so "Put back" can restore them), your answer to the question above, what you shared and the notices it has not shown yet.
- The mixer reads which apps are making sound on this Mac and sends nothing.
- Audio is processed live in memory. It is never recorded or written to disk, and never leaves your Mac.
- The camera is used only while you run camera-assisted display matching; frames are analysed in memory and not saved.

## What is stored, and where

All in `~/Library/Application Support/Whopper/` (the folder keeps the project's old working name so upgrades keep your data) unless noted:

| File | Contents |
|---|---|
| `input.json` | Your key and mouse rules and key replacements |
| `audio.json` | Equalizer, app volumes and mutes, effects, plugin chains and their saved plugin settings, mic and routing settings, device names last seen |
| `windows.json`, `clipboard.json` | Settings for those modules |
| `license.json` | This Mac's pass and when it was last refreshed. No key |
| `recipes.json`, `presets.json` | Your recipes (including the settings and device names they cover) and saved presets |
| `picklsss.json` | Shared setups you took (and the settings from just before, for Put back), your yes or no to counting, the take code until it is used, the days a taken setup was active, what you shared, and notices not yet shown |
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
