import importlib.util
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

spec = importlib.util.spec_from_file_location("live_client", Path(__file__).resolve().parents[1] / "tools/live_client.py")
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class LiveClientTests(unittest.TestCase):
    def test_saved_values_expire_even_when_mac_app_stops_writing(self):
        received = datetime(2026, 10, 1, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "live.json"
            path.write_text(json.dumps({"schema_version": 1, "connected": True, "fresh": True,
                "received_at": "2026-10-01T00:00:00.000Z", "valid_until": "2026-10-01T00:00:05.000Z",
                "measurements": {"spo2_percent": 96, "pulse_bpm": 77, "rrp_per_min": 13,
                                 "pvi_percent": 29, "pi_percent": 17}}))
            current = client.read_live(path, received + timedelta(seconds=1))
            self.assertTrue(current["fresh"])
            self.assertEqual(current["measurements"]["pulse_bpm"], 77)
            for offset in (-1, 5, 60):
                expired = client.read_live(path, received + timedelta(seconds=offset))
                self.assertFalse(expired["fresh"])
                self.assertEqual(len(expired["measurements"]), 5)
                self.assertTrue(all(value is None for value in expired["measurements"].values()))

    def test_missing_dates_never_make_a_reading_live(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "live.json"
            path.write_text(json.dumps({"schema_version": 1, "connected": True, "fresh": True,
                                       "received_at": None, "valid_until": None, "measurements": {"pulse_bpm": 77}}))
            self.assertFalse(client.read_live(path)["fresh"])
            self.assertIsNone(client.read_live(path)["measurements"]["pulse_bpm"])


if __name__ == "__main__":
    unittest.main()
