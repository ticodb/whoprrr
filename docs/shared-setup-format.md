# Shared setups: the document format

Format version **1**. For the people building the shelf on `whoprrr.app` and for the Mac app. It is the contract between the two:
the Mac writes a document and checks it, the server checks the same document with the same rules, and the Mac checks it again every
time it opens one. The Swift code is in `Sources/WhopperKit/SharedSetup/` (`SharedSetupTable.swift` holds every number below in one
place, `SharedSetupLimits.swift` is the checker). The test vectors at the end let the server prove its JavaScript checker agrees
with the Swift one.

People read "shared setup" (the shelf's word for one is *a picklsss*, see `picklsss.md` in the website repository). In code and in
messages a person sees, it is a shared setup. A person's own saved setups are *recipes*.

## 1. The idea

A shared setup may only set **Whoprrr's own settings**. It cannot type text, open an address, run a command, launch an app or carry
a plugin, and applying it cannot harm gear, hearing, a keyboard or someone's data. So the format is a strict allow-list:

- Every field has a type, a unit and a range. A field that is not in this document is a violation, not something to ignore.
- A newer format must bump `formatVersion`. Version 1 documents are read only by version 1 rules.
- The checker never needs Swift types. It walks the document as plain JSON: objects, arrays, strings, booleans, `null` and numbers
  in stated units (dB, Hz, ms, seconds, points, MB, KB). No base64, no JSON inside strings.

Where the same checks run: **when sharing** (the Mac refuses to produce a document that breaks them), **on the server**
(`POST /api/shelf/share` and `update`), and **every time a setup or a file is opened** on a Mac.

## 2. The document

| Field | Type | Rule |
| --- | --- | --- |
| `formatVersion` | whole number | `1`. Anything else is the rule `format` and nothing else is checked. |
| `title` | string | 1 to 60 characters (UTF-16 code units, like JavaScript's `length`), no control characters. |
| `line` | string | 1 to 160 characters, no control characters. The one line that says what it is for. |
| `parts` | array of strings | 1 to 6 of `audio`, `microphone`, `windows`, `keys`, `clipboard`, `display`, no repeats, **in that order**. |
| `gear` | array | 0 to 20 items `{ "role", "model" }` (section 3). The author's devices. Parts point at them by position. |
| `requirements` | object | `{ "plugins", "minMacOS", "permissions" }` (section 3). |
| `settings` | object | One key per part named in `parts`, and no other key. Each value is described in section 4. |
| `typingLanguage` | optional object | `{ "id", "name" }` for an explicitly shared macOS keyboard input source. The ID matches `^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$`. The display name has 1 to 100 UTF-16 code units and follows the personal-text checks. Omit the field when typing language is left out. |

The same words are the card fields of the shelf's `share` call (`title`, `line`, `parts`, `gear`, `requirements`); the app sends the
document in `document` and these fields beside it, and they are the same values. Roles are these words: `microphone`, `speaker`,
`display`, `keyboard`, `mouse`, `other`. (The examples in `picklsss.md` say `speakers` and `monitor`; the Mac writes `speaker` and
`display`. The server must not compare roles to a fixed list: a newer Mac may know more roles.)

The optional field is available when sending a setup file. Shelf submissions and updates use the existing v1 fields. The receiver leaves the language off if the input source is unavailable or disabled. The same rule applies when a recipe from a backup made under another key is opened as a shared setup.

## 3. Gear and requirements

`gear[i]`: `{ "role": string, "model": string }`, nothing else.

- `role`: lowercase letters only, 1 to 30 (`^[a-z]{1,30}$`).
- `model`: 1 to 80 characters. The **model name only**: never a name the person gave the device, never a serial number, never an
  identifier of a Mac or a device. The Mac removes a person's name the way `KnownGear.publicName` does ("Ana’s AirPods Pro" becomes
  "AirPods Pro"). The checker refuses a model that holds a web address, a file path, a person's name (`’s ` or `'s `), the word
  "serial" or "s/n", a UUID, a colon, or a word of 8 or more characters with 6 or more digits (rule `no-personal-text`).

`requirements`:

| Field | Type | Rule |
| --- | --- | --- |
| `plugins` | array of strings | 0 to 20 names of audio plugins the setup refers to, each 1 to 40 characters, no address or path. The plugins themselves are never included. |
| `minMacOS` | string or `null` | `null`, or like `14` or `14.2` (`^[0-9]{1,2}(\.[0-9]{1,2})?$`). The key is always present. |
| `permissions` | array of strings | 0 to 10 of `accessibility`, `inputMonitoring`, `camera`, `microphone`, `systemAudio`, no repeats. |

## 4. The parts

All numbers are JSON numbers. "Whole" means it has no fractional part (`Number.isInteger`). Ranges are inclusive and are **the
app's own ranges**: what its sliders and its settings code can produce. A number outside its range is the rule `range`, and it
proves the document was edited by hand (`tampered`). The safety limits of section 5 are separate and tighter; both are reported.

`gear` fields below are whole numbers that index `gear` (0 is the first item) and must point at a device of the stated role
(otherwise `gear-ref`).

### Curve

`{ "enabled": bool, "preampDb": number, "bands": [Band] }`

| Field | Unit | Range |
| --- | --- | --- |
| `preampDb` | dB | -12 to 6 |
| `bands` | list | 0 to 16 items |
| `Band.hz` | Hz | 10 to 22000 |
| `Band.gainDb` | dB | -12 to 12 (the sliders; the model itself does not clamp) |
| `Band.q` | | 0.1 to 10 |
| `Band.kind` | string | `peak`, `lowShelf`, `highShelf`, `highPass`, `lowPass` |

### Compressor

`{ "enabled", "thresholdDb", "ratio", "attackMs", "releaseMs", "makeupDb" }`: threshold -50 to 0 dB, ratio 1 to 12, attack 1 to 100 ms,
release 20 to 1000 ms, make-up gain 0 to 18 dB.

### Plugin

`{ "name": string 1..40, "maker": string 0..40, "enabled": bool }`. Nothing else: no component codes, no settings, no state, no
path. The receiving Mac finds the plugin it has installed by name and maker.

### `audio`

| Field | Meaning |
| --- | --- |
| `equalizer.enabled` | bool |
| `equalizer.curve` | Curve: the default curve for any speaker without its own |
| `equalizer.speakerCurves` | 0 to 20 items `{ "gear": speaker, "curve": Curve }`: a curve made for one of the author's speakers |
| `effects.compressor` | Compressor, on the system output |
| `effects.limiter` | `{ "enabled": true, "ceilingDb": -12 to 0, "releaseMs": 10 to 500 }`. **Required.** `enabled` must be `true` and `ceilingDb` at most -1 |
| `effects.plugins` | 0 to 10 Plugins on the system output |
| `keepAwake` | 0 to 20 items `{ "gear": speaker, "enabled": bool, "levelDb": -90 to -20, "frequencyHz": 15 to 2000, "pulseEverySeconds": 0 to 600, "burstSeconds": 0.05 to 10 }`: the tone that keeps a Bluetooth speaker awake |
| `keepInput` | `{ "enabled": bool, "gear": [microphone] }`: keep one of these microphones as the input, in priority order (0 to 20) |

### `microphone`

| Field | Meaning |
| --- | --- |
| `enabled` | bool |
| `source` | a `gear` index (a microphone) or `null` |
| `gainDb` | -12 to 24 dB |
| `highPass` | `{ "enabled": bool, "hz": 40 to 200 }` |
| `equalizer` | Curve |
| `gate` | `{ "enabled", "thresholdDb": -80 to -20, "attackMs": 0.1 to 100, "releaseMs": 10 to 1000 }` |
| `compressor` | Compressor |
| `plugins` | 0 to 10 Plugins |

### `windows`

| Field | Meaning |
| --- | --- |
| `shortcutsEnabled`, `cycleHalves`, `snapByDrag` | bool |
| `gapPoints` | 0 to 30 points |
| `drawer` | `null` (the built-in set) or up to 16 layout names |
| `disabled` | layout names whose shortcut is off |
| `shortcuts` | items `{ "action": layout, "key": whole 0..127, "modifiers": [names] }`, one per action |

Layout names: `leftHalf rightHalf topHalf bottomHalf topLeft topRight bottomLeft bottomRight firstThird centerThird lastThird firstTwoThirds lastTwoThirds maximize maximizeHeight center larger smaller nextDisplay previousDisplay restore`.
Shortcut modifiers are `command`, `control`, `option`, `shift`. A shortcut needs at least one of `command`, `control`, `option`, and
cannot be ⌃⌥⇧⌘⎋ (`shortcut-safe`). `key` is a macOS virtual key code.

### `keys` (keys and mouse)

| Field | Meaning |
| --- | --- |
| `enabled`, `invertMouseWheel` | bool |
| `hid` | 0 to 8 items `{ "from": "capsLock" \| "rightCommand" \| "rightOption", "to": "f18" \| "f19" }`: the key changes Whoprrr's own presets make through macOS |
| `rules` | 0 to 500 Rules |

Rule: `{ "enabled": bool, "trigger", "mods": [names], "anyExtraMods": bool, "tap": Action, "hold"?: Action, "holdMs": whole 100..600, "scope": { "mode": "everywhere"|"only"|"except", "apps": [id] }, "layer"?: string, "layouts"?: ["ansi"|"iso"|"jis"], "keyboardTypes"?: [whole 0..255] }`.
`hold`, `layer`, `layouts` and `keyboardTypes` may be absent, never `null`. There is no `id` and no `name`: names are never shared.

- `trigger`: `{ "type": "key", "code": whole 0..127 }`, `{ "type": "mouse", "button": whole 0..15 }` (0 is the left click, 1 right, 2 middle, 3 back, 4 forward) or `{ "type": "logi", "control": whole 0..65535 }`.
- `mods` and `chord.mods`: names from `shift control option command fn`.
- `scope.apps`: up to 50 app identifiers, each `^[A-Za-z0-9][A-Za-z0-9.\-]{0,99}$`.
- `layer`, and `layer` actions' `name`: `^[A-Za-z0-9 _\-]{1,24}$` (rule `layer-name`).
- Action, by `type`:
  `chord` `{ key, mods }` ·
  `modifiers` `{ mods }` ·
  `layer` `{ name }` ·
  `media` `{ key: volumeUp volumeDown brightnessUp brightnessDown mute playPause next previous }` ·
  `mouseButton` `{ button: whole 0..15 }` ·
  `command` `{ id }` with `id` one of the list below ·
  `sequence` `{ chords: [ { key, mods } ] }` (up to 8) ·
  `nothing` `{}`.
- Commands allowed: `clipboard.open`; `system.missionControl system.appExpose system.showDesktop system.spaceLeft system.spaceRight system.spotlight system.screenshot system.screenshotTools`; `common.back common.forward common.prevTab common.nextTab common.newTab common.closeTab common.reopenTab common.switchApp common.minimize common.fullscreen common.copy common.paste common.cut common.undo common.redo common.selectAll common.top common.bottom common.pageUp common.pageDown`; and `window.` followed by a layout name. Not `system.lock`.
- The types `text`, `openURL`, `openApp` and `shell` do not exist in a shared setup. If one arrives, that is the rule `keys-no-run`.

### `clipboard`

| Field | Meaning |
| --- | --- |
| `enabled`, `captureImages`, `captureFiles`, `autoPaste`, `plainTextByDefault` | bool |
| `hotkey` | `{ "key": whole 0..127, "modifiers": [names] }`, same rules as window shortcuts |
| `maxItems` | whole, 100 to 10000 |
| `maxAgeDays` | whole, 1 to 365 days |
| `maxImageMb` | whole, 1 to 100 MB |
| `maxTextKb` | whole, 1 to 10240 KB |
| `ignoredApps` | **optional, and the Mac never writes it.** If present: up to 200 app identifiers that must include every password manager in the table below. The receiving Mac adds these to its own list and never removes one |

Password managers that are always ignored: `com.1password.1password`, `com.1password.1password7`, `com.agilebits.onepassword7`,
`com.agilebits.onepassword-osx`, `com.bitwarden.desktop`, `com.apple.keychainaccess`, `com.apple.Passwords`, `org.keepassxc.keepassxc`,
`com.dashlane.dashlanephonefinal`, `com.lastpass.lastpassmacdesktop`, `in.sinew.Enpass-Desktop`.

### `display`

`{ "monitor": gear index (role display), "values": { ... } }`. `values` holds one or more of exactly four names, all whole numbers:
`brightness` 0 to 100, `contrast` 0 to 100, `color` 1 to 4 (the tone presets; "Custom" is never shared), `sharpness` 0 to 100.
Any other name (input source, volume, red/green/blue gain, a manufacturer code like `vcpe0`, a code learned by scanning) is the rule
`display-codes`. The values apply only on a monitor of the **same model** as `gear[monitor]`.

## 5. The limits

These are the owner's numbers. The first column is the rule name a violation carries in `limit`.

| Rule | What it says | Number |
| --- | --- | --- |
| `boost-6db` | No stage of the audio or microphone chain adds more than +6 dB: every equalizer band, every pre-amp, the microphone gain, every compressor make-up gain. Cuts are not limited | **+6 dB** |
| `boost-curve` *(added)* | On one curve the pre-amp plus the biggest band boost cannot add up to more than +6 dB (the model only clamps with sliders, and the two act together) | **+6 dB** |
| `limiter-on` | `audio.effects.limiter.enabled` is `true` | on |
| `limiter-ceiling` | the limiter ceiling is no higher than the app's own default | **-1 dB** |
| `keepawake-level` | the keep-awake tone is this quiet or quieter (the app itself allows up to -20 dBFS) | **-50 dBFS** |
| `keepawake-frequency` | the keep-awake tone is inside the app's own range | **15 to 2000 Hz** |
| `display-codes` | display: only `brightness`, `contrast`, `color`, `sharpness`; applied only on the same model | 4 values |
| `keys-emergency-off` | no rule has trigger ⎋ (code 53) with `shift control option command` all in `mods` | |
| `keys-protected-key` | no rule with empty `mods` on Return (36), keypad Enter (76), Space (49), Escape (53), Tab (48), Delete (51), forward Delete (117) or an arrow (123 to 126) has `nothing` (or an empty `sequence`) as its `tap` or `hold` | |
| `keys-primary-click` | no rule has trigger `mouse` button 0 | |
| `keys-no-run`, `keys-command` | no typing, opening, launching or running; commands only from the list in section 4 | |
| `keys-hid` *(added)* | only the macOS key changes listed in section 4 | |
| `shortcut-safe` *(added)* | window shortcuts and the clipboard shortcut need ⌘, ⌃ or ⌥, and cannot be ⌃⌥⇧⌘⎋ | |
| `clipboard-ignore-list` | a shared ignore list holds every default password manager. A setup may add apps, never remove one | 11 apps |
| `size` | the document is at most this big, measured as the UTF-8 bytes of the compact JSON (`JSON.stringify(document)`) | **64 KB** (65536 bytes) |
| `text-length` | `title` 1 to 60, `line` 1 to 160, `model` 1 to 80, plugin names 1 to 40 | |

Other rule names: `format` (a `formatVersion` that is not 1), `shape` (an unknown field or part, a missing field, a wrong type, a
part and its settings that do not match, parts out of order), `range` (a number outside the app's own range or a list longer than
the app writes), `gear-role`, `gear-ref`, `no-personal-text`, `layer-name`.

The rules marked *(added)* are not in the owner's list: they close ways to hurt gear or lock a keyboard that the list did not mention.

### Which violations mean "tampered"

| Rule | tampered |
| --- | --- |
| `shape`, `range`, `gear-ref`, `display-codes`, `keys-emergency-off`, `keys-no-run`, `keys-command`, `keys-hid`, `limiter-on`, `limiter-ceiling`, `clipboard-ignore-list` | yes |
| `shortcut-safe` | yes when the shortcut is ⌃⌥⇧⌘⎋, otherwise no |
| `format`, `size`, `text-length`, `no-personal-text`, `gear-role`, `layer-name`, `boost-6db`, `boost-curve`, `keepawake-level`, `keepawake-frequency`, `keys-protected-key`, `keys-primary-click` | no |

`keepawake-frequency` is always accompanied by `range`, because the limit and the app's range are the same.

## 6. What is always left out

The Mac removes these when it makes a document, and lists what it removed so a person can see it before sending:

clipboard history and snippets · any text a key rule would type · the list of apps the clipboard ignores · serial numbers · display
IDs (EDIDs), audio device UIDs and any other identifier of a device or Mac · the names a person gave their devices (the model name is
kept) · file paths and anything under the home folder · plugin files and plugin state (plugins are named) · web addresses · shell
commands · rules that open apps · rule names · the names of display presets and their notes · installed features (which parts of
Whoprrr are on) · the audio device the equalizer follows.

The export also **switches the output limiter on and lowers its ceiling to -1 dB in the shared copy**, because the app's own
limiter is off by default and a shared setup must carry it on. The person's own recipe is never changed, and the Mac says so.

## 7. ok, ordinary, unusual, tampered

- **ok**: the checker found no violation.
- **tampered**: some violation is one the app could never have written (see the table in section 5). A tampered document is
  never ok. Do not trust anything else in it.
- **unusual**: it is ok, but it holds any of:
  - a `display` part,
  - a value within the top 10% of what a safety limit allows: a boost of **5.4 dB or more** (up to 6) in any band, pre-amp, microphone gain or make-up gain (the span is 0 to 6 dB, and 10% of it is 0.6), or a keep-awake level of **-54 dBFS or louder** (up to -50; the span is -90 to -50, and 10% of it is 4),
  - **more than 40** key and mouse rules (`keys.rules` has 41 or more).
- **ordinary**: ok and not unusual. Only an ordinary document may go on the shelf without the owner looking at it.

The checker returns `{ ok, ordinary, tampered, violations: [ { line, limit, message } ] }`. `line` is a path into the document
(`settings.audio.equalizer.curve.bands[3].gainDb`), `limit` is the rule name, `message` is one plain sentence for the person, for example:

> Equalizer: bass +18 dB at 60 Hz. Shared setups cannot boost more than +6 dB, so nobody’s speakers or ears are hurt.

The server may word `message` its own way; the vectors compare rule names only. Violations are sorted by `line`, then `limit`.

## 8. Writing the JavaScript checker

- Walk `JSON.parse(body)`. Numbers are IEEE doubles, as in Swift's `JSONValue`.
- Check an object's keys against the list in this document: an unknown key is `shape`; a missing required key is `shape`. Optional
  keys are named above; everything else is required.
- A type that is wrong (a string where a number is expected) is `shape`. A number outside its range is `range`, even when the safety
  rule also fires. Both are reported.
- Lengths are UTF-16 code units. Control characters are anything below U+0020 and U+007F.
- Personal text (`no-personal-text`), for gear models, plugin names, plugin makers: in this order, the first match names the reason:
  a string holding `://`, `www.` or `mailto:`; a string that starts with `/` or `~`, holds `\`, or holds `/Users/`, `/Library/`,
  `/Volumes/`, `/private/`, `/var/`, `/System/`, `/Applications/` or `/tmp/`; and, for gear models only: `’s ` or `'s ` followed by
  anything (a person's name), the text `serial` or `s/n` (any case), a UUID, a `:`, or a word (split on spaces) of 8 or more characters
  with 6 or more digits. Titles and descriptions are **not** checked for addresses here: the server's own rules hold those.
- `unusual` is computed in doubles: a gain-like value `x` with `x <= 6` and `x >= 6 - 0.1 * 6` (5.4), or a keep-awake level `x` with
  `x <= -50` and `x >= -50 - 0.1 * (-50 - -90)` (-54). Values above the limit are violations, not "unusual".
- `boost-6db` fires for any gain-like value above 6, whatever the range. `boost-curve` fires only when every value of the curve is
  at most 6 and `preampDb + max(0, biggest band gain)` is more than 6.
- Check `parts` before `settings`: `parts` must list exactly the keys of `settings`, in the order of section 2.
- `size` is the byte length of the compact JSON of the whole document.
- A violation of `format` ends the check. A document that is not an object is a single `shape`.

## 9. The file

A shared setup sent person to person is a file with the extension `.whoprrr-setup` (not registered with macOS yet):

```json
{ "fileVersion": 1, "madeBy": "<opaque text, up to 200 characters>", "setup": { "formatVersion": 1, "...": "the document" } }
```

No other top-level field is allowed. `madeBy` is opaque to Whoprrr (it will be a key fingerprint). Opening a file runs the checker on
`setup` and hands nothing back unless it passes. A file is at most 65536 + 1024 bytes.

## 10. Fitting on the receiving Mac

Not part of the checks, written here so the server and the app mean the same thing. Opening a shared setup shows how it fits **before
anything changes**:

- Each of the author's `gear` items gets a proposed match among the connected devices: the same role and the same model first, the
  same role otherwise, none otherwise. A person can pick another.
- Each line of the setup is then *applies*, *applies with a note*, or *switched off* with the reason in words: no matching device; a
  different speaker model (the equalizer curve is skipped and the receiver's own is kept); a different monitor model; a plugin that is
  not installed; a macOS that is too old; a permission that is not allowed.
- The result is an ordinary recipe of the receiver's own, with the author's original and the skipped lines kept so they can be switched
  on later.

## 11. Test vectors

`Tests/WhopperKitTests/Fixtures/shared-setup-vectors.json` holds the vectors; copy the file to the server's tests.

```json
{ "about": "...", "formatVersion": 1,
  "vectors": [ { "name": "...", "note": "...", "document": { }, "expect": { "ok": true, "ordinary": true, "tampered": false, "limits": [] } } ] }
```

For every vector the checker run on `document` must give: `ok`, `ordinary`, `tampered` exactly as in `expect`, and the set of rule names of
its violations, sorted and without repeats, equal to `expect.limits`. In JavaScript:

```js
for (const v of vectors.vectors) {
  const r = check(v.document)            // { ok, ordinary, tampered, violations: [{ line, limit, message }] }
  assert.equal(r.ok, v.expect.ok, v.name)
  assert.equal(r.ordinary, v.expect.ordinary, v.name)
  assert.equal(r.tampered, v.expect.tampered, v.name)
  assert.deepEqual([...new Set(r.violations.map(x => x.limit))].sort(), v.expect.limits, v.name)
}
```

The file has 134 vectors. The base documents are `ordinary-audio-only` (one part) and `full-example` (every part, section 12);
most vectors are one of those with one value changed. A few, in words (a path means "set this value in the base"):

| Vector | Change | Result |
| --- | --- | --- |
| `ordinary-audio-only` | none | ok, ordinary |
| `full-example` | none | ok, **not** ordinary (it has a display part) |
| `boost-band-exactly-6-passes` | a band at +6 dB | ok, not ordinary (within 10% of the limit) |
| `boost-band-6.01-fails` | a band at +6.01 dB | `boost-6db`, not tampered |
| `boost-band-plus-40-tampered` | a band at +40 dB | `boost-6db` and `range`, **tampered** |
| `curve-total-over-6` | pre-amp +3 and a band at +4 | `boost-curve` |
| `mic-makeup-6.01` | microphone make-up gain +6.01 dB | `boost-6db` |
| `keepawake-minus-50-passes` | tone at -50 dBFS | ok, not ordinary |
| `keepawake-minus-49.9-fails` | tone at -49.9 dBFS | `keepawake-level` |
| `keepawake-2000hz-passes` / `keepawake-2000.1hz` | 2000 Hz / 2000.1 Hz | ok / `keepawake-frequency` and `range`, tampered |
| `limiter-off` | `limiter.enabled` false | `limiter-on`, tampered |
| `display-input-switch-code` | `display.values.input` = 17 | `display-codes`, tampered |
| `keys-emergency-off-remapped` | a rule on ⌃⌥⇧⌘⎋ | `keys-emergency-off`, tampered |
| `keys-return-does-nothing` | a rule: Return, `nothing` | `keys-protected-key` |
| `keys-primary-click-swallowed` | a rule on mouse button 0 | `keys-primary-click` |
| `keys-types-text` | a rule whose tap has `type` `text` | `keys-no-run`, tampered |
| `keys-exactly-40-rules-ordinary` / `keys-41-rules-unusual` | 40 / 41 rules | ordinary / ok, not ordinary |
| `clipboard-ignore-list-removes-a-default` | `ignoredApps` without 1Password | `clipboard-ignore-list`, tampered |
| `clipboard-ignore-list-adds-an-app` | the defaults plus one app | ok, ordinary |
| `unknown-top-level-field`, `unknown-nested-field`, `unknown-part` | an extra field or part | `shape`, tampered |
| `format-version-2` | `formatVersion` 2 | `format`, not tampered |
| `title-60-passes` / `title-61` | 60 / 61 characters | ok / `text-length` |
| `keys-over-64kb` | document over 65536 bytes | `size` |
| `gear-model-has-a-persons-name` | model "Ana’s AirPods Pro" | `no-personal-text` |

A small complete vector, so the shape of one is plain (a window gap of 90 points; the app's own range is 0 to 30):

```json
{
 "document": {
  "formatVersion": 1,
  "gear": [
   {
    "model": "Edifier R1280",
    "role": "speaker"
   },
   {
    "model": "Shure MV7",
    "role": "microphone"
   },
   {
    "model": "S34CG50",
    "role": "display"
   },
   {
    "model": "MX Ergo",
    "role": "mouse"
   }
  ],
  "line": "Low volume, the right mic, windows tidied.",
  "parts": [
   "windows"
  ],
  "requirements": {
   "minMacOS": "14.2",
   "permissions": [
    "accessibility",
    "inputMonitoring",
    "microphone",
    "systemAudio"
   ],
   "plugins": [
    "Pro-Q 3"
   ]
  },
  "settings": {
   "windows": {
    "cycleHalves": true,
    "disabled": [],
    "drawer": [
     "leftHalf",
     "rightHalf",
     "maximize"
    ],
    "gapPoints": 90,
    "shortcuts": [
     {
      "action": "maximize",
      "key": 36,
      "modifiers": [
       "control",
       "option"
      ]
     }
    ],
    "shortcutsEnabled": true,
    "snapByDrag": true
   }
  },
  "title": "Quiet desk"
 },
 "expect": {
  "limits": [
   "range"
  ],
  "ok": false,
  "ordinary": false,
  "tampered": true
 },
 "name": "windows-gap-90"
}
```

## 12. A complete example

Every part, every field. It is the vector `full-example`, and a test checks that this block is that vector, byte for byte after parsing.

```json
{
  "formatVersion": 1,
  "gear": [
    {
      "model": "Edifier R1280",
      "role": "speaker"
    },
    {
      "model": "Shure MV7",
      "role": "microphone"
    },
    {
      "model": "S34CG50",
      "role": "display"
    },
    {
      "model": "MX Ergo",
      "role": "mouse"
    }
  ],
  "line": "Low volume, the right mic, windows tidied.",
  "parts": [
    "audio",
    "microphone",
    "windows",
    "keys",
    "clipboard",
    "display"
  ],
  "requirements": {
    "minMacOS": "14.2",
    "permissions": [
      "accessibility",
      "inputMonitoring",
      "microphone",
      "systemAudio"
    ],
    "plugins": [
      "Pro-Q 3"
    ]
  },
  "settings": {
    "audio": {
      "effects": {
        "compressor": {
          "attackMs": 8,
          "enabled": false,
          "makeupDb": 3,
          "ratio": 3,
          "releaseMs": 150,
          "thresholdDb": -20
        },
        "limiter": {
          "ceilingDb": -1,
          "enabled": true,
          "releaseMs": 80
        },
        "plugins": [
          {
            "enabled": true,
            "maker": "FabFilter",
            "name": "Pro-Q 3"
          }
        ]
      },
      "equalizer": {
        "curve": {
          "bands": [
            {
              "gainDb": 4,
              "hz": 32,
              "kind": "peak",
              "q": 1.41
            },
            {
              "gainDb": 3,
              "hz": 64,
              "kind": "peak",
              "q": 1.41
            },
            {
              "gainDb": 2,
              "hz": 125,
              "kind": "peak",
              "q": 1.41
            },
            {
              "gainDb": 0,
              "hz": 250,
              "kind": "peak",
              "q": 1.41
            },
            {
              "gainDb": 0,
              "hz": 500,
              "kind": "peak",
              "q": 1.41
            },
            {
              "gainDb": 0,
              "hz": 1000,
              "kind": "peak",
              "q": 1.41
            },
            {
              "gainDb": 0,
              "hz": 2000,
              "kind": "peak",
              "q": 1.41
            },
            {
              "gainDb": 1,
              "hz": 4000,
              "kind": "peak",
              "q": 1.41
            },
            {
              "gainDb": 2,
              "hz": 8000,
              "kind": "peak",
              "q": 1.41
            },
            {
              "gainDb": 2,
              "hz": 16000,
              "kind": "peak",
              "q": 1.41
            }
          ],
          "enabled": true,
          "preampDb": -3
        },
        "enabled": true,
        "speakerCurves": [
          {
            "curve": {
              "bands": [
                {
                  "gainDb": 3,
                  "hz": 32,
                  "kind": "peak",
                  "q": 1.41
                },
                {
                  "gainDb": 2,
                  "hz": 64,
                  "kind": "peak",
                  "q": 1.41
                },
                {
                  "gainDb": 1,
                  "hz": 125,
                  "kind": "peak",
                  "q": 1.41
                },
                {
                  "gainDb": 0,
                  "hz": 250,
                  "kind": "peak",
                  "q": 1.41
                },
                {
                  "gainDb": 0,
                  "hz": 500,
                  "kind": "peak",
                  "q": 1.41
                },
                {
                  "gainDb": 0,
                  "hz": 1000,
                  "kind": "peak",
                  "q": 1.41
                },
                {
                  "gainDb": 0,
                  "hz": 2000,
                  "kind": "peak",
                  "q": 1.41
                },
                {
                  "gainDb": 0,
                  "hz": 4000,
                  "kind": "peak",
                  "q": 1.41
                },
                {
                  "gainDb": 1,
                  "hz": 8000,
                  "kind": "peak",
                  "q": 1.41
                },
                {
                  "gainDb": 1,
                  "hz": 16000,
                  "kind": "peak",
                  "q": 1.41
                }
              ],
              "enabled": true,
              "preampDb": -2
            },
            "gear": 0
          }
        ]
      },
      "keepAwake": [
        {
          "burstSeconds": 0.5,
          "enabled": true,
          "frequencyHz": 40,
          "gear": 0,
          "levelDb": -60,
          "pulseEverySeconds": 0
        }
      ],
      "keepInput": {
        "enabled": true,
        "gear": [
          1
        ]
      }
    },
    "clipboard": {
      "autoPaste": true,
      "captureFiles": true,
      "captureImages": true,
      "enabled": true,
      "hotkey": {
        "key": 9,
        "modifiers": [
          "command",
          "control"
        ]
      },
      "maxAgeDays": 30,
      "maxImageMb": 20,
      "maxItems": 1000,
      "maxTextKb": 1024,
      "plainTextByDefault": false
    },
    "display": {
      "monitor": 2,
      "values": {
        "brightness": 40,
        "color": 2,
        "contrast": 60,
        "sharpness": 5
      }
    },
    "keys": {
      "enabled": true,
      "hid": [
        {
          "from": "capsLock",
          "to": "f18"
        }
      ],
      "invertMouseWheel": false,
      "rules": [
        {
          "anyExtraMods": false,
          "enabled": true,
          "hold": {
            "mods": [
              "control"
            ],
            "type": "modifiers"
          },
          "holdMs": 200,
          "mods": [],
          "scope": {
            "apps": [],
            "mode": "everywhere"
          },
          "tap": {
            "key": 53,
            "mods": [],
            "type": "chord"
          },
          "trigger": {
            "code": 79,
            "type": "key"
          }
        },
        {
          "anyExtraMods": false,
          "enabled": true,
          "holdMs": 200,
          "mods": [],
          "scope": {
            "apps": [],
            "mode": "everywhere"
          },
          "tap": {
            "id": "common.back",
            "type": "command"
          },
          "trigger": {
            "button": 3,
            "type": "mouse"
          }
        },
        {
          "anyExtraMods": false,
          "enabled": true,
          "holdMs": 200,
          "mods": [],
          "scope": {
            "apps": [],
            "mode": "everywhere"
          },
          "tap": {
            "id": "clipboard.open",
            "type": "command"
          },
          "trigger": {
            "control": 237,
            "type": "logi"
          }
        }
      ]
    },
    "microphone": {
      "compressor": {
        "attackMs": 8,
        "enabled": true,
        "makeupDb": 3,
        "ratio": 3,
        "releaseMs": 150,
        "thresholdDb": -20
      },
      "enabled": true,
      "equalizer": {
        "bands": [
          {
            "gainDb": 0,
            "hz": 32,
            "kind": "peak",
            "q": 1.41
          },
          {
            "gainDb": 0,
            "hz": 64,
            "kind": "peak",
            "q": 1.41
          },
          {
            "gainDb": 0,
            "hz": 125,
            "kind": "peak",
            "q": 1.41
          },
          {
            "gainDb": 0,
            "hz": 250,
            "kind": "peak",
            "q": 1.41
          },
          {
            "gainDb": 0,
            "hz": 500,
            "kind": "peak",
            "q": 1.41
          },
          {
            "gainDb": 0,
            "hz": 1000,
            "kind": "peak",
            "q": 1.41
          },
          {
            "gainDb": 0,
            "hz": 2000,
            "kind": "peak",
            "q": 1.41
          },
          {
            "gainDb": 3,
            "hz": 4000,
            "kind": "peak",
            "q": 1.41
          },
          {
            "gainDb": 0,
            "hz": 8000,
            "kind": "peak",
            "q": 1.41
          },
          {
            "gainDb": 0,
            "hz": 16000,
            "kind": "peak",
            "q": 1.41
          }
        ],
        "enabled": true,
        "preampDb": 0
      },
      "gainDb": 3,
      "gate": {
        "attackMs": 3,
        "enabled": false,
        "releaseMs": 120,
        "thresholdDb": -55
      },
      "highPass": {
        "enabled": true,
        "hz": 80
      },
      "plugins": [],
      "source": 1
    },
    "windows": {
      "cycleHalves": true,
      "disabled": [],
      "drawer": [
        "leftHalf",
        "rightHalf",
        "maximize"
      ],
      "gapPoints": 8,
      "shortcuts": [
        {
          "action": "maximize",
          "key": 36,
          "modifiers": [
            "control",
            "option"
          ]
        }
      ],
      "shortcutsEnabled": true,
      "snapByDrag": true
    }
  },
  "title": "Quiet desk"
}
```
