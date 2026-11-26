"""Verify repeated requests against the real command and pinned Silero weights."""

import json
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
import wave


ROOT = Path(__file__).resolve().parents[2]


class VADWorkerTest(unittest.TestCase):
    def test_one_worker_loads_once_and_keeps_each_detection_independent(self):
        worker = Path(os.environ.get("VOXLOOM_VAD_WORKER", ROOT / ".runtime/whisper-build/bin/voxloom-vad"))
        model = Path(os.environ.get("VOXLOOM_VAD_MODEL", ROOT / "models/ggml-silero-v5.1.2.bin"))
        speech = ROOT / "src/business/QwenASR/Tests/Fixtures/FLEURS/fleurs-09.wav"
        with TemporaryDirectory() as scratch:
            silence = Path(scratch) / "silence with spaces.wav"
            with wave.open(str(silence), "wb") as wav:
                wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                wav.writeframes(bytes(32000))
            requests = [speech, silence, speech]
            payload = "".join(json.dumps({"audio": str(path)}) + "\n" for path in requests)
            result = subprocess.run([worker, "--model", model], input=payload, text=True,
                                    capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([json.loads(line) for line in result.stdout.splitlines()],
                         [{"ready": True}, {"speech": True}, {"speech": False}, {"speech": True}])


if __name__ == "__main__":
    unittest.main()
