from pathlib import Path
import subprocess
import sys
import unittest


class VoiceIsolationPackagingTest(unittest.TestCase):
    def test_cannot_bundle_isolation_in_legacy_demo(self):
        package = Path(__file__).resolve().parents[1] / "make-demo.py"
        result = subprocess.run([sys.executable, str(package), "--voice-isolation", "--product", "voice-demo"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--voice-isolation requires --product voxloom", result.stderr)
