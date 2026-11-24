#!/usr/bin/env python3
"""Package either desktop executable with the shared offline model resources."""
from pathlib import Path
import argparse
import os
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
APP_ICON = ROOT / "src/business/VoxloomDesktop/App/Resources/AppIcon.icns"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--product", choices=("voice-demo", "voxloom"), default="voice-demo")
    parser.add_argument("-c", "--configuration", choices=("debug", "release"), default="release")
    parser.add_argument("--output")
    parser.add_argument("--bundle-id")
    parser.add_argument("--external-models", action="store_true",
                        help="Include the model download catalog and omit model weights from Voxloom")
    parser.add_argument("--voice-isolation", action="store_true",
                        help="Include the prepared offline voice isolation runtime in Voxloom")
    arguments = parser.parse_args()
    standalone = arguments.product == "voxloom"
    if arguments.external_models and not standalone:
        parser.error("--external-models requires --product voxloom")
    isolation_runtime = ROOT / ".runtime/voice-isolation-runtime"
    if arguments.voice_isolation:
        if not standalone:
            parser.error("--voice-isolation requires --product voxloom")
        if not (isolation_runtime / "voice-isolation").is_file():
            parser.error("Run python3 scripts/prepare-voice-isolation.py first")
        if not arguments.external_models and not (isolation_runtime / "voxlock/chunk_int8.onnx").is_file():
            parser.error("Run python3 scripts/prepare-voice-isolation.py with model weights first")
    name = "Voxloom" if standalone else "voxloom 0.3.2"
    identifier = "dev.voxloom.app" if standalone else "dev.voxloom.demo.v032"
    if arguments.configuration == "debug":
        name += " Debug"
        identifier += ".debug"
    output = arguments.output or f"{name}.app"
    bundle_id = arguments.bundle_id or identifier
    build_path = ROOT / ".build" / arguments.configuration
    subprocess.run(["bash", "scripts/swift-command.sh", "build", "-c", arguments.configuration,
                    "--product", arguments.product],
                   cwd=ROOT, check=True)
    app = ROOT / output
    contents = app / "Contents"
    executable = contents / "MacOS"
    resources = contents / "Resources"
    executable.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(build_path / arguments.product, executable / arguments.product)
    source_files = {
        "whisper-cli": ROOT / ".runtime/whisper-build/bin/whisper-cli",
        "chinese.wav": ROOT / ".runtime/asr_zh.wav",
        "english.wav": ROOT / ".runtime/whisper.cpp-1.8.2/samples/jfk.wav",
        "RxSwift-LICENSE.txt": ROOT / ".runtime/RxSwift-6.10.2/LICENSE.md",
        "whisper-LICENSE.txt": ROOT / ".runtime/whisper.cpp-1.8.2/LICENSE",
        "llama-completion": ROOT / ".runtime/llama-build/bin/llama-completion",
        "llama-LICENSE.txt": ROOT / ".runtime/llama.cpp-1.0.0/LICENSE",
        "Qwen-models-LICENSE.txt": ROOT / ".runtime/asr-site/packaging-26.3.dist-info/licenses/LICENSE.APACHE",
    }
    weights = (
        "ggml-tiny.bin", "ggml-base.bin", "ggml-silero-v5.1.2.bin", "ggml-large-v3-turbo-q5_0.bin",
        "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
    )
    qwen_model = "Qwen3-ASR-1.7B-4bit"
    catalog = "model-downloads.json"
    if arguments.external_models:
        source_files[catalog] = ROOT / "scripts" / catalog
        for name in weights:
            (resources / name).unlink(missing_ok=True)
        if (resources / qwen_model).exists():
            shutil.rmtree(resources / qwen_model)
    else:
        (resources / catalog).unlink(missing_ok=True)
        source_files.update({name: ROOT / "models" / name for name in weights})
    for name, source in source_files.items():
        destination = resources / name
        if destination.exists():
            destination.unlink()
        # Hard links avoid duplicating weights while remaining self-contained.
        try:
            os.link(source, destination)
        except OSError:
            shutil.copy2(source, destination)
    for bundle in build_path.glob("RxSwift_*.bundle"):
        shutil.copytree(bundle, resources / bundle.name, dirs_exist_ok=True)
    def link_or_copy(source, destination):
        if os.path.exists(destination):
            os.unlink(destination)
        try:
            os.link(source, destination)
        except OSError:
            shutil.copy2(source, destination)
        return destination
    if not arguments.external_models:
        shutil.copytree(ROOT / "models" / qwen_model, resources / qwen_model,
                        copy_function=link_or_copy, dirs_exist_ok=True)
    # Resolve staging links so the application has no dependency on the workspace.
    shutil.copytree(ROOT / ".runtime/qwen-asr-runtime", resources / "qwen-asr-runtime",
                    symlinks=False, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    isolation_destination = resources / "voice-isolation-runtime"
    if isolation_destination.exists():
        shutil.rmtree(isolation_destination)
    if arguments.voice_isolation:
        ignore_cache = shutil.ignore_patterns("__pycache__", "*.pyc")

        def ignore_isolation_files(directory, names):
            ignored = ignore_cache(directory, names)
            if arguments.external_models and Path(directory) == isolation_runtime:
                ignored.add("voxlock")
            return ignored

        shutil.copytree(isolation_runtime, isolation_destination,
                        ignore=ignore_isolation_files)
    info = {
        "CFBundleName": app.stem, "CFBundleDisplayName": app.stem,
        "CFBundleExecutable": arguments.product, "CFBundleIdentifier": bundle_id,
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0" if standalone else "0.3.2",
        "CFBundleVersion": "1" if standalone else "5",
        "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
        "NSMicrophoneUsageDescription": "点击开始录音后，使用麦克风进行本机离线语音转写。音频不会上传。",
    }
    if standalone:
        shutil.copy2(APP_ICON, resources / APP_ICON.name)
        info["CFBundleIconFile"] = APP_ICON.name
        info["LSUIElement"] = True
        info["NSMicrophoneUsageDescription"] = "按住 Fn 说话时，使用麦克风进行本机离线转写。音频不会上传。"
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    # Sign a separate copied executable: never modify hard-linked engine resources.
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run(["codesign", "--verify", str(app)], check=True)
    print(app)


if __name__ == "__main__":
    main()
