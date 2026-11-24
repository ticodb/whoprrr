# Permissions: what each one is for

Whoprrr never asks for a permission a feature you switched off would need. The **Permissions** page shows which feature uses which grant and flags grants nothing uses any more.

| Permission | Used by | Why |
|---|---|---|
| **Accessibility** | Windows, Keys and mouse | To move and resize other apps' windows, and to post the key and mouse events your rules produce. |
| **Input Monitoring** | Keys and mouse | To see key presses and mouse buttons so rules can match them, and to talk to Logitech devices over HID++. Whoprrr never stores or sends what you type. |
| **System Audio Recording** | Audio (equalizer, effects) | To capture what your apps play, process it, and send it to your speakers. Audio is not recorded. |
| **Microphone** | Microphone | To read your real mic so it can be processed and sent to Whoprrr Mic. |
| **Camera** | External displays (matching) | Only when you run camera-assisted matching, to see both screens at once. Frames are analysed in memory and discarded. |
| **Paste from Other Apps** (macOS 15.4 and newer) | Clipboard | macOS asks whenever an app reads the clipboard in the background. Set Whoprrr to **Always Allow** in System Settings → Privacy & Security → Paste from Other Apps. |
| **Administrator password** | Microphone → Install | Not a privacy permission: writing the driver into `/Library/Audio/Plug-Ins/HAL/` needs it. Once. |

## Things macOS does not let any app do

- Remap keys typed into **secure fields** (passwords) or at the login window. Only a signed system extension can; Whoprrr is not one.
- Read Accessibility or Input Monitoring status reliably from outside; if a switch looks on but nothing works, toggle it off and on.
