#!/bin/zsh
# Builds build/Whoprrr.app (arm64, menu bar only).
#
# Signing, chosen by SIGN_IDENTITY:
#   unset            the local identity "Whopper Local Signing" if it exists (scripts/make-signing-identity.sh), else ad-hoc.
#                    A stable identity keeps Accessibility / Input Monitoring grants across rebuilds; ad-hoc does not.
#   "-"              ad-hoc (what public beta zips use; macOS asks again for permissions after each update).
#   "Developer ID Application: Name (TEAMID)"   a real certificate: hardened runtime + timestamp, ready to notarize.
set -euo pipefail
cd "$(dirname "$0")/.."
LOCAL_IDENTITY="Whopper Local Signing"
VERSION="$(cat VERSION)"
LABEL="${RELEASE_LABEL-beta 6}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN="${SIGN_IDENTITY-}"
# Sparkle (automatic updates). The public EdDSA key is safe to commit; the private key lives only in the
# login Keychain of the machine that publishes releases (Sparkle's generate_keys). Override for a rotated key.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-WSpaAANVXwS41b7h8DzlmD/8HTZzcN8O0aisoEaXfmA=}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://whoprrr.app/mac/appcast.xml}"
if [[ -z "$SIGN" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q "$LOCAL_IDENTITY"; then SIGN="$LOCAL_IDENTITY"; else SIGN="-"; fi
fi

swift build -c release --product Whopper
BIN="$(swift build -c release --show-bin-path)/Whopper"
APP="build/Whoprrr.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Whoprrr"
# Sparkle.framework from the SwiftPM artifact, embedded with symlinks intact; the binary finds it via an rpath.
SPARKLE_FW="$(find .build/artifacts -maxdepth 6 -path '*macos-arm64_x86_64/Sparkle.framework' -type d | head -1)"
[[ -d "$SPARKLE_FW" ]] || { echo "Sparkle.framework not found: run 'swift package resolve'" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
otool -l "$APP/Contents/MacOS/Whoprrr" | grep -q "@executable_path/../Frameworks" \
  || install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Whoprrr"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>gg.tico.whopper</string>
  <key>CFBundleName</key><string>Whoprrr</string>
  <key>CFBundleDisplayName</key><string>Whoprrr</string>
  <key>CFBundleExecutable</key><string>Whoprrr</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>WhoprrrReleaseLabel</key><string>${LABEL}</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Tico Ituarte. MIT License.</string>
  <key>NSCameraUsageDescription</key><string>Whoprrr uses a camera that sees both screens to match their brightness and color. Frames are analysed locally and never saved or sent anywhere.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Whoprrr captures the system sound so its equalizer and effects can process it. Audio is processed live and never recorded or sent anywhere.</string>
  <key>NSMicrophoneUsageDescription</key><string>Whoprrr reads your microphone so it can apply effects and route it to the virtual mic. Audio is processed live and never recorded or sent anywhere.</string>
  <key>NSCameraUseContinuityCameraDeviceType</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Whoprrr shared setup</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>gg.tico.whoprrr.setup</string></array>
  </dict></array>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>gg.tico.whoprrr.setup</string>
    <key>UTTypeDescription</key><string>Whoprrr shared setup</string>
    <key>UTTypeConformsTo</key><array><string>public.json</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>whoprrr-setup</string></array></dict>
  </dict></array>
  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST

# Virtual microphone driver, embedded so the app can install it on request.
./Driver/build-driver.sh >/dev/null
cp -R Driver/build/WhopperMic.driver "$APP/Contents/Resources/"

# Sparkle's nested code, signed inside-out (XPC services, Autoupdate, Updater.app, then the framework) with the
# same identity as the app. A real identity also gets the hardened runtime and a timestamp.
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ "$SIGN" == "-" || "$SIGN" == "$LOCAL_IDENTITY" ]]; then SPK_OPTS=(); else SPK_OPTS=(--options runtime --timestamp); fi
for part in "$SPK/XPCServices/Installer.xpc" "$SPK/XPCServices/Downloader.xpc"; do
  codesign --force "${SPK_OPTS[@]}" --preserve-metadata=entitlements --sign "$SIGN" "$part" >/dev/null
done
codesign --force "${SPK_OPTS[@]}" --sign "$SIGN" "$SPK/Autoupdate" >/dev/null
codesign --force "${SPK_OPTS[@]}" --sign "$SIGN" "$SPK/Updater.app" >/dev/null
codesign --force "${SPK_OPTS[@]}" --sign "$SIGN" "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null

if [[ "$SIGN" == "-" || "$SIGN" == "$LOCAL_IDENTITY" ]]; then
  codesign --force --sign "$SIGN" "$APP/Contents/Resources/WhopperMic.driver" >/dev/null 2>&1
  codesign --force --sign "$SIGN" "$APP" >/dev/null
  if [[ "$SIGN" == "-" ]]; then echo "Signed ad-hoc: macOS will re-ask for permissions after every update." >&2; else echo "Signed with stable local identity: $SIGN"; fi
else
  codesign --force --options runtime --timestamp --sign "$SIGN" "$APP/Contents/Resources/WhopperMic.driver" >/dev/null
  codesign --force --options runtime --timestamp --entitlements Resources/Whoprrr.entitlements --sign "$SIGN" "$APP" >/dev/null
  echo "Signed for distribution: $SIGN (notarize next: see docs/releasing.md)"
fi
codesign --verify --deep --strict "$APP"
echo "Built: $APP  (version ${VERSION} ${LABEL}, build ${BUILD})"
