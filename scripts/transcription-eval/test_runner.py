"""Exercise the evaluation CLI with controlled ASR and correction process replies."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import wave


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / ".build/reports/bilingual-eval/transcription-eval"


class EvaluationRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.manifest = self.directory / "manifest.json"
        self.asr_report = self.directory / "asr.json"
        self.correction_report = self.directory / "correction.json"

        audio = self.directory / "test.wav"
        with wave.open(str(audio), "wb") as wav:
            wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            wav.writeframes(b"\x01\x01" * 160)
        self.manifest.write_text(json.dumps({"clips": [
            {"id": "one", "audio": str(audio), "reference": "hello world", "language": "en", "group": "en"},
        ]}), encoding="utf-8")

        for weight in ("Qwen3-ASR-1.7B-4bit/model.safetensors", "ggml-large-v3-turbo-q5_0.bin",
                       "ggml-silero-v5.1.2.bin", "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"):
            path = self.directory / weight
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        self.write_executable("qwen-asr-runtime/qwen-asr", """\
printf '%s\\n' '{"ready":true}'
while IFS= read -r request; do
  case "$request" in
    *'"language":"auto"'*) printf '%s\\n' '{"text":"hello word","language":"en"}';;
    *) exit 1;;
  esac
done
""")
        self.write_executable("whisper-cli", """\
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output-file ]; then prefix="$2"; fi
  shift
done
printf '%s\\n' '{"model":{"multilingual":true},"params":{"translate":false},"result":{"language":"en"},"transcription":[{"text":"hello world"}]}' > "$prefix.json"
""")
        self.write_executable("llama-completion", "printf '%s\\n' '{\"edits\":[{\"from\":\"word\",\"to\":\"world\"}]}'\n")

    def write_executable(self, name, body):
        path = self.directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nset -eu\n" + body, encoding="utf-8")
        path.chmod(0o700)

    def evaluate(self, stage, source, destination):
        return subprocess.run([str(RUNNER), stage, str(source), str(self.directory), str(destination)],
                              check=False, capture_output=True, text=True, timeout=20)

    def test_asr_scores_each_model_against_the_same_reference(self):
        run = self.evaluate("asr", self.manifest, self.asr_report)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(self.asr_report.is_file(), "ASR phase did not publish a report")
        report = json.loads(self.asr_report.read_text())
        self.assertEqual(report["recognitionLanguage"], "auto")
        self.assertTrue(report["complete"])
        self.assertEqual({row["model"]: row["score"]["edits"] for row in report["observations"]},
                         {"qwen3-asr-1.7b-4bit": 1, "whisper-large-v3-turbo-q5_0": 0})
        self.assertNotIn("hello", run.stdout + run.stderr)

    def test_correction_uses_frozen_qwen_text_and_scores_the_change(self):
        asr = self.evaluate("asr", self.manifest, self.asr_report)
        self.assertEqual(asr.returncode, 0, asr.stderr)
        frozen_input = self.asr_report.read_bytes()
        self.manifest.unlink()
        self.write_executable("qwen-asr-runtime/qwen-asr", "exit 1\n")
        run = self.evaluate("correction", self.asr_report, self.correction_report)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(self.correction_report.is_file(), "Correction phase did not publish a report")
        report = json.loads(self.correction_report.read_text())
        self.assertEqual(self.asr_report.read_bytes(), frozen_input)
        self.assertTrue(report["complete"])
        row, = report["observations"]
        self.assertEqual((row["original"], row["corrected"]), ("hello word", "hello world"))
        self.assertEqual(row["score"]["comparison"], "improved")
        self.assertNotIn("hello", run.stdout + run.stderr)

    def test_failed_asr_is_preserved_through_the_correction_report(self):
        (self.directory / "test.wav").unlink()
        asr = self.evaluate("asr", self.manifest, self.asr_report)
        self.assertEqual(asr.returncode, 1)
        asr_results = json.loads(self.asr_report.read_text())
        self.assertTrue(asr_results["complete"])
        self.assertEqual(len(asr_results["observations"]), 2)
        self.assertTrue(all(row.get("failure") and "score" not in row for row in asr_results["observations"]))

        correction = self.evaluate("correction", self.asr_report, self.correction_report)
        self.assertEqual(correction.returncode, 1)
        results = json.loads(self.correction_report.read_text())
        self.assertTrue(results["complete"])
        row, = results["observations"]
        self.assertEqual(row["status"], "unavailableASR")
        self.assertNotIn("score", row)
        self.assertEqual(results["summaries"][0]["unavailableASR"], 1)

    def test_correction_dataset_scores_published_hypotheses_without_running_asr(self):
        self.write_executable("qwen-asr-runtime/qwen-asr", "exit 1\n")
        self.write_executable("whisper-cli", "exit 1\n")
        self.manifest.write_text(json.dumps({"clips": [
            {"id": "public-example", "group": "en", "reference": "hello world", "transcript": "hello word"},
        ]}), encoding="utf-8")

        run = self.evaluate("correction-dataset", self.manifest, self.correction_report)

        self.assertEqual(run.returncode, 0, run.stderr)
        report = json.loads(self.correction_report.read_text())
        self.assertTrue(report["complete"])
        self.assertEqual(report["datasetManifest"], str(self.manifest))
        self.assertNotIn("asrModel", report)
        row, = report["observations"]
        self.assertEqual((row["original"], row["corrected"]), ("hello word", "hello world"))
        self.assertEqual(row["score"]["comparison"], "improved")

    def test_correction_rejects_an_incomplete_qwen_checkpoint(self):
        self.asr_report.write_text(json.dumps({
            "formatVersion": 1, "manifest": str(self.manifest), "recognitionLanguage": "auto",
            "expectedClips": 1, "models": ["qwen3-asr-1.7b-4bit"], "complete": False,
            "observations": [], "summaries": [],
        }), encoding="utf-8")
        correction = self.evaluate("correction", self.asr_report, self.correction_report)
        self.assertEqual(correction.returncode, 1)
        self.assertIn("incompleteASRInput", correction.stderr)
        self.assertFalse(self.correction_report.exists())


if __name__ == "__main__":
    unittest.main()
