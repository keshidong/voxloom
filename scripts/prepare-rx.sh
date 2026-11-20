#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_dir="$project_root/.runtime"
mkdir -p "$runtime_dir"
archive="$runtime_dir/RxSwift-6.10.2.tar.gz"
if [ ! -f "$archive" ]; then
    curl --fail --location --retry 2 --connect-timeout 15 \
        https://github.com/ReactiveX/RxSwift/archive/refs/tags/6.10.2.tar.gz --output "$archive.part"
    mv "$archive.part" "$archive"
fi
if [ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" != f5055592dc82b736b37701a8dbd0ff11be20be3536ab0fd0ddc7ed1c5cd4ed79 ]; then
    printf '%s\n' 'RxSwift archive checksum mismatch' >&2
    exit 1
fi
if [ ! -f "$runtime_dir/RxSwift-6.10.2/Package.swift" ]; then tar -xzf "$archive" -C "$runtime_dir"; fi
