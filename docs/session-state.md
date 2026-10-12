# Connection and freshness state

`SessionState.swift` is a portable, sequential value model, independent of the packet and measurement decoders. It has no Bluetooth transport, timers, persistence implementation, command queue, authentication replies, device-control API, or side effects. It does not establish that any hardware works.

## Adapter contract

- Own one `SessionState` for the adapter's lifetime, serialized on one actor/queue (for example `MainActor` on iOS). `Sendable` permits value transfer; it does **not** make concurrent mutation safe. Do not fork copies as independent owners and merge events.
- Load an already-vetted saved identifier into `init(savedDeviceID:configuration:)`. The model preserves identifiers exactly; empty identifiers are rejected. Persist `savedDeviceID` externally after deliberate supported selection. It does not inspect advertisements or determine compatibility itself.
- Supply explicit `SessionConfiguration(staleAfter:phaseTimeout:requiresAuthentication:)`. Both intervals must be finite and positive. There are no hardware-timing defaults. The test values are synthetic app-policy fixtures, not equipment guarantees.
- Inject finite, nonnegative seconds from one monotonic clock domain into every event and `tick(at:)`. Never mix wall-clock dates, peripheral ticks, or different epochs. Equal event times are allowed; clock time cannot go backward. Observation timestamps also use this domain.
- Capture the returned `ConnectionAttempt` in the actual transport operation/callback. Tokens contain both exact device identity and monotonically increasing generation. Never relabel an old callback with `state.attempt`. Tokens are local to one state-owner lifetime; detach/cancel callbacks before replacing that owner. They are not global identifiers or persisted capabilities.
- Execute `.scan` / `.connect(token)` externally only as discovery/connection intentions. The model never sends commands. When selecting another device, cancel the old transport separately; old callbacks cannot change the new state.
- Call `tick(at:)` periodically and after app resume. There are no internal timers. Call `freshness(at:)` whenever rendering and show `reading.attempt.deviceID` and `reading.observedAt`, especially if a retained sample belongs to a previously selected device.

## Quick launch and phases

`launch(at:)` returns `.connect(attempt)` for the remembered identifier, or `.scan` on first run without an identifier. Discovery does not automatically select a peripheral. `selectDevice(_:supported:at:)` starts a new generation only for an explicitly selected, supported, nonempty identifier; unsupported selection is ignored. No project/wizard state intervenes.

The accepted success path is:

```
connecting --connected--> subscribing --subscribed--> authenticating --authenticated--> ready
```

With an explicitly configured non-authenticating device, `subscribed` instead enters `ready`. A connected transport is never enough. Out-of-order and duplicate callbacks do not advance the phase. `subscribed` means all required measurement notifications are actually confirmed enabled, not merely that subscription was requested. `authenticated` means a validated positive authentication result, not receipt of a challenge or transmission of a response. The conservative ordering is a model contract, not a verified universal hardware sequence; an adapter must not bypass it or fabricate completion callbacks.

Each setup phase independently expires when elapsed time is **greater than or equal to** `phaseTimeout`. Matching callbacks check this deadline themselves, so a late completion cannot bypass a missed timer tick. `failed(_:reason:at:)` or a setup timeout enters terminal `error`; `disconnected` enters `disconnected`. The adapter can call `launch(at:)` after either terminal state to request a new attempt, including a separately scheduled reconnect policy. Repeated launch during an active, unexpired attempt returns `.none`. There is no autonomous retry loop, backoff, or queued operation replay.

## Retained samples versus live readings

`SessionSnapshot(values:)` is an immutable value copy of nonempty named finite numeric fields. Keys, physical units, ranges, model compatibility, completeness, missing-value handling, and checksum validity belong to the measurement adapter. This type intentionally has no dependency on a specific decoder API. Do **not** turn unknown fields, finite missing-value sentinels, or physically invalid values into a snapshot merely because they are numeric. If a measurement is rejected before snapshot construction, call `rejectReading(from:at:)` for that attempt; unrelated notifications should not call this measurement-specific method.

`receive(_:from:observedAt:at:)` accepts only a current-generation/current-device sample while `ready`. Its observation timestamp must be finite/nonnegative, no earlier than the ready transition, no later than the supplied current time, and younger than `staleAfter`. For the same generation it must be strictly newer than the last accepted sample: duplicate/out-of-order observations cannot refresh the display. Invalid observations invalidate freshness but never overwrite the retained snapshot.

`SessionReading` retains the immutable snapshot, original observation timestamp, and originating attempt. Disconnect, failure, setup timeout, clock error, rejected measurement, and reconnect preserve it as stale. Reaching `ready` again does not restore live status; only a newly accepted reading does. A reading becomes stale exactly at `age >= staleAfter`; arrival time cannot reset an older observation's age. An already-expired incoming sample is rejected rather than replacing the display.

`freshness(at:)` returns `absent`, `stale`, or `live`. It is intentionally **mutating**: like `tick(at:)`, it advances the clock watermark and persists expiration/clock failure. An expired sample cannot become live again through a subsequent display evaluation at an older time. All accepted-scope operations/evaluations advance the watermark; nonfinite/negative/backward time enters `error(.invalidTime)` and fails closed (freshness remains `absent` if there is no retained sample). Retry requires a valid time at least as large as the last valid watermark and a new attempt. Foreign/terminal callbacks are ignored before examining their timestamps, so obsolete events cannot poison the current connection's clock or freshness.

## Safety and limits

- Neither launch, reconnect, authentication completion, nor a fresh reading requests actuation. Actions can only be none, scan, or connect.
- No saved sample is populated automatically, and no fixture is represented as device traffic. Tests explicitly label all samples as synthetic.
- Numeric finiteness is not physical or protocol validation. The adapter must validate a complete display snapshot and retain semantic/unit metadata externally if needed.
- A timeout/error changes state only; the adapter must stop/cancel transport resources itself.
- Saved-ID storage, Bluetooth permissions/radio state, compatible-device discovery, BLE service/characteristic details, real authentication ordering, subscriptions, target iOS compilation/signing, and hardware response latency remain unverified here.

## Verification

The XCTest suite uses injected times, with no sleeps. Tests were written and run RED before implementation (missing session types), then run GREEN against the real Swift 6.0.3 Linux package using an isolated scratch build directory:

```sh
/home/galgathor/.local/share/gaugeglass-toolchains/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swift test --scratch-path .build/session-review --filter SessionStateTests
```

The final debug and optimized release runs each executed **15 SessionStateTests with 0 failures**. A separate behavioral RED regression reproduced expired-reading resurrection through backward display time; the final implementation persists freshness evaluations' clock watermark and passes that regression. Release verification used the same command with `-c release`.

The suite covers remembered/first-run launch, explicit compatibility selection, phase ordering and optional auth, stale retention through reconnect, age/setup timeout boundaries and late callbacks, terminal failures, old-generation and wrong-device events, rejected measurements, immutable snapshot provenance, invalid inputs/timestamps, and clock failures. Portable unit-test success does not constitute BLE or iOS hardware verification.
