from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("test-swift.sh")


class SwiftTestGroups(unittest.TestCase):
    def test_module_tests_run_in_separate_processes_and_keep_existing_exclusions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
            (scripts / "swift-command.sh").write_text(r'''#!/bin/bash
set -euo pipefail
if [ "${2:-}" = list ]; then
    cat <<'EOF'
AudioTests.AudioCodecTests/wavRoundTrip()
CaptureTests.PCMConverterTests/convertsMicrophoneAudio()
E2EOnly.WhisperE2ETests/realModel()
DesktopTests.DemoWindowTests/opens()
VoxloomDesktopTests.VoxloomApplicationTests/opens()
VoxloomDesktopTests.VoxloomDraftApplicationTests/edits()
VoxloomDesktopTests.VoxloomPanelTests/expands()
EOF
    exit
fi
printf '%s\n' "$*" >> invocations
printf '%s\n' 'Test run with 1 test in 1 suite passed'
''')
            subprocess.run(["bash", scripts / SCRIPT.name], cwd=root, check=True, capture_output=True)
            invocations = (root / "invocations").read_text().splitlines()

        self.assertEqual(len(invocations), 6)
        self.assertIn(r"--filter ^AudioTests\.", invocations[0])
        self.assertIn(r"--filter ^CaptureTests\.", invocations[1])
        for line in invocations[:2]:
            self.assertIn("--skip WhisperE2ETests|", line)
        for line, suite in zip(invocations[2:], ["DemoWindowTests", "VoxloomApplicationTests",
                                                "VoxloomDraftApplicationTests", "VoxloomPanelTests"]):
            self.assertIn(f"{suite}/", line)
