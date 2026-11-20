#!/usr/bin/env python3
"""Run colocated Python protocol tests; gate owned worker line coverage."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
REPORT = ROOT / ".build/reports"


def main():
    REPORT.mkdir(parents=True, exist_ok=True)
    covers = ROOT / ".build/python-coverage"
    with (REPORT / "python-tests.log").open("w") as output:
        result = subprocess.run([sys.executable, "-m", "trace", "--count", "--missing", "--summary", "--coverdir", str(covers),
            "src/business/QwenASR/Runtime/Tests/test_worker.py"], cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit((REPORT / "python-tests.log").read_text())
    log = (REPORT / "python-tests.log").read_text()
    ran = re.search(r"Ran (\d+) tests", log)
    if not ran or int(ran[1]) != 2 or "\nOK\n" not in log:
        raise SystemExit("Expected two successful Python protocol tests")
    cover = next(covers.glob("*qwen_asr_worker.cover"))
    rows = cover.read_text().splitlines()
    covered = sum(bool(re.match(r"\s*\d+: ", row)) for row in rows)
    missed = sum(row.startswith(">>>>>>") for row in rows)
    total = covered + missed
    percent = 100 * covered / total
    report = {"tests": int(ran[1]), "file": "src/business/QwenASR/Runtime/qwen_asr_worker.py",
              "coveredLines": covered, "executableLines": total, "linePercent": percent,
              "threshold": 90, "gatePassed": percent >= 90, "branchCoverage": None,
              "scope": "Python stdlib trace; real MLX is replaced at model boundary. Real-model E2E excluded."}
    (REPORT / "python-coverage.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not report["gatePassed"]:
        raise SystemExit("Python worker coverage gate failed")


if __name__ == "__main__":
    main()
