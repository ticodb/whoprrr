# Uninstall

The easy way: `scripts/uninstall.sh` (asks before each step).

By hand:

1. Quit Whoprrr (menu-bar panel → Quit). Remaps made with `hidutil` are cleared on quit; to be sure run `hidutil property --set '{"UserKeyMapping":[]}'`.
2. If you installed the virtual mic: Microphone → **Remove…**, or `sudo rm -rf /Library/Audio/Plug-Ins/HAL/WhopperMic.driver && sudo killall coreaudiod`.
3. Delete `/Applications/Whoprrr.app`.
4. Delete your data: `~/Library/Application Support/Whopper` and `~/Library/Application Support/SamsungDisplayControl`.
5. Remove the *Open at login* entry if you enabled it (System Settings → General → Login Items).
6. Remove Whoprrr from Accessibility, Input Monitoring, System Audio Recording, Microphone and Camera in System Settings → Privacy & Security.
