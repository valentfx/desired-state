import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from desired_state.storage.history import sessions, timeline


class HistoryTests(unittest.TestCase):
    def test_device_filter_and_complete_counts(self):
        with TemporaryDirectory() as temp:
            root = Path(temp)
            folder = root / "20260927T040000Z_test"
            folder.mkdir()
            (folder / "manifest.json").write_text(json.dumps({"assignments": {"H10A": "Mike", "H10B": "Guest"}}))
            def write(name, rows):
                (folder / f"{name}.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
            write("measurements", [{"polar_id": "H10A", "heart_rate_bpm": hr,
                                     "received_utc": f"2026-09-27T04:00:{i:02d}+00:00"}
                                    for i, hr in enumerate((70, 72, 68))] +
                 [{"polar_id": "H10B", "heart_rate_bpm": 90, "received_utc": "2026-09-27T04:00:00+00:00"}])
            write("rr", [{"polar_id": "H10A", "rr_ms": 900,
                          "received_utc": "2026-09-27T04:00:00+00:00"}])
            record = sessions(root, "H10A")[0]
            self.assertEqual((record["measurement_count"], record["rr_count"], record["hr_min"], record["hr_max"]), (3, 1, 68, 72))
            self.assertEqual(len(timeline(root, folder.name, "H10A")["measurements"]), 3)
            self.assertEqual(sessions(root, "OTHER"), [])
            with self.assertRaises(ValueError):
                timeline(root, folder.name, "OTHER")
