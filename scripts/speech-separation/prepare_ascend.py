"""Build two-speaker mixtures for every utterance in the official ASCEND test set."""

import argparse
from bisect import bisect_left
from collections import defaultdict
import io
from pathlib import Path
import wave

import duckdb
import numpy as np

from separate import SAMPLE_RATE, has_signal


def decode(payload):
    with wave.open(io.BytesIO(payload), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, SAMPLE_RATE):
            raise ValueError("ASCEND audio must be 16 kHz mono PCM16")
        return np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float32) / 32768


def build(parquet, output):
    with duckdb.connect() as connection:
        rows = connection.execute(
            """SELECT id, language, original_speaker_id, session_id, audio.bytes
               FROM read_parquet(?) ORDER BY id""", [str(parquet)]).fetchall()
    audio = [decode(row[4]) for row in rows]
    by_language = defaultdict(list)
    for index, (_, language, speaker, _, _) in enumerate(rows):
        by_language[language, speaker].append((len(audio[index]), index))
    for group in by_language.values():
        group.sort()
    speakers = sorted({row[2] for row in rows})
    reference_keys = sorted({(row[2], row[3]) for row in rows})
    reference_ids = []
    for speaker, session in reference_keys:
        candidates = [
            index for count, index in by_language["zh", speaker]
            if rows[index][3] != session and count >= 3 * SAMPLE_RATE
            and has_signal(audio[index][:3 * SAMPLE_RATE])
        ]
        if not candidates:
            raise ValueError(f"No independent 3-second Mandarin enrollment for {speaker} / {session}")
        reference_ids.append(min(candidates, key=lambda index: abs(len(audio[index]) - 4 * SAMPLE_RATE)))

    rng = np.random.default_rng(7301)
    clean_tracks, interference_tracks = [], []
    labels, enrollments, offsets = [], [], [0]
    interferer_ids, target_ids, relative_levels = [], [], []
    for index, (identifier, language, speaker, session, _) in enumerate(rows):
        clean = audio[index]
        candidates = sorted(
            item for other in speakers if other != speaker for item in by_language[language, other]
        )
        start = min(bisect_left(candidates, (len(clean), -1)), max(0, len(candidates) - 16))
        _, other = candidates[start + int(rng.integers(min(16, len(candidates) - start)))]
        interferer = audio[other]
        if len(interferer) > len(clean):
            offset = int(rng.integers(len(interferer) - len(clean) + 1))
            interferer = interferer[offset:offset + len(clean)]
        interferer = np.pad(interferer, (0, len(clean) - len(interferer)))
        level = int(rng.choice([-6, 0, 6]))
        target_level = np.linalg.norm(clean)
        other_level = np.linalg.norm(interferer)
        if not target_level or not other_level:
            raise ValueError(f"Silent source audio in {identifier}")
        interferer = interferer * (target_level / other_level * 10 ** (-level / 20))
        scale = min(1.0, 0.95 / max(float(np.max(np.abs(clean + interferer))),
                                    float(np.max(np.abs(clean))), float(np.max(np.abs(interferer)))))
        padding = max(0, 8 * SAMPLE_RATE // 10 - len(clean))
        clean_tracks.append(np.pad((clean * (32768 * scale)).astype("<i2"), (0, padding)))
        interference_tracks.append(np.pad((interferer * (32768 * scale)).astype("<i2"), (0, padding)))
        offsets.append(offsets[-1] + len(clean) + padding)
        enrollments.append(reference_keys.index((speaker, session)))
        labels.append(language)
        target_ids.append(identifier)
        interferer_ids.append(rows[other][0])
        relative_levels.append(level)

    output.parent.mkdir(parents=True, exist_ok=True)
    np.savez(output, offsets=offsets, clean=np.concatenate(clean_tracks),
             interferer=np.concatenate(interference_tracks), enrollments=enrollments, languages=labels,
             references=[(audio[index][:3 * SAMPLE_RATE] * 32768).astype("<i2") for index in reference_ids],
             reference_ids=[rows[index][0] for index in reference_ids], target_ids=target_ids,
             interferer_ids=interferer_ids, sir_db=relative_levels)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("parquet", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build(args.parquet, args.output)
