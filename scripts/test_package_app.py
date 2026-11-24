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
    def test_voxloom_display_name_follows_the_bundle_language(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for resource in (
                ".build/release/voxloom",
                ".runtime/whisper-build/bin/whisper-cli",
                ".runtime/asr_zh.wav",
                ".runtime/whisper.cpp-1.8.2/samples/jfk.wav",
                ".runtime/RxSwift-6.10.2/LICENSE.md",
                ".runtime/whisper.cpp-1.8.2/LICENSE",
                ".runtime/llama-build/bin/llama-completion",
                ".runtime/llama.cpp-1.0.0/LICENSE",
                ".runtime/asr-site/packaging-26.3.dist-info/licenses/LICENSE.APACHE",
                ".runtime/qwen-asr-runtime/qwen-asr",
                "scripts/model-downloads.json",
            ):
                file = root / resource
                file.parent.mkdir(parents=True, exist_ok=True)
                file.touch()

            main = runpy.run_path(str(SCRIPT))["main"]
            with patch.dict(main.__globals__, ROOT=root), patch.object(sys, "argv", [
                str(SCRIPT), "--external-models", "--output", "Staged.app",
                "--version", "0.1.2", "--build-number", "14",
            ]), patch.object(subprocess, "run"):
                main()

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
