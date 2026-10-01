"""Generate documentation figures from invented values; never read recordings.

Requires Matplotlib. Run from any directory with `python docs/generate_visuals.py`.
The app itself does not depend on this script or Matplotlib.
"""
import html
import json
import math
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "docs" / "assets"
sys.path.insert(0, str(ROOT / "tools"))
from live_client import read_live

INK = "#172b42"
MUTED = "#52667a"
BLUE = "#2563eb"
TEAL = "#087f78"
GRID = "#e4eaf0"
STALE = "#fde8e5"
plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 12, "text.color": INK,
    "axes.labelcolor": INK, "xtick.color": MUTED, "ytick.color": MUTED,
    "axes.edgecolor": GRID, "figure.facecolor": "white", "axes.facecolor": "white",
    "svg.fonttype": "none", "svg.hashsalt": "masimo-live-docs",
})


def save(fig, name, title, description):
    ASSETS.mkdir(parents=True, exist_ok=True)
    fig.savefig(ASSETS / f"{name}.png", dpi=150,
                metadata={"Software": "Masimo Live documentation; synthetic examples"})
    svg = ASSETS / f"{name}.svg"
    fig.savefig(svg, metadata={"Date": None, "Creator": "Masimo Live documentation"})
    text = svg.read_text()
    start = text.index("<svg ")
    end = text.index(">", start) + 1
    text = text[:end] + f"\n<title>{html.escape(title)}</title><desc>{html.escape(description)}</desc>" + text[end:]
    svg.write_text("\n".join(line.rstrip() for line in text.splitlines()) + "\n")
    plt.close(fig)


def canvas(height):
    fig = plt.figure(figsize=(12.8, height))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set(xlim=(0, 1280), ylim=(height * 100, 0))
    ax.axis("off")
    return fig, ax


def card(ax, x, y, width, title, subtitle, accent=BLUE):
    ax.add_patch(FancyBboxPatch((x, y), width, 104,
                 boxstyle="round,pad=0,rounding_size=12", linewidth=1,
                 edgecolor=GRID, facecolor="#f6f9fc"))
    ax.plot([x + 20, x + 20], [y + 25, y + 79], color=accent, linewidth=3)
    ax.text(x + 38, y + 39, title, fontsize=16, weight="bold", va="center")
    ax.text(x + 38, y + 73, subtitle, fontsize=11.5, color=MUTED, va="center")


def arrow(ax, x1, x2, y, label):
    ax.add_patch(FancyArrowPatch((x1, y), (x2, y), arrowstyle="-|>",
                                mutation_scale=16, linewidth=1.5, color=MUTED))
    ax.text((x1 + x2) / 2, y - 18, label, fontsize=10.5, ha="center", color=MUTED)


def connections():
    fig, ax = canvas(5.8)
    ax.text(50, 55, "Two local paths from your device to your Mac", fontsize=25, weight="bold")
    ax.text(50, 91, "Independent interoperability software · Apple frameworks · no network server", fontsize=12, color=MUTED)
    ax.text(50, 147, "DIRECT BLUETOOTH", fontsize=11, color=BLUE, weight="bold")
    card(ax, 50, 172, 242, "Your MightySat", "Device you own")
    card(ax, 414, 172, 350, "Masimo Live on Mac", "CoreBluetooth + packet decoder")
    card(ax, 886, 172, 344, "Your local project", "Read captures/live.json")
    arrow(ax, 302, 404, 224, "Bluetooth LE")
    arrow(ax, 774, 876, 224, "Local JSON")
    ax.text(414, 306, "Native display: SpO₂ · pulse · RRp · PVI · PI", fontsize=12, color=MUTED)
    ax.text(50, 366, "OPTIONAL IPHONE USB", fontsize=11, color=TEAL, weight="bold")
    card(ax, 50, 391, 242, "Your MightySat", "Device you own", TEAL)
    card(ax, 414, 391, 274, "iPhone app", "Visible Home screen", TEAL)
    card(ax, 810, 391, 420, "Mac screen reader", "AVFoundation + Vision OCR", TEAL)
    arrow(ax, 302, 404, 443, "Bluetooth LE")
    arrow(ax, 698, 800, 443, "USB screen")
    ax.text(810, 528, "Separate output: captures/usb/latest.json", fontsize=12, color=MUTED)
    ax.text(50, 562, "USB screen readings do not populate the Bluetooth live.json export.", fontsize=11, color=MUTED)
    save(fig, "connection-paths", "Two local connection paths",
         "Direct Bluetooth: MightySat to Mac to local JSON consumers. Optional USB: MightySat to iPhone app to Mac OCR, with a separate export.")


def readings():
    times = list(range(31))
    fields = [
        ("spo2_percent", "SpO₂ (%)", lambda t: 98 + round(math.sin(t / 4)), (96, 100)),
        ("pulse_bpm", "Pulse (bpm)", lambda t: 72 + round(4 * math.sin(t / 3)), (66, 78)),
        ("rrp_per_min", "RRp (/min)", lambda t: 16 + round(math.sin(t / 5)), (14, 18)),
        ("pvi_percent", "PVI (%)", lambda t: 20 + round(3 * math.cos(t / 4)), (15, 25)),
        ("pi_percent", "PI (%)", lambda t: round(5.5 + 0.8 * math.sin(t / 4), 2), (4, 7)),
    ]
    values = {key: [] for key, *_ in fields}
    base = datetime(2030, 1, 1, tzinfo=timezone.utc)
    with tempfile.TemporaryDirectory(prefix="masimo-doc-synthetic-") as directory:
        path = Path(directory) / "invented.json"
        for t in times:
            # Invented one-second packet cadence and eight-second reception pause.
            if t < 12 or t >= 20:
                received = base + timedelta(seconds=t)
                packet = {"schema_version": 1, "source": "bluetooth", "connected": True,
                          "fresh": True, "received_at": received.isoformat(),
                          "valid_until": (received + timedelta(seconds=5)).isoformat(),
                          "measurements": {key: function(t) for key, _, function, _ in fields}}
                path.write_text(json.dumps(packet))
            snapshot = read_live(path, now=base + timedelta(seconds=t))
            for key in values:
                value = snapshot["measurements"][key]
                values[key].append(float("nan") if value is None else value)
    fig, axes = plt.subplots(5, 1, figsize=(12.8, 8.2), sharex=True)
    fig.subplots_adjust(left=0.12, right=0.96, top=0.83, bottom=0.095, hspace=0.38)
    fig.text(0.055, 0.955, "What a local consumer could plot", fontsize=24, weight="bold")
    fig.text(0.055, 0.915, "Synthetic values and timing · not a recording, benchmark, or clinical result", fontsize=12, color=MUTED)
    axes[0].text(16, 101.1, "No packets: 12–20 s", color=MUTED, fontsize=11, ha="center")
    axes[0].text(18, 100.3, "Expired: null", color="#aa3a2c", fontsize=10, ha="center")
    for ax, (key, label, _, limits) in zip(axes, fields):
        ax.axvspan(12, 20, facecolor="#f1f4f7", zorder=0)
        ax.axvspan(16, 20, facecolor=STALE, zorder=1)
        ax.step(times, values[key], where="post", linewidth=2.1, color=BLUE, zorder=3)
        # Last fresh value is held until, but not including, the 5-second deadline.
        ax.hlines(values[key][15], 15, 16, colors=BLUE, linewidth=2.1, zorder=3)
        received_times = [t for t in times if t < 12 or t >= 20]
        ax.scatter(received_times, [values[key][t] for t in received_times], s=14, color=BLUE, zorder=4)
        ax.set_ylabel(label, fontsize=11)
        ax.set_ylim(*limits)
        ax.grid(axis="y", color=GRID, linewidth=0.7)
        ax.spines[["top", "right"]].set_visible(False)
        ax.tick_params(labelsize=10)
    axes[-1].set(xlim=(0, 30), xlabel="Illustrative elapsed time (seconds)")
    fig.text(0.12, 0.025, "Last packet: 11 s → expires at 16 s. New packets resume at 20 s. These curves are not built into the app.", fontsize=11, color=MUTED)
    save(fig, "synthetic-readings", "Five synthetic measurement traces",
         "Invented SpO2, pulse, RRp, PVI and PI values. Reception pauses from 12 to 20 seconds. The last value expires at 16 seconds; null values create gaps until reception resumes.")


def freshness():
    fig, ax = plt.subplots(figsize=(12.8, 4.5))
    fig.subplots_adjust(left=0.09, right=0.96, top=0.75, bottom=0.18)
    fig.text(0.055, 0.92, "A file on disk is not proof of a live reading", fontsize=24, weight="bold")
    fig.text(0.055, 0.86, "Synthetic single-packet example · no further packets arrive", fontsize=12, color=MUTED)
    ax.axvspan(0, 5, facecolor="#e3f3ef")
    ax.axvspan(5, 8, facecolor=STALE)
    ax.plot([0, 8], [0, 8], color=BLUE, linewidth=2.3)
    ax.axhline(5, color=MUTED, linestyle="--", linewidth=1.2)
    ax.axvline(5, color=MUTED, linestyle="--", linewidth=1.2)
    ax.scatter([5], [5], color=BLUE, s=44, zorder=4)
    ax.text(0.4, 7.2, "Age < 5 s: fresh", fontsize=12, color=TEAL, weight="bold")
    ax.text(5.3, 1.4, "Age ≥ 5 s: stale\nmeasurements = null", fontsize=12, color="#aa3a2c")
    ax.annotate("Expiry is exact at 5 seconds", xy=(5, 5), xytext=(1.9, 5.9),
                fontsize=11, color=INK, arrowprops={"arrowstyle": "->", "color": MUTED})
    ax.set(xlim=(0, 8), ylim=(0, 8), xlabel="Seconds since the last packet arrived", ylabel="Packet age (seconds)")
    ax.spines[["top", "right"]].set_visible(False)
    ax.grid(color=GRID, linewidth=0.6)
    fig.text(0.09, 0.04, "Freshness also requires schema 1, a connected continuous reading, valid dates, and an unexpired deadline.", fontsize=10.5, color=MUTED)
    save(fig, "freshness-window", "The five-second freshness deadline",
         "Without further packets, age grows with elapsed time. Readings are fresh before five seconds and stale at five seconds or later, even if the last JSON file remains on disk.")


def example_frame():
    frame = bytearray([0x77, 0x11, 0x05, 0, 0, 0, 0, 0, 98, 0, 72, 0x10, 20, 0, 0x26, 0x02, 0, 16])
    crc = 0
    for byte in frame[2:]:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ (0x07 if crc & 0x80 else 0)) & 0xFF
    frame.append(crc)
    return frame


def packet_layout():
    frame = example_frame()
    fig, ax = canvas(4.6)
    ax.text(50, 55, "Inside a 19-byte live frame", fontsize=25, weight="bold")
    ax.text(50, 91, "Invented readings · zero-based full-frame offsets · CRC-8 checked by the decoder", fontsize=12, color=MUTED)
    for index, byte in enumerate(frame):
        x = 50 + index * 62
        fill = "#e1eafa" if index < 3 else "#e3f3ef" if index in [8, 10, 12, 13, 14, 15, 17] else "#fff1d3" if index == 18 else "#eff2f5"
        ax.text(x + 27, 139, str(index), fontsize=11, color=MUTED, ha="center")
        ax.add_patch(FancyBboxPatch((x, 154), 54, 58, boxstyle="round,pad=0,rounding_size=6", facecolor=fill, edgecolor="none"))
        ax.text(x + 27, 183, f"{byte:02X}", fontsize=15, family="DejaVu Sans Mono", weight="bold", ha="center", va="center")
    for index, label, value in [(8, "SpO₂", "98%"), (10, "Pulse", "72 bpm"), (12.5, "PVI", "20%"), (14.5, "PI", "5.50%"), (17, "RRp", "16/min")]:
        x = 50 + index * 62 + 27
        ax.plot([x, x], [219, 236], color=TEAL, linewidth=1.1)
        ax.text(x, 260, label, fontsize=12, ha="center", weight="bold")
        ax.text(x, 285, value, fontsize=11, color=MUTED, ha="center")
    ax.text(50, 242, "77  prefix\n11  length = 17\n05  live opcode", fontsize=12, family="DejaVu Sans Mono", linespacing=1.6, va="top")
    ax.text(50, 365, "Blue: framing     Gray: status/flags     Green: measurement bytes     Amber: CRC", fontsize=11, color=MUTED)
    ax.text(50, 404, "PVI: 14 00 → 0x0014 = 20     PI: 26 02 → 0x0226 = 550 → 5.50%", fontsize=12, family="DejaVu Sans Mono")
    ax.text(50, 440, "CRC covers opcode + payload (indexes 2–17), not prefix, length, or the checksum byte.", fontsize=11, color=MUTED)
    save(fig, "live-packet-layout", "An annotated synthetic live packet",
         "Nineteen-byte example with frame header, status flags, SpO2 98 percent, pulse 72 bpm, PVI 20 percent, PI 5.5 percent, RRp 16 per minute, and an independently encoded CRC-8.")
    print("Synthetic live frame:", frame.hex(" ").upper())


if __name__ == "__main__":
    connections()
    readings()
    freshness()
    packet_layout()
    print("Generated four figures as SVG and PNG; no recording files were read.")
