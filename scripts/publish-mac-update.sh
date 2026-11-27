#!/bin/zsh
# Adds the current release to the Sparkle appcast, stages the zip next to it and records it (with its SHA-256) in
# site/releases.json. It does NOT deploy.
#
#   scripts/release.sh                 # builds dist/Whoprrr-<tag>.zip (same VERSION / RELEASE_LABEL)
#   scripts/publish-mac-update.sh      # signs the zip, writes the appcast item, copies the zip
#   (then run the deploy command it prints)
#
# The EdDSA private key is read from the login Keychain by Sparkle's own sign_update; it is never printed or copied.
# UPDATES_DIR   the folder served at https://whoprrr.app (default ~/whoprrr-updates)
# SPARKLE_KEY_FILE  optional private-key file for sign_update (tests only); normally the Keychain key is used
# BASE_URL      public base URL of that folder (default https://whoprrr.app)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
LABEL="${RELEASE_LABEL-beta 9}"
TAG="${VERSION}${LABEL:+-${LABEL// /}}"
UPDATES_DIR="${UPDATES_DIR:-$HOME/whoprrr-updates}"
# The site folder can have unreleased site work checked out. This script writes into it and the next step deploys it,
# so refuse unless it is on main.
if git -C "$UPDATES_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  SITE_BRANCH="$(git -C "$UPDATES_DIR" branch --show-current)"
  [ "$SITE_BRANCH" = "main" ] || { echo "$UPDATES_DIR is on branch '$SITE_BRANCH', not main. Deploying it would put unreleased site work live. Switch it to main first."; exit 1; }
fi
BASE_URL="${BASE_URL:-https://whoprrr.app}"
ZIP="dist/Whoprrr-${TAG}.zip"
SIGN_UPDATE="$(find .build/artifacts -maxdepth 5 -path '*Sparkle/bin/sign_update' -type f | head -1)"

[[ -f "$ZIP" ]] || { echo "Missing $ZIP: run scripts/release.sh first (same VERSION and RELEASE_LABEL)." >&2; exit 1; }
[[ -x "$SIGN_UPDATE" ]] || { echo "sign_update not found: run 'swift package resolve'." >&2; exit 1; }
[[ -d "$UPDATES_DIR/mac" ]] || { echo "Missing $UPDATES_DIR/mac (set UPDATES_DIR)." >&2; exit 1; }

# The build number Sparkle compares comes from the app inside the zip, so it can never disagree with the build.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unzip -q -o "$ZIP" 'Whoprrr.app/Contents/Info.plist' -d "$TMP"
PLIST="$TMP/Whoprrr.app/Contents/Info.plist"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
[[ "$SHORT" == "$VERSION" ]] || { echo "Zip is version $SHORT but VERSION is $VERSION." >&2; exit 1; }

# sign_update prints: sparkle:edSignature="..." length="..."
KEYARGS=(); [[ -n "${SPARKLE_KEY_FILE:-}" ]] && KEYARGS=(-f "$SPARKLE_KEY_FILE")
SIG_LINE="$("$SIGN_UPDATE" "${KEYARGS[@]}" "$ZIP")"
ED_SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIG_LINE")"
LENGTH="$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<<"$SIG_LINE")"
[[ -n "$ED_SIG" && -n "$LENGTH" ]] || { echo "sign_update gave no signature (is the key in the Keychain? see docs/releasing.md)." >&2; exit 1; }
"$SIGN_UPDATE" "${KEYARGS[@]}" --verify "$ZIP" "$ED_SIG" >/dev/null || { echo "Signature does not verify." >&2; exit 1; }

ZIPNAME="Whoprrr-${TAG}.zip"
cp "$ZIP" "$UPDATES_DIR/mac/$ZIPNAME"

# The site refuses to build unless site/releases.json names this zip with its SHA-256. Hash the copy that will be served.
RELEASES="$UPDATES_DIR/site/releases.json"
[[ -f "$RELEASES" ]] || { echo "Missing $RELEASES (set UPDATES_DIR)." >&2; exit 1; }
ZIPSHA="$(shasum -a 256 "$UPDATES_DIR/mac/$ZIPNAME" | awk '{print $1}')"
python3 - "$RELEASES" "${VERSION}${LABEL:+ $LABEL}" "$ZIPNAME" "$ZIPSHA" <<'PY'
import json, sys
path, version, name, sha = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
mac = data.setdefault("mac", {})
mac["version"], mac["file"], mac["sha256"] = version, name, sha
# Same layout as the file already uses: 2-space indent, UTF-8, trailing newline. Other keys (notes included) are untouched.
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY

python3 - "$UPDATES_DIR/mac/appcast.xml" "$BASE_URL" "$ZIPNAME" "$BUILD" "$SHORT" "$MINOS" "$ED_SIG" "$LENGTH" "$VERSION" "$LABEL" "$TAG" <<'PY'
import sys, re, html, email.utils
appcast, base, zipname, build, short, minos, sig, length, version, label, tag = sys.argv[1:]

# Release notes: the CHANGELOG section for this version (and label), as simple HTML.
log = open("CHANGELOG.md", encoding="utf-8").read()
want = f"{version} {label}".strip()
m = re.search(r"^## " + re.escape(want) + r"\b.*?$(.*?)(?=^## |\Z)", log, re.M | re.S)
if not m:
    sys.exit(f"CHANGELOG.md has no '## {want}' section: add one before publishing.")
def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"`(.+?)`", r"<code>\1</code>", t)
    t = re.sub(r"\[(.+?)\]\((.+?)\)", lambda x: f'<a href="{x.group(2)}">{x.group(1)}</a>', t)
    return t
out, in_list = [], False
for line in m.group(1).strip().splitlines():
    if line.startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        out.append(f"<li>{inline(line[2:])}</li>")
        continue
    if in_list: out.append("</ul>"); in_list = False
    if line.startswith("### "): out.append(f"<h3>{inline(line[4:])}</h3>")
    elif line.strip(): out.append(f"<p>{inline(line)}</p>")
if in_list: out.append("</ul>")
notes = "\n".join(out).replace("]]>", "]]]]><![CDATA[>")

title = f"Whoprrr {version}" + (f" {label}" if label else "")
item = f"""    <item>
      <title>{html.escape(title)}</title>
      <pubDate>{email.utils.formatdate(localtime=False, usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(short)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minos}</sparkle:minimumSystemVersion>
      <description><![CDATA[
{notes}
      ]]></description>
      <enclosure url="{base}/mac/{zipname}" sparkle:edSignature="{sig}" length="{length}" type="application/octet-stream"/>
    </item>
"""
xml = open(appcast, encoding="utf-8").read()
# Replace an existing item with the same build number (re-publishing), else add as the newest item.
xml = re.sub(r"^[ \t]*<item>(?:(?!</item>).)*?<sparkle:version>" + re.escape(build) + r"</sparkle:version>.*?</item>\n?", "", xml, flags=re.S | re.M)
if re.search(r"^[ \t]*<item>", xml, re.M):
    xml = re.sub(r"^(?=[ \t]*<item>)", lambda _: item, xml, count=1, flags=re.M)
else:
    xml = xml.replace("  </channel>", item + "  </channel>")
open(appcast, "w", encoding="utf-8").write(xml)
PY

xmllint --noout "$UPDATES_DIR/mac/appcast.xml"
echo
echo "Staged update $TAG (build $BUILD) in $UPDATES_DIR/mac:  $ZIPNAME, appcast.xml"
echo "site/releases.json: mac.version \"${VERSION}${LABEL:+ $LABEL}\", mac.file $ZIPNAME, mac.sha256 $ZIPSHA"
echo "Public key in this build: $PUBKEY"
echo "Nothing is live yet. To publish, run:"
echo "  cd $UPDATES_DIR && vercel deploy --prod"
echo "Then check:  curl -sI $BASE_URL/mac/$ZIPNAME | head -1 && curl -s $BASE_URL/mac/appcast.xml | head -20"
