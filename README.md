# Gaugeglass

Independent instrument-panel app in development for Bluetooth HVAC equipment. Intended everyday workflow: open, reconnect to saved devices, and see fresh measurements immediately. Not affiliated with or endorsed by NAVAC.

## Current milestone

This repository currently contains a **working offline Swift protocol core and packet inspector**, not an installable iOS application. Hex parsing, packet inspection, the observed checksum, and authentication challenge/reply primitives compile and have Linux unit tests. No Bluetooth connection, physical readings, valve control, Apple-platform build, signing, or sideload test has been performed.

No valve operations exist. Computing an authentication response does not transmit it. Tests use generated/source-derived fixtures, never hardware captures. Wire behavior remains provisional until measured on equipment.

## Build and test

Requires Swift 6.0 or later. No third-party package dependencies.

```sh
swift test --jobs 2
swift run gaugeglass-inspect '01 06 01 01 12 34 56 78 F1'
swift run gaugeglass-inspect --report-checksum '01 03 01 02 0A F4'
```

The first example is a generated authentication challenge. The inspector computes `01030102906F`, prints it, and **does not send it**. Invalid checksums fail by default. `--report-checksum` is for forensic inspection and does not turn invalid frames into authentication events.

## Architecture and boundaries

- `GaugeglassCore`: dependency-free, portable packet/authentication code.
- `gaugeglass-inspect`: offline diagnostic CLI.
- Next: bounded family-aware measurement decoding and stale-reading/connection state.
- Later: CoreBluetooth adapter, SwiftUI instrument panel, and an Apple-platform build/signing path.

Keep research downloads, proprietary source/assets, credentials, and signing material outside this repository. Do not carry official-app receive hooks into the client: some automatically change settings. Source-supported field widths and units vary by device family; unknowns must remain unknown rather than becoming plausible-looking readings.

See [protocol notes](docs/protocol.md). Do not use this software to make operational decisions until readings and units are verified against real equipment.
