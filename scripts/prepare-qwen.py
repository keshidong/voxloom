#!/usr/bin/env python3
"""Pinned, workspace-local Qwen ASR + correction setup; runtime stays offline."""
from pathlib import Path
import hashlib
from importlib.metadata import distributions
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = ROOT / ".runtime"


def run(*args):
    subprocess.run(list(map(str, args)), cwd=ROOT, check=True)


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url, destination, checksum):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and sha(destination) == checksum:
        return
    partial = destination.with_name(destination.name + ".part")
    run("curl", "--http1.1", "--fail", "--location", "--retry", "3", "--retry-all-errors",
        "--connect-timeout", "20", "--output", partial, url)
    if sha(partial) != checksum:
        raise RuntimeError("Checksum mismatch: " + destination.name)
    partial.replace(destination)


def main():
    RUNTIME.mkdir(exist_ok=True)
    uv_archive = RUNTIME / "uv-aarch64-apple-darwin.tar.gz"
    download("https://github.com/astral-sh/uv/releases/download/0.13.9/uv-aarch64-apple-darwin.tar.gz", uv_archive,
             "5aeca67f2283f75235de40d0bd9c0a5bbc5fce23b6d48b3bf9fa1b2db08382ca")
    uv = RUNTIME / "uv-aarch64-apple-darwin/uv"
    if not uv.exists():
        run("tar", "-xzf", uv_archive, "-C", RUNTIME)
    os.environ["UV_CACHE_DIR"] = str(RUNTIME / "uv-cache")
    python_root = RUNTIME / "python-installs/cpython-3.12.16-macos-aarch64-none"
    python = python_root / "bin/python3.12"
    if not python.exists():
        run(uv, "python", "install", "3.12.16", "--install-dir", RUNTIME / "python-installs", "--no-bin")
    site = RUNTIME / "asr-site"
    installed = {d.metadata["Name"].lower().replace("_", "-"): d.version for d in distributions(path=[str(site)])}
    wanted = [line.strip().split("==") for line in (ROOT / "scripts/qwen-asr-requirements.txt").read_text().splitlines() if line.strip()]
    if any(installed.get(name.lower().replace("_", "-")) != version for name, version in wanted):
        run(uv, "pip", "install", "--python", python, "--target", site, "-r", ROOT / "scripts/qwen-asr-requirements.txt")

    revision = "78a389c776a5483b2d0d4ea5494e11012e0d6159"
    for name, checksum in json.loads((ROOT / "scripts/qwen-asr-assets.json").read_text()).items():
        download(f"https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit/resolve/{revision}/{name}",
                 ROOT / "models/Qwen3-ASR-1.7B-4bit" / name, checksum)
    download("https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
             ROOT / "models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
             "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597")

    archive = RUNTIME / "llama.cpp-1.0.0.tar.gz"
    download("https://github.com/ggml-org/llama.cpp/archive/refs/tags/v1.0.0.tar.gz", archive,
             "3f5f750e36326aea4d65c7623e7d597a33e395d65f4d76e5e0532171f252532b")
    source = RUNTIME / "llama.cpp-1.0.0"
    if not source.exists():
        run("tar", "-xzf", archive, "-C", RUNTIME)
    engine = RUNTIME / "llama-build/bin/llama-completion"
    if not engine.exists():
        cmake = shutil.which("cmake") or RUNTIME / "cmake-4.1.3-macos-universal/CMake.app/Contents/bin/cmake"
        run(cmake, "-S", source, "-B", RUNTIME / "llama-build", "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=OFF", "-DLLAMA_BUILD_TESTS=OFF", "-DLLAMA_BUILD_EXAMPLES=OFF",
            "-DLLAMA_BUILD_SERVER=OFF", "-DLLAMA_CURL=OFF", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0")
        run(cmake, "--build", RUNTIME / "llama-build", "--target", "llama-completion", "-j", "4")

    stage = RUNTIME / "qwen-asr-runtime"
    stage.mkdir(exist_ok=True)
    for name, target in [("asr-python", python_root), ("asr-site", site)]:
        if not (stage / name).exists():
            (stage / name).symlink_to(target, target_is_directory=True)
    for name in ["qwen-asr", "qwen_asr_worker.py"]:
        shutil.copy2(ROOT / "src/business/QwenASR/Runtime" / name, stage / name)
    (stage / "qwen-asr").chmod(0o755)
    print("Qwen ASR and correction resources verified and ready.")


if __name__ == "__main__":
    main()
