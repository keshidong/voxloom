#!/usr/bin/env python3
"""Build a self-contained offline Qwen ASR + LLM macOS demo."""
from pathlib import Path
import argparse
import os
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="语音转写 Demo 0.3.1.app")
    parser.add_argument("--bundle-id", default="dev.voiceinput.whisper.demo.v31")
    arguments = parser.parse_args()
    subprocess.run(["bash", "scripts/swift-command.sh", "build", "-c", "release", "--product", "voice-demo"], cwd=ROOT, check=True)
    app = ROOT / arguments.output
    contents = app / "Contents"
    executable = contents / "MacOS"
    resources = contents / "Resources"
    executable.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / ".build/release/voice-demo", executable / "voice-demo")
    source_files = {
        "whisper-cli": ROOT / ".runtime/whisper-build/bin/whisper-cli",
        "ggml-tiny.bin": ROOT / "models/ggml-tiny.bin",
        "ggml-base.bin": ROOT / "models/ggml-base.bin",
        "ggml-silero-v5.1.2.bin": ROOT / "models/ggml-silero-v5.1.2.bin",
        "ggml-large-v3-turbo-q5_0.bin": ROOT / "models/ggml-large-v3-turbo-q5_0.bin",
        "chinese.wav": ROOT / ".runtime/asr_zh.wav",
        "english.wav": ROOT / ".runtime/whisper.cpp-1.8.2/samples/jfk.wav",
        "RxSwift-LICENSE.txt": ROOT / ".runtime/RxSwift-6.10.2/LICENSE.md",
        "whisper-LICENSE.txt": ROOT / ".runtime/whisper.cpp-1.8.2/LICENSE",
        "llama-completion": ROOT / ".runtime/llama-build/bin/llama-completion",
        "llama-LICENSE.txt": ROOT / ".runtime/llama.cpp-1.0.0/LICENSE",
        "Qwen3-4B-Instruct-2507-Q4_K_M.gguf": ROOT / "models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        "Qwen-models-LICENSE.txt": ROOT / ".runtime/asr-site/packaging-26.3.dist-info/licenses/LICENSE.APACHE",
    }
    for name, source in source_files.items():
        destination = resources / name
        if destination.exists():
            destination.unlink()
        # Hard links avoid duplicating weights while remaining self-contained.
        try:
            os.link(source, destination)
        except OSError:
            shutil.copy2(source, destination)
    for bundle in (ROOT / ".build/release").glob("RxSwift_*.bundle"):
        shutil.copytree(bundle, resources / bundle.name, dirs_exist_ok=True)
    def link_or_copy(source, destination):
        if os.path.exists(destination):
            os.unlink(destination)
        try:
            os.link(source, destination)
        except OSError:
            shutil.copy2(source, destination)
        return destination
    shutil.copytree(ROOT / "models/Qwen3-ASR-1.7B-4bit", resources / "Qwen3-ASR-1.7B-4bit",
                    copy_function=link_or_copy, dirs_exist_ok=True)
    # Resolve staging links so the application has no dependency on the workspace.
    shutil.copytree(ROOT / ".runtime/qwen-asr-runtime", resources / "qwen-asr-runtime",
                    symlinks=False, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    info = {
        "CFBundleName": app.stem, "CFBundleDisplayName": app.stem,
        "CFBundleExecutable": "voice-demo", "CFBundleIdentifier": arguments.bundle_id,
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.3.1", "CFBundleVersion": "4",
        "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
        "NSMicrophoneUsageDescription": "点击开始录音后，使用麦克风进行本机离线语音转写。音频不会上传。",
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    # Sign a separate copied executable: never modify hard-linked engine resources.
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run(["codesign", "--verify", str(app)], check=True)
    print(app)


if __name__ == "__main__":
    main()
