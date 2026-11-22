#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p .build/reports

report_failure() {
    local group="$1"
    local log="$2"
    printf 'Swift tests did not finish successfully in group %s. See %s\n' "$group" "$log" >&2
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        local details
        details="$(grep -Em 10 '✘|[Ee]rror:|[Ff]ailed' "$log" || true)"
        details="${details:-$(tail -n 4 "$log")}"
        if [ "$group" = desktop-sample ]; then
            local crash
            crash="$(python3 - <<'PY'
import json
from pathlib import Path
import time

root = Path.home() / "Library/Logs/DiagnosticReports"
for path in sorted(root.glob("swiftpm-testing-helper*.ips"), key=lambda item: item.stat().st_mtime, reverse=True)[:1]:
    if time.time() - path.stat().st_mtime >= 180:
        continue
    with path.open() as source:
        source.readline()
        report = json.load(source)
    fault = report.get("faultingThread")
    print(report.get("exception", {}).get("signal", "unknown signal"))
    if fault is not None:
        for frame in report["threads"][fault]["frames"][:14]:
            binary = report["usedImages"][frame["imageIndex"]]["name"]
            print(binary, frame.get("symbol", frame.get("imageOffset", "")))
PY
)"
            details="$details
$crash"
        fi
        details="${details//%/%25}"
        details="${details//$'\r'/%0D}"
        details="${details//$'\n'/%0A}"
        printf '::error title=Swift tests (%s)::%s\n' "$group" "${details:-No test summary was produced.}"
    fi
}

run_group() {
    local group="$1"
    local log=".build/reports/swift-${group}.log"
    shift
    bash scripts/swift-command.sh test "$@" 2>&1 | tee "$log" || {
        local result=$?
        report_failure "$group" "$log"
        return "$result"
    }
    # SwiftPM can return zero if its test host exits before completing the run.
    if ! grep -Eq 'Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed' "$log"; then
        report_failure "$group" "$log"
        return 1
    fi
}

run_group modules --no-parallel --skip 'WhisperE2ETests|QwenE2ETests|QwenASRE2ETests|QwenCorrectionCorpusE2ETests|realWhisperCommandLine|DemoWindowTests|VoxloomApplicationTests|VoxloomSampleApplicationTests|VoxloomPanelTests'
run_group demo-window --skip-build --no-parallel --filter '^DesktopTests\.DemoWindowTests/'
run_group desktop-application --skip-build --no-parallel --filter '^VoxloomDesktopTests\.VoxloomApplicationTests/'
run_group desktop-sample --skip-build --no-parallel --filter '^VoxloomDesktopTests\.VoxloomSampleApplicationTests/'
run_group desktop-panel --skip-build --no-parallel --filter '^VoxloomDesktopTests\.VoxloomPanelTests/'
