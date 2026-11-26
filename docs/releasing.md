# Releasing

## Beta build (ad-hoc signed, what the first public beta uses)

1. Update `VERSION`, `CHANGELOG.md` and (for a beta) `RELEASE_LABEL`, e.g. `RELEASE_LABEL="beta 2"`.
2. `swift test` and the driver self-test must pass. Run the manual checklist in `docs/dev/manual-checklist.md` on real hardware.
3. `scripts/release.sh` creates `dist/Whoprrr-<version>-<label>.dmg`, `.zip` and `SHA256SUMS`.
4. Tag (`git tag v0.9.0-beta1 && git push --tags`) and create a GitHub release marked **pre-release**; attach the three files and paste the changelog section. The release workflow does this for tags.
5. Smoke-test the downloaded dmg on a Mac that is not your build machine: first launch (Gatekeeper path), Permissions page, one feature per module.

## Automatic updates (Sparkle)

The app checks `https://whoprrr.app/mac/appcast.xml` daily. That folder is the Vercel project `whoprrr-updates` (local copy `~/whoprrr-updates`, also served as get.tico.gg). Updates are verified against the EdDSA public key in `Info.plist` (`SUPublicEDKey`, set in `scripts/build-app.sh`).

**Key.** The private key lives only in the login Keychain of the publishing Mac (created once by Sparkle's `generate_keys`, Keychain item account `ed25519`). Never export, commit or paste it. Back it up with `generate_keys -x <file>` into a password manager, not the repo. If it is lost, installed apps can never verify another update: a new key means users must install once by hand. The first time `sign_update` reads the key macOS asks to allow Keychain access: choose Always Allow.

**Publish an update** (after the normal beta or proper release steps above; `VERSION`, `RELEASE_LABEL` and the matching `CHANGELOG.md` section must be set, and `CFBundleVersion` must go up: it is the commit count, or set `BUILD_NUMBER`):

```sh
scripts/release.sh                  # dist/Whoprrr-<version>[-label].zip
scripts/publish-mac-update.sh       # signs the zip, writes the appcast item (notes from CHANGELOG), copies the zip
cd ~/whoprrr-updates && vercel deploy --prod   # goes live; the script only prints this. The folder must be on main:
                                               # the script refuses to stage otherwise
```

`publish-mac-update.sh` never deploys. Re-running it for the same build replaces its item. The zip must be the one users download (Sparkle checks the signature of exactly those bytes), so publish the zip you released, do not rebuild in between.

Sparkle.framework is embedded by `build-app.sh` and signed inside-out (XPC services, Autoupdate, Updater.app, framework, then the app) with the same identity; with a Developer ID the runtime hardening and timestamp apply to all of them, and notarization covers them.

**Testing locally.** Build with `SPARKLE_FEED_URL=http://127.0.0.1:8765/mac/appcast.xml`, serve a folder with a higher-build appcast, and launch the binary with `WHOPPER_FORCE_UPDATER=1` (otherwise the updater stays off for `WHOPPER_NO_START`/debug-window launches and outside a `.app`). Sparkle stores its state in the app's defaults (`SULastCheckTime` and friends); delete them afterwards.

## Proper release (Developer ID + notarization)

This needs a paid Apple Developer account. It removes the Gatekeeper warning and keeps permission grants across updates.

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" RELEASE_LABEL="" scripts/release.sh
xcrun notarytool submit dist/Whoprrr-<version>.zip --keychain-profile "whoprrr-notary" --wait
xcrun stapler staple build/Whoprrr.app           # then rebuild the dmg/zip from the stapled app
spctl --assess --type execute -vv build/Whoprrr.app
```

`build-app.sh` signs with the hardened runtime and `Resources/Whoprrr.entitlements` (audio input, camera, and `disable-library-validation` so third-party Audio Units can load in process). The bundled `WhopperMic.driver` is signed with the same identity.

Things to verify once on a clean Mac after a Developer-ID build: the app launches, Whoprrr Mic installs and loads, the system equalizer starts, an Audio Unit plugin loads.

## Checklist before announcing

- [ ] Product name cleared (trademark search) and the repository URL in `Sources/Whopper/Shell/AppInfo.swift`, README and docs is the real one.
- [ ] Screenshots are current: `scripts/screenshots.sh` (sample data, never your settings).
- [ ] `SECURITY.md` private reporting is enabled on the repository (Settings → Code security).
- [ ] Release notes mention the beta status and known issues.
