#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

output="$root/.build/reports/bilingual-eval/transcription-eval"
mkdir -p "$(dirname "$output")"
bash scripts/swift-command.sh build -c release --product voxloom >&2
build="$(bash scripts/swift-command.sh build -c release --show-bin-path)"
scoring=src/business/QwenASR/Tests/AccuracyScoring
scratch="$(mktemp -d "$(dirname "$output")/build.XXXXXXXX")"
trap 'rm -f "$scratch/transcription-eval"; rmdir "$scratch"' EXIT
swiftc -O -swift-version 6 -parse-as-library -module-name VoxloomTranscriptionEval -I "$build/Modules" \
    -module-cache-path "$root/.build/module-cache" -target "$(uname -m)-apple-macosx14.0" \
    scripts/transcription-eval/*.swift "$scoring/ASRAccuracy.swift" "$scoring/CorrectionAccuracy.swift" \
    "$build/SpeechFoundation.build/"*.swift.o "$build/SpeechInput.build/"*.swift.o \
    "$build/RxSwift.build/"*.swift.o -o "$scratch/transcription-eval"
mv "$scratch/transcription-eval" "$output"
rmdir "$scratch"
trap - EXIT

if [[ $# -eq 1 && "$1" == build ]]; then
    printf '%s\n' "$output"
else
    exec "$output" "$@"
fi
