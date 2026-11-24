#!/bin/bash
set -euo pipefail
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--prepare-only" ]; }; then
    echo "Usage: $0 [--prepare-only]" >&2
    exit 2
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
bash scripts/prepare-rx.sh
for model_name in tiny base large-v3-turbo-q5_0 silero-v5.1.2; do bash scripts/prepare-whisper.sh "$model_name"; done
sample_path="$project_root/.runtime/asr_zh.wav"
if [ ! -f "$sample_path" ] || [ "$(shasum -a 256 "$sample_path" | cut -d ' ' -f 1)" != 46dbc998c9d1d48111267c40741dd3200f2e5bcf4075f8c4c97f4451160dce50 ]; then
    curl --fail --location --retry 2 --connect-timeout 15 \
        https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen3-ASR-Repo/asr_zh.wav --output "$sample_path.part"
    [ "$(shasum -a 256 "$sample_path.part" | cut -d ' ' -f 1)" = 46dbc998c9d1d48111267c40741dd3200f2e5bcf4075f8c4c97f4451160dce50 ]
    mv "$sample_path.part" "$sample_path"
fi
python3 scripts/prepare-qwen.py
if [ "$#" -eq 0 ]; then
    python3 scripts/make-demo.py
fi
