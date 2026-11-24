import unittest

import numpy as np

from separate import SAMPLE_RATE
from voxlock_model import VoxLockPreview, combine_references


class VoxLockEnrollmentTest(unittest.TestCase):
    def test_quiet_normal_and_loud_references_make_a_balanced_profile(self):
        time = np.arange(3 * SAMPLE_RATE, dtype=np.float32) / SAMPLE_RATE
        frequencies = [190, 310, 470]
        takes = [gain * np.sin(2 * np.pi * frequency * time)
                 for gain, frequency in zip([0.08, 0.16, 0.32], frequencies, strict=True)]
        enrollment = combine_references(takes)
        self.assertEqual(len(enrollment), 3 * SAMPLE_RATE)
        levels = []
        for part, frequency in zip(np.split(enrollment, 3), frequencies, strict=True):
            self.assertEqual(np.argmax(abs(np.fft.rfft(part))), frequency)
            levels.append(float(np.sqrt(np.mean(part ** 2))))
        self.assertLess(max(levels) / min(levels), 1.05)

    def test_does_not_accept_silent_enrollment(self):
        with self.assertRaises(ValueError):
            combine_references([np.zeros(3 * SAMPLE_RATE)])

    def test_previews_process_only_new_samples_and_keep_the_previous_output(self):
        received = []

        class Stream:
            def push(self, chunk):
                received.append(chunk.copy())
                return chunk * 2

        preview = VoxLockPreview(Stream())
        audio = np.arange(3000, dtype=np.float32)
        np.testing.assert_array_equal(preview.extend(audio[:1300]), audio[:1300] * 2)
        np.testing.assert_array_equal(preview.extend(audio), audio * 2)
        np.testing.assert_array_equal(preview.extend(audio), audio * 2)
        np.testing.assert_array_equal(np.concatenate(received), audio)
        self.assertTrue(all(len(chunk) <= 1280 for chunk in received))
        with self.assertRaises(ValueError):
            preview.extend(audio[:1300])
