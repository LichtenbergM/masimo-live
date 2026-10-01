# Contributing

Thanks for helping make direct MightySat-to-Mac connectivity more useful.
Small, focused fixes and carefully documented compatibility reports are welcome.

## Report compatibility or a problem

Include the device model, firmware if known, macOS version, connection mode,
and a short description of what happened. Say whether the device's own display
showed valid values and whether the phone app was disconnected for a direct
Bluetooth test. Never include a serial number or a personal measurement history.

Before posting logs, remove health measurements, device identifiers, names,
timestamps, local paths, and unrelated Bluetooth traffic. Prefer a minimal
synthetic packet or a redacted error message. Do not upload full `captures/`
folders, iPhone screenshots, or PacketLogger traces.

## Make a change

1. Fork the repository and work on a branch.
2. Keep changes focused and preserve the existing connection and freshness rules.
3. Run `bash test.sh` and `bash build.sh` on a Mac before opening a pull request.
4. Explain the behavior changed, how it was checked, and any device or firmware
   limitations. Separate automated tests from actual hardware observations.

The app uses Apple frameworks without third-party package dependencies. Python
is optional for consumers, but required for the client tests.

## Protocol work

Do not broaden the firmware check or replay additional commands based only on
a successful connection. Validate frame structure, checksums, status flags,
and comparisons with the device's visible output first. Use synthetic fixtures
for new tests. Distinguish verified behavior from hypotheses.

Preserve explicit user-initiated streaming, one activation per connection,
conservative handling of unknown flags, and expiry of stale measurements.
Keep stored records separate from live data. Commands for clock setting,
archive retrieval, or firmware changes are outside the current scope.

Contribute only material you have the right to share. Do not submit extracted
vendor code, proprietary SDKs, firmware, third-party app bundles, personal
recordings, or third-party branding assets. Changes should serve interoperability
with devices the user owns or is authorized to access.

Contributions are made under the project's MIT License.
