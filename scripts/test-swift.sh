#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p .build/reports

run_group() {
    local group="$1"
    local log=".build/reports/swift-${group}.log"
    shift
    bash scripts/swift-command.sh test "$@" 2>&1 | tee "$log"
    # SwiftPM can return zero if its test host exits before completing the run.
    if ! grep -Eq 'Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed' "$log"; then
        printf 'Swift tests did not finish successfully in group %s. See %s\n' "$group" "$log" >&2
        return 1
    fi
}

run_group modules --skip 'WhisperE2ETests|QwenE2ETests|QwenASRE2ETests|QwenCorrectionCorpusE2ETests|realWhisperCommandLine|VoxloomApplicationTests|VoxloomPanelTests'
run_group desktop-application --skip-build --no-parallel --filter VoxloomApplicationTests
run_group desktop-panel --skip-build --no-parallel --filter VoxloomPanelTests
