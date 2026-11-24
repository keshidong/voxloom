"""Use a fixed three-second enrollment assembled from the saved speaking styles."""

import numpy as np

from separate import SAMPLE_RATE, has_signal


def combine_references(references):
    if not 1 <= len(references) <= 3 or any(len(ref) < 3 * SAMPLE_RATE or not has_signal(ref) for ref in references):
        raise ValueError("Provide one to three reference clips, at least three seconds each")
    lengths = [3 * SAMPLE_RATE // len(references)] * len(references)
    lengths[-1] += 3 * SAMPLE_RATE - sum(lengths)
    parts = []
    for reference, length in zip(references, lengths, strict=True):
        step = SAMPLE_RATE // 100
        energy = np.square(reference[:len(reference) // step * step]).reshape(-1, step).mean(axis=1)
        start = int(np.argmax(np.convolve(energy, np.ones(length // step), mode="valid"))) * step
        start = min(start, len(reference) - length)
        part = reference[start:start + length].copy()
        fade = np.linspace(0, 1, step, dtype=np.float32)
        part[:step] *= fade
        part[-step:] *= fade[::-1]
        parts.append(part)
    if len(parts) > 1:
        levels = [float(np.sqrt(np.mean(part ** 2))) for part in parts]
        target_level = float(np.median(levels))
        for part, level in zip(parts, levels, strict=True):
            gain = np.clip(target_level / max(level, 1e-8), 0.25, 4.0)
            part *= min(gain, 0.95 / max(float(np.max(np.abs(part))), 1e-8))
    return np.concatenate(parts)


class VoxLockPreview:
    """Keep the streaming state for one recording as its PCM prefix grows."""

    def __init__(self, stream):
        self.stream = stream
        self.consumed = 0
        self.parts = []

    def extend(self, audio):
        if len(audio) < self.consumed:
            raise ValueError("Preview audio must be an append-only prefix")
        step = 80 * SAMPLE_RATE // 1000
        for start in range(self.consumed, len(audio), step):
            filtered = self.stream.push(audio[start:start + step])
            if not np.isfinite(filtered).all():
                raise ValueError("Invalid VoxLock preview output")
            self.parts.append(filtered)
        self.consumed = len(audio)
        return np.concatenate(self.parts) if self.parts else np.zeros(0, dtype=np.float32)


class VoxLockModel:
    def __init__(self, assets, threads):
        import voxlock

        weights = assets / "voxlock"
        if not all((weights / name).is_file() for name in ("enroll.onnx", "chunk_int8.onnx")):
            raise ValueError("Missing bundled VoxLock weights")
        self.model = voxlock.VoxLock(model_dir=weights, precision="int8", threads=threads)

    def enroll(self, references):
        return combine_references(references)

    def preview(self, enrollment):
        return VoxLockPreview(self.model.stream(enrollment))

    def run(self, audio, enrollment):
        if not len(audio) or not has_signal(audio):
            return np.zeros_like(audio)
        # The upstream STFT needs a few hundred samples for its reflected padding.
        source = np.pad(audio, (0, max(0, 512 - len(audio))))
        result = self.model.isolate(source, sample=enrollment)
        if result.shape != source.shape or not np.isfinite(result).all():
            raise ValueError("Invalid VoxLock output")
        return result[:len(audio)]
