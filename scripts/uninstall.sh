#!/bin/zsh
# Removes Whoprrr from this Mac. Asks before each step. Safe to run twice.
set -u
yes_no() { read -q "REPLY?$1 [y/N] "; echo; [[ "$REPLY" == "y" ]]; }

echo "Whoprrr uninstaller"
osascript -e 'tell application id "gg.tico.whopper" to quit' 2>/dev/null; sleep 1; pkill -x Whoprrr 2>/dev/null

# Key replacements made with hidutil (Caps Lock etc.) are normally removed on quit; make sure.
hidutil property --set '{"UserKeyMapping":[]}' >/dev/null 2>&1 && echo "Cleared key replacements."

if [[ -e /Library/Audio/Plug-Ins/HAL/WhopperMic.driver ]] && yes_no "Remove the Whoprrr Mic driver (needs your password; audio restarts briefly)?"; then
  sudo rm -rf /Library/Audio/Plug-Ins/HAL/WhopperMic.driver && sudo killall coreaudiod && echo "Driver removed."
fi
if [[ -d /Applications/Whoprrr.app ]] && yes_no "Move /Applications/Whoprrr.app to the Trash?"; then
  osascript -e 'tell application "Finder" to delete POSIX file "/Applications/Whoprrr.app"' >/dev/null && echo "App moved to the Trash."
fi
DATA="$HOME/Library/Application Support/Whopper"
if [[ -d "$DATA" ]] && yes_no "Delete your Whoprrr data (rules, recipes, presets, clipboard history) in $DATA?"; then
  rm -rf "$DATA" && echo "Data deleted."
fi
DISPLAYDATA="$HOME/Library/Application Support/SamsungDisplayControl"
if [[ -d "$DISPLAYDATA" ]] && yes_no "Delete your saved display presets in $DISPLAYDATA?"; then
  rm -rf "$DISPLAYDATA" && echo "Display data deleted."
fi
defaults delete gg.tico.whopper >/dev/null 2>&1 && echo "Preferences deleted."
echo "Done. Permission entries (Accessibility, Input Monitoring…) can be removed in System Settings > Privacy & Security."
