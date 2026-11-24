# Install Whoprrr

Requires macOS 14.2 or newer. Display control needs an Apple Silicon Mac.

## 1. Get it

Download `Whoprrr-<version>.dmg` (or the `.zip`) from the project's **Releases** page. Optionally check it against `SHA256SUMS`:

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Open the disk image and drag **Whoprrr** to **Applications**.

## 2. First launch (beta builds are not notarized yet)

Beta builds are signed ad-hoc, not with an Apple Developer ID, so macOS shows *"Whoprrr can't be opened because Apple cannot check it for malicious software"*. This is expected for now. Either:

- **Right-click** Whoprrr in Applications → **Open** → **Open**; or
- System Settings → **Privacy & Security** → scroll down → **Open Anyway**; or
- in Terminal: `xattr -dr com.apple.quarantine /Applications/Whoprrr.app`

You only need to do this once per downloaded version. If you would rather not run an unnotarized app, [build it yourself](building.md): it is a few commands.

Whoprrr lives in the menu bar (no Dock icon unless its window is open). The first time, it opens its window on **Permissions**.

## 3. Grant permissions

Turn on only the features you use; each asks only for what it needs. [What each permission is for →](permissions.md)

Because beta builds are ad-hoc signed, macOS treats every new version as a new app and asks again. If a permission looks granted but does nothing after an update, switch it off and on again in System Settings, or run `tccutil reset All gg.tico.whopper` and grant again.

## 4. Optional: the virtual microphone

**Microphone → Install…** adds *Whoprrr Mic* so effects reach every app. It needs your administrator password once and audio restarts for a second or two. On some Macs an unsigned audio driver is not loaded until you restart; see [troubleshooting](troubleshooting.md).

## 5. Try it

- Press the menu-bar icon: quick actions and your **Recipe**.
- **Settings…** (⌘,) for everything else.
- Make a **Recipe** once your setup is the way you like it.
- **⌃⌥⇧⌘⎋** pauses all key and mouse rules if anything feels wrong.

## Uninstall

Run `scripts/uninstall.sh` from the project, or see [uninstall.md](uninstall.md).
