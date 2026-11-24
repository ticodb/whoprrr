# Releasing

## Beta build (ad-hoc signed, what the first public beta uses)

1. Update `VERSION`, `CHANGELOG.md` and (for a beta) `RELEASE_LABEL`, e.g. `RELEASE_LABEL="beta 2"`.
2. `swift test` and the driver self-test must pass. Run the manual checklist in `docs/dev/manual-checklist.md` on real hardware.
3. `scripts/release.sh` creates `dist/Whoprrr-<version>-<label>.dmg`, `.zip` and `SHA256SUMS`.
4. Tag (`git tag v0.9.0-beta1 && git push --tags`) and create a GitHub release marked **pre-release**; attach the three files and paste the changelog section. The release workflow does this for tags.
5. Smoke-test the downloaded dmg on a Mac that is not your build machine: first launch (Gatekeeper path), Permissions page, one feature per module.

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
