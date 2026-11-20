#!/usr/bin/env python3
"""Real, local-model E2E through the shipped CLI. Never downloads resources."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
REPORTS = ROOT / ".build/reports"


def main():
    REPORTS.mkdir(parents=True, exist_ok=True)
    engine = ROOT / ".runtime/whisper-build/bin/whisper-cli"
    english = ROOT / ".runtime/whisper.cpp-1.8.2/samples/jfk.wav"
    chinese = ROOT / ".runtime/asr_zh.wav"
    resources = {
        ROOT / "models/ggml-tiny.bin": ("sha1", "bd577a113a864445d4c299885e0cb97d4ba92b5f"),
        ROOT / "models/ggml-large-v3-turbo-q5_0.bin": ("sha1", "e050f7970618a659205450ad97eb95a18d69c9ee"),
        english: ("sha256", "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e"),
        chinese: ("sha256", "46dbc998c9d1d48111267c40741dd3200f2e5bcf4075f8c4c97f4451160dce50"),
    }
    for path, (algorithm, expected) in resources.items():
        if not path.is_file():
            raise SystemExit(f"Missing {path.relative_to(ROOT)}; see README.md for installation. E2E NOT run.")
        digest = hashlib.new(algorithm)
        with path.open("rb") as file:
            for chunk in iter(lambda: file.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected:
            raise SystemExit(f"Resource checksum mismatch: {path}")
    subprocess.run(["bash", "scripts/swift-command.sh", "build", "--product", "voice-input"], cwd=ROOT, check=True)
    swift_tests = subprocess.run(["bash", "scripts/swift-command.sh", "test", "--filter",
                                  "realWhisperTranscribesAnOfflineRecordingThroughPublicAPI|realWhisperCommandLine"], cwd=ROOT,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (REPORTS / "e2e-swift.log").write_bytes(swift_tests.stdout)
    if swift_tests.returncode or b"skipped" in swift_tests.stdout or b"2 tests in" not in swift_tests.stdout:
        raise SystemExit("Real Swift API/CLI E2E did not pass both tests; see .build/reports/e2e-swift.log")

    cases = [
        ("tiny-en", "tiny", english, "en", "en", ["ask", "country"]),
        ("turbo-en", "large-v3-turbo-q5_0", english, "en", "en", ["ask", "country"]),
        ("turbo-zh", "large-v3-turbo-q5_0", chinese, "zh", "zh", ["交易", "停滞"]),
        ("turbo-auto-zh", "large-v3-turbo-q5_0", chinese, "auto", "zh", ["交易", "停滞"]),
    ]
    results = []
    for name, model, audio, language, expected_language, words in cases:
        arguments = [str(ROOT / ".build/debug/voice-input"), "transcribe", str(audio),
                     "--engine", str(engine), "--model", str(ROOT / f"models/ggml-{model}.bin"),
                     "--language", language, "--cpu", "--json"]
        started = time.perf_counter()
        process = subprocess.run(arguments, cwd=ROOT, capture_output=True, timeout=150)
        elapsed = time.perf_counter() - started
        transcript = json.loads(process.stdout) if process.returncode == 0 else {}
        passed = (process.returncode == 0 and transcript.get("language") == expected_language
                  and all(word in transcript.get("text", "").lower() for word in words))
        results.append({"scenario": name, "passed": passed, "exitCode": process.returncode,
                        "transcript": transcript, "elapsedSeconds": round(elapsed, 3)})
        # Only public fixtures are transcribed by this script.
        print(name, "PASS" if passed else "FAIL", f"{elapsed:.3f}s", transcript.get("text", ""))
    report = {"platform": platform.platform(), "mode": "CPU, 4 threads, new process per utterance",
              "swiftE2E": "2/2 passed", "scenarios": results,
              "limitations": "Public short recordings; no accuracy corpus, microphone, Watch, or memory-budget acceptance. System file cache not cleared; timings are not latency benchmarks."}
    (REPORTS / "e2e.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    if not all(result["passed"] for result in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
