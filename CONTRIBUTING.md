# Contributing

Thank you for helping. Whoprrr is a one-person project in public beta; small, focused contributions are the easiest to review.

## Ways to help

- **Report hardware results.** The most valuable thing right now: which displays, keyboards, mice, microphones and plugins work or do not. Use the issue forms; "Report a problem" in the app's About page copies a safe diagnostics summary.
- **Fix bugs and add tests.**
- **Improve docs.**
- Discuss big features in an issue before writing a lot of code.

## The licensing rule

Whoprrr is MIT licensed. **Do not copy code from GPL (or other copyleft) projects**: not Solaar, Vorssaint, BlackHole, nor anything else. Reading their documentation for protocol details is fine; pasting or closely translating their code is not. If you used outside code, say where it came from and under what license in the pull request, and we will decide whether it can go in. New third-party code must be listed in `THIRD_PARTY_LICENSES.md`.

## Setup

```sh
git clone https://github.com/ticodb/whoprrr.git && cd whoprrr
swift test
./scripts/build-app.sh && open build/Whoprrr.app
```

Needs macOS 14.2+ and a Swift 6 toolchain (Xcode 16 or newer). See [docs/building.md](docs/building.md).

## How the code is organised

Each feature is a library with no UI and a fake backend for tests (`DisplayCore`, `WindowCore`, `ClipboardCore`, `InputCore`, `LogitechCore`, `AudioCore`), plus `WhopperKit` (shared plumbing) and the SwiftUI app in `Sources/Whopper`. Read [docs/architecture.md](docs/architecture.md) first.

## Pull requests

- One change per pull request; explain *why*.
- **Add or update tests** for logic. Tests must not touch real hardware, change system settings or need permissions; use the fakes.
- Anything that writes to hardware or intercepts input needs a safety story: how does it stay recoverable if the app crashes?
- Keep user-visible text plain and short (see the voice section of the [brand manual](docs/brand/brand-manual.html)). Nothing in the interface smaller than 12 pt.
- Run `swift test` before you push. CI runs it again on macOS.
- Do not commit personal data: device serials, UUIDs, clipboard contents, paths under `/Users/...`.

## Names

The module and bundle identifiers still use the project's original working name (`Whopper`, `gg.tico.whopper`) on purpose so existing installs keep their permissions and data. Do not rename them in unrelated changes.

By contributing you agree that your work is released under the MIT License.
