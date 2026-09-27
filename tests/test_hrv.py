import unittest

from desired_state.processing.hrv import summarize_rr


class HrvTests(unittest.TestCase):
    def test_time_domain_metrics_from_adjacent_intervals(self):
        rows = [{"rr_ms": value, "received_monotonic_ns": index * 1_000_000_000}
                for index, value in enumerate((1000, 1020, 980))]
        result = summarize_rr(rows)
        self.assertEqual(result["rmssd_ms"], 31.62)
        self.assertEqual(result["sdnn_ms"], 20.0)
        self.assertEqual(result["pnn50_percent"], 0.0)
        self.assertEqual(result["intervals_accepted"], 3)

    def test_suspect_interval_and_gap_are_not_bridge_pairs(self):
        rows = [{"rr_ms": v, "received_monotonic_ns": t * 1_000_000_000}
                for v, t in ((1000, 0), (1020, 1), (2500, 2), (1010, 3), (1000, 20))]
        result = summarize_rr(rows)
        self.assertEqual(result["intervals_excluded"], 1)
        self.assertEqual(result["adjacent_pairs"], 1)
        self.assertEqual(result["rmssd_ms"], 20.0)

    def test_insufficient_data_returns_no_rmssd(self):
        self.assertIsNone(summarize_rr([{"rr_ms": 900}])["rmssd_ms"])
