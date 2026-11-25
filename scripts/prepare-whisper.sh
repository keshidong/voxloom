#!/bin/bash
# Setup only. Runtime recognition never downloads models or sends audio anywhere.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
model_name="${1:-tiny}"
case "$model_name" in
    tiny) model_sha=bd577a113a864445d4c299885e0cb97d4ba92b5f ;;
    base) model_sha=465707469ff3a37a2b9b8d8f89f2f99de7299dac ;;
    large-v3-turbo-q5_0) model_sha=e050f7970618a659205450ad97eb95a18d69c9ee ;;
    silero-v5.1.2) model_sha=a372f48dcf0bd9e4330eef2802bc46e061c19634 ;;
    --runtime-only) ;;
    *) printf '%s\n' 'Usage: bash scripts/prepare-whisper.sh [tiny|base|large-v3-turbo-q5_0|silero-v5.1.2|--runtime-only]' >&2; exit 2 ;;
esac
runtime_dir="$project_root/.runtime"
mkdir -p "$runtime_dir" "$project_root/models"

# Keep tools, source, and models inside this workspace. No sudo or global install.
if command -v cmake >/dev/null 2>&1; then
    cmake_bin="$(command -v cmake)"
else
    cmake_version=4.1.3
    cmake_archive="cmake-$cmake_version-macos-universal.tar.gz"
    cmake_bin="$runtime_dir/cmake-$cmake_version-macos-universal/CMake.app/Contents/bin/cmake"
    if [ ! -x "$cmake_bin" ]; then
        curl --fail --location --retry 2 --connect-timeout 15 \
            "https://github.com/Kitware/CMake/releases/download/v$cmake_version/$cmake_archive" \
            --output "$runtime_dir/$cmake_archive.part"
        mv "$runtime_dir/$cmake_archive.part" "$runtime_dir/$cmake_archive"
        tar -xzf "$runtime_dir/$cmake_archive" -C "$runtime_dir"
    fi
fi

whisper_version=1.8.2
whisper_source="$runtime_dir/whisper.cpp-$whisper_version"
if [ ! -d "$whisper_source" ]; then
    curl --fail --location --retry 2 --connect-timeout 15 \
        "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$whisper_version.tar.gz" \
        --output "$runtime_dir/whisper-source.tar.gz.part"
    mv "$runtime_dir/whisper-source.tar.gz.part" "$runtime_dir/whisper-source.tar.gz"
    tar -xzf "$runtime_dir/whisper-source.tar.gz" -C "$runtime_dir"
fi
"$cmake_bin" -S "$whisper_source" -B "$runtime_dir/whisper-build" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
"$cmake_bin" --build "$runtime_dir/whisper-build" --config Release --target whisper-cli vad-speech-segments -j 4
if [ "$model_name" = --runtime-only ]; then
    exit 0
fi

model_path="$project_root/models/ggml-$model_name.bin"
model_repository="ggerganov/whisper.cpp"
if [ "$model_name" = silero-v5.1.2 ]; then model_repository="ggml-org/whisper-vad"; fi
if [ ! -f "$model_path" ] || [ "$(shasum "$model_path" | cut -d ' ' -f 1)" != "$model_sha" ]; then
    curl --fail --location --retry 2 --connect-timeout 15 \
        "https://huggingface.co/$model_repository/resolve/main/ggml-$model_name.bin?download=true" \
        --output "$model_path.part"
    actual_sha="$(shasum "$model_path.part" | cut -d ' ' -f 1)"
    if [ "$actual_sha" != "$model_sha" ]; then
        printf '%s\n' 'Model checksum mismatch; partial download retained for inspection.' >&2
        exit 1
    fi
    mv "$model_path.part" "$model_path"
fi
printf 'Whisper: %s\nModel: %s\n' "$runtime_dir/whisper-build/bin/whisper-cli" "$model_path"
