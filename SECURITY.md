# Security policy

Whoprrr is a beta. It runs with powerful permissions (Accessibility, Input Monitoring, System Audio Recording), installs an audio driver on request, and loads Audio Unit plugins, so security reports are welcome and taken seriously.

## Reporting a vulnerability

Please **do not open a public issue** for a vulnerability. Use GitHub's private reporting: the repository's **Security** tab → **Report a vulnerability**. Include what you found, how to reproduce it, and the macOS and Whoprrr versions.

You can expect an acknowledgement within a few days. This is a small project run by one person, so fixes are best-effort, but anything that lets another app or user abuse Whoprrr's permissions goes to the front of the queue.

## What is in scope

- Ways another process could abuse Whoprrr's permissions (for example through its settings files, the driver, or shell-command rules).
- Mistakes in the driver installer (it runs with administrator rights).
- Leaks of clipboard contents or other private data.
- Anything that could leave the Mac in a bad state (stuck keys, buttons that stay taken over, dead audio).

## Things to know

- Shell-command rules run exactly what you wrote, as you. Treat imported rule files like scripts: read them first.
- Settings and the clipboard database are unencrypted files owned by your user.
- Audio Unit plugins are third-party code. They run in a separate process by default; "Run inside Whoprrr" loads them in the app, where a faulty or malicious plugin has the app's permissions. Only use plugins you trust.
- Beta builds are not notarized, so macOS cannot check them for you. Download only from this repository's Releases and compare the `SHA256SUMS` file.
