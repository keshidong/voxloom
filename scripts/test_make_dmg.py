from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().with_name("make-dmg.py")


class DiskImagePackagingTest(unittest.TestCase):
    def test_debug_image_stages_app_and_install_shortcut(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "distribution" / "Voxloom-debug.dmg"
            app_name = "Voxloom Debug.app"
            verified = []
            layouts = []

            def build_disk_image(image, volume_name, *, settings):
                self.assertEqual(volume_name, "Voxloom Debug")
                self.assertEqual(Path(settings["files"][0]).name, app_name)
                self.assertTrue(Path(settings["files"][0]).is_dir())
                self.assertEqual(Path(settings["icon"]), Path(settings["files"][0]) / "Contents/Resources/AppIcon.icns")
                self.assertEqual(Path(settings["icon"]).read_bytes(), b"app icon")
                self.assertEqual(settings["symlinks"], {"Applications": "/Applications"})
                self.assertTrue(Path(settings["background"]).is_file())
                self.assertEqual(settings["default_view"], "icon-view")
                app_location = settings["icon_locations"][app_name]
                applications_location = settings["icon_locations"]["Applications"]
                self.assertLess(app_location[0], applications_location[0])
                self.assertEqual(app_location[1], applications_location[1])
                layouts.append(settings)
                Path(image).write_bytes(b"test disk image")

            def run_command(command, **kwargs):
                if command[0] == sys.executable:
                    self.assertEqual(command[1:4], ["scripts/package-app.py", "--configuration", "debug"])
                    app = Path(command[command.index("--output") + 1])
                    self.assertEqual(app.name, app_name)
                    self.assertIn("--voice-isolation", command)
                    self.assertIn("--external-models", command)
                    self.assertEqual(command[command.index("--version") + 1], "0.1.2")
                    self.assertEqual(command[command.index("--build-number") + 1], "14")
                    resources = app / "Contents/Resources"
                    resources.mkdir(parents=True)
                    (resources / "AppIcon.icns").write_bytes(b"app icon")
                else:
                    self.assertEqual(command[:2], ["hdiutil", "verify"])
                    self.assertFalse(output.exists())
                    verified.append(Path(command[-1]).read_bytes())

            with patch.object(sys, "argv", [
                str(SCRIPT), "--configuration", "debug", "--voice-isolation", "--output", str(output),
                "--version", "0.1.2", "--build-number", "14",
            ]), patch.object(subprocess, "run", side_effect=run_command), \
                    patch.dict(sys.modules, dmgbuild=SimpleNamespace(build_dmg=build_disk_image)):
                runpy.run_path(str(SCRIPT), run_name="__main__")

            self.assertEqual(len(layouts), 1, "installer must have a Finder layout")
            self.assertEqual(verified, [b"test disk image"])
            self.assertEqual(output.read_bytes(), b"test disk image")
            self.assertEqual(list(output.parent.iterdir()), [output])


if __name__ == "__main__":
    unittest.main()
