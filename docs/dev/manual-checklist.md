# Manual checklist: M1 + Anker hub + Samsung S34CG50

Mark each result as hardware (H) or fake (F); logs carry the transport tag.

- [ ] `ddcprobe list` shows exactly one external display with `ddcEndpoint=true`.
- [ ] `ddcprobe read` returns plausible brightness/max. Note latency.
- [ ] `ddcprobe brightness-test --yes --hold 15`: **the Samsung OSD shows the probe value during the hold and the original after restore.**
- [ ] App: choose Samsung on Control tab. Slider is disabled until a valid read. Release the slider: status says "verified".
- [ ] MacBook display is selectable but shows no controls; no write is ever sent to it.
- [ ] Unplug DisplayPort/USB-C mid-drag: slider disables, status asks to reselect, no write appears on another display. Diagnostics shows topology events.
- [ ] Replug: the app rescans, re-reads (read-only) and re-enables controls. Brightness is unchanged from before replug.
- [ ] Sleep then wake: Diagnostics shows sleep/wake events, controls re-read first, no preset applied.
- [ ] Match tab: pattern opens on both displays, windows are movable.
- [ ] Save a preset, quit, relaunch: preset is listed for the Samsung. Preview shows brightness "will apply", others "skipped".
- [ ] Apply, then "Restore values from before apply" returns brightness to its prior value (readback verified).
- [ ] Mark blackout, then Export redacted: file contains no UUID or serial.
- [ ] Reproduce the "No Signal" problem on HDMI vs DisplayPort and record whether any event appeared.

## Auto match (camera)
- [ ] Match tab lists your camera(s). Allow the camera prompt on first use.
- [ ] "Preview camera": both screens fully visible, image steady (turn off Studio Light / Center Stage / tracking).
- [ ] Press "Match Samsung to MacBook": screens flash white one at a time, then gray; log shows rounds shrinking toward 0 %.
- [ ] Final state looks matched side by side. Status says matched, or names the limit (e.g. Samsung too dim).
- [ ] Esc during a run closes the patches immediately; values written so far stay until you press Undo.
- [ ] Undo returns brightness and RGB (and tone: Custom) to what they were before.
- [ ] Unplug the Samsung mid-run: the run stops, no error dialogs, no writes to the MacBook.
