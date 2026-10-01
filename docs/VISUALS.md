# Documentation visuals

The README includes a connection diagram, five synthetic measurement traces,
a five-second freshness plot, an annotated hex packet, and a native Mermaid
startup sequence.

All plot values and timing are invented. No session recordings, screenshots,
device identifiers, serial numbers, or third-party logos are used. The traces
illustrate local-consumer behavior, not device accuracy or performance. The app
currently displays numeric readings rather than these plots.

## Reproduce the figures

Matplotlib is only needed to regenerate the documentation assets. It is not an
app dependency. The current figures were generated with Matplotlib 3.11.2.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install 'matplotlib==3.11.2'
.venv/bin/python docs/generate_visuals.py
```

The generator creates both SVG and PNG files under `docs/assets/`. SVG is used
in the README for sharp text and diagrams; PNG copies are available for reuse.
The SVGs include accessible titles and descriptions. Generated metadata omits
creation dates, private paths, and device information.

The generator writes invented snapshots to a temporary directory and calls the
existing `tools/live_client.py` reader to produce stale-data gaps. It never opens
the real `captures/` directory. A separate synthetic frame is encoded with CRC-8
for the byte diagram and README hex example.

Keep the diagrams and captions in sync with the protocol implementation. Avoid
presenting synthetic curves as real sensor data or adding medical reference
ranges. Do not add personal screenshots or raw packet captures to the assets.

GitHub renders the sequence diagram from the README's `mermaid` block; see
[GitHub's diagram documentation](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams).
