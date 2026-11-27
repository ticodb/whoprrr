# Install Whoprrr

Requires macOS 14.2 or newer. Display control needs an Apple Silicon Mac.

## 1. Get it

The source is free under the MIT licence, and you can [build it yourself](building.md). The ready build, its updates and help cost $5 once at [whoprrr.app](https://whoprrr.app) (beta price). Download the zip from your personal downloads page there, double-click it to unpack it and drag **Whoprrr** to **Applications**. The install page shows the file's SHA-256 when one is published, so you can check it:

```sh
shasum -a 256 Whoprrr-<version>.zip
```

The ready build activates from your order page. You can type the key from your receipt email instead. It contacts whoprrr.app to activate, then again about once a week; see [PRIVACY.md](../PRIVACY.md). A release build you make yourself (`scripts/build-app.sh`) asks for a key too; only debug builds (`swift build`) skip the check, for development.

## 2. First launch (beta builds are not notarized yet)

Beta builds are signed ad-hoc, not with an Apple Developer ID, so macOS says it could not verify Whoprrr. This is expected for now. On macOS 15 and later the right-click → Open route no longer works. Do this instead:

1. **Double-click** Whoprrr in Applications once. macOS says it could not verify Whoprrr; press **Done**.
2. Open **System Settings → Privacy & Security** and scroll down to the message about Whoprrr.
3. Press **Open Anyway** and confirm (with your password or Touch ID if macOS asks).

Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Whoprrr.app`

You only need to do this once per downloaded version. If you would rather not run an unnotarized app, [build it yourself](building.md): it is a few commands.

Whoprrr lives in the menu bar (no Dock icon unless its window is open). On first launch it opens Setup.

## 3. Set up this Mac

On your order page, press **Activate this Mac**. The link opens Whoprrr and activates this Mac. If the link expires, get a fresh one from the order page or choose **Type my key instead**. Then choose **Scan my setup** to review a recipe for the gear connected to this Mac. The recipe lists the grants its switched-on lines need. **Set up by hand** goes straight to Features.

Setup remembers where you stopped. Follow the guide for each grant, then try the features in **Taste test**. If you skip a grant, its features stay off with their settings saved. The menu bar offers **Continue** when you’re ready. [What each grant is for](permissions.md)

On the first launch of a new build, Whoprrr checks what it can quietly. It opens a renewal window if a grant needs attention. System Audio Recording needs a chime you start yourself.

## 4. Optional: the virtual microphone

**Microphone → Install…** adds *Whoprrr Mic* so effects reach every app. It needs your administrator password once and audio restarts for a second or two. On some Macs an unsigned audio driver is not loaded until you restart; see [troubleshooting](troubleshooting.md).

## 5. Try it

- Press the menu-bar icon: quick actions and your **Recipe**.
- **Settings…** (⌘,) for everything else.
- Make a **Recipe** once your setup is the way you like it.
- **⌃⌥⇧⌘⎋** pauses all key and mouse rules if anything feels wrong.

## Add a TV

If your order includes Whoprrr TV, open **Extras → Add a TV**. Keep the Mac and the Android TV on the same network. If your TV shows **Needs one setting**, follow the steps for turning on USB debugging. You can also enter the TV’s address from **Settings → Network**.

Choose **Install** on the TV you want. If this Mac has no `adb`, Whoprrr downloads Google’s Android SDK Platform-Tools on the first install. On the TV, choose **Always allow from this computer**, then **Allow**. The Mac checks the APK, installs it and opens Whoprrr TV with a short-lived setup code from your order. Finish setup on the TV.

## Uninstall

Run `scripts/uninstall.sh` from the project, or see [uninstall.md](uninstall.md).
