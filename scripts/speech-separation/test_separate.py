import unittest

import numpy as np

from separate import TargetSpeaker


class TargetSpeakerTests(unittest.TestCase):
    def setUp(self):
        self.a = np.tile(np.array([0.1, -0.1], dtype=np.float32), 16000)
        self.b = np.tile(np.array([0.1, 0.1, -0.1, -0.1], dtype=np.float32), 8000)

    def test_uses_all_references_and_follows_the_target_when_tracks_swap(self):
        calls = 0

        def separate(audio):
            nonlocal calls
            calls += 1
            return np.stack([self.a, self.b] if calls % 2 else [self.b, self.a])

        def embedding(audio):
            return np.array([audio[0], audio[1]]) / np.linalg.norm(audio[:2])

        filter = TargetSpeaker(separate, embedding, similarity_floor=0.5)
        mixed = np.concatenate([self.a + self.b] * 3)
        output = filter.run(mixed, filter.enroll([self.a, self.b]))
        self.assertEqual(len(output), len(mixed))
        self.assertGreater(calls, 1)
        self.assertTrue(np.isfinite(output).all())
        selected = filter.run(mixed, filter.enroll([self.b]))
        self.assertGreater(float(np.mean(selected * np.tile(self.b, 3))), 0.008)

    def test_rejects_a_window_with_a_different_speaker(self):
        matcher = TargetSpeaker(lambda audio: np.stack([audio, -audio]),
                                lambda audio: np.array([1, 0]), similarity_floor=0.5)
        filtered = matcher.run(self.a, np.array([[0, 1]]))
        self.assertFalse(np.any(filtered))

    def test_silence_is_preserved_without_running_the_separator(self):
        def unexpected(audio):
            self.fail("Silence does not need a model call")

        matcher = TargetSpeaker(unexpected, unexpected)
        self.assertEqual(matcher.run(np.zeros(123, dtype=np.float32), np.ones((1, 2))).shape, (123,))


if __name__ == "__main__":
    unittest.main()
