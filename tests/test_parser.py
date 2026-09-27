import unittest

from desired_state.devices.polar_h10.parser import parse_heart_rate


class HeartRateParsingTests(unittest.TestCase):
    def test_multiple_rr_intervals(self):
        value = parse_heart_rate(bytes([0x16, 72, 0x00, 0x04, 0x20, 0x04]))
        self.assertEqual(value.bpm, 72)
        self.assertEqual(value.rr_ticks, (1024, 1056))
        self.assertTrue(value.contact_detected)

    def test_wide_hr_with_energy(self):
        value = parse_heart_rate(bytes([0x19, 0x2c, 0x01, 0x05, 0x00, 0x00, 0x04]))
        self.assertEqual((value.bpm, value.rr_ticks), (300, (1024,)))

    def test_reject_truncated_rr(self):
        with self.assertRaises(ValueError):
            parse_heart_rate(bytes([0x10, 70, 0x01]))


if __name__ == "__main__":
    unittest.main()
