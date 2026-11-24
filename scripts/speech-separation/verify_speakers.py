"""Compare speaker embeddings on target-only and interferer-only recordings."""

import argparse
from collections import defaultdict
import json
from pathlib import Path
from time import perf_counter

import numpy as np

from benchmark import cases_from_split
from models import load_embedding


def equal_error_rate(positive, negative):
    thresholds = np.unique(np.concatenate([positive, negative, [np.inf]]))
    missed = np.searchsorted(np.sort(positive), thresholds, side="left")
    admitted = len(negative) - np.searchsorted(np.sort(negative), thresholds, side="left")
    fnr, fpr = missed / len(positive), admitted / len(negative)
    best = int(np.argmin(np.abs(fnr - fpr)))
    return {"eer_pct": round(float(50 * (fnr[best] + fpr[best])), 2),
            "missed_targets": int(missed[best]), "accepted_other": int(admitted[best]),
            "threshold": round(float(thresholds[best]), 5)}


def verify(dataset, embedding):
    splits = defaultdict(list)
    known = {}
    for _, language, _, reference, sources in cases_from_split(dataset):
        if len(sources) != 2:
            continue
        key = reference.tobytes()
        if key not in known:
            known[key] = embedding(reference)
        started = perf_counter()
        positive = float(known[key] @ embedding(sources[0]))
        negative = float(known[key] @ embedding(sources[1]))
        splits[language].append((positive, negative, (perf_counter() - started) * 500))
    report = {}
    for group, trials in sorted(splits.items()):
        positive, negative, milliseconds = zip(*trials, strict=True)
        report[group] = {**equal_error_rate(positive, negative), "pairs": len(trials),
                         "p95_ms_per_clip": round(float(np.percentile(milliseconds, 95)), 1)}
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    args = parser.parse_args()
    report = {
        model: verify(args.dataset, load_embedding(args.assets / f"{model}.onnx", 2))
        for model in ("campplus", "eres2netv2")
    }
    print(json.dumps(report, indent=2))
