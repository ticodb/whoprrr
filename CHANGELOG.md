# Changelog

All notable changes to Whoprrr. Versions follow [Semantic Versioning](https://semver.org); betas are labelled `0.9.0 beta N`.

## Unreleased

### Added
- **Typing language per recipe.** Recipes can select an enabled keyboard input source. A manual language switch takes precedence until you reapply a recipe.
- **Full backups.** Save all recipes, presets and per-device settings. A restore shows what it replaces and keeps a copy of the current data.
- **Mixer** on the Audio page. Turn individual apps down or mute them. Recipes remember the apps you adjust, and shared setups and setup files leave app volumes out.
- **Picklsss milestones** celebrate your first take, first accepted setup, first keep, and the ranks and takes that follow. Every take and share adds a pickle. See your burger grow on “My shared setups”.

### Changed
- The menu-bar overview opens each section inside the drawer, with a way back to the overview. The recipe Switch menu appears when two or more recipes are available.
- Audio effects use a searchable picker, and the mixer refreshes its audio process list periodically so newly active apps appear.
- Permission renewal can clear a failed grant before asking again, with the current app available to add manually in System Settings.

### Fixed
- The mixer hides dormant audio clients and keeps heard apps available through pauses. Fader changes, mute, and reset reuse the audio route instead of rebuilding it.
- Snap previews update only when their position changes and skip Whoprrr’s own windows.

### Changed
- A pinned save bar names the sections you’ve edited and offers preset and recipe saves, Put back, and Undo. Press ⌘S to update the active recipe.
- **One preset menu per section** shows built-ins, personal presets, and which preset is in use. Press ⌘U to update a personal preset. Manage presets to rename or delete yours, or hide and restore built-ins.
- Open Whoprrr closes the menu-bar drawer and brings the main window to the current Space.
- The menu-bar drawer shows what the last update check found.

### Fixed
- System Audio Recording shows the macOS permission state when it can be read.
- Whoprrr loads older preset libraries and keeps unreadable libraries in place with a timestamped copy.

## 0.9.0 beta 8: make it a combo from the app

Released 2026-11-27.

### Fixed
- **Make it a combo** on the Extras page (was "The Combo") adds Whoprrr TV to a Mac order for $2, the difference to the Combo price. Before, its Add button opened a page that only offered Frrries and Picklsss.
- Each **Add** on the Extras page opens your order's purchase page with just that item ticked.

## 0.9.0 beta 7: guided setup, activate from your order page, Add a TV

Released 2026-11-27.

### Added
- **Activate this Mac** on your order page hands Whoprrr a one-time setup code. The app can still activate with the key from your receipt.
- **Add a TV** under Extras finds Android TVs on your network, verifies and installs Whoprrr TV, then opens it with a setup code from your order.
- **Setup** takes this Mac from activation through a gear scan, recipe, permission guide and taste test in one window. It picks up where you left off and keeps the settings of any parked feature.
- **After an update**, Whoprrr checks permissions quietly while your features keep running, and offers to renew only grants that clearly stopped working. The check never shows a macOS prompt or presses keys, and gives up after a few seconds. **Reset and ask again** clears a single supported grant for Whoprrr, only when you press it.

## 0.9.0 beta 6: the version in the menu-bar panel

Released 2026-11-27.

### Changed
- **The menu-bar panel shows which version you have.** The bottom line now reads, for example, "0.9.0 beta 6 (build 34)" in place of "Check for Updates…". Press it to open the About page. It is violet while you have the latest version and turns to the notice yellow, with "Update available", when a newer one is out.
- **Updates are offered on the About page.** A new Updates card says "Up to date" with "Check now", or names the newer version with an Install button. Whoprrr asks the update feed quietly, at most once an hour, and only while automatic update checks are on.
- **One way into Settings from the panel**: the gear at the top right (⌘,). The second "Settings…" button at the bottom is gone.

## 0.9.0 beta 5: buy Picklsss straight from the app

Released 2026-11-27.

### Changed
- **"Get Picklsss" opens a page for this purchase.** Whoprrr sends its pass to whoprrr.app and gets back a one-time link to a small page, "Add to your order". It shows your order number, a hidden form of your email and the name of this Mac, and never your key. There you can tick Picklsss ($4, setups other people shared, paid once) and Frrries ($4, 4 more devices), pay, and come back. The link works for 10 minutes and ends after one payment. If the link has timed out, press the button again.
- **Whoprrr notices a purchase made somewhere else.** When you open the Picklsss page or the Extras page and the extra is not on this Mac yet, Whoprrr asks for a fresh pass in the background, at most once every 10 minutes. Before, it learned about a purchase after "Check now" or within about a week.
- Coming back from paying with nothing found now says "Not on your key yet. If you just paid, give it a moment." beside "Check now".

### Fixed
- If whoprrr.app cannot be reached when you press "Get Picklsss", Whoprrr says so ("Could not reach whoprrr.app. Check your connection and try again.") and offers "Find my order by email instead", which opens the page beta 4 opened. Buying does not depend on the new link.
- The project builds again on GitHub's build machines: one long expression in the shared-setups code was split into smaller steps. Nothing about how it behaves changes.

## 0.9.0 beta 4: recipes like documents, and Picklsss (shared setups)

Released 2026-11-27.

### Added
- **Recipes behave like documents**: while the active recipe differs from your settings, the main window shows a save bar on every page (Save, Save as new recipe, Put back). It waits until you have left the settings alone for 2 seconds; until then only a small "Cookin'" label shows. After saving there is a confirmation with Undo, and every recipe keeps the version from before its last save: "Go back to the version before…" in its menu swaps the two, so going back can itself be undone.
- **Unsaved changes are never dropped**: closing the window asks nothing and the change stays live, also after a quit. The next time the window opens it lands on the page that changed with a reminder, until you save or put back. When gear changes would switch recipes automatically and the current one has unsaved changes, Whoprrr asks first (save then switch, switch without saving, or stay).
- **Gear is stored by role and model** (for example microphone, "RØDE PodMic USB") as well as what this Mac needs to recognise it, so a recipe file makes sense on another Mac. `recipes.json` now has a `formatVersion`. An older file is converted on first launch and the original is kept beside it as `recipes.backup-v1.json`; a file that cannot be read is kept aside as `.bad` and never overwritten.
- **Picklsss, the shelf of setups other people shared**: a page with tabs For your gear, Popular and New, and search. Browsing needs no extra and sends nothing about your gear (ranking is done on your Mac). Open one to see every line with a fit label judged against *your* gear, match their devices to yours, review a before and after, and apply with "Cookin'". The result is an ordinary recipe, with two ways back in its menu (before your last save; the author's original as fitted) and one button that puts everything back. Take one part on its own into your presets. Plugins are never downloaded or installed; a missing one is a link you may click.
- **The extra**: taking needs the shared-setups extra ($4, paid once, free if a setup you share is accepted). Everything up to and including the review is free; the lock appears at the first action that changes your Mac. Paying happens in the browser; Whoprrr re-checks its pass when it comes to the front and on "Check now", then carries on where you were.
- **Share as a picklsss…**, **Send as a file…** and **Share the update** in a recipe's menu: what goes, what is always left out, a switch per part, limits checked per line before anything is sent. "My shared setups" shows each one's state; updates are a separate step with a note; taking down asks first.
- **Count what you keep** (opt-in, asked once, changeable on the Extras page): 7 days after a take, one yes or no is sent, worked out on your Mac. **Kitchen time**, for people who share only, is counted once a day. The once-a-day shelf round (notices, the day-7 answer, kitchen time) usually runs with the update check, and keeps running for people who use shared setups when automatic update checks are off.
- **Notices**: an update is offered with the author's note and a before and after (a plain choice between yours and the new one); a setup removed because its author can no longer share is announced with "Put back".
- **Did it work? / Something is off** after taking, reusing the gear scan's report.
- **`.whoprrr-setup` files** are registered with the app. Opening one runs the checker every time and refuses a hand-edited file; a file made under your own key always opens free.
- **Extras page**: what your order includes, what can be added, devices, the count switch, "Check now".
- Debug builds: `WHOPRRR_SCRIPT` runs JSON steps and takes screenshots for end-to-end checks; the display presets now follow `WHOPPER_DATA_DIR` too.

### Changed
- "Update with my current settings" in a recipe's menu and the "Active, changed" chip are replaced by the save bar.

### Known limits
- The shared-setups extra ($4) cannot be bought yet: its "Get Picklsss" button opens the "Find your downloads" page, and the website does not offer the extra until it goes on sale. Browsing, opening, reviewing and sharing work; taking a setup onto your Mac stays locked until then, unless a setup you shared was accepted.

## 0.9.0 beta 3: recipes no longer look changed when they are not

### Fixed
- A recipe you had not touched could show **Active, changed** after Whoprrr was quit and opened again, when its window settings had more than one switched-off shortcut or a custom set of drawer layouts (the starter recipe from the gear scan has one). Those lists were saved in a different order each launch and compared letter for letter. They are now saved in a fixed order, and recipes saved before this update compare correctly too. Nothing about your settings changes.

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
