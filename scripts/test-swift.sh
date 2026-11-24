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

module_exclusions='WhisperE2ETests|QwenE2ETests|QwenASRE2ETests|QwenCorrectionCorpusE2ETests|realWhisperCommandLine|DemoWindowTests|VoxloomApplicationTests|VoxloomDraftApplicationTests|VoxloomPanelTests'
test_list="$(bash scripts/swift-command.sh test list)"
targets="$(printf '%s\n' "$test_list" | awk -F. -v skip="$module_exclusions" \
    '$0 !~ skip && /^[[:alnum:]_]+\.[[:alnum:]_]+\// { print $1 }' | sort -u)"
if [ -z "$targets" ]; then
    printf '%s\n' 'No Swift module tests were discovered.' >&2
    exit 1
fi

while IFS= read -r target; do
    run_group "$target" --skip-build --no-parallel --filter "^${target}\\." --skip "$module_exclusions"
done <<< "$targets"

run_group demo-window --skip-build --no-parallel --filter '^DesktopTests\.DemoWindowTests/'
run_group desktop-application --skip-build --no-parallel --filter '^VoxloomDesktopTests\.VoxloomApplicationTests/'
run_group desktop-draft --skip-build --no-parallel --filter '^VoxloomDesktopTests\.VoxloomDraftApplicationTests/'
run_group desktop-panel --skip-build --no-parallel --filter '^VoxloomDesktopTests\.VoxloomPanelTests/'
