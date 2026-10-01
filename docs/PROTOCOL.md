# Implemented Bluetooth protocol

These notes describe the behavior implemented in `Sources/Protocol.swift`.
They are observations for an independent interoperability implementation,
not vendor specifications. The supported direct-streaming path was checked
on one MightySat Rx with firmware 1.0.6.3; other firmware is unverified.

## GATT channels

| Role | UUID |
| --- | --- |
| Service | `54C21000-A720-4B4F-11E4-9FE20002A5D5` |
| TX, Write Without Response | `54C21001-A720-4B4F-11E4-9FE20002A5D5` |
| RX, notifications | `54C21002-A720-4B4F-11E4-9FE20002A5D5` |

Do not assume ATT handles are the same on another device. The app discovers
services and characteristics using UUIDs and subscribes before writing.

## Framing

A frame is `77 LENGTH OPCODE PAYLOAD… CRC`.

- Total frame size is `LENGTH + 2` bytes; length must be at least 2.
- CRC-8 uses polynomial `0x07`, initial value `0x00`, and no final XOR.
- CRC covers the opcode and payload, excluding prefix, length, and CRC itself.
- A notification can contain a fragment, multiple frames, or a frame boundary.
- The decoder buffers fragments and discards invalid prefixes or checksums
  while searching for the next valid frame.

## Explicit streaming startup

1. The user clicks Start live readings with an active RX subscription and a
   writable TX characteristic.
2. The app sends the observed status query `77 02 01 07` once.
3. It waits for a valid 22-byte status frame with opcode `01` and bytes
   `63 10` at full-frame indexes 3 and 4, the observed firmware signature.
4. Once CoreBluetooth allows another write, it sends the observed activation
   `77 05 03 1F 00 03 D6` once.

The activation's three parameter bytes are not fully explained. The implementation
uses the observed sequence only after the matching status response; it does not
claim a general command set. No clock-setting, archive retrieval, or firmware
update commands are sent. Reconnecting creates a new session and requires an
explicit start again.

## Live values

Only checksum-valid, 19-byte frames with opcode `05` enter the proprietary
live decoder. All offsets below are zero-based indexes into the full frame.

| Index | Implemented interpretation |
| --- | --- |
| 3–7 | General status bytes; all must be zero |
| 8 | SpO₂ percentage, accepted from 1 through 100 |
| 9 | Additional primary status; must be zero |
| 10 | Pulse rate in bpm; zero and `FF` are rejected |
| 11 | Pulse flag; only `00` and `10` are accepted |
| 12–13 | PVI, unsigned little endian; accepted through 100 |
| 14–15 | PI, unsigned little endian divided by 100; accepted through 20% |
| 16 | RRp flag; only zero enables a value |
| 17 | RRp per minute, accepted from 1 through 100 |
| 18 | CRC |

These are parser acceptance limits, not medical reference ranges. Unknown general
status or pulse flags reject the whole reading. Invalid optional values become
absent independently. In particular, RRp flags `01` and `04` are unexplained and
remain hidden.

Status, acknowledgement, signal, and archived-record frames do not refresh live
measurements or their age. Displayed readings expire after five seconds without
a valid update and clear on disconnection. The export requires a connected,
continuous reading whose reception age is nonnegative and less than five seconds.

## Standard Pulse Oximeter decoder

`DeviceProtocol` also parses characteristics `2A5F` (continuous) and `2A5E`
(spot-check), including SFLOAT values and supported optional status fields.
Unknown UUIDs, truncated fields, special SFLOAT values, invalid measurement
statuses, and nonzero sensor status are rejected. Spot checks are marked as
single measurements and do not qualify as fresh continuous export data.

## Validation limits

Tests exercise fragmentation, CRC rejection, session sequencing, supported and
unsupported statuses, and expiry without a sensor. Packet examples in the test
suite are small protocol fixtures, not complete session recordings. Hardware
validation covered direct streaming and finger removal/reinsertion on the tested
device. It does not establish clinical accuracy or compatibility with other
models, firmware, or conditions.
