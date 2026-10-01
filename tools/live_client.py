"""Local live-data reader. Import read_live(), or run with --once / continuously."""
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

LIVE_FILE = Path(__file__).resolve().parents[1] / "captures" / "live.json"


def read_live(path=LIVE_FILE, now=None):
    snapshot = json.loads(Path(path).read_text())
    current = now or datetime.now(timezone.utc)
    try:
        received = datetime.fromisoformat(snapshot["received_at"].replace("Z", "+00:00"))
        expires = datetime.fromisoformat(snapshot["valid_until"].replace("Z", "+00:00"))
        age = (current - received).total_seconds()
        fresh = (snapshot.get("schema_version") == 1 and snapshot.get("fresh") is True
                 and snapshot.get("connected") is True and 0 <= age < 5 and current < expires)
    except (KeyError, TypeError, ValueError, AttributeError):
        fresh = False
    snapshot["fresh"] = fresh
    if not fresh:
        snapshot["measurements"] = {key: None for key in (
            "spo2_percent", "pulse_bpm", "rrp_per_min", "pvi_percent", "pi_percent")}
    return snapshot


if __name__ == "__main__":
    once = "--once" in sys.argv[1:]
    previous = None
    try:
        while True:
            snapshot = read_live()
            output = json.dumps(snapshot, sort_keys=True)
            if output != previous:
                print(output, flush=True)
                previous = output
            if once:
                break
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
