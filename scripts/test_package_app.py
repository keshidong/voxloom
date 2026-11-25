from pathlib import Path
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().with_name("package-app.py")


class AppBundlePackagingTest(unittest.TestCase):
    def test_voxloom_packages_the_voice_activity_tool_without_the_external_weights(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.package(root, mlx_minimum="14.0")

            resources = root / "Staged.app/Contents/Resources"
            self.assertTrue((resources / "vad-speech-segments").is_file())
            self.assertFalse((resources / "ggml-silero-v5.1.2.bin").exists())

    def test_voxloom_display_name_follows_the_bundle_language(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.package(root, mlx_minimum="14.0")

            contents = root / "Staged.app/Contents"
            with (contents / "Info.plist").open("rb") as file:
                info = plistlib.load(file)
            self.assertEqual(info["CFBundleIdentifier"], "dev.voxloom.app")
            self.assertEqual(info["CFBundleDisplayName"], "Voxloom")
            self.assertEqual(info["CFBundleDevelopmentRegion"], "en")
            self.assertEqual(info["CFBundleShortVersionString"], "0.1.2")
            self.assertEqual(info["CFBundleVersion"], "14")
            self.assertTrue((contents / "Resources" / info["CFBundleIconFile"]).is_file())
            self.assertTrue((contents / "Resources/MenuBarIcon.svg").is_file())

            for language, name in (("en", "Voxloom"), ("zh-Hans", "小声哔哔"), ("zh-Hant", "小声哔哔")):
                with self.subTest(language=language):
                    strings = contents / "Resources" / f"{language}.lproj/InfoPlist.strings"
                    localization = plistlib.loads(subprocess.check_output([
                        "plutil", "-convert", "xml1", "-o", "-", str(strings),
                    ]))
                    self.assertEqual(localization["CFBundleDisplayName"], name)
                    self.assertEqual(localization["CFBundleName"], name)

    def test_packaging_rejects_an_mlx_runtime_newer_than_the_apps_minimum_system(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "requires macOS 26.2"):
                self.package(Path(directory), mlx_minimum="26.2")

    def test_checks_the_qwen_runtime_in_an_existing_app_without_building(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Voxloom.app"
            mlx = app / "Contents/Resources/qwen-asr-runtime/asr-site/mlx"
            binaries = [mlx / "core.cpython-312-darwin.so", mlx / "lib/libmlx.dylib"]
            for binary in binaries:
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.touch()

            main = runpy.run_path(str(SCRIPT))["main"]
            command = [str(SCRIPT), "--check-qwen-runtime", str(app)]
            with patch.object(sys, "argv", command), patch.object(subprocess, "run") as build, \
                 patch.object(subprocess, "check_output", return_value="    minos 14.0\n") as inspect:
                main()

            build.assert_not_called()
            self.assertEqual({Path(call.args[0][-1]) for call in inspect.call_args_list}, set(binaries))

    def package(self, root, mlx_minimum):
        for resource in (
            ".build/release/voxloom",
            ".runtime/whisper-build/bin/whisper-cli",
            ".runtime/whisper-build/bin/vad-speech-segments",
            ".runtime/asr_zh.wav",
            ".runtime/whisper.cpp-1.8.2/samples/jfk.wav",
            ".runtime/RxSwift-6.10.2/LICENSE.md",
            ".runtime/whisper.cpp-1.8.2/LICENSE",
            ".runtime/llama-build/bin/llama-completion",
            ".runtime/llama.cpp-1.0.0/LICENSE",
            ".runtime/asr-site/packaging-26.3.dist-info/licenses/LICENSE.APACHE",
            ".runtime/qwen-asr-runtime/qwen-asr",
            ".runtime/qwen-asr-runtime/asr-site/mlx/core.cpython-312-darwin.so",
            ".runtime/qwen-asr-runtime/asr-site/mlx/lib/libmlx.dylib",
            "scripts/model-downloads.json",
        ):
            file = root / resource
            file.parent.mkdir(parents=True, exist_ok=True)
            file.touch()

        main = runpy.run_path(str(SCRIPT))["main"]
        command = [str(SCRIPT), "--external-models", "--output", "Staged.app",
                   "--version", "0.1.2", "--build-number", "14"]
        build_info = (f"      cmd LC_BUILD_VERSION\n platform MACOS\n    minos {mlx_minimum}\n      sdk 26.5\n"
                      "   ntools 1\n     tool LD\n  version 1267.0\n")
        with patch.dict(main.__globals__, ROOT=root), patch.object(sys, "argv", command), \
             patch.object(subprocess, "run"), patch.object(subprocess, "check_output", return_value=build_info):
            main()
