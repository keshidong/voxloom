#!/usr/bin/env python3
"""Real local-model pipeline E2E, with sampled Darwin process-tree footprint."""
import ctypes
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
REPORT = ROOT / ".build/reports"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, help="Verify engines and models inside an existing App bundle")
    arguments = parser.parse_args()
    REPORT.mkdir(parents=True, exist_ok=True)
    required = ["models/Qwen3-ASR-1.7B-4bit/model.safetensors", "models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
                ".runtime/qwen-asr-runtime/qwen-asr", ".runtime/llama-build/bin/llama-completion"]
    environment = dict(os.environ)
    stem = "qwen-e2e"
    if arguments.app:
        resources = arguments.app.resolve() / "Contents/Resources"
        required = [str(resources / name) for name in ["Qwen3-ASR-1.7B-4bit/model.safetensors",
                    "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", "qwen-asr-runtime/qwen-asr", "llama-completion"]]
        environment["VOICE_INPUT_DEMO_RESOURCES"] = str(resources)
        stem = "qwen-bundled-e2e"
    for name in required:
        if not (ROOT / name).is_file():
            raise SystemExit("Missing required local resource: " + name)
    subprocess.run(["bash", "scripts/swift-command.sh", "test", "--list-tests"], cwd=ROOT,
                   stdout=subprocess.DEVNULL, check=True)
    lib = ctypes.CDLL("/usr/lib/libproc.dylib")
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    peak, samples = 0, 0
    started = time.monotonic()
    exit_code = 0
    with (REPORT / (stem + ".log")).open("w") as log:
        # Swift Testing runs unrelated top-level suites concurrently. Separate
        # invocations keep each GPU suite isolated without weakening deadlines.
        for suite in ["QwenASRE2ETests", "QwenE2ETests"]:
            process = subprocess.Popen(["bash", "scripts/swift-command.sh", "test", "--skip-build",
                "--filter", suite], cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
            while process.poll() is None:
                rows = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
                parents = {int(parts[0]): int(parts[1]) for line in rows.splitlines() if len(parts := line.split()) == 2}
                family = {process.pid}
                while True:
                    expanded = family | {pid for pid, parent in parents.items() if parent in family}
                    if expanded == family: break
                    family = expanded
                footprint = 0
                for pid in family:
                    buffer = ctypes.create_string_buffer(4096)
                    if lib.proc_pid_rusage(pid, 4, buffer) == 0:
                        footprint += ctypes.c_uint64.from_buffer(buffer, 72).value
                peak = max(peak, footprint)
                samples += 1
                time.sleep(0.1)
            exit_code = process.returncode
            if exit_code: break
    content = (REPORT / (stem + ".log")).read_text()
    passed = list(re.finditer(r"Test run with (\d+) tests in (\d+) suites? passed", content))
    count = sum(int(match[1]) for match in passed)
    result = {"exitCode": exit_code, "passedTests": count,
              "seconds": time.monotonic() - started, "sampledProcessTreePeakBytes": peak, "samples": samples,
              "memoryMethod": "Darwin ri_phys_footprint summed across test process descendants, sampled about 100ms; shared mappings may be counted twice.",
              "host": "Apple M5 Pro / 48 GiB; this is a short pipeline smoke test, not 16 GiB / 8 GiB acceptance.",
              "execution": "GPU suites run sequentially; ordinary per-request deadlines remain enabled.",
              "scope": "Real ASR zh/en/silence, ASR-to-LLM pipeline, repeated object references, valid person references, long dictation, prompt length variations and domain words; excludes AirPods and Watch."}
    (REPORT / (stem + ".json")).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if exit_code or len(passed) != 2 or count != 6 or "skipped" in content:
        raise SystemExit("Qwen model E2E failed; inspect .build/reports/" + stem + ".log")


if __name__ == "__main__":
    main()
