"""Worker protocol contracts; MLX is replaced only at the external model boundary."""
import importlib.util
import io
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

WORKER = Path(__file__).resolve().parents[1] / "qwen_asr_worker.py"
spec = importlib.util.spec_from_file_location("qwen_asr_worker", WORKER)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class Model:
    def __init__(self):
        self.calls = []

    def generate(self, audio, **options):
        self.calls.append((audio, options))
        if audio == "failure":
            raise ValueError("model failure")
        return types.SimpleNamespace(text="本地转写", language=["", "Chinese"] if audio == "zh" else "English")


class WorkerTests(unittest.TestCase):
    def run_worker(self, requests, load_error=False):
        model, output = Model(), io.StringIO()
        def load_model(path):
            self.assertEqual(path, "/local/model")
            if load_error:
                raise ValueError("bad model")
            return model
        modules = {"mlx": types.ModuleType("mlx"), "mlx.core": types.ModuleType("mlx.core"),
                   "mlx_audio": types.ModuleType("mlx_audio"), "mlx_audio.stt": types.ModuleType("mlx_audio.stt"),
                   "mlx_audio.stt.utils": types.ModuleType("mlx_audio.stt.utils")}
        modules["mlx.core"].clear_cache = lambda: None
        modules["mlx_audio.stt.utils"].load_model = load_model
        with patch.dict(sys.modules, modules), patch.object(sys, "argv", ["worker", "--model", "/local/model"]), \
             patch.object(sys, "stdin", io.StringIO("\n".join(requests))), patch.object(sys, "__stdout__", output):
            status = worker.main()
        return status, [json.loads(line) for line in output.getvalue().splitlines()], model.calls

    def test_local_protocol_preserves_language_and_vocabulary_and_recovers_after_invalid_requests(self):
        requests = [json.dumps({"audio": "zh", "language": "zh", "context": "预付费 USD"}),
                    json.dumps({"audio": "en", "language": "auto"}),
                    json.dumps({"audio": "en", "language": "en"}),
                    "{", "x" * 65537,
                    json.dumps({"audio": "zh", "language": "zh", "context": "x" * 4097}),
                    json.dumps({"audio": "failure", "language": "zh"})]
        status, results, calls = self.run_worker(requests)
        self.assertEqual(status, 0)
        self.assertEqual(results[0], {"ready": True})
        self.assertEqual(results[1], {"text": "本地转写", "language": "zh"})
        self.assertEqual(results[2]["language"], "en")
        self.assertEqual(calls[0][1]["system_prompt"], "预付费 USD")
        self.assertIsNone(calls[1][1]["language"])
        self.assertIsNone(calls[1][1]["system_prompt"])
        self.assertEqual(results[4:], [{"error": "inference_failed"}] * 4)

    def test_model_failure_is_reported_before_accepting_audio(self):
        status, results, calls = self.run_worker([], load_error=True)
        self.assertEqual(status, 1)
        self.assertEqual(results, [{"ready": False}])
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main(module=types.SimpleNamespace(WorkerTests=WorkerTests))
