#!/usr/bin/env python3
"""Package Voxloom or the legacy demo with the shared inference runtimes."""
from pathlib import Path
import argparse
import os
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
APP_ICON = ROOT / "src/business/VoxloomDesktop/App/Resources/AppIcon.icns"
MINIMUM_MACOS = "14.0"


def verify_mlx_runtime(runtime):
    mlx = runtime / "asr-site/mlx"
    extensions = list(mlx.glob("core.*.so"))
    libraries = list((mlx / "lib").glob("*.dylib"))
    if not extensions or mlx / "lib/libmlx.dylib" not in libraries:
        raise RuntimeError("Qwen ASR runtime is missing. Run python3 scripts/prepare-qwen.py --runtime-only.")
    supported_version = tuple(map(int, MINIMUM_MACOS.split("."))) + (0,)
    for binary in extensions + libraries:
        build_info = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
        versions = re.findall(r"^\s*minos\s+(\d+(?:\.\d+){1,2})\s*$", build_info, re.MULTILINE)
        if not versions:
            raise RuntimeError(f"Cannot verify the minimum macOS version of {binary.name}")
        for version in versions:
            reported_version = (tuple(map(int, version.split("."))) + (0,))[:3]
            if reported_version > supported_version:
                raise RuntimeError(f"{binary.name} requires macOS {version}, but Voxloom supports {MINIMUM_MACOS}. "
                                   "Run python3 scripts/prepare-qwen.py --runtime-only.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--product", choices=("voxloom", "voice-demo"), default="voxloom")
    parser.add_argument("-c", "--configuration", choices=("debug", "release"), default="release")
    parser.add_argument("--output")
    parser.add_argument("--bundle-id")
    parser.add_argument("--version", help="App version in major.minor.patch form")
    parser.add_argument("--build-number", help="Positive integer identifying this build")
    parser.add_argument("--external-models", action="store_true",
                        help="Include the model download catalog and omit model weights from Voxloom")
    parser.add_argument("--voice-isolation", action="store_true",
                        help="Include the prepared offline voice isolation runtime in Voxloom")
    parser.add_argument("--check-qwen-runtime", type=Path, metavar="APP",
                        help="Check macOS compatibility of the Qwen runtime in an existing App bundle")
    arguments = parser.parse_args()
    if arguments.check_qwen_runtime is not None:
        runtime = arguments.check_qwen_runtime / "Contents/Resources/qwen-asr-runtime"
        verify_mlx_runtime(runtime)
        print(f"Bundled Qwen runtime supports the macOS {MINIMUM_MACOS} deployment target.")
        return
    if arguments.version is not None and not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", arguments.version):
        parser.error("--version must contain three numeric components")
    if arguments.build_number is not None and not re.fullmatch(r"[1-9][0-9]*", arguments.build_number):
        parser.error("--build-number must be a positive integer")
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
    bundle_name = "Voxloom" if standalone else "voxloom 0.3.2"
    identifier = "dev.voxloom.app" if standalone else "dev.voxloom.demo.v032"
    if arguments.configuration == "debug":
        bundle_name += " Debug"
        identifier += ".debug"
    output = arguments.output or f"{bundle_name}.app"
    bundle_id = arguments.bundle_id or identifier
    build_path = ROOT / ".build" / arguments.configuration
    qwen_runtime = ROOT / ".runtime/qwen-asr-runtime"
    verify_mlx_runtime(qwen_runtime)
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
        "llama-LICENSE.txt": ROOT / ".runtime/llama.cpp-1.0.0/LICENSE",
        "Qwen-models-LICENSE.txt": ROOT / ".runtime/asr-site/packaging-26.3.dist-info/licenses/LICENSE.APACHE",
    }
    weights = (
        "ggml-tiny.bin", "ggml-base.bin", "ggml-silero-v5.1.2.bin", "ggml-large-v3-turbo-q5_0.bin",
    )
    demo_text_model = "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
    if standalone:
        source_files["vad-speech-segments"] = ROOT / ".runtime/whisper-build/bin/vad-speech-segments"
        source_files["voxloom-vad"] = ROOT / ".runtime/whisper-build/bin/voxloom-vad"
        (resources / "llama-completion").unlink(missing_ok=True)
        (resources / demo_text_model).unlink(missing_ok=True)
    else:
        source_files["llama-completion"] = ROOT / ".runtime/llama-build/bin/llama-completion"
        weights += (demo_text_model,)
    qwen_model = "Qwen3-ASR-1.7B-4bit"
    catalog = "model-downloads.json"
    if arguments.external_models:
        source_files[catalog] = ROOT / "scripts" / catalog
        source_files["llama-mtmd-cli"] = ROOT / ".runtime/llama-build/bin/llama-mtmd-cli"
        source_files["llama-server"] = ROOT / ".runtime/llama-build/bin/llama-server"
        for name in weights:
            (resources / name).unlink(missing_ok=True)
        if (resources / qwen_model).exists():
            shutil.rmtree(resources / qwen_model)
    else:
        (resources / catalog).unlink(missing_ok=True)
        (resources / "llama-mtmd-cli").unlink(missing_ok=True)
        (resources / "llama-server").unlink(missing_ok=True)
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
    qwen_destination = resources / qwen_runtime.name
    if qwen_destination.exists():
        shutil.rmtree(qwen_destination)
    shutil.copytree(qwen_runtime, qwen_destination, symlinks=False,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
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
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": arguments.version or ("0.1.0" if standalone else "0.3.2"),
        "CFBundleVersion": arguments.build_number or ("1" if standalone else "5"),
        "LSMinimumSystemVersion": MINIMUM_MACOS, "NSHighResolutionCapable": True,
        "NSMicrophoneUsageDescription": "点击开始录音后，使用麦克风进行本机离线语音转写。音频不会上传。",
    }
    if standalone:
        shutil.copy2(APP_ICON, resources / APP_ICON.name)
        menu_icon = APP_ICON.with_name("MenuBarIcon.svg")
        shutil.copy2(menu_icon, resources / menu_icon.name)
        info["CFBundleName"] = bundle_name
        info["CFBundleDisplayName"] = bundle_name
        info["CFBundleDevelopmentRegion"] = "en"
        info["CFBundleIconFile"] = APP_ICON.name
        info["LSUIElement"] = True
        info["NSMicrophoneUsageDescription"] = "按住 Fn 说话时，使用麦克风进行本机离线转写。音频不会上传。"
        chinese_name = "小声哔哔 Debug" if arguments.configuration == "debug" else "小声哔哔"
        for language, display_name in (("en", bundle_name), ("zh-Hans", chinese_name), ("zh-Hant", chinese_name)):
            localization = resources / f"{language}.lproj"
            localization.mkdir(exist_ok=True)
            (localization / "InfoPlist.strings").write_text(
                f'"CFBundleDisplayName" = "{display_name}";\n"CFBundleName" = "{display_name}";\n',
                encoding="utf-8",
            )
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    # Sign a separate copied executable: never modify hard-linked engine resources.
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run(["codesign", "--verify", str(app)], check=True)
    print(app)


if __name__ == "__main__":
    main()
