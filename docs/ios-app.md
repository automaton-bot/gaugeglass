# Native iOS app source

## Status and scope

An independently written SwiftUI instrument panel and foreground CoreBluetooth adapter are in `iOS/Gaugeglass/`. The app consumes the local parent Swift package's `GaugeglassCore`; there are no app runtime dependencies beyond Apple frameworks and that package. Minimum deployment target: iOS 16. Swift language mode: 6.

**Apple SDK simulator compilation and XcodeGen generation PASSED in GitHub run `38291069511` for commit `e4ee0f371645bca4ced845a73e0e3c3e58b8728a`.** Xcode 16.4 / Swift 6.1.2 produced an unsigned iOS Simulator app with x86_64 and arm64 executables. The 65 portable core tests and app-policy checks also passed on macOS. Simulator/device launch, physical-device compilation, signing, sideloading, and hardware testing have NOT been performed. Linux grammar/config checks below remain useful but are not Apple SDK typechecking. See `github-build.md` for the recorded result; this is not yet a phone-installable or hardware-validated release.

No proprietary source, assets, captured packets, original package data, credentials, signing identity, or equipment control implementation is included. A manual-only shell-based unsigned compile workflow is now included under `.github/workflows/ios-simulator.yml`.

## Files

- `iOS/Gaugeglass/GaugeglassApp.swift`: SwiftUI application, readable instrument tiles, per-field age/LIVE/STALE labels, picker, warnings and local temperature context.
- `iOS/Gaugeglass/InstrumentModel.swift`: main-actor app/session ownership, selected-device persistence, foreground timer, bounded discovery/retry policy, strict measurement/auth integration.
- `iOS/Gaugeglass/ConnectionTransport.swift`: per-attempt central/delegate, exact GATT discovery, subscription, auth-only writes, terminal-callback cancellation barrier.
- `iOS/Gaugeglass/InstrumentPolicy.swift`: portable profile map, saved-device validation, auth allowlist, independent field freshness and bounded backoff.
- `iOS/Gaugeglass/Info.plist`: Bluetooth usage disclosure; no background mode.
- `iOS/project.json`: declarative XcodeGen spec with local package path `..` and shared `Gaugeglass` scheme.
- `iOS/Tests/PolicyChecks.swift`: isolated portable executable checks; intentionally not a parent SwiftPM target.
- `iOS/validate.py`: reproducible Linux validation, outputs confined to ignored `iOS/.validation/`.
- `iOS/.gitignore`: excludes validation products, generated project, user state and DerivedData.

## Generate and compile later on a Mac

Use Xcode 16 or later with a Swift 6 compiler and an appropriate iOS SDK. Install **XcodeGen 2.44.1** (the spec requires at least that version; use that version for reproduction). XcodeGen is a project-generation dependency on the build host, not a bundled/runtime dependency. The JSON format, local package `path`, target package/product dependency and scheme fields are based on XcodeGen's own 2.44.1 `Docs/ProjectSpec.md`. Actual interpretation and project generation passed with that version in the recorded GitHub build.

From the repository root:

```sh
cd iOS
xcodegen --version
xcodegen generate --spec project.json
xcodebuild -list -project Gaugeglass.xcodeproj
xcodebuild -project Gaugeglass.xcodeproj -scheme Gaugeglass \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

The project must remain inside `iOS/` so the local package resolves to the repository root. There are no network package dependencies. Generation must create the app target, local `GaugeglassCore` product link and scheme; verify these with `xcodebuild -list` before building. The generated `.xcodeproj` is ignored because `project.json` is authoritative. No generation/build has been triggered by the Linux validation script.

A physical-device build is a separate step: choose a bundle identifier you are entitled to use and a signing team in Xcode, then build/run manually with your permission. `com.automaton.gaugeglass` is a default configuration value, not a claim of identifier ownership. No team or credentials are supplied. App icon/store packaging and distribution are not part of this source milestone.

## Linux checks actually exercised

From the repository root, with the available Swift 6.0.3 compiler:

```sh
SWIFTC=/home/galgathor/.local/share/gaugeglass-toolchains/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swiftc \
  python3 iOS/validate.py
```

For another Linux machine, set `SWIFTC` to its Swift 6 compiler or put `swiftc` on `PATH`. The script independently compiles a `GaugeglassCore` shared library/module from the existing sources into `iOS/.validation/`, compiles/links the portable policy checks, executes them, and runs `swiftc -frontend -parse` for every app Swift file. It does not modify the core or its package/test targets.

Observed exit status: **0**. Output:

```text
PASS: profile/auth allowlist, independent field freshness, missing/partial handling, generation isolation, unknown units, bounded retries
PASS: Swift grammar for all app sources (NOT Apple SDK typechecking)
PASS: common-mode foreground ticker source invariant (NOT iOS runtime verification)
PASS: JSON/plist parsing and local package, target, scheme, foreground-only config invariants
NOT RUN: XcodeGen generation, xcodebuild, Apple SDK typecheck, signing, BLE/hardware tests
```

The portable checks were written first and initially failed because the app policy types did not exist. Passing checks use synthetic/source-derived packets, not actual device traffic. They cover literal advertisement tokens (including `NAVAC-N1DXI-`, not repaired to digit `1`), unsupported profiles, auth allowlisting, independent battery/pressure age, missing sentinel clearing, incomplete-report non-refresh, disconnect invalidation, generation isolation, unknown temperature units/context clearing, and bounded retry delays.

The configuration check is explicit JSON/plist parsing and assertions, **not a full XcodeGen schema/generation check**. It checks the deployment target, Swift mode, parent package/product path, source inclusion, scheme and foreground-only permission configuration.

## Connection and write boundaries

- First use requires an explicit picker selection. Only exact case-sensitive reachable source-name tokens mapped to `MeasurementFamily` appear. Source-supported families are categories 0, 1, 3, 4, 5, 8, 9, 10, 29, 34 and 35. Unsupported scales, category 11 pressure, category 15 valves, category 30 routes, category 36/NMA1/analyzers and recovery-machine dead-code maps are excluded.
- The selected CoreBluetooth UUID, category and advertisement name are saved locally. Relaunch/foreground resume immediately tries `retrievePeripherals(withIdentifiers:)` and connects the saved UUID. If unavailable, fallback scanning accepts only that saved UUID with a matching supported advertised profile. Nothing auto-selects the nearest/new/merely similarly named peripheral.
- Names and services are spoofable; a saved UUID is persistence, **not authenticated equipment identity**. Even protocol auth is not an identity certificate. The picker says to confirm the physical label; the panel says to compare physical readings.
- Exact Bluetooth-base UUIDs are used: service `0000FE60-0000-1000-8000-00805F9B34FB`, incoming `0000FE62-0000-1000-8000-00805F9B34FB`, writes `0000FE61-0000-1000-8000-00805F9B34FB`. The source established FE60/61/62 tokens by substring, not a hardware-confirmed full GATT inventory. The app deliberately fails closed on other full UUIDs/properties.
- Both characteristics must be discovered in the exact service; FE62 must support notify or indicate, and FE61 acknowledged writes. Authentication starts only after FE62's successful notification-state callback reports `isNotifying`.
- The independently generated initial auth packet has prefix `00040100A55A` plus core BCC, yielding `00040100A55A06`. This source-supported request precedes the core-supported four-byte challenge / generated reply / acceptance flow. The length byte is explicitly source-derived, not inferred from a universal length contract. Successful subscription-before-auth timing and the need for this request remain hardware-unverified.
- The only value-write call is private `writeAuth`. It can write the exact initial request or a checksum-valid core-generated challenge reply, once each per connection, serialized as `.withResponse`. Challenges arriving before the initial write completion wait in a single auth-reply slot. Duplicate/unexpected challenges, rejection, discovery/subscription/write failure or phase timeout fail safely and cancel. There is no general write API or queued settings/control replay.
- **No units, refrigerant, calibration, OTA, valve, pump or other settings/control messages are sent.** Valve UI is disabled with an explanation. Local decode-context selection is not an equipment command.

## Freshness and lifecycle

Only checksum-valid command `03`, a known selected category and a complete core report may update readings. Auth/settings/status/ack/long packets never become measurements. Unknown widths, truncation, trailing data and rejected measurements do not refresh any field. One callback is assumed to contain exactly one complete packet; no speculative fragmentation/concatenation deframer is implemented.

Each field carries its own monotonic receipt time, original connection attempt and invalidation flag. A battery-only report never merges retained pressures into a new timestamp. Missing sentinels remove their own fields. Disconnect, failed/rejected readings, foreground suspension and reconnection invalidate retained values. New valid reports restore only the newly reported fields; older or previous-generation fields remain STALE. The core `SessionSnapshot` contains only numeric fields from the current report, not the retained display dictionary. UI freshness is evaluated from the separate per-field store.

Temperatures default to unknown and show an unlabeled scale. The user may select a local °C/°F decode context **only to match the gauge's actual current setting**; it does not infer settings, convert/relabel retained readings or write a device setting. Changing context removes retained temperatures and waits for new reports. Vacuum readings explicitly mark provisional Pa scaling. Battery clamping/ff→zero source normalization is visible rather than silently implying a hardware-confirmed value.

A one-second main-run-loop tick, registered in common modes so UI tracking does not intentionally pause it, uses monotonic uptime while active. Five seconds to stale, twenty seconds per connection phase and a fifteen-second picker scan are app-policy choices, not equipment cadence guarantees. There are at most three automatic retries at 2/4/8 seconds per foreground/manual activation; auth success does not reset the budget for a flapping device. No endless scan, keepalive/query loop, background mode or restoration identifier is configured. Inactive/background transitions stop scans/timer, invalidate readings and cancel transport; foreground resumes saved-device reconnection without replaying commands.

Each connection attempt has its **own `CBCentralManager` and delegate proxy with its immutable `ConnectionAttempt` token**. Central and peripheral callbacks call the owner synchronously on the explicitly specified main queue; the Swift 6 main-actor delegates use `@preconcurrency` only to bridge SDK delegate isolation. The timer enters `MainActor.assumeIsolated` because it is created on the main run loop. No uncontrolled asynchronous `Task` callback hops are used.

Old transports are retained while cancellation is outstanding, including across picker/scene changes. A replacement attempt cannot begin until `didDisconnectPeripheral` or `didFailToConnect` terminates the old connect/connection. Late `didConnect` during cancellation is cancelled again without discovery/auth. Old notifications and writes are ignored while closing. If no connect was ever submitted, a scan-only attempt can terminate immediately. If a terminal callback never arrives, retries remain blocked; the panel explains that relaunch may be needed. **A timeout never discards the barrier and starts an overlapping connection.** CoreBluetooth can reuse peripheral objects; replacement delegates are installed only after this barrier, and central callbacks are scoped to their own manager/proxy. Actual trailing-callback behavior under resets still needs platform testing.

## Primary API references consulted

Apple documents notification subscription success via `peripheral(_:didUpdateNotificationStateFor:error:)`, subsequent value delivery via `peripheral(_:didUpdateValueFor:error:)`, known UUID retrieval, main-queue manager delivery, and short UUID expansion to the Bluetooth base UUID. Its cancellation guidance states that cancellation is nonblocking, pending operations may or may not finish, and local disconnection is reported through the delegate. These are the basis for subscription-before-auth and waiting for terminal callbacks, not a promise that all hardware behaves identically.

- Apple Developer Documentation: `CBPeripheral.setNotifyValue(_:for:)`
- Apple Developer Documentation: `CBCentralManager.retrievePeripherals(withIdentifiers:)`
- Apple Developer Documentation: `CBCentralManager.init(delegate:queue:)`
- Apple Developer Documentation: `CBUUID`
- Apple Developer Documentation: `ScenePhase` and iOS-16-compatible `onChange(of:perform:)`
- Apple Core Bluetooth Programming Guide: *Best Practices for Interacting with a Remote Peripheral Device*, disconnect guidance
- XcodeGen 2.44.1 upstream `Docs/ProjectSpec.md`: JSON format, local packages, dependencies and schemes

## Remaining acceptance gates

1. **Simulator compile gate passed** in the recorded GitHub run. Repeat generation/build after source changes. Linux grammar checks still cannot verify SDK overloads; a successful Apple SDK compile does not verify runtime actor assumptions or simulator launch.
2. Run on iPhone/iPad: permission denial/grant, powered-off/reset Bluetooth, inactive/background transitions, accessible large text/layout, picker dismissal, saved UUID persistence and reconnect.
3. Test delayed terminal callbacks, rapid device changes, cancel-then-connect, service invalidation, write errors and notification loss. Specifically verify peripheral-object reuse does not leak previous-generation callbacks, and a terminal event always releases the barrier where expected.
4. Verify exact full GATT UUIDs/properties and source auth bytes against the actual hardware model with a read-only measurement session. Confirm required authentication timing, challenge/status shape, complete packet delivery, checksum acceptance, no needed keepalive/query, cloud independence and notification cadence.
5. Compare every supported reading and sentinel/unit interpretation to the physical display, especially vacuum Pa and temperature-setting context. Model identity, measurement scaling and source-derived tests are not hardware certification. No unsupported decoder/profile or controls should be enabled merely to make connection succeed.

No Mac signing credentials or hardware model are necessary to review these sources, but these gates are necessary before claiming a working iOS/hardware deployment.
