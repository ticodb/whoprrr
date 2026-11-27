# Permissions: what each one is for

The proposed recipe shows the grants it needs as you switch lines on and off. Setup takes you through those grants one at a time. A small Whoprrr card stays beside System Settings and brings you back when it sees the change.

Choose **Not now** to park the features that need that grant. Their settings stay saved. Use **Continue** in the menu bar or open the feature’s page to pick up again.

After the switches, **Taste test** tries the features. **Permissions** shows what uses each grant and whether the check worked. **Reset and ask again** clears that service for Whoprrr when macOS supports it. **Open the switch for me** never resets anything; only that button does. After two resets you can park the feature and copy diagnostics.

| Permission | Used by | Why |
|---|---|---|
| **Accessibility** | Windows, Keys and mouse | To move and resize other apps' windows, and to post the key and mouse events your rules produce. |
| **Input Monitoring** | Keys and mouse | To see keys and buttons so rules can match them. Choose **Quit & Reopen** when asked. Setup comes back to the same step. |
| **System Audio Recording** | Audio (equalizer, effects) | A short chime starts the equalizer and gives you a chance to choose **Allow**. Audio is processed live. |
| **Microphone** | Microphone | Choose **Allow**, then speak during the taste test so Whoprrr can check the level. |
| **Camera** | External displays (matching) | Only when you run camera-assisted matching, to see both screens at once. Frames are analysed in memory and discarded. |
| **Paste from Other Apps** (macOS 15.4 and newer) | Clipboard | Setup asks you to choose **Always Allow** in System Settings → Privacy & Security → Paste from Other Apps. If you keep **Ask**, clipboard history still runs and macOS asks as before; only **Deny** pauses it. |
| **Whoprrr Mic driver** | Microphone | Install it with your Mac password. Setup waits for Whoprrr Mic to appear among the inputs. Some Macs need a restart. |

## Things macOS does not let any app do

- Remap keys typed into **secure fields** (passwords) or at the login window. Only a signed system extension can; Whoprrr is not one.
- Read System Audio Recording through a public preflight API. After an update, Whoprrr relies on the equalizer having heard sound before; it never pauses the equalizer for this grant on its own.

## After an update

The first launch of a new build checks quietly while your features run as usual. It only reads grant states and runs checks that can't show a macOS prompt or press keys. A feature is paused only when a grant it needs is clearly off (switched off or denied, or Accessibility or Input Monitoring no longer granted) or its own check fails with the grant on. The check gives up after a few seconds and says so in the menu-bar panel. It writes nothing, not even to the clipboard, and an external display that doesn't answer is reported as not checked. If a grant needs renewing, the renewal window appears without taking focus from the app you are typing in. System Settings, the guide card and any macOS prompt start only when you press **Renew**.
