# Protocol notes — initial core

Evidence level: static source-derived rules; code tested on Linux; hardware unverified. Third-party package provenance and lack of hardware captures limit confidence. No vendor code/assets are distributed here.

## Packet representation

Given one complete, externally delimited frame, retain one byte handle, one byte **raw length**, one byte command, variable payload, and a final checksum byte. Minimum representable frame is four bytes. This is not a stream deframer: fragmentation, concatenation, MTU, and message boundaries need observation.

General length-field semantics are unresolved. Some outgoing source examples are inconsistent with a universal rule. Callers explicitly supply rawLength; decoder does not validate it against payload size or cap packet size at 255. Do not infer a valid equipment message merely because it can be represented here.

Checksum is the low byte of the negative of XOR across all preceding bytes. Default decode requires a matching checksum. Diagnostic `.report` preserves an invalid received byte; authentication decoding independently checks validity. Device acceptance of this checksum check remains unverified.

## Observed authentication subset

Command 01 payload beginning 01 supplies four challenge bytes a,b,c,d. Response is wrapping `(a XOR c) + (b XOR d)`. Source uses fixed reply prefix `01 03 01 02`, then response and calculated checksum; it does not echo the incoming handle. Payload beginning 03 has a following status: 00 is accepted; preserve nonzero codes without invented explanations.

Our decoder requires exact payload sizes for this supported subset (5 for challenge, 2 for status), rejecting additional bytes until further evidence exists. The original app slices fields without such validation. This strictness is a client policy, not a proven universal wire contract.

Generated vectors (not captured traffic):

- challenge frame `0106010112345678F1` -> response 90, computed reply `01030102906F`.
- challenge bytes `01020304` -> response 08, computed reply `0103010208F7`.
- status frame `010301030000` -> accepted.

Building reply bytes never performs transport writes. Cloud independence, auth timing, initial request/handshake requirements, notification subscription ordering, and other subcommands remain unresolved.

## Measurement investigation summary

The inspected shared incoming command 03 uses a count followed by key-specific values. Device categories select widths, endianness, missing-value sentinels and consumer units. It is NOT safe to implement one universal numeric map for all models.

Important risks for the next milestone:

- Vacuum consumer scales conflict with decoder comments; UI consumers indicate raw/100 Pa for several families, requiring hardware cross-checks.
- Pressure-probe scale differs from manifold pressure scale.
- Temperature interpretation can depend on configured units.
- Unknown keys have no supplied per-field width: bounded parsing must stop and preserve the remainder rather than skip guessed bytes.
- Some source signed-number helpers have boundary defects; represent raw values and test sign-edge intent independently.
- Long analyzer data has a separate schema from manifold measurements.
- Settings/status/acknowledgment commands reuse field IDs but must not populate live measurements.
- Some official-app receive/auth hooks trigger settings/control-related writes; the independent parser has no such side effects.

## Safety and verification gates

The portable core has no transport writes; the authored iOS adapter allows authentication only, not equipment-setting or valve-control writes. Firmware operations, calibration, and control replay are absent. Retained readings are invalidated on disconnect and stay stale until fresh validated events. An unsigned iOS Simulator build passed in GitHub run `38291069511`; simulator/device execution and real Bluetooth tests have not occurred. Hardware validation is required before trusting measurements or introducing control.
