#!/usr/bin/env python3
"""Prepare pinned VoxLock weights and their offline runtime for Voxloom."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = ROOT / ".runtime"
DESTINATION = RUNTIME / "voice-isolation-runtime"


def stage_weight(source, destination, asset):
    if source:
        shutil.copy2(source / destination.name, destination)
    else:
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--connect-timeout", "20",
                        "--output", str(destination), asset["url"]], check=True)
    digest = hashlib.sha256()
    with destination.open("rb") as content:
        for block in iter(lambda: content.read(8 * 1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != asset["sha256"]:
        raise ValueError(f"Checksum mismatch: {destination.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--weights", type=Path, help="Use a local copy of the two published ONNX files")
    mode.add_argument("--runtime-only", action="store_true", help="Skip model weights")
    arguments = parser.parse_args()
    python = RUNTIME / "qwen-asr-runtime/asr-python/bin/python3.12"
    uv = RUNTIME / "uv-aarch64-apple-darwin/uv"
    if not python.is_file() or not uv.is_file():
        parser.error("Run python3 scripts/prepare-qwen.py first")

    with tempfile.TemporaryDirectory(dir=RUNTIME, prefix="prepare-isolation-") as directory:
        stage = Path(directory) / DESTINATION.name
        stage.mkdir()
        if not arguments.runtime_only:
            assets = json.loads((ROOT / "scripts/model-downloads.json").read_text())
            (stage / "voxlock").mkdir()
            for asset in assets["voiceIsolation"]:
                stage_weight(arguments.weights, stage / asset["path"], asset)
        elif (DESTINATION / "voxlock").is_dir():
            shutil.copytree(DESTINATION / "voxlock", stage / "voxlock")
        environment = {**os.environ, "UV_CACHE_DIR": str(RUNTIME / "uv-cache")}
        subprocess.run([str(uv), "pip", "install", "--python", str(python), "--only-binary", ":all:",
                        "--target", str(stage / "site"), "voxlock==1.2.0", "onnxruntime==1.24.4",
                        "numpy==2.2.6", "huggingface-hub==0.33.5"], env=environment, check=True)
        for name in ("voice-isolation", "voice_worker.py", "models.py", "residual.py", "separate.py", "voxlock_model.py"):
            shutil.copy2(ROOT / "scripts/speech-separation" / name, stage / name)
        (stage / "voice-isolation").chmod(0o755)
        (stage / "engine.json").write_text(json.dumps({"model": "voxlock", "backend": "cpu", "threads": 4}) + "\n")
        if DESTINATION.exists():
            shutil.rmtree(DESTINATION)
        stage.rename(DESTINATION)
    print(DESTINATION)


if __name__ == "__main__":
    main()
