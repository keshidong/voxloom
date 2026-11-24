from pathlib import Path
import runpy
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().with_name("make-dmg.py")


class DiskImagePackagingTest(unittest.TestCase):
    def test_debug_image_stages_app_and_install_shortcut(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "distribution" / "Voxloom-debug.dmg"
            app_name = "Voxloom Debug.app"
            verified = []

            def run_command(command, **kwargs):
                if command[0] == sys.executable:
                    self.assertEqual(command[1:6], [
                        "scripts/make-demo.py", "--product", "voxloom", "--configuration", "debug",
                    ])
                    app = Path(command[command.index("--output") + 1])
                    self.assertEqual(app.name, app_name)
                    self.assertIn("--voice-isolation", command)
                    self.assertIn("--external-models", command)
                    app.mkdir()
                elif command[:2] == ["hdiutil", "create"]:
                    source = Path(command[command.index("-srcfolder") + 1])
                    self.assertEqual(stat.S_IMODE(source.stat().st_mode), 0o755)
                    self.assertEqual({entry.name for entry in source.iterdir()}, {app_name, "Applications"})
                    self.assertEqual((source / "Applications").readlink(), Path("/Applications"))
                    Path(command[-1]).write_bytes(b"test disk image")
                else:
                    self.assertEqual(command[:2], ["hdiutil", "verify"])
                    self.assertFalse(output.exists())
                    verified.append(Path(command[-1]).read_bytes())

            with patch.object(sys, "argv", [
                str(SCRIPT), "--configuration", "debug", "--voice-isolation", "--output", str(output),
            ]), patch.object(subprocess, "run", side_effect=run_command):
                runpy.run_path(str(SCRIPT), run_name="__main__")

            self.assertEqual(verified, [b"test disk image"])
            self.assertEqual(output.read_bytes(), b"test disk image")
            self.assertEqual(list(output.parent.iterdir()), [output])


if __name__ == "__main__":
    unittest.main()
