from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("prepare-demo.sh")


class DemoPreparationTest(unittest.TestCase):
    def test_prepare_only_stages_resources_without_building_a_demo_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copy2(SCRIPT, scripts / SCRIPT.name)
            (root / ".runtime").mkdir()
            (root / ".runtime/asr_zh.wav").touch()

            # Stand-ins for the resource installation and app build boundaries.
            shell = """
                bash() { :; }
                shasum() { echo '46dbc998c9d1d48111267c40741dd3200f2e5bcf4075f8c4c97f4451160dce50  asr_zh.wav'; }
                python3() {
                    case "$1" in
                        scripts/prepare-qwen.py) mkdir .runtime/qwen-asr-runtime ;;
                        scripts/make-demo.py) mkdir 'voxloom 0.3.2.app' ;;
                    esac
                }
                source "$0" "$@"
            """
            subprocess.run(
                ["/bin/bash", "-c", shell, str(scripts / SCRIPT.name), "--prepare-only"],
                cwd=root, check=True, capture_output=True, text=True,
            )

            self.assertTrue((root / ".runtime/qwen-asr-runtime").is_dir())
            self.assertEqual(list(root.glob("*.app")), [])


if __name__ == "__main__":
    unittest.main()
