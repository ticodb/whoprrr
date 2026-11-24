# Hardware probe record

Run 2026-11-23 on the target machine. Identifiers redacted (`uuid#…`).

## Environment
- MacBook Air M1 (arm64), macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2.
- Display seen by macOS: `S34CG50` (vendor 19501 / model 29455), 3440x1440 @ 100 Hz, plus the built-in Color LCD.
- Chain as reported by the tester: M1 → USB-C → Anker hub → DisplayPort → Samsung. The full rear-label SKU has **not** been verified.

## Probe 1: upstream m1ddc (read-only)
Pinned `waydabber/m1ddc@9d75fb6c407ac60dc77a9e32c43d60fd0e6d1612`, built with `make`.

| Command | Exit | Result | Latency |
|---|---|---|---|
| `display list detailed` | 0 | Samsung is a unique match (uuid selector); built-in listed separately | n/a |
| `get luminance` / `max luminance` | 0 | 100 / 100 | ~165 ms |
| `get/max contrast` | 0 | 60 / 100 | ~165 ms |
| `get red/green/blue` | 0 | 56 / 56 / 63 (max 100) | ~165 ms |
| `get input` | 0 | 15 (DP 1) | ~165 ms |

**Conclusion: the current hub path (Anker → DisplayPort) returns valid DDC/CI replies.** No direct USB-C→DP comparison was needed or run; it stays *pending / not tested*.
(The first scripted attempt failed with "Missing parameter" because zsh did not word-split a variable. That was a harness bug, not a hardware result.)

## Probe 2: this repo's `ddcprobe` (CDDC transport + DisplayController)
Same values as m1ddc; ~80-88 ms per read with a 50 ms read wait.

Bounded brightness write (`ddcprobe brightness-test --yes --delta -10 --hold 6`):
baseline 100/100 → wrote 90 → readback 90 (verified) → held 6 s → restored 100 → readback 100 (verified). Final state re-read: 100.

## Probe 3: full DDC scan and per-control write proofs (2026-11-23)
`ddcprobe scan` (read-only, 256 codes, ~22 s): **51 codes answer.** Standard ones: 0x10 brightness, 0x12 contrast, 0x14 color preset,
0x16/18/1A RGB gain, 0x60 input, 0x62 volume, 0x87 sharpness, 0xD6 power, 0xDF VCP version 2.2. The rest (0x23, 0x25, 0x2B-0x2E, 0xDB, 0xDC,
0xE0-0xFE ...) are Samsung-specific and undocumented; the app's **Learn** tab maps them by diffing scans while an OSD item is changed.

Write proofs (`ddcprobe write-test <code> --yes`: baseline, small change, readback, restore, readback). All restored to the original values.

| Control | Result |
|---|---|
| Brightness 0x10 | 100 → 90 → 100, verified |
| Contrast 0x12 | 60 → 55 → 60, verified |
| Red / Green / Blue 0x16/18/1A | 56 → 51 → 56, 56 → 51 → 56, 63 → 58 → 63, verified |
| Sharpness 0x87 | wrote 51, display settled on **48**: it moves in steps of ~8. Accepted ("adjusted"), restore 56 verified |
| Volume 0x62 | 80 → 75 → 80, verified |
| Input 0x60 | same-value write (15 → 15) verified. A real switch was **not** tested |
| Color preset 0x14 | values 1-4 selectable and verified (see below); **5 is rejected** |

**Color tone model (measured):** the monitor was in tone value **5 = Custom** (user RGB 56/56/63). Selecting a preset overrides the RGB gains:

| 0x14 | RGB gains | Likely OSD name (derived from the gains) |
|---|---|---|
| 1 | 33 / 40 / 50 | Cool |
| 2 | 50 / 50 / 50 | Normal |
| 3 | 50 / 45 / 30 | Warm 1 |
| 4 | 50 / 31 / 6 | Warm 2 |
| 5 | user values | Custom |

Writing 5 to 0x14 is silently refused (readback stays at the old preset); writing any RGB gain switches the tone back to Custom.
This is how the test run returned the monitor to Custom 56/56/63. The color preset also reports max=4 while using 5, so **reported max is
unreliable for choice controls**; the controller bounds them with the catalogue instead.

**Bug found and fixed during testing:** the controller clamped writes to the reported max, so restoring tone 5 failed and left the monitor on
preset 4 until RGB gains were rewritten by hand. Fixed, with a regression test.

## Still unverified (needs a human)
- **Samsung OSD value during the hold was not checked.** DDC readback proves the monitor reports 90; it is not the OSD check the spec asks for. Run `ddcprobe brightness-test --yes --hold 15` and watch the OSD/panel.
- A real input switch (DP 1 → another input) and whether the OSD labels for tone 1-4 match "Cool / Normal / Warm 1 / Warm 2".
- Direct USB-C → DisplayPort comparison, HDMI path, sleep/wake and unplug behaviour on real hardware.
