"""Compare target-speaker waveforms on every case in a public mixture split."""

import argparse
import json
import platform
from pathlib import Path
import subprocess
from time import perf_counter
import wave

import numpy as np

from models import load_matcher
from separate import SAMPLE_RATE, has_signal


def si_sdr(estimate, reference):
    estimate = np.asarray(estimate, dtype=np.float64)
    reference = np.asarray(reference, dtype=np.float64)
    estimate -= estimate.mean()
    reference -= reference.mean()
    projection = reference * (np.dot(estimate, reference) / max(np.dot(reference, reference), 1e-8))
    residual = estimate - projection
    if not np.any(estimate):
        return -60.0
    return float(10 * np.log10((np.dot(projection, projection) + 1e-8) /
                              (np.dot(residual, residual) + 1e-8)))


def cases_from_split(dataset):
    with np.load(dataset, allow_pickle=False) as arrays:
        if "languages" in arrays:
            yield from authored_cases(arrays)
            return
        audio = arrays["mixture"]
        sources = arrays["sources"]
        kinds = arrays["kinds"]
    for index, (mixture, tracks, labels) in enumerate(zip(audio, sources, kinds, strict=True)):
        speakers = tracks[labels == 1].astype(np.float32) / 32768
        midpoint = len(mixture) // 2
        # The reference comes from the isolated stem in the other half of the clip.
        # No samples from the scored interval are included in the reference.
        reference, target = np.split(speakers[0], [midpoint])
        if not has_signal(reference) or not has_signal(target):
            raise ValueError(f"Missing speech in case {index}")
        yield index, str(len(speakers)), mixture[midpoint:].astype(np.float32) / 32768, reference, speakers[:, midpoint:]


def authored_cases(arrays):
    offsets, clean, interference = (arrays[key] for key in ("offsets", "clean", "interferer"))
    references = arrays["references"].astype(np.float32) / 32768
    for index, (group, enrollment) in enumerate(zip(arrays["languages"], arrays["enrollments"], strict=True)):
        interval = slice(offsets[index], offsets[index + 1])
        sources = np.stack([clean[interval], interference[interval]]).astype(np.float32) / 32768
        yield index, str(group), sources.sum(axis=0), references[enrollment], sources


def write_wav(path, audio):
    with wave.open(str(path), "wb") as output:
        output.setparams((1, 2, SAMPLE_RATE, 0, "NONE", "not compressed"))
        output.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())


def summary(rows):
    multiple = [row for row in rows if row["wrong_speaker"] is not None]
    return {
        "cases": len(rows),
        "multi_speaker_cases": len(multiple),
        "mean_si_sdri_db": round(float(np.mean([row["si_sdri_db"] for row in rows])), 3),
        "median_si_sdri_db": round(float(np.median([row["si_sdri_db"] for row in rows])), 3),
        "degraded": sum(row["si_sdri_db"] < 0 for row in rows),
        "wrong_speaker": sum(row["wrong_speaker"] for row in multiple),
        "silent": sum(row["silent"] for row in rows),
        "p50_ms": round(float(np.percentile([row["milliseconds"] for row in rows], 50)), 1),
        "p95_ms": round(float(np.percentile([row["milliseconds"] for row in rows], 95)), 1),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--model", choices=["sepformer", "mossformer2", "voxlock"], required=True)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--backend", choices=["cpu", "accelerated"], default="cpu")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--examples", type=Path)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    start = perf_counter()
    model = load_matcher(args.assets.resolve(), args.model, args.threads, args.backend)
    load_ms = round((perf_counter() - start) * 1000, 1)
    rows = []
    for index, group, mixture, reference, sources in cases_from_split(args.dataset):
        registered = model.enroll([reference])
        begin = perf_counter()
        filtered = model.run(mixture, registered)
        elapsed = (perf_counter() - begin) * 1000
        target_score = si_sdr(filtered, sources[0])
        silent = not has_signal(filtered)
        wrong = (not silent and max(si_sdr(filtered, other) for other in sources[1:]) > target_score
                 if len(sources) > 1 else None)
        rows.append({"case": index, "speakers": group, "si_sdri_db": target_score - si_sdr(mixture, sources[0]),
                     "wrong_speaker": wrong, "silent": silent, "milliseconds": elapsed})
        if args.examples and index < 3:
            args.examples.mkdir(parents=True, exist_ok=True)
            for name, audio in [("mixture", mixture), ("reference", reference),
                                ("target", sources[0]), (args.model, filtered)]:
                write_wav(args.examples / f"{index:03d}-{name}.wav", audio)
        if (index + 1) % 25 == 0:
            print(f"{args.model}: {index + 1} cases", flush=True)
        if args.smoke:
            break
    chip = subprocess.run(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], text=True,
                          capture_output=True).stdout.strip() or platform.machine()
    report = {"model": args.model, "dataset": args.dataset.name, "chip": chip,
              "system": platform.platform(), "threads": args.threads, "backend": args.backend, "cold_load_ms": load_ms,
              "first_ms": round(rows[0]["milliseconds"], 1), "summary": summary(rows),
              "groups": {group: summary([row for row in rows if row["speakers"] == group])
                         for group in sorted({row["speakers"] for row in rows})}, "rows": rows}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "rows"}, indent=2))


if __name__ == "__main__":
    main()
