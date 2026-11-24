import unittest

import numpy as np

from residual import suppress_residual


class ResidualSuppressionTest(unittest.TestCase):
    def test_a_sustained_low_level_residual_becomes_silence(self):
        raw = np.full(16_000, 0.1, dtype=np.float32)
        isolated = raw * 0.012
        np.testing.assert_array_equal(suppress_residual(raw, isolated), np.zeros_like(isolated))

    def test_quiet_speech_surviving_isolation_stays_at_its_original_level(self):
        raw = np.full(16_000, 0.002, dtype=np.float32)
        isolated = raw * 0.8
        np.testing.assert_array_equal(suppress_residual(raw, isolated), isolated)

    def test_a_decodable_output_is_retained_even_when_the_recording_was_much_louder(self):
        raw = np.full(16_000, 0.125, dtype=np.float32)
        isolated = np.full_like(raw, 0.003)
        np.testing.assert_array_equal(suppress_residual(raw, isolated), isolated)

    def test_a_short_gap_near_retained_speech_is_preserved(self):
        raw = np.full(12_800, 0.1, dtype=np.float32)
        isolated = raw * 0.7
        isolated[5120:7680] *= 0.01
        np.testing.assert_array_equal(suppress_residual(raw, isolated), isolated)

    def test_preview_compares_only_the_aligned_input_prefix(self):
        raw = np.full(16_000, 0.1, dtype=np.float32)
        prefix = raw[:7800] * 0.012
        np.testing.assert_array_equal(suppress_residual(raw, prefix), np.zeros_like(prefix))
