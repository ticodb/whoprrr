# Upstream provenance

Files in this directory are copied **unmodified** from
[waydabber/m1ddc](https://github.com/waydabber/m1ddc), commit
`9d75fb6c407ac60dc77a9e32c43d60fd0e6d1612` (2026-11-21, "Fix --read-wait argument handling and update CLI documentation (#82)"),
MIT License, Copyright (c) 2021 waydabber (see `LICENSE-m1ddc`).

Copied: `ioregistry.{h,m}`, `i2c.{h,m}`, `utils.h`.
Not copied: `avservice.{h,m}` (direct sink enumeration, out of scope for v1) and `m1ddc.m` (the CLI).

The transport relies on private macOS symbols (`IOAVService*`, `CoreDisplay_DisplayCreateInfoDictionary`).
They can change between macOS releases; re-validate on the target machine after each OS update.

All project-specific code lives one level up in `../CDDC.m` and `../include/CDDC.h`.
