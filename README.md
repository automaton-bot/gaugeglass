# Gaugeglass

Independent instrument-panel app in development for Bluetooth HVAC equipment. Intended everyday workflow: open, reconnect to saved devices, and see fresh measurements immediately. Not affiliated with or endorsed by NAVAC.

## Current milestone

This repository contains a **tested portable Swift core and authored native iOS app source**: packet/authentication primitives, passive measurements, connection/freshness state, an offline inspector, a CoreBluetooth adapter, and a SwiftUI instrument panel. It is **not yet an installable or hardware-tested iOS application**. All **65 XCTest tests pass in debug and release on Linux** using generated/source-derived fixtures. Portable app-policy checks, app Swift grammar checks, and JSON/plist/source invariants also pass. **XcodeGen project generation, Apple SDK typechecking/builds, signing, sideloading, and Bluetooth hardware tests have not been performed.**

No valve operations exist. The offline inspector never transmits its computed reply. The iOS adapter's sole BLE value-write path is restricted to source-supported authentication; it has no settings, calibration, firmware, or equipment-control write path. Tests are not hardware captures, and wire behavior remains provisional until measured on equipment.

## Build and test

Requires Swift 6.0 or later. No third-party package dependencies.

```sh
swift test --jobs 2
swift run gaugeglass-inspect '01 06 01 01 12 34 56 78 F1'
swift run gaugeglass-inspect --report-checksum '01 03 01 02 0A F4'
```

The first example is a generated authentication challenge. The inspector computes `01030102906F`, prints it, and **does not send it**. Invalid checksums fail by default. `--report-checksum` is for forensic inspection and does not turn invalid frames into authentication events.

## Architecture and boundaries

- `GaugeglassCore`: dependency-free packet/authentication code, bounded family-aware measurement decoding, and deterministic connection/freshness state.
- `gaugeglass-inspect`: offline diagnostic CLI.
- Measurement parsing retains raw bytes and uncertainty; temperature units default to unknown and vacuum scaling is provisional. See [measurement notes](docs/measurements.md).
- Saved-device connection intent and stale-reading rules are portable, not a live transport. See [session-state notes](docs/session-state.md).
- `iOS/Gaugeglass`: foreground-only CoreBluetooth adapter and SwiftUI instrument panel, explicitly uncompiled against Apple SDKs.
- `iOS/project.json`: reproducible XcodeGen configuration using the local core package; generation remains unverified.
- See [iOS source, Linux validation, and later Mac build instructions](docs/ios-app.md). The next acceptance gate is an unsigned Apple-platform compile, followed by signing and read-only hardware tests.

Keep research downloads, proprietary source/assets, credentials, and signing material outside this repository. Do not carry official-app receive hooks into the client: some automatically change settings. Source-supported field widths and units vary by device family; unknowns must remain unknown rather than becoming plausible-looking readings.

See [protocol notes](docs/protocol.md). Do not use this software to make operational decisions until readings and units are verified against real equipment.
