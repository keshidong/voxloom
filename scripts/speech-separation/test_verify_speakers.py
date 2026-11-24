import unittest

from verify_speakers import equal_error_rate


class SpeakerVerificationTest(unittest.TestCase):
    def test_reports_missed_target_and_admitted_other_at_the_same_threshold(self):
        result = equal_error_rate([0.9, 0.2], [0.8, 0.1])
        self.assertEqual(result, {"eer_pct": 50.0, "missed_targets": 1, "accepted_other": 1, "threshold": 0.8})
