# Bounded, source-derived measurement decoding

`Measurements.decode(_:context:)` is an independently written, passive command-`03` decoder. It performs no transport operations, settings writes, authentication replies, or equipment controls. This is a portable core milestone, **not a completed iOS app or a device-compatibility claim**.

## Evidence and confidence

The schema was derived from an inert-text protocol investigation of the source application's shared receive branch and its measurement UI consumers. No proprietary code or assets are included. Evidence anchors below identify source locations, not hardware captures:

- `html/home/home_frm.html:3336–3578`: one-byte field count, literal two-byte keys, exact key/category-dependent value widths.
- `html/home/home_frm.html:1719–1810`: active advertisement-name category selection. The packet itself does not identify a family.
- `html/NX4G_data/sxfhb_data_frm.html:7822–7828,7952–8043,8098–8117`: vacuum/pressure/temperature and auxiliary consumers; equivalent newer-family consumers exist under `sxfhb_data` and `N1DX1_data`.
- `html/sxsb_data/sxsb_data_frm.html:6101–6107`: category-4/8 vacuum consumer; `html/zkb_data/zkb_data_frm.html:3521–3526` and `html/zkj_data/zkj_data_frm.html:2889–2893`: categories 3/5.
- `script/hexUtil.js:111–137`: source signed helper has a minimum-value defect. This implementation uses conventional, source-intended two's complement instead, including signed minima. Hardware encoding remains unverified.

Every report exposes `confidence == .sourceDerivedHardwareUnverified`. Numeric values carry a separate `scaleConfidence` (`sourceDerived` or `provisional`); this is not a hardware-validation badge. All test fixtures are generated/source-derived, **not captured device traffic**.

## Caller context and bounded families

`MeasurementContext(category:temperatureUnit:)` requires an externally determined category. `family` is a recognized source category, not proof the connected equipment belongs to it. No advertisement matching or transport identity inference happens here.

| Categories | Scope admitted here | Source advertisement tokens (not certified marketing models) |
|---|---|---|
| 4 / 8 | Shared digital/four-valve manifold fields | `NAVAC-NMGD1`, `NAVAC-NX1-` / `NAVAC-NX4-` |
| 29 / 34 / 35 | Newer manifold and explicitly gated probe/auxiliary fields | `NAVAC-NX1G-` / `NAVAC-NX4G-` / `NAVAC-N1DXI-` (uppercase **I**, not numeral 1) |
| 0 / 1 | Clamp battery and low/high temperature paths | `NAVAC-NST1` / `NAVAC-NST2` |
| 3 / 5 | Battery and provisional vacuum | Pump `NAVAC-NP8D 1S`, `NAVAC-NP8DS(V)` / gauge `NAVAC-NMV 1S`, `NAVAC-NMV1S` |
| 9 / 10 | Generic temperature; 10 also humidity and an opaque auxiliary field | `NAVAC-NST3`, `NAVAC-NSTL` / `NAVAC-NSH1`, `VALUE-VSH1` |

The source's unguarded battery/opaque branches are admitted within these bounded categories; that does **not** establish that each category emits them. Individual fields are optional. No packet is required to contain batteries or every catalog field.

Category **11** pressure has conflicting UI scales and is unsupported as a whole. Category **36 (NMA1)** uses a separate long-data schema and is unsupported. Legacy scales, recovery machines, combined scales, valve families, category 30, and unknown categories are also unsupported here. The source branch contains 24 distinct keys; this implementation does not claim universal support for them.

## Exact field catalog

Keys are ordered wire bytes, not host-endian numeric IDs. LE means little endian for the value only. `M` below means categories 4/8/29/34/35; `N` means 29/34/35. An admitted opaque field consumes a proven width but does not become a numeric measurement.

| Key | Value width | Admitted categories | Meaning and interpretation |
|---|---:|---|---|
| `0100` | 1 | All bounded categories above | Battery U8, upper-clamped to 100. `FF` becomes 100, **not** missing. Raw integer/bytes and normalization remain available. |
| `1000` / `1100` / `1200` / `1300` | 1 each | N | Main / low-temperature-probe / high-temperature-probe / vacuum-probe battery. `FF` is explicitly source-mapped to zero, otherwise upper-clamped to 100. Zero is not certified as physically empty; it can result from this normalization. |
| `0200` / `0300` | 2 each | 0/1 and M | LE signed-16 low/high temperature, raw / 10. Raw -9999 is missing **only M**. |
| `0400` | 2 | 9/10 | LE signed-16 generic temperature, raw / 10; no manifold sentinel applied. |
| `0500` / `0600` | 4 each | M | LE signed-32 low/high pressure; source-derived Pa hint. Raw -1000000 means missing. |
| `0900` | 4 | 3/5 and M | LE signed-32 live vacuum. UI consumers suggest raw / 100 Pa, explicitly **provisional** because the decoder comment conflicts. Raw -1 means missing **only M**, not 3/5. |
| `0B00` | 2 | 10 | LE U16 humidity, raw / 10 percent RH. |
| `0B00` / `0C00` | 2 each | N | Auxiliary high/low temperature-named fields, **opaque**: scale, units, and physical identity unresolved. |
| `0C00` | 2 | 10 | Opaque; consumer meaning unresolved. |
| `1400` / `1500` / `1600` | 2 each | All bounded categories | Opaque bytes; no invented signedness, unit, or semantics. |
| `1700` | 1 | N | Charging indicator bytes, opaque; enum values unverified. |
| `1800` / `1900` | 4 each | N | LE signed-32 auxiliary high/low pressure; source-derived Pa hint. Raw -1061293825 means missing. Remote/probe identity unresolved. |

`0700`, `0800`, `0A00`, `0001`, and `0008` are recognized catalog keys but unsupported by this decoder. Other category/key combinations stop as unsupported; unknown keys stop as unknown. Neither case guesses a value width or attempts to skip ahead.

**Temperature units:** the default is `.unknown`. The caller must supply `.celsius` or `.fahrenheit` only with explicit known configured-unit context. The decoder scales raw / 10 in that unit, without Celsius/Fahrenheit conversion. Source settings/history paths prevent an unconditional Celsius assumption. Choosing a context is a caller assertion, not a unit detected from the packet.

## API and failure contract

```swift
let packet = try Packet.decode(notificationBytes) // one externally delimited frame
let report = try Measurements.decode(
    packet,
    context: MeasurementContext(category: 29, temperatureUnit: .unknown)
)
guard report.isComplete else {
    // Diagnostic only: retain report.issue, report.fields, report.unparsedRemainder.
    // Do not render a parsed prefix as a complete new live update.
    return
}
// Fields retain ordered literal key, rawValue, semantic, and number/missing/opaque value.
// Attach connection identity and receipt time externally; no device timestamp is inferred.
```

- Checksum validity is required even for a `Packet` created with inspection `.report` policy. Invalid checksums throw `PacketError`; every command other than `03` throws `MeasurementError.unexpectedCommand`. Configuration `02` reuses keys with different layouts, and settings/status/acknowledgment `04/05/06/82/83/84/85` are not live readings here.
- Parsing is bounded by the U8 declared field count and each selected declarative width. Zero fields is valid only without trailing bytes. Duplicate keys remain ordered; they are not silently merged.
- `MeasurementReport` retains the full original packet (including raw length, command, checksum and payload), caller context, declared count, parsed prefix, issue and unparsed remainder. `isComplete` is true only after exactly the declared fields consume the entire payload.
- Missing count, exhausted count, truncated key/value, unknown/unsupported key and trailing bytes are explicit issues. A stopped remainder starts **at the offending key, including both key bytes and partial value**; a truncated key retains its available byte. Unsupported categories retain the **entire payload including count**.
- No generic packet-length contract is invented. `Packet.rawLength` remains raw. This is not stream reassembly, fragmentation handling, concatenated-frame splitting, or a guarantee that any checksum-valid truncated transmission can be detected from framing alone.
- Missing sentinels are represented as `.missing(rawInteger:)`, never as plausible readings. Raw bytes remain retained even after clamping, missing-value mapping or interpretation.
- A complete parse does not make an old reading fresh. A transport/session adapter must timestamp receipt, validate connection identity, mark stale/disconnected data, and require fresh validated events after reconnect.

## Verification and remaining acceptance gates

Tests cover source-derived LE and signed boundary vectors; family-specific battery `FF` and sentinels; explicit temperature units; provisional vacuum; opaque/auxiliary values; incorrect commands/key collisions; checksum failures; zero/max/count mismatch; unknown-key stops; truncated keys and values; duplicates/trailing bytes; and lossless byte accounting over every prefix plus deterministic synthetic byte sequences.

A genuine assertion-level RED was observed for zero-count/trailing-byte behavior before implementation, followed by GREEN using the same XCTest runner. A concurrent session worker initially had tests without its production type, so the assertion-level RED used an isolated `swiftc`/XCTest runner under `.build/measurement-review`; later SwiftPM runs use the same isolated scratch path and include the complete project.

Verified with Swift 6.0.3 on Linux:

- Assertion-level RED: `testMissingAndZeroCounts`, 1 test with 3 expected assertion failures; after implementation, the same runner passed with 0 failures.
- `swift test --scratch-path .build/measurement-review --filter MeasurementTests`: **24 tests, 0 failures**.
- `swift test --scratch-path .build/measurement-review`: **65 tests, 0 failures**, including the concurrently implemented session-state tests at verification time.
- `swift test --scratch-path .build/measurement-review -c release --filter MeasurementTests`: **24 tests, 0 failures**.

These results validate the implementation against synthetic fixtures, not equipment compatibility or Apple-platform integration.

Hardware acceptance is still outstanding: actual models, captured notifications, GATT properties, family identity, signed encoding, units after settings changes, sentinels, framing/fragmentation, authentication timing, cadence and reconnection behavior. No hardware writes have been performed, and no settings/control behavior was inherited from the source receive hooks. Valves and other controls remain outside this decoder's scope.
