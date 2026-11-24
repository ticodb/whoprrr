# Automated matcher

**Status: built and tested in simulation; not yet run against a real camera.** Accuracy goal is "good enough that nobody fiddles
with the OSD", not metrology.

## How it works (Match tab → "Match Samsung to MacBook")
1. A camera that sees **both screens at once** (iPhone via Continuity Camera, or a webcam such as the Insta360 Link 2) stays still.
   Measuring both screens in the *same frame* means the camera's auto-exposure and white balance affect both equally, so only the
   ratio between the screens matters. No colorimeter, no manual camera settings.
2. **Locate:** Samsung full-screen white (MacBook black), then the reverse. The largest bright area in each frame is that display.
3. **Measure:** both screens show sRGB 50 % gray (bright enough to read, far from clipping). Average linear RGB of each screen's inner area, 3 frames.
4. **Adjust the Samsung only**, every write read back:
   - R and B gain toward the MacBook's R/G and B/G ratios (green is the reference); writing RGB also puts the monitor in Custom tone.
   - Brightness to equalise luminance, after predicting the effect of the gain change.
   - Steps are damped; the loop repeats until luminance < 5 % and chroma < 3 % off, or 8 rounds.
5. Reports "Samsung is at maximum brightness and still dimmer than the MacBook" when it runs out of range.
6. **Undo** restores the earlier values (including re-entering Custom tone correctly).
Esc or Cancel stops at any time and closes the patch windows. Stale connection (unplug/sleep) stops the run with no further writes.

## Tested (simulation, `swift test`)
Frame analyzer on synthetic frames; engine steps; closed loop against a simulated Samsung that responds to real DDC writes through the fake
transport: converges in ~5 rounds from a blue-leaning, 37 %-too-bright start **with a deliberately wrong response model**; converges from too dim;
reports the too-dim limit; undo; overlapping/missing screens; overexposed camera; stale target; cancellation closes patches. Only the Samsung's
brightness and RGB gains are ever written.

## Not tested (needs the real camera and screens)
Continuity Camera / webcam capture and permission prompt, full-screen patch windows on both panels, real response of the S34CG50 gains to the
engine's gamma-2.2 model (damping should absorb it), viewing-angle effects (the Samsung is a curved VA panel: keep the camera roughly centred
and the same distance from both), True Tone / auto-brightness drift on the MacBook (disable True Tone while matching).

## Next
- Run it once for real, then consider a second measurement pass at a dark gray for contrast/black level.
- Optional automatic trigger after wake or reconnect (not enabled: it would flash full-screen patches unprompted and needs the camera present).
