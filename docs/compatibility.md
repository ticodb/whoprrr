# Compatibility

This is an honest table of what has been **verified on real hardware** and what has not. If you test something, please [report it](../../../issues/new/choose).

Reference setup used for development: MacBook Air (M1), macOS 27.2.1, Samsung S34CG50 on DisplayPort through a USB-C hub, Logitech MX Keys S (Bolt receiver), Logitech MX Ergo (Unifying receiver), RØDE PodMic USB, a Bluetooth speaker.

| Area | Verified | Not verified |
|---|---|---|
| macOS | 27.2.x on Apple Silicon | macOS 14.2 to 26, Intel Macs |
| Display control | Samsung S34CG50 over DisplayPort (brightness, contrast, RGB, input read) | Other Samsung models, other brands, HDMI, direct USB-C |
| Windows | Moving and resizing through the Accessibility API; geometry unit tests | Many third-party apps; Stage Manager edge cases |
| Clipboard | Capture, search, concealed-copy skipping, write-back | Very large images/files; every password manager |
| Keys and mouse | Rule engine (unit tests), `hidutil` mappings, Logitech HID++ for MX Keys S and MX Ergo | Other keyboards and mice; non-US layouts beyond the layout classes |
| Logitech | MX Keys S, MX Ergo via Bolt/Unifying | Bluetooth-direct connections, other models |
| System audio | Equalizer, compressor, limiter and Audio Unit plugins on the built-in speakers | Bluetooth and USB outputs under heavy use, aggregate devices |
| Audio Unit plugins | 102 of 124 installed effect plugins load and process | VST/VST3-only plugins (not supported), mono-only plugins |
| Whoprrr Mic | Driver against a simulated host and installed on the reference Mac | Other Macs and macOS versions, apps with unusual capture code |
| Recipes | Capture/apply logic (unit tests), gear detection | Long-term use with many recipes |

Whoprrr uses a few private macOS interfaces (the display DDC transport, Mission Control's Dock notification). A macOS update can break them. It is not eligible for the Mac App Store.
