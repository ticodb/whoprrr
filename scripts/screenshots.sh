#!/bin/zsh
# Regenerates docs/screenshots/*.png from sample data. Never touches your real settings: it runs the debug build with
# WHOPPER_DEMO=1 and a temporary WHOPPER_DATA_DIR. Quits a running Whoprrr first (they would fight over shortcuts) and
# relaunches it at the end. Needs the screen-recording permission for your terminal to capture windows.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Whopper
swiftc scripts/window-id.swift -o /tmp/whoprrr-window-id
BIN=.build/debug/Whopper
DATA="$(mktemp -d)"
OUT=docs/screenshots; mkdir -p "$OUT"
WAS_RUNNING=0; pgrep -x Whoprrr >/dev/null && WAS_RUNNING=1
osascript -e 'tell application id "gg.tico.whopper" to quit' 2>/dev/null || true; sleep 2; pkill -x Whoprrr 2>/dev/null || true

shot() {  # name view page appearance wait-seconds
  WHOPPER_DEMO=1 WHOPPER_DATA_DIR="$DATA" WHOPPER_APPEARANCE="$4" WHOPPER_VIEW="$2" WHOPPER_PAGE="$3" SDC_DEBUG_WINDOW=1 "$BIN" >/dev/null 2>&1 &
  local pid=$!
  sleep "$5"
  local id; id="$(/tmp/whoprrr-window-id | awk '/^[0-9]+ \{/{print $1}' | head -1)"
  screencapture -x -l "$id" "$OUT/$1.png"
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; sleep 1
}

shot recipes-dark   main  recipes  dark  16     # first run seeds the sample data
shot recipes-light  main  recipes  light 9
shot menu-bar-dark  quick x        dark  9
shot menu-bar-light quick x        light 9
shot keys-and-mouse main  remap    dark  9
shot audio          main  audio    dark  11
shot windows        main  windows  dark  9
shot about          main  about    dark  8

rm -rf "$DATA"
(( WAS_RUNNING )) && open /Applications/Whoprrr.app
ls -la "$OUT"
