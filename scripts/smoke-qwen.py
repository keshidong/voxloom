#!/usr/bin/env python3
"""Real local-model pipeline E2E, with sampled Darwin process-tree footprint."""
import ctypes
import json
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
REPORT = ROOT / ".build/reports"


def main():
    REPORT.mkdir(parents=True, exist_ok=True)
    required = ["models/Qwen3-ASR-1.7B-4bit/model.safetensors", "models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
                ".runtime/qwen-asr-runtime/qwen-asr", ".runtime/llama-build/bin/llama-completion"]
    for name in required:
        if not (ROOT / name).is_file():
            raise SystemExit("Missing required local resource: " + name)
    subprocess.run(["bash", "scripts/swift-command.sh", "test", "--list-tests"], cwd=ROOT,
                   stdout=subprocess.DEVNULL, check=True)
    lib = ctypes.CDLL("/usr/lib/libproc.dylib")
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    peak, samples = 0, 0
    started = time.monotonic()
    with (REPORT / "qwen-e2e.log").open("w") as log:
        process = subprocess.Popen(["bash", "scripts/swift-command.sh", "test", "--skip-build",
            "--filter", "QwenASRE2ETests|QwenE2ETests"], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        while process.poll() is None:
            rows = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
            parents = {int(parts[0]): int(parts[1]) for line in rows.splitlines() if len(parts := line.split()) == 2}
            family = {process.pid}
            while True:
                expanded = family | {pid for pid, parent in parents.items() if parent in family}
                if expanded == family:
                    break
                family = expanded
            footprint = 0
            for pid in family:
                buffer = ctypes.create_string_buffer(4096)
                if lib.proc_pid_rusage(pid, 4, buffer) == 0:
                    # Darwin rusage_info_v0 prefix: uuid[16], followed by
                    # user/system/wakeups/pageins/wired/resident/phys_footprint.
                    footprint += ctypes.c_uint64.from_buffer(buffer, 72).value
            peak = max(peak, footprint)
            samples += 1
            time.sleep(0.1)
    content = (REPORT / "qwen-e2e.log").read_text()
    passed = re.search(r"Test run with (\d+) tests in (\d+) suites passed", content)
    result = {"exitCode": process.returncode, "passedTests": int(passed[1]) if passed else 0,
              "seconds": time.monotonic() - started, "sampledProcessTreePeakBytes": peak, "samples": samples,
              "memoryMethod": "Darwin ri_phys_footprint summed across test process descendants, sampled about 100ms; shared mappings may be counted twice.",
              "host": "Apple M5 Pro / 48 GiB; this is a short pipeline smoke test, not 16 GiB / 8 GiB acceptance.",
              "scope": "Real resident ASR zh/en/silence, real domain correction, real ASR-to-LLM pipeline; excludes AirPods and Watch."}
    (REPORT / "qwen-e2e.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if process.returncode or not passed or int(passed[1]) != 3 or "skipped" in content:
        raise SystemExit("Qwen model E2E failed; inspect .build/reports/qwen-e2e.log")


if __name__ == "__main__":
    main()
