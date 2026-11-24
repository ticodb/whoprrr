# Building from source

Requirements: macOS 14.2+, a Swift 6 toolchain (Xcode 16 or newer, or the matching command-line tools).

```sh
git clone https://github.com/ticodb/whoprrr.git && cd whoprrr
swift build            # debug build of everything
swift test             # all unit tests; none touches real hardware or needs permissions
./scripts/build-app.sh # build/Whoprrr.app (also builds and embeds the Whoprrr Mic driver)
open build/Whoprrr.app
```

## Signing and permissions

macOS ties permission grants (Accessibility, Input Monitoring…) to an app's code signature. An ad-hoc signature changes with every build, so you would re-grant after each rebuild. For development create a stable local identity once:

```sh
./scripts/make-signing-identity.sh   # self-signed "Whopper Local Signing" certificate in your login keychain
```

`build-app.sh` then uses it automatically. Force ad-hoc with `SIGN_IDENTITY="-"`; use a real certificate with `SIGN_IDENTITY="Developer ID Application: …"` (see [releasing.md](releasing.md)).

## Useful pieces

| Command | What |
|---|---|
| `swift run audioprobe list` | List audio devices; also `pin`, `keepalive`, `tap`, `plugins [name]` (loads Audio Units and pushes a test tone through them) |
| `swift run windowprobe` / `clipprobe` / `inputprobe` / `logiprobe` / `ddcprobe` | Read-mostly probes that check the real system without the UI. `logiprobe --divert <cid,…> 5 <seconds>` and `--query <cid>` are diagnostics for Logitech buttons |
| `./Driver/build-driver.sh` then `clang -o Driver/build/driver_test Driver/test/driver_test.c -framework CoreAudio -framework CoreFoundation && Driver/build/driver_test Driver/build/WhopperMic.driver` | Build the virtual-mic driver and run its simulator tests |
| `WHOPPER_TEST_PLUGINS=1 swift test --filter PluginSweep` | Opt-in sweep over every installed effect plugin |
| `SDC_FAKE=1` | Fake display transport (no hardware writes) |
| `WHOPPER_NO_START=1` | Start the UI without starting any background feature |
| `SDC_DEBUG_WINDOW=1` (`WHOPPER_VIEW=quick`, `WHOPPER_PAGE=remap`) | Show a view in a normal window, for screenshots and debugging |
| `WHOPPER_RENDER_ICON=<dir>` | Render the app icon set and logo PNGs from the SwiftUI artwork |
| `scripts/screenshots.sh` | Regenerate `docs/screenshots/` from sample data (`WHOPPER_DEMO=1` + a temporary `WHOPPER_DATA_DIR`; never touches real settings) |
| `WHOPPER_DATA_DIR=<dir>` | Point the app at another settings folder to try things safely |
| `python3 scripts/brand/gen_manual.py` | Regenerate the brand manual, SVG assets and tokens |

## Layout

See [architecture.md](architecture.md).

## Names

The package, module and bundle identifiers keep the project's original working name (`Whopper`, bundle id `gg.tico.whopper`) so that grants and data survive renames of the product. The product name is *Whoprrr*.
