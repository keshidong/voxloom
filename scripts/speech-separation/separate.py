"""Target-speaker selection shared by the local worker and evaluation."""

import numpy as np

SAMPLE_RATE = 16_000
WINDOW = 2 * SAMPLE_RATE
HOP = 3 * SAMPLE_RATE // 2


def has_signal(audio):
    return float(np.mean(np.square(audio, dtype=np.float64))) > 1e-8


class TargetSpeaker:
    def __init__(self, separate, embedding, similarity_floor=0.35):
        self.separate = separate
        self.embedding = embedding
        self.similarity_floor = similarity_floor

    def enroll(self, references):
        embeddings = [self.embedding(clip) for clip in references if len(clip) and has_signal(clip)]
        if not embeddings:
            raise ValueError("At least one reference must contain voice")
        return np.asarray(embeddings, dtype=np.float32)

    def run(self, audio, enrollment):
        output = np.zeros_like(audio, dtype=np.float32)
        if not len(audio) or not has_signal(audio):
            return output
        weights = np.zeros_like(output)
        overlap = WINDOW - HOP
        fade = np.linspace(0, 1, overlap + 2, dtype=np.float32)[1:-1]
        for offset in range(0, len(audio), HOP):
            end = min(offset + WINDOW, len(audio))
            section = audio[offset:end]
            if has_signal(section):
                tracks = self.separate(np.pad(section, (0, WINDOW - len(section))))[:, :len(section)]
                if tracks.shape != (2, len(section)) or not np.isfinite(tracks).all():
                    raise ValueError("Invalid separator output")
                active = [track for track in tracks if has_signal(track)]
                if active:
                    scores = [float(np.max(enrollment @ self.embedding(track))) for track in active]
                    best = int(np.argmax(scores))
                    if scores[best] >= self.similarity_floor:
                        output[offset:end] += active[best] * self._weights(fade, len(section), offset > 0, end < len(audio))
            weights[offset:end] += self._weights(fade, len(section), offset > 0, end < len(audio))
            if end == len(audio):
                break
        return output / weights

    @staticmethod
    def _weights(fade, count, previous, following):
        weights = np.ones(count, dtype=np.float32)
        overlap = min(count, len(fade))
        if previous:
            weights[:overlap] = fade[:overlap]
        if following:
            weights[-overlap:] = fade[::-1][-overlap:]
        return weights
