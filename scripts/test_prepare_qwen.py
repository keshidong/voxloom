from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().with_name("prepare-qwen.py")


class QwenRuntimePreparationTest(unittest.TestCase):
    def test_same_version_cached_on_a_newer_mac_is_reinstalled_for_the_supported_os(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / ".runtime"
            for name in (
                ".runtime/uv-aarch64-apple-darwin/uv",
                ".runtime/python-installs/cpython-3.12.16-macos-aarch64-none/bin/python3.12",
                ".runtime/llama.cpp-1.0.0/.source",
                ".runtime/llama-build/bin/llama-completion",
                "src/business/QwenASR/Runtime/qwen-asr",
                "src/business/QwenASR/Runtime/qwen_asr_worker.py",
            ):
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.touch()

            requirements = root / "scripts/qwen-asr-requirements.txt"
            requirements.parent.mkdir()
            requirements.write_text("mlx==0.32.4\nmlx-metal==0.32.4\n")
            for name in ("mlx", "mlx-metal"):
                metadata = runtime / "asr-site" / f"{name.replace('-', '_')}-0.32.4.dist-info"
                metadata.mkdir(parents=True)
                (metadata / "METADATA").write_text(f"Name: {name}\nVersion: 0.32.4\n")
                (metadata / "WHEEL").write_text("Tag: cp312-cp312-macosx_26_0_arm64\n")

            prepare = runpy.run_path(str(SCRIPT))["main"]
            commands = Mock()
            with patch.dict(prepare.__globals__, ROOT=root, RUNTIME=runtime, download=Mock(), run=commands), \
                 patch.object(sys, "argv", [str(SCRIPT), "--runtime-only"]):
                prepare()
                prepare()

            installs = [call for call in commands.call_args_list if call.args[1:3] == ("pip", "install")]
            self.assertEqual(len(installs), 1)
            install = installs[0]
            self.assertIn("--reinstall", install.args)
            self.assertIn("--only-binary", install.args)
            self.assertEqual(install.args[install.args.index("--python-platform") + 1], "aarch64-apple-darwin")
            self.assertEqual(install.kwargs["env"]["MACOSX_DEPLOYMENT_TARGET"], "14.0")
            builds = [call for call in commands.call_args_list if call.args[1:2] == ("--build",)]
            self.assertTrue(any("llama-mtmd-cli" in call.args for call in builds))


if __name__ == "__main__":
    unittest.main()
