"""Discard a recording only when the separator consistently leaves a weak residual."""

import numpy as np

from separate import SAMPLE_RATE

WINDOW_SAMPLES = SAMPLE_RATE * 3 // 2
HOP_SAMPLES = WINDOW_SAMPLES // 2
MAX_RESIDUAL_RMS = 0.002
MAX_RESIDUAL_POWER_RATIO = 10 ** (-30 / 10)


def _power(samples):
    return float(np.mean(np.square(samples, dtype=np.float64)))


def suppress_residual(raw, isolated):
    if len(isolated) > len(raw):
        raise ValueError("Isolated audio exceeds the input")
    if not len(isolated) or _power(isolated) > MAX_RESIDUAL_RMS ** 2:
        return isolated
    # Streaming output can be shorter than the received input. Compare only
    # the aligned prefix, and retain the entire recording if any window passes.
    last = max(0, len(isolated) - WINDOW_SAMPLES)
    starts = [*range(0, last, HOP_SAMPLES), last]
    for start in starts:
        window = slice(start, min(len(isolated), start + WINDOW_SAMPLES))
        if _power(isolated[window]) >= max(_power(raw[window]), 1e-12) * MAX_RESIDUAL_POWER_RATIO:
            return isolated
    return np.zeros_like(isolated)
